"""A real Chromium, a real proxy: what the browser can and cannot reach.

The fake-Playwright tests cannot see what Chromium really does with a redirect, so these start
the real thing (skipped where Chromium is not installed). "The public internet" is a local
server reached under the made-up name `public.test`, and "the private network" is
`private.test`, a name the proxy's address rule refuses; nothing leaves the machine.

Measured before the proxy existed, with a route guard in the browser instead: an HTTP redirect from
an allowed page to a refused host still sent the request (the guard is not asked about redirect
hops), and so did a WebSocket opened by the page's own script. Through the proxy, every hop is
checked where it connects:

**A redirect, a meta refresh, an image, a script `fetch` and a WebSocket to a refused host never
reach the proxy's connect step** - nothing is sent, not even a request whose reply is thrown away.
**An allowed page still loads and is read**, so the proxy is not simply refusing everything.
"""

from __future__ import annotations

import http.server
import socket
import threading
import time
import urllib.parse
from collections.abc import Iterator
from typing import Any

import pytest

from pli.web import ChromiumReader
from pli.webguard import FilteringProxy

LONG = " ".join(f"sentence{n} about the topic." for n in range(30))


@pytest.fixture(scope="module")
def chromium() -> None:
    sync_api = pytest.importorskip("playwright.sync_api")
    playwright = sync_api.sync_playwright().start()
    try:
        playwright.chromium.launch(headless=True).close()
    except Exception as exc:  # the browser binary is not downloaded
        pytest.skip(f"Chromium is not available: {str(exc).splitlines()[0]}")
    finally:
        playwright.stop()


class Site(http.server.ThreadingHTTPServer):
    """Serves the pages below on 127.0.0.1; `hits` is every path requested."""

    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _Handler)
        self.hits: list[str] = []
        self.posts: list[str] = []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def port(self) -> int:
        return self.server_address[1]


class _Handler(http.server.BaseHTTPRequestHandler):
    server: Site

    def do_GET(self) -> None:
        self.server.hits.append(self.path)
        port = self.server.port
        elsewhere = f"http://private.test:{port}"
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"{elsewhere}/after-redirect")
            self.end_headers()
            return
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("q", [""])[0]
        body = {
            "/formmethod": f'<html><body><main><form action="/sink"><input type="search" name="q" '
            f'placeholder="Search"><button formmethod="post">Go</button></form><p>{LONG}</p></main>'
            "</body></html>",
            "/flip": f'<html><body><main><form action="/results"><input type="search" name="q" '
            f'placeholder="Search" oninput="this.form.method=\'post\'"></form><p>{LONG}</p>'
            "</main></body></html>",
            "/onsubmit": f'<html><body><main><form action="/results" onsubmit="fetch(\'/sink\', '
            f'{{method: \'POST\', body: \'x\'}})"><input type="search" name="q" '
            f'placeholder="Search"></form><p>{LONG}</p></main></body></html>',
            "/pretag": f'<html><body><main><form method="post" action="/sink">'
            f'<input type="password" '
            f'name="pw" data-pli-box="0"></form><form action="/results"><input type="search" '
            f'name="q" placeholder="The real box"></form><p>{LONG}</p></main></body></html>',
            "/staff": f'<html><body><main><form action="/people"><input type="search" name="q" '
            f'placeholder="Search staff directory"></form><p>{LONG}</p></main></body></html>',
            "/lib": f'<html><body><main><form action="/results"><input type="search" name="q" '
            f'placeholder="Search the library"></form><p>{LONG}</p></main></body></html>',
            "/posting": f'<html><body><main><form method="post" action="/results">'
            f'<input type="search" name="q"></form><p>{LONG}</p></main></body></html>',
            "/results": f"<html><body><main><p>RESULTS FOR [{query}]</p><p>{LONG}</p>"
            "</main></body></html>",
            "/page": f"<html><body><main><p>{LONG}</p></main></body></html>",
            "/meta": f'<html><head><meta http-equiv="refresh" content="0;url={elsewhere}/m">'
            f"</head><body><p>{LONG}</p></body></html>",
            "/nav": f'<html><body><nav><a href="http://public.test:{port}/about">About us</a>'
            f"</nav><main><p>NAVTEXT {LONG}</p></main></body></html>",
            "/image": f'<html><body><p>{LONG}</p><img src="{elsewhere}/an-image"></body></html>',
            "/fetch": f"<html><body><p>{LONG}</p><script>fetch('{elsewhere}/a-fetch')"
            ".catch(()=>0)</script></body></html>",
            "/socket": f"<html><body><p>{LONG}</p><script>new WebSocket('ws://private.test:{port}/s')"
            "</script></body></html>",
        }.get(urllib.parse.urlsplit(self.path).path, "")
        self.send_response(200 if body else 404)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())

    def do_POST(self) -> None:
        self.server.posts.append(self.path)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args: object) -> None:
        pass


@pytest.fixture
def site() -> Iterator[Site]:
    server = Site()
    yield server
    server.shutdown()
    server.server_close()


class Setup:
    """A reader whose proxy treats 127.0.0.1 as 'public' and `private.test` as a private host."""

    def __init__(self, site: Site) -> None:
        self.site = site
        self.connects: list[tuple[str, int]] = []

    def _resolve(self, host: str, port: object, **kwargs: object) -> list[tuple]:
        address = {"public.test": "127.0.0.1", "private.test": "10.9.9.9"}.get(host)
        if address is None:
            raise socket.gaierror(host)
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))]

    def _connect(self, address: str, port: int, timeout: float) -> socket.socket:
        self.connects.append((address, port))
        if address != "127.0.0.1":
            raise ConnectionRefusedError(address)  # nothing real lives at a refused address
        return socket.create_connection((address, port), timeout)

    def proxy(self) -> FilteringProxy:
        return FilteringProxy(
            resolve=self._resolve,
            connect=self._connect,
            allow=lambda address: address == "127.0.0.1",
        )

    def read(self, path: str) -> object:
        reader = ChromiumReader(proxy=self.proxy)
        [page] = reader.read_all([f"http://public.test:{self.site.port}{path}"])
        time.sleep(1.0)  # let a late subresource or socket attempt happen before we look
        return page

    @property
    def forbidden(self) -> list[tuple[str, int]]:
        return [c for c in self.connects if c[0] != "127.0.0.1"]


@pytest.fixture
def setup(chromium: None, site: Site) -> Setup:
    return Setup(site)


def test_an_allowed_page_loads_through_the_proxy_and_is_read(setup: Setup) -> None:
    page = setup.read("/page")

    assert page is not None and "sentence29" in page.text
    assert setup.connects == [("127.0.0.1", setup.site.port)] and setup.site.hits == ["/page"]


def test_an_http_redirect_to_a_refused_host_sends_nothing_there(setup: Setup) -> None:
    page = setup.read("/redirect")

    assert page is None
    assert setup.forbidden == []
    assert setup.site.hits == ["/redirect"]


@pytest.mark.parametrize("path", ["/meta", "/image", "/fetch", "/socket"])
def test_a_meta_refresh_an_image_a_script_and_a_websocket_cannot_reach_a_refused_host(
    setup: Setup, path: str
) -> None:
    setup.read(path)

    assert setup.forbidden == []
    assert all(hit == path for hit in setup.site.hits)  # nothing was fetched from the "other" host


def test_a_refused_page_costs_the_lookup_nothing_but_that_page(setup: Setup) -> None:
    reader = ChromiumReader(proxy=setup.proxy)
    base = f"http://public.test:{setup.site.port}"

    pages = reader.read_all(
        [f"{base}/redirect", f"{base}/page", f"http://private.test:{setup.site.port}/x"]
    )

    assert pages[0] is None and pages[2] is None
    assert pages[1] is not None and "sentence3" in pages[1].text


def test_a_pages_navigation_links_are_offered_though_its_navigation_text_is_not(
    setup: Setup,
) -> None:
    """Links are taken before the text script strips the navigation, or a site's other sections
    (what a browsing model needs to choose from) would never be seen."""
    page = setup.read("/nav")

    assert page is not None and "sentence29" in page.text
    assert [(link.text, link.url) for link in page.links] == [
        ("About us", f"http://public.test:{setup.site.port}/about")
    ]
    assert "About us" not in page.text


def test_a_pages_plain_search_box_is_offered_but_a_form_that_posts_is_not(setup: Setup) -> None:
    library = setup.read("/lib")
    posting = setup.read("/posting")

    assert library is not None and library.boxes == ("Search the library",)
    assert posting is not None and posting.boxes == ()


def test_typing_into_a_site_search_box_submits_a_plain_get_and_reads_the_results(
    setup: Setup,
) -> None:
    reader = ChromiumReader(proxy=setup.proxy)

    page = reader.search_site(
        f"http://public.test:{setup.site.port}/lib", 0, "Search the library", "machine learning"
    )

    assert page is not None and "RESULTS FOR [machine learning]" in page.text
    assert setup.site.hits == ["/lib", "/results?q=machine+learning"]
    assert setup.forbidden == []


def test_typed_text_cannot_add_parameters_or_end_the_query(setup: Setup) -> None:
    """The browser encodes what is typed, so `&` and `#` stay inside the one value."""
    reader = ChromiumReader(proxy=setup.proxy)

    page = reader.search_site(
        f"http://public.test:{setup.site.port}/lib", 0, "Search the library", "a&admin=1#frag"
    )

    assert page is not None and "RESULTS FOR [a&admin=1#frag]" in page.text
    assert setup.site.hits[-1].count("=") == 1


# --- the typing review's attacks, against a real browser --------------------------------------


def _type_into(setup: Setup, path: str, label: str, text: str = "hello") -> Any:
    reader = ChromiumReader(proxy=setup.proxy)
    page = reader.search_site(f"http://public.test:{setup.site.port}{path}", 0, label, text)
    time.sleep(0.5)  # let a late request happen before the server is looked at
    return page


@pytest.mark.parametrize(
    ("path", "label"),
    [
        ("/formmethod", "Search"),  # the default submit button says formmethod=post
        ("/flip", "Search"),  # a script flips the form to POST as soon as something is typed
        ("/onsubmit", "Search"),  # the page's own onsubmit handler POSTs in the background
    ],
)
def test_enter_can_never_make_the_browser_send_a_post(setup: Setup, path: str, label: str) -> None:
    _type_into(setup, path, label)

    assert setup.site.posts == []
    assert setup.forbidden == []


def test_a_field_the_page_tagged_itself_does_not_take_the_text(setup: Setup) -> None:
    page = _type_into(setup, "/pretag", "The real box", "needle")

    assert page is not None and "RESULTS FOR [needle]" in page.text  # it went to the real box
    assert setup.site.posts == []


def test_a_page_that_now_offers_a_different_box_gets_nothing_typed(setup: Setup) -> None:
    """The label the model saw was 'Search library'; this page's box 0 is the staff directory."""
    page = _type_into(setup, "/staff", "Search library")

    assert page is None
    assert setup.site.hits == ["/staff"]  # opened, and nothing was submitted
