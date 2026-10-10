"""The browser behind web lookups: a fresh, signed-out, download-less Chromium behind a proxy.

No browser is launched and no network is touched: Playwright is replaced at the `start` seam
with a hand-written fake, which is also the only way to see what the reader asked Chromium for.
What the browser can REACH is not tested here (a fake cannot say) but in
`test_web_proxy_browser.py` with a real Chromium. The rules pinned here are about what it must be:

**Never the signed-in profile.** `data/browser` holds the university session cookies; a web page
must not be able to ride on them. The reader launches a plain browser and opens a new, empty
context - `launch_persistent_context` is never called.

**Always behind the filtering proxy.** The browser is launched with the proxy as its only way
out, and nothing is filtered inside the browser (a route guard there does not see redirects).
Downloads and service workers are off.

**Nothing started until there is a page to read, and nothing kept after.** Every page gets its
own throwaway browser, opened and closed around that one read - even when it fails - and the
pages of one lookup are read at the same time, so a page that hangs costs its own time limit.
A page that outlasts the whole batch's deadline (a script that spins forever) is given up on, so
the lookup always returns.

**A page is only "read" when it is a real page:** HTML, a successful status, and some text.
Anything else is `None`, so the lookup moves on.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

import pytest

from pli.browser import SessionError
from pli.web import (
    _BOXES_JS,
    _LINKS_JS,
    MAX_BOXES,
    MAX_LINKS,
    PAGE_TIMEOUT_MS,
    SETTLE_MS,
    ChromiumReader,
    WebError,
    WebLink,
    WebPage,
)

PUBLIC = "https://example.org/"
PROXY_URL = "http://127.0.0.1:55555"


# --- a hand-written Playwright --------------------------------------------------------------


class FakeResponse:
    def __init__(self, status: int = 200, content_type: str = "text/html; charset=utf-8") -> None:
        self.ok = 200 <= status < 300
        self.headers = {"content-type": content_type}


class FakePage:
    def __init__(self, context: FakeContext, spec: dict[str, Any]) -> None:
        self._context, self.spec = context, spec
        self.url = "about:blank"

    def goto(self, url: str, **kwargs: Any) -> FakeResponse | None:
        self._context.visited.append((url, kwargs))
        if self.spec.get("barrier"):
            self.spec["barrier"].wait()  # raises BrokenBarrierError if the others never arrive
        if self.spec.get("hang") == url:
            threading.Event().wait(30)  # a page that never answers
        time.sleep(self.spec.get("slow", {}).get(url, 0))
        if self.spec.get("goto_error"):
            raise RuntimeError(self.spec["goto_error"])
        self.url = self.spec.get("final_url", url)
        return self.spec.get("response", FakeResponse())

    def fill(self, selector: str, text: str, **kwargs: Any) -> None:
        self._context.actions.append(("fill", selector, text))
        self._context.strict.append(bool(kwargs.get("strict")))
        if self.spec.get("fill_error"):
            raise RuntimeError("the box would not take text")

    def press(self, selector: str, key: str, **kwargs: Any) -> None:
        self._context.actions.append(("press", selector, key))
        self._context.strict.append(bool(kwargs.get("strict")))
        if self.spec.get("press_error"):
            raise RuntimeError("the key press failed")
        if self.spec.get("hang_press"):
            threading.Event().wait(30)
        self.url = self.spec.get("results_url", self.url)

    def wait_for_load_state(self, state: str, **kwargs: Any) -> None:
        if self.spec.get("load_state_error"):
            raise RuntimeError("no load event")

    def wait_for_timeout(self, ms: float) -> None:
        self._context.actions.append(("wait", str(int(ms))))

    def evaluate(self, script: str, *args: Any) -> Any:
        if script is _BOXES_JS:
            if self.spec.get("boxes_error"):
                raise RuntimeError("the page would not list its boxes")
            return self.spec.get("boxes", [])
        if script is _LINKS_JS:
            if self.spec.get("links_error"):
                raise RuntimeError("the page would not list its links")
            return self.spec.get("links", [])
        if self.spec.get("evaluate_error"):
            raise RuntimeError("evaluation failed")
        return self.spec.get("text", "Some page text.")

    def title(self) -> str:
        return self.spec.get("title", "A title")


class FakeRoute:
    def __init__(self, method: str) -> None:
        self.request = type("Request", (), {"method": method})()
        self.outcome = ""

    def continue_(self) -> None:
        self.outcome = "continue"

    def abort(self, reason: str = "") -> None:
        self.outcome = "abort"


class FakeContext:
    """Records `route` handlers: reading a page installs none, typing installs the GET-only one."""

    def __init__(self, options: dict[str, Any], spec: dict[str, Any]) -> None:
        self.options, self.spec = options, spec
        self.visited: list[tuple[str, dict[str, Any]]] = []
        self.actions: list[tuple[str, ...]] = []
        self.routes: list[Callable[[Any], None]] = []
        self.strict: list[bool] = []

    def route(self, pattern: str, handler: Callable[[Any], None]) -> None:
        assert pattern == "**/*"
        self.routes.append(handler)

    def new_page(self) -> FakePage:
        if self.spec.get("new_page_error"):
            raise RuntimeError("the tab crashed")
        return FakePage(self, self.spec)


class FakeBrowser:
    def __init__(self, spec: dict[str, Any]) -> None:
        self.spec = spec
        self.contexts: list[FakeContext] = []
        self.closed = False

    def new_context(self, **options: Any) -> FakeContext:
        context = FakeContext(options, self.spec)
        self.contexts.append(context)
        return context

    def close(self) -> None:
        self.closed = True


class FakeChromium:
    def __init__(self, spec: dict[str, Any]) -> None:
        self.spec = spec
        self.launched: list[dict[str, Any]] = []
        self.browsers: list[FakeBrowser] = []
        self._lock = threading.Lock()

    def launch(self, **options: Any) -> FakeBrowser:
        with self._lock:
            self.launched.append(options)
            failing = len(self.launched) <= self.spec.get("launch_failures", 0)
            if failing or self.spec.get("launch_error"):
                raise RuntimeError(self.spec.get("launch_error", "Executable doesn't exist"))
            browser = FakeBrowser(self.spec)
            self.browsers.append(browser)
            return browser

    def launch_persistent_context(self, *args: Any, **kwargs: Any) -> None:
        raise AssertionError("the signed-in profile must never be used for the web")


class FakePlaywright:
    def __init__(self, spec: dict[str, Any]) -> None:
        self.chromium = FakeChromium(spec)
        self.stopped = 0

    def stop(self) -> None:
        self.stopped += 1


class FakeProxy:
    """Stands in for `FilteringProxy`: a context manager with a URL, remembering its use."""

    entered = 0
    exited = 0
    url = PROXY_URL

    def __enter__(self) -> FakeProxy:
        type(self).entered += 1
        return self

    def __exit__(self, *exc: object) -> None:
        type(self).exited += 1


def _reader(**spec: Any) -> tuple[ChromiumReader, FakePlaywright, list[int]]:
    playwright = FakePlaywright(spec)
    starts: list[int] = []

    def start() -> FakePlaywright:
        starts.append(1)
        return playwright

    FakeProxy.entered = FakeProxy.exited = 0
    deadline = spec.get("deadline", 5)
    return ChromiumReader(start=start, proxy=FakeProxy, deadline=deadline), playwright, starts


def _read(reader: ChromiumReader, url: str = PUBLIC) -> Any:
    [page] = reader.read_all([url])
    return page


# --- what is launched ---------------------------------------------------------------------


def test_nothing_is_started_until_there_is_a_page_to_read() -> None:
    reader, playwright, starts = _reader()

    assert reader.read_all([]) == []

    assert starts == [] and playwright.chromium.launched == []
    assert FakeProxy.entered == 0


def test_the_browser_is_launched_behind_the_proxy_and_never_with_the_profile() -> None:
    reader, playwright, _ = _reader()

    _read(reader)

    [options] = playwright.chromium.launched
    assert options["headless"] is True and "user_data_dir" not in options
    # The only way out, and loopback is sent through it too: without the explicit entry, one
    # environment variable (PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK) lets
    # 127.0.0.1, localhost and 169.254.x.x go direct.
    assert options["proxy"] == {"server": PROXY_URL, "bypass": "<-loopback>"}
    assert "--force-webrtc-ip-handling-policy=disable_non_proxied_udp" in options["args"]


def test_the_context_is_empty_has_no_downloads_and_no_service_workers() -> None:
    reader, playwright, _ = _reader()

    _read(reader)

    [context_options] = [c.options for c in playwright.chromium.browsers[0].contexts]
    assert context_options["accept_downloads"] is False
    assert context_options["service_workers"] == "block"
    assert "Headless" not in context_options["user_agent"]
    assert "storage_state" not in context_options


def test_one_proxy_serves_a_whole_batch_and_stops_when_it_is_over() -> None:
    reader, _, _ = _reader()

    reader.read_all([PUBLIC, "https://example.net/", "https://example.com/"])

    assert FakeProxy.entered == 1 and FakeProxy.exited == 1


def test_the_proxy_is_stopped_even_when_every_browser_failed() -> None:
    reader, _, _ = _reader(launch_error="Executable doesn't exist")

    with pytest.raises(WebError):
        reader.read_all([PUBLIC])

    assert FakeProxy.exited == 1


def test_every_page_gets_its_own_browser_which_is_closed_when_the_read_is_over() -> None:
    reader, playwright, starts = _reader()

    reader.read_all([PUBLIC, "https://example.net/", "https://example.com/"])

    assert len(starts) == 3 and len(playwright.chromium.browsers) == 3
    assert all(browser.closed for browser in playwright.chromium.browsers)
    assert playwright.stopped == 3


def test_the_browser_is_closed_even_when_the_page_could_not_be_read() -> None:
    for spec in ({"goto_error": "boom"}, {"response": FakeResponse(500)}, {"evaluate_error": True}):
        reader, playwright, _ = _reader(**spec)

        assert _read(reader) is None

        assert playwright.chromium.browsers[0].closed and playwright.stopped == 1


def test_pages_are_read_at_the_same_time_and_come_back_in_the_order_asked() -> None:
    """A barrier only opens when all three reads are inside `goto` together: read one after
    another, the first would wait out its timeout and come back None."""
    barrier = threading.Barrier(3, timeout=5)
    reader, _, _ = _reader(barrier=barrier)
    urls = [f"https://s{i}.example/" for i in range(3)]

    pages = reader.read_all(urls)

    assert [p.url for p in pages] == urls


def test_a_page_that_is_slow_does_not_delay_the_others_beyond_its_own_time() -> None:
    reader, _, _ = _reader(slow={"https://slow.example/": 0.6})
    started = time.monotonic()

    pages = reader.read_all(["https://slow.example/", "https://a.example/", "https://b.example/"])

    assert time.monotonic() - started < 1.5 and all(pages)


def test_a_page_that_never_answers_is_given_up_on_at_the_deadline_and_the_rest_are_kept() -> None:
    """Measured: a page script that spins forever hung `read_all` for good - Playwright's
    `evaluate` has no timeout, so the page limit alone does not bound a read."""
    reader, _, _ = _reader(hang="https://stuck.example/", deadline=0.4)
    started = time.monotonic()

    pages = reader.read_all(["https://stuck.example/", "https://a.example/"])

    assert time.monotonic() - started < 3
    assert pages[0] is None and pages[1] is not None
    # The stuck read is still running; it must not be able to keep the program from exiting.
    abandoned = [t for t in threading.enumerate() if "_work" in t.name and t.is_alive()]
    assert abandoned and all(t.daemon for t in abandoned)


def test_a_browser_that_cannot_start_is_a_web_error_that_names_the_fix() -> None:
    def start() -> None:
        raise SessionError("Chromium is not installed for Playwright. Run `playwright install`.")

    with pytest.raises(WebError, match="playwright install"):
        ChromiumReader(start=start, proxy=FakeProxy).read_all([PUBLIC])


def test_a_browser_that_cannot_launch_is_a_web_error_and_the_driver_is_stopped() -> None:
    reader, playwright, _ = _reader(launch_error="Executable doesn't exist")

    with pytest.raises(WebError, match="Executable doesn't exist"):
        reader.read_all([PUBLIC])

    assert playwright.stopped == 1


def test_one_browser_failing_to_start_does_not_throw_away_the_pages_that_were_read() -> None:
    reader, _, _ = _reader(launch_failures=1)

    pages = reader.read_all([PUBLIC, "https://example.net/", "https://example.com/"])

    assert sum(page is not None for page in pages) == 2


# --- reading a page -------------------------------------------------------------------------------


def test_a_page_is_its_final_address_its_title_and_its_cleaned_text() -> None:
    reader, _, _ = _reader(
        final_url="https://example.org/final", title="The \x1b[2J title\n2", text="a\x07b\n\n\nc"
    )

    page = _read(reader)

    assert page == WebPage("https://example.org/final", "The [2J title 2", "ab\nc")


def test_a_page_is_opened_without_waiting_for_every_image_and_with_a_time_limit() -> None:
    reader, playwright, _ = _reader()

    _read(reader)

    [(url, kwargs)] = playwright.chromium.browsers[0].contexts[0].visited
    assert url == PUBLIC
    assert kwargs["wait_until"] == "domcontentloaded" and kwargs["timeout"] == PAGE_TIMEOUT_MS


def test_page_text_is_capped() -> None:
    reader, _, _ = _reader(text="word " * 5_000)

    page = _read(reader)

    assert page is not None and len(page.text) <= 4_000


@pytest.mark.parametrize(
    "spec",
    [
        {"response": FakeResponse(404)},
        {"response": FakeResponse(403)},
        {"response": FakeResponse(429)},
        {"response": FakeResponse(200, "application/pdf")},
        {"response": FakeResponse(200, "image/png")},
        {"response": None},
        {"goto_error": "net::ERR_TUNNEL_CONNECTION_FAILED"},
        {"goto_error": "Timeout 10000ms exceeded."},
        {"goto_error": "Download is starting"},
        {"evaluate_error": True},
        {"new_page_error": True},
        {"text": ""},
        {"text": "\x1b\x07 ​"},
    ],
    ids=lambda spec: str(next(iter(spec))) + ":" + str(next(iter(spec.values())))[:30],
)
def test_anything_that_is_not_a_readable_html_page_is_none(spec: dict[str, Any]) -> None:
    reader, _, _ = _reader(**spec)

    assert _read(reader) is None


def test_only_web_addresses_are_ever_opened_and_no_browser_is_started_for_anything_else() -> None:
    reader, playwright, starts = _reader()

    pages = reader.read_all(
        ["file:///etc/hostname", "view-source:https://example.org/", "ftp://x/"]
    )

    assert pages == [None, None, None]
    assert starts == [] and playwright.chromium.launched == []


def test_a_page_that_rewrites_its_own_address_to_something_huge_keeps_the_requested_one() -> None:
    """`history.replaceState` can set a megabyte of address, which would reach the prompt."""
    reader, _, _ = _reader(final_url="https://example.org/" + "a" * 5_000)

    page = _read(reader)

    assert page is not None and page.url == PUBLIC


# --- the links a page offers ----------------------------------------------------------------------


def test_a_page_carries_its_links_cleaned_deduplicated_and_without_itself() -> None:
    reader, _, _ = _reader(
        final_url="https://example.org/final",
        links=[
            ["The guide", "https://example.org/guide"],
            ["  Guide\x1b[2J   again\n ", "https://example.org/guide#top"],  # the same page
            ["Back here", "https://example.org/final#section"],  # this page
            ["Mail us", "mailto:someone@example.org"],
            ["Run", "javascript:alert(1)"],
            ["Download", "ftp://example.org/file"],
            ["File", "file:///etc/hostname"],
            ["", "https://example.org/untitled"],
            ["Docs", "https://docs.example.org/"],
            ["Long " + "x" * 300, "https://example.org/long"],
            [42, "https://example.org/odd"],
            ["Huge", "https://example.org/" + "a" * 5_000],
            "not a pair",
        ],
    )

    page = _read(reader)

    assert [link.url for link in page.links] == [
        "https://example.org/guide",
        "https://docs.example.org/",
        "https://example.org/long",
    ]
    assert page.links[0].text == "The guide"
    long_text = page.links[2].text
    assert len(long_text) == 80 and long_text.startswith("Long x") and long_text.endswith("\u2026")


def test_a_page_offers_a_bounded_number_of_links() -> None:
    reader, _, _ = _reader(links=[[f"Link {n}", f"https://example.org/{n}"] for n in range(500)])

    page = _read(reader)

    assert len(page.links) == MAX_LINKS and page.links[0] == WebLink(
        "Link 0", "https://example.org/0"
    )


def test_a_page_that_will_not_list_its_links_is_still_a_page() -> None:
    reader, _, _ = _reader(links_error=True)

    page = _read(reader)

    assert page is not None and page.links == () and page.text


def test_a_page_with_no_links_says_so_with_an_empty_tuple() -> None:
    reader, _, _ = _reader()

    assert _read(reader).links == ()


# --- the search boxes a page offers, and typing into one -----------------------------------------


def test_a_page_carries_its_search_boxes_cleaned_and_bounded() -> None:
    reader, _, _ = _reader(
        boxes=["Search the library", "  Find\x1b[2J \n again ", "x" * 200, "fourth"]
    )

    page = _read(reader)

    assert len(page.boxes) == MAX_BOXES == 3
    assert page.boxes[0] == "Search the library" and page.boxes[1] == "Find[2J again"
    assert len(page.boxes[2]) == 60


def test_a_page_whose_boxes_cannot_be_listed_is_still_a_page() -> None:
    reader, _, _ = _reader(boxes_error=True)

    page = _read(reader)

    assert page is not None and page.boxes == () and page.text


def test_a_box_with_no_usable_label_keeps_its_place_so_the_numbers_stay_true() -> None:
    """The numbers are tags in the page: dropping a label would point the next one at the wrong
    box."""
    reader, _, _ = _reader(boxes=["", 42, "Real"])

    assert _read(reader).boxes == ("search", "search", "Real")


def test_a_page_that_will_not_list_its_boxes_is_still_a_page() -> None:
    reader, _, _ = _reader(boxes="not a list")

    page = _read(reader)

    assert page is not None and page.boxes == () and page.text


def test_typing_fills_the_box_presses_enter_and_reads_the_page_that_comes_back() -> None:
    reader, playwright, _ = _reader(
        boxes=["Search the library", "Other"],
        results_url="https://example.org/results?q=machine+learning",
        text="Results for machine learning.",
    )

    page = reader.search_site(PUBLIC, 1, "Other", "machine learning")

    [context] = playwright.chromium.browsers[0].contexts
    assert context.actions == [
        ("fill", '[data-pli-box="1"]', "machine learning"),
        ("press", '[data-pli-box="1"]', "Enter"),
        ("wait", str(SETTLE_MS)),  # results shown by script need a moment
    ]
    assert (page.url, page.title, page.text) == (
        "https://example.org/results?q=machine+learning",
        "A title",
        "Results for machine learning.",
    )


def test_typing_happens_behind_the_proxy_in_a_throwaway_browser_that_is_closed() -> None:
    reader, playwright, _ = _reader(boxes=["Search"])

    reader.search_site(PUBLIC, 0, "Search", "hello")

    [options] = playwright.chromium.launched
    assert options["proxy"] == {"server": PROXY_URL, "bypass": "<-loopback>"}
    assert playwright.chromium.browsers[0].closed and playwright.stopped == 1
    assert FakeProxy.entered == 1 and FakeProxy.exited == 1


def test_the_typed_text_is_one_clean_line_of_bounded_length() -> None:
    reader, playwright, _ = _reader(boxes=["Search"])

    reader.search_site(PUBLIC, 0, "Search", "line one\n\x1b[2Jline two " + "x" * 500)

    [(_, _, typed)] = [
        a for a in playwright.chromium.browsers[0].contexts[0].actions if a[0] == "fill"
    ]
    assert "\n" not in typed and "\x1b" not in typed and 0 < len(typed) <= 200


@pytest.mark.parametrize(
    ("url", "box", "text"),
    [
        ("file:///etc/hostname", 0, "x"),
        ("view-source:https://example.org/", 0, "x"),
        ("ftp://example.org/", 0, "x"),
        (PUBLIC, -1, "x"),
        (PUBLIC, MAX_BOXES, "x"),
        (PUBLIC, 0, ""),
        (PUBLIC, 0, "  \x1b \n "),
    ],
)
def test_a_request_that_is_not_a_plain_search_starts_nothing(url: str, box: int, text: str) -> None:
    reader, playwright, starts = _reader(boxes=["Search"])

    assert reader.search_site(url, box, "Search", text) is None
    assert starts == [] and playwright.chromium.launched == []


def test_a_box_the_page_does_not_have_gets_nothing_typed_into_it() -> None:
    reader, playwright, _ = _reader(boxes=["Only one"])

    assert reader.search_site(PUBLIC, 1, "Other", "hello") is None
    assert playwright.chromium.browsers[0].contexts[0].actions == []
    assert playwright.chromium.browsers[0].closed


@pytest.mark.parametrize(
    "spec",
    [
        {"goto_error": "boom"},
        {"response": FakeResponse(404)},
        {"response": FakeResponse(200, "application/pdf")},
        {"fill_error": True},
        {"press_error": True},
        {"new_page_error": True},
        {"text": ""},
    ],
    ids=lambda spec: next(iter(spec)),
)
def test_every_failure_while_typing_is_nothing_and_the_browser_is_closed(
    spec: dict[str, Any],
) -> None:
    reader, playwright, _ = _reader(boxes=["Search"], **spec)

    assert reader.search_site(PUBLIC, 0, "Search", "hello") is None
    assert all(browser.closed for browser in playwright.chromium.browsers)


def test_a_page_with_no_load_event_after_the_search_is_still_read() -> None:
    """Many sites show results by script, without a navigation."""
    reader, _, _ = _reader(boxes=["Search"], load_state_error=True, text="Results shown by script.")

    page = reader.search_site(PUBLIC, 0, "Search", "hello")

    assert page is not None and page.text == "Results shown by script."


def test_a_page_that_hangs_while_typing_is_given_up_on_at_the_deadline() -> None:
    reader, _, _ = _reader(boxes=["Search"], hang_press=True, deadline=0.4)
    started = time.monotonic()

    assert reader.search_site(PUBLIC, 0, "Search", "hello") is None
    assert time.monotonic() - started < 3


def test_a_browser_that_cannot_start_for_a_search_is_a_web_error() -> None:
    reader, _, _ = _reader(launch_error="Executable doesn't exist")

    with pytest.raises(WebError, match="Executable doesn't exist"):
        reader.search_site(PUBLIC, 0, "Search", "hello")


# --- found by the typing review ------------------------------------------------------------------


def test_while_typing_the_browser_refuses_every_request_that_is_not_a_get_or_a_head() -> None:
    """Enter could still POST: a submit button with formmethod=post, a script flipping the form's
    method, an onsubmit fetch. The agent only reads, so nothing else may leave the browser."""
    reader, playwright, _ = _reader(boxes=["Search"])

    reader.search_site(PUBLIC, 0, "Search", "hello")

    [context] = playwright.chromium.browsers[0].contexts
    [handler] = context.routes
    outcomes = {}
    for method in ("GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"):
        route = FakeRoute(method)
        handler(route)
        outcomes[method] = route.outcome
    assert outcomes == {
        "GET": "continue",
        "HEAD": "continue",
        "POST": "abort",
        "PUT": "abort",
        "DELETE": "abort",
        "PATCH": "abort",
        "OPTIONS": "abort",
    }


def test_the_route_is_in_place_before_the_page_is_opened() -> None:
    """Otherwise the first load could already carry a request the rule should have stopped."""
    reader, playwright, _ = _reader(boxes=["Search"])

    reader.search_site(PUBLIC, 0, "Search", "hello")

    [context] = playwright.chromium.browsers[0].contexts
    assert len(context.routes) == 1 and context.visited  # installed, and a page was opened


def test_reading_a_page_installs_no_such_rule() -> None:
    """Pages make their own POSTs (analytics, beacons) while being read; that is not typing."""
    reader, playwright, _ = _reader()

    _read(reader)

    assert playwright.chromium.browsers[0].contexts[0].routes == []


def test_the_box_is_matched_strictly_so_a_second_lookalike_cannot_take_the_text() -> None:
    reader, playwright, _ = _reader(boxes=["Search"])

    reader.search_site(PUBLIC, 0, "Search", "hello")

    assert playwright.chromium.browsers[0].contexts[0].strict == [True, True]


def test_when_the_box_at_that_number_has_a_different_label_nothing_is_typed() -> None:
    """The page can serve other boxes the second time; number 0 is then a different field."""
    reader, playwright, _ = _reader(boxes=["Search staff directory"])

    assert reader.search_site(PUBLIC, 0, "Search library", "hello") is None
    assert playwright.chromium.browsers[0].contexts[0].actions == []
    assert playwright.chromium.browsers[0].closed
