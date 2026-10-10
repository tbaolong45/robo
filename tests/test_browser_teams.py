"""The Teams channel reader: the properties whose failure is silent.

Channel posts are where a lecturer announces that a deadline moved, which is the
highest-value signal in the whole tool - and the one thing the Graph API could
not reach without tenant admin consent. That makes the failure modes here
expensive in a way that is invisible from the output:

* a post that is *paraphrased* rather than copied reads perfectly and is wrong.
  Nothing downstream can tell "Quiz 3 moved to Friday" from "Quiz 3 moved", so
  bodies are asserted character for character, non-ASCII, pipes and newlines
  included;
* a post the reader silently dropped looks exactly like a quiet week, and a
  quiet week is what the planner fills with study blocks;
* an id that changes between runs stores the same post every night. The ids are
  the only thing standing between a nightly sync and a channel of duplicates;
* the relative-date arithmetic ("next Thursday") is where a model is most
  confident and most wrong, so it lives in Python and is tested against the
  cases that break naive implementations: a weekday already past, a month
  boundary, and a DST transition;
* one unreadable channel must cost that channel and nothing else - the posts in
  the other nine are the reason the tool reads Teams at all.

No browser is launched and no network is touched. The page, the capture layer
and the judge are hand-written fakes; the three sibling modules are injected
into `sys.modules` rather than imported, which is possible only because
`pli.browser.teams` imports them lazily inside the functions that need them.

The one thing the fakes cannot tell you is whether Teams' real markup matches
`config/browser.toml` - that is what a live headed run is for.
"""

from __future__ import annotations

import logging
import sys
import types
from contextlib import contextmanager
from dataclasses import dataclass, field, fields
from datetime import UTC, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import pytest

from pli.browser import BrowserError, SessionError
from pli.browser import session as real_session
from pli.browser.selectors import Selectors
from pli.browser.teams import (
    DateParts,
    TeamChannel,
    clear_judgements,
    last_judgements,
    list_channels,
    parse_posted_at,
    read_channel,
    read_messages,
    resolve_relative_date,
)
from pli.config import Settings
from pli.judge import MAX_OPTIONS, MAX_QUESTIONS_PER_CALL, Candidate, Judgements

DUBLIN = "Europe/Dublin"
NEW_YORK = "America/New_York"
TEAM = "CS301 Algorithms"
CHANNEL = "General"
#: A Monday, so every relative-date case below can be read off a known week.
NOW = datetime(2026, 9, 28, 12, 0, tzinfo=UTC)

#: The real selector set. The fake page resolves a query back to the field it
#: came from, so a literal selector in the reader fails here instead of going
#: unnoticed until a page changes.
SELECTORS = Selectors()
_FIELDS = [field.name for field in fields(Selectors)]


def _declared(selector: str) -> str:
    for name in _FIELDS:
        if getattr(SELECTORS, name) == selector:
            return name
    raise AssertionError(f"the reader used a selector no module declares: {selector!r}")


# --- the fake page -------------------------------------------------------------------


class FakeElement:
    """A Playwright ElementHandle with the handful of methods the reader uses."""

    def __init__(
        self,
        *,
        label: str = "",
        text: str = "",
        box: dict[str, float] | None = None,
        children: dict[str, FakeElement] | None = None,
        on_click: Any = None,
        scroll: list[int] | None = None,
        kind: str = "",
        click_log: list[str] | None = None,
    ) -> None:
        self._label = label
        self._text = text
        self._box = box
        self._children = dict(children or {})
        self._on_click = on_click
        self._scroll = scroll
        self.clicks = 0
        #: Which `Selectors` field this element was found by, and where a click
        #: on it is recorded. A click is the reader's only way to change the
        #: page, so these two together are how a test can say what it touched -
        #: see `FakePage.clicked`.
        self.kind = kind
        self._click_log = click_log

    def get_attribute(self, name: str) -> str | None:
        return self._label if name == "aria-label" and self._label else None

    def inner_text(self) -> str:
        return self._text

    def bounding_box(self) -> dict[str, float] | None:
        return dict(self._box) if self._box else None

    def click(self) -> None:
        self.clicks += 1
        if self._click_log is not None:
            self._click_log.append(self.kind or "unknown")
        if self._on_click is not None:
            self._on_click()

    def query_selector(self, selector: str) -> FakeElement | None:
        return self._children.get(_declared(selector))

    def query_selector_all(self, selector: str) -> list[FakeElement]:
        return []

    def evaluate(self, script: str, arg: Any = None) -> Any:
        assert self._scroll is not None, f"the reader scripted something unscrollable: {script}"
        if "Math.max" in script:
            self._scroll[0] = max(0, self._scroll[0] - int(arg))
            return None
        assert "scrollTop" in script, f"the reader ran a script it should not have: {script}"
        return self._scroll[0]


class _ChannelList:
    """The sidebar's channel list, whose items belong to whichever team is open."""

    def __init__(self, page: FakePage) -> None:
        self._page = page

    def query_selector_all(self, selector: str) -> list[FakeElement]:
        assert _declared(selector) == "teams_channel_item"
        return self._page.channel_items()


class FakePage:
    """A `Page` showing a canned Teams sidebar and one channel's messages.

    Every query is resolved back to the `Selectors` field it came from, so this
    fake is also the check that the reader asks for the elements the project
    declares and no others.
    """

    def __init__(
        self,
        *,
        teams: dict[str, list[str]] | None = None,
        message_elements: list[FakeElement] | None = None,
        channel_items_use_text: bool = False,
        has_message_list: bool = True,
        has_more_messages: bool = False,
    ) -> None:
        self.teams = dict(teams or {})
        self.message_elements = list(message_elements or [])
        self.channel_items_use_text = channel_items_use_text
        self.has_message_list = has_message_list
        #: Some Teams views scroll to older posts and some put an explicit
        #: control at the top; which one a channel gets is not the reader's to
        #: choose, so both have to be exercised.
        self.has_more_messages = has_more_messages
        # Starts high so every scroll "moves"; the read ends on the stall rule.
        self.scroll = [5000]
        self.current_team = ""
        self.opened = ""
        #: Where the page has landed. The real browser is asked this to tell a
        #: sign-in wall from a restyled app; the default here is the app, so
        #: only a test that sets it to a login URL sees the refusal.
        self.url = "https://teams.microsoft.com/v2/"
        self.gotos: list[str] = []
        self.waits = 0
        self.mouse = _FakeMouse()
        #: The kind of every element the reader clicked, in order. Clicking is
        #: the reader's only way to touch the page - everything else it does is
        #: a read - so this list, next to `gotos`, is what says whether it
        #: stayed read-only, and what the tests below pin.
        self.clicked: list[str] = []

    def goto(self, url: str) -> None:
        self.gotos.append(url)

    def wait_for_timeout(self, milliseconds: int) -> None:
        self.waits += 1

    def _tracked(self, element: FakeElement, kind: str) -> FakeElement:
        """Say which selector found this element, and record its clicks.

        Stamped where the reader is handed the element rather than where it is
        built, so an element a test assigns to `message_elements` afterwards is
        attributed too, instead of a click on it vanishing into nothing.
        """
        element.kind = kind
        element._click_log = self.clicked
        return element

    def channel_items(self) -> list[FakeElement]:
        return [
            self._tracked(
                FakeElement(
                    label="" if self.channel_items_use_text else name,
                    text=name if self.channel_items_use_text else "",
                    on_click=lambda name=name: self._open_channel(name),
                ),
                "teams_channel_item",
            )
            for name in self.teams.get(self.current_team, [])
        ]

    def query_selector_all(self, selector: str) -> list[FakeElement]:
        which = _declared(selector)
        if which == "teams_app_bar":
            return [
                self._tracked(
                    FakeElement(label=team, on_click=lambda team=team: self._open_team(team)),
                    "teams_app_bar",
                )
                for team in self.teams
            ]
        if which == "teams_channel_item":
            return self.channel_items()
        if which == "teams_message":
            return [self._tracked(element, "teams_message") for element in self.message_elements]
        raise AssertionError(f"the reader asked the page for {which} as a list")

    def query_selector(self, selector: str) -> Any:
        which = _declared(selector)
        if which == "teams_channel_list":
            return _ChannelList(self)
        if which == "teams_message_list":
            if not self.has_message_list:
                return None
            return self._tracked(FakeElement(scroll=self.scroll), "teams_message_list")
        if which == "teams_more_messages":
            # The ordinary case: no explicit "older messages" control exists.
            if not self.has_more_messages:
                return None
            return self._tracked(FakeElement(), "teams_more_messages")
        raise AssertionError(f"the reader asked the page for {which} as a single element")

    def _open_team(self, team: str) -> None:
        self.current_team = team

    def _open_channel(self, channel: str) -> None:
        self.opened = f"{self.current_team}/{channel}"


class _FakeMouse:
    def __init__(self) -> None:
        self.wheels: list[tuple[int, int]] = []

    def wheel(self, dx: int, dy: int) -> None:
        self.wheels.append((dx, dy))


def _message_element(
    *, author: str = "", stamp: str = "", box: dict[str, float] | None = None
) -> FakeElement:
    return FakeElement(
        box=box,
        children={
            "teams_message_author": FakeElement(text=author),
            "teams_message_time": FakeElement(text=stamp),
        },
    )


# --- the fake judge ------------------------------------------------------------------


@dataclass
class _Answer:
    choice: str = ""
    confidence: float = 0.99
    probabilities: dict[str, float] = field(default_factory=dict)


@dataclass
class ScriptedPost:
    """How the judge answers the questions about one post.

    `marker` is a phrase that appears in the post's body, which is how the fake
    finds which scripted post a question is about - the real judge reads the
    body the same way.
    """

    marker: str
    deadline: float = 0.1
    course: str = "none"
    course_confidence: float = 0.9
    stated: bool = False
    month: str = "none"
    day: str = "none"
    weekday: str = "none"
    relative: str = "none"


class FakeJudge:
    """A `Judge` with canned answers that records every question it was asked.

    The answers are returned as a real `pli.judge.Judgements`, so the accessors
    the reader relies on - `ranked`, `choice`, `probability`, `is_yes` - are the
    ones under test rather than a re-implementation of them.
    """

    #: P(a fragment is a channel post) when nothing in the script names it.
    UNMATCHED = 0.05
    SELECTED = 0.9

    def __init__(self, *, posts: list[ScriptedPost] | None = None, select_all: bool = False):
        self.posts = list(posts or [])
        self.select_all = select_all
        self.calls: list[dict[str, Any]] = []
        self.states: list[str] = []

    def ask(self, state: Any, questions: Any) -> Judgements:
        self.calls.append(dict(questions))
        self.states.append(str(state))
        fragments = _fragments(str(state))
        choices: dict[str, _Answer] = {}
        nouls: dict[str, float] = {}
        for name, question in questions.items():
            if name == "is_post":
                choices[name] = _Answer(probabilities=self._is_post(fragments, question))
                continue
            post = self._post(fragments, name)
            if name.endswith(".deadline"):
                nouls[name] = post.deadline
            elif name.endswith(".date_stated"):
                nouls[name] = 1.0 if post.stated else 0.0
            elif name.endswith(".course"):
                choices[name] = _Answer(
                    choice=post.course,
                    confidence=post.course_confidence,
                    probabilities=_split(post.course, post.course_confidence),
                )
            elif name.endswith(".month"):
                choices[name] = _Answer(choice=post.month, probabilities=_split(post.month, 0.95))
            elif name.endswith(".day"):
                choices[name] = _Answer(choice=post.day, probabilities=_split(post.day, 0.95))
            elif name.endswith(".weekday"):
                choices[name] = _Answer(
                    choice=post.weekday, probabilities=_split(post.weekday, 0.95)
                )
            elif name.endswith(".relative"):
                choices[name] = _Answer(
                    choice=post.relative, probabilities=_split(post.relative, 0.95)
                )
            else:  # pragma: no cover - the reader must not invent question names
                raise AssertionError(f"the reader asked an unknown question: {name}")
        return Judgements(choices=choices, nouls=nouls)

    # Every other way of asking is a one-at-a-time call, which this reader is
    # built to avoid: a hundred posts must not become a hundred requests.
    def locate(self, *args: Any, **kwargs: Any) -> None:  # pragma: no cover
        raise AssertionError("this reader must batch, not locate candidates one at a time")

    def confirm(self, *args: Any, **kwargs: Any) -> None:  # pragma: no cover
        raise AssertionError("this reader must batch its yes/no questions")

    def asks(self, *args: Any, **kwargs: Any) -> None:  # pragma: no cover
        raise AssertionError("this reader must batch its candidate questions")

    def _is_post(self, fragments: dict[str, str], question: Any) -> dict[str, float]:
        """Which offered fragments are channel posts.

        The options are the ids the reader offered, taken from the question
        itself so a reader that offered something other than what it put in the
        state is caught here.
        """
        options = list(getattr(question, "criteria", None) or fragments)
        return {
            candidate_id: (
                self.SELECTED
                if self.select_all or self._scripted(fragments.get(candidate_id, ""))
                else self.UNMATCHED
            )
            for candidate_id in options
        }

    def _post(self, fragments: dict[str, str], name: str) -> ScriptedPost:
        """The scripted post a `p<index>.<field>` question is about."""
        index = name.split(".")[0]
        body = fragments.get(index, "")
        for post in self.posts:
            if post.marker in body:
                return post
        return ScriptedPost(marker=body)

    def _scripted(self, text: str) -> bool:
        return any(post.marker in text for post in self.posts)


def _fragments(state: str) -> dict[str, str]:
    """The id-to-text map out of `label_candidates`' rendering."""
    found: dict[str, str] = {}
    for line in state.splitlines():
        candidate_id, _, text = line.partition("|")
        found[candidate_id] = text
    return found


def _split(option: str, probability: float) -> dict[str, float]:
    """A probability map with the named option on top and `none` taking the rest."""
    rest = round(1.0 - probability, 6)
    return {option: probability, "none": rest} if option != "none" else {option: probability}


# --- wiring --------------------------------------------------------------------------


@dataclass
class FakeBrowser:
    """The three sibling modules, faked, plus what they recorded.

    `passes` is what each capture returns, in order; the last one repeats, which
    is what makes the reader's stall rule end a read. `by_channel` keys the same
    scripts on the channel the page has open, so a multi-channel read sees two
    different channels.
    """

    tmp_path: Any
    page: FakePage = field(default_factory=FakePage)
    passes: list[list[Candidate]] = field(default_factory=list)
    by_channel: dict[str, list[list[Candidate]]] = field(default_factory=dict)
    failures: dict[str, Exception] = field(default_factory=dict)
    diagnostics: list[str] = field(default_factory=list)
    captured: int = 0
    _used: dict[str, int] = field(default_factory=dict)

    def candidates(self, page: Any, *, selectors: Any = None, limit: int = 400) -> list[Candidate]:
        self.captured += 1
        if page.opened in self.failures:
            raise self.failures[page.opened]
        script = self.by_channel.get(page.opened, self.passes)
        if not script:
            return []
        index = self._used.get(page.opened, 0)
        self._used[page.opened] = index + 1
        return list(script[min(index, len(script) - 1)])

    def saved(self, label: str) -> str:
        return str(self.tmp_path / f"{label}.txt")


@pytest.fixture
def settings(tmp_path: Any) -> Settings:
    return Settings(_env_file=None, pli_timezone=DUBLIN, pli_home=tmp_path)


@pytest.fixture(autouse=True)
def _no_judgements_left_over() -> None:
    """`last_judgements` is per-read state; a leaked entry would read as one."""
    clear_judgements()


@pytest.fixture
def browser(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> FakeBrowser:
    fake = FakeBrowser(tmp_path=tmp_path)

    capture = types.ModuleType("pli.browser.capture")
    capture.capture_candidates = lambda page, *, selectors=None, limit=400: fake.candidates(
        page, selectors=selectors, limit=limit
    )

    def diagnostics(page: Any, settings: Any, *, label: str) -> Any:
        fake.diagnostics.append(label)
        path = tmp_path / f"{label}.txt"
        path.write_text("what the page looked like")
        return path

    capture.diagnostics = diagnostics

    selectors = types.ModuleType("pli.browser.selectors")
    selectors.load = lambda path=None: Selectors()

    session = types.ModuleType("pli.browser.session")

    @contextmanager
    def _session(settings: Any, *, headless: bool | None = None) -> Any:
        yield fake.page

    session.session = _session
    # Mirrored from the real module so the reader's sign-in advice is the one
    # constant the rest of the tool uses, not a copy that can drift. The check
    # itself is mirrored rather than stubbed: whether a URL is a sign-in wall is
    # exactly the rule under test, and a stub would answer whatever the test
    # expected instead of what the tool would do.
    session.SIGN_IN = real_session.SIGN_IN
    session.require_signed_in = real_session.require_signed_in

    monkeypatch.setitem(sys.modules, "pli.browser.capture", capture)
    monkeypatch.setitem(sys.modules, "pli.browser.selectors", selectors)
    monkeypatch.setitem(sys.modules, "pli.browser.session", session)
    return fake


# --- building a page ------------------------------------------------------------------


def _fragment(
    id: str, text: str, x: float, y: float, *, width: float = 300.0, height: float = 18.0
) -> Candidate:
    return Candidate(id=id, text=text, x=x, y=y, width=width, height=height)


def _box(y: float, *, height: float = 40.0) -> dict[str, float]:
    return {"x": 0.0, "y": y, "width": 600.0, "height": height}


def _sidebar(teams: dict[str, list[str]] | None = None) -> FakePage:
    return FakePage(teams=teams if teams is not None else {TEAM: [CHANNEL]})


def _read(browser: FakeBrowser, judge: FakeJudge, settings: Settings, **kwargs: Any):
    return read_channel(settings, judge, team=TEAM, channel=CHANNEL, page=browser.page, **kwargs)


def _call_with(judge: FakeJudge, name: str) -> dict[str, Any]:
    """The one request that carried `name`.

    A read is two batches - which fragments are posts, then the questions about
    each of them - so a test that looks at the wrong call sees an empty answer.
    """
    found = [call for call in judge.calls if name in call]
    assert len(found) == 1, f"expected exactly one request naming {name}, got {len(found)}"
    return found[0]


# --- the sidebar ----------------------------------------------------------------------


def test_list_channels_reads_every_team_and_channel_the_siderail_offers(browser: FakeBrowser):
    browser.page = FakePage(
        teams={"CS301 Algorithms": ["General", "Announcements"], "MA101 Calculus": ["General"]}
    )

    assert list_channels(browser.page) == [
        TeamChannel(team="CS301 Algorithms", channel="General"),
        TeamChannel(team="CS301 Algorithms", channel="Announcements"),
        TeamChannel(team="MA101 Calculus", channel="General"),
    ]


def test_a_channel_listed_twice_under_one_team_is_one_channel(browser: FakeBrowser):
    """A pinned channel also appears in the full list; it is still one channel."""
    browser.page = FakePage(teams={TEAM: ["General", "General", "Announcements"]})

    assert list_channels(browser.page) == [
        TeamChannel(team=TEAM, channel="General"),
        TeamChannel(team=TEAM, channel="Announcements"),
    ]


def test_a_channel_named_only_by_its_visible_text_is_still_found(browser: FakeBrowser):
    """The accessible name is preferred, but a list that only renders text works."""
    browser.page = FakePage(teams={TEAM: ["General"]}, channel_items_use_text=True)

    assert list_channels(browser.page) == [TeamChannel(team=TEAM, channel="General")]


def test_a_sidebar_with_no_teams_blames_the_selector_not_the_session(browser: FakeBrowser):
    """An empty sidebar must not be reported as a signed-out profile.

    This test used to assert the opposite, and it was wrong. `read_messages`
    checks the session the moment Teams is open, so by the time the sidebar is
    read a sign-in wall has already been refused - the session is known good.
    An empty rail therefore means the query for it stopped matching, and saying
    "sign in again" would send the user to fix the one thing that is not broken.
    """
    browser.page = FakePage(teams={})

    with pytest.raises(BrowserError) as raised:
        list_channels(browser.page)

    message = str(raised.value)
    assert "sidebar" in message
    assert "restyled" in message
    assert "BROWSER_HEADLESS=false" not in message


def test_a_signed_out_teams_page_is_refused_before_the_sidebar_is_read(
    browser: FakeBrowser, settings: Settings
):
    """The refusal that makes the test above true: a login wall is caught first.

    Teams does not fail the navigation when the session has expired - it serves
    the login page, the sidebar is simply empty, and "no channels" then looks
    exactly like a restyled list. This is the check that tells them apart, and
    it has to run before anything is looked for.
    """
    browser.page = FakePage(teams={TEAM: [CHANNEL]})
    browser.page.url = (
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=abc"
    )

    with pytest.raises(SessionError) as raised:
        read_messages(settings, FakeJudge(), since=NOW - timedelta(days=1))

    message = str(raised.value)
    assert "sign-in" in message
    assert "BROWSER_HEADLESS=false" in message


# --- reading a channel -----------------------------------------------------------------


def _announcement_page() -> tuple[FakePage, list[list[Candidate]], FakeElement]:
    """One post: a DOM message element, its body fragment, and the author line.

    The stamp is an absolute date rather than "Yesterday ...": the reader parses
    a page stamp against the clock it is actually running on, and a test that
    depends on that clock passes today and fails tomorrow.
    """
    body = "Quiz 3 | ย้ายไปวันศุกร์\nNo late submissions."
    page = FakePage(
        teams={TEAM: [CHANNEL]},
        message_elements=[
            _message_element(author="Dr Smith", stamp="27 September 2026 14:32", box=_box(100))
        ],
    )
    fragments = [
        _fragment("C000", "Chat", 10, 40, width=60),
        _fragment("C001", body, 20, 110, width=400),
    ]
    return page, [fragments], page.message_elements[0]


def test_a_post_body_is_stored_verbatim(browser: FakeBrowser, settings: Settings):
    """The whole point of the read: a paraphrase of a moved deadline is a wrong one.

    The exact string is asserted, pipes, Thai script and the newline included.
    """
    browser.page, browser.passes, _ = _announcement_page()
    body = browser.passes[0][1].text

    messages = _read(browser, FakeJudge(posts=[ScriptedPost(marker="Quiz 3")]), settings)

    assert [message.body for message in messages] == [body]
    assert "ย้ายไปวันศุกร์" in messages[0].body
    assert "\n" in messages[0].body


def test_the_author_and_the_posted_time_are_read_from_the_message_element(
    browser: FakeBrowser, settings: Settings
):
    browser.page, browser.passes, _ = _announcement_page()

    (message,) = _read(browser, FakeJudge(posts=[ScriptedPost(marker="Quiz 3")]), settings)

    assert message.author == "Dr Smith"
    # 14:32 on 27 September in Dublin (IST, UTC+1) is 13:32 UTC.
    assert message.posted_at == datetime(2026, 9, 27, 13, 32, tzinfo=UTC)


def test_every_posted_at_crossing_the_boundary_is_timezone_aware_utc(
    browser: FakeBrowser, settings: Settings
):
    browser.page, browser.passes, _ = _announcement_page()

    (message,) = _read(browser, FakeJudge(posts=[ScriptedPost(marker="Quiz 3")]), settings)

    assert message.posted_at.utcoffset() == timedelta(0)
    assert message.source == "teams"
    assert message.team == TEAM
    assert message.channel == CHANNEL


def test_a_post_with_no_message_element_falls_back_to_the_text_above_it(
    browser: FakeBrowser, settings: Settings
):
    """Capture finds the post; the header is the fragment sitting above it.

    The author and the stamp are their own short fragments and are not posts, so
    the judge never selects them - which is why the header has to be read from
    every fragment on the page and not just from the selected ones.
    """
    browser.page = _sidebar()
    browser.passes = [
        [
            _fragment("C000", "Dr Smith", 10, 100, width=80),
            _fragment("C001", "24 September 2026 09:15", 400, 100, width=120),
            _fragment("C002", "The lab has moved to Thursday 10am.", 10, 140, width=300),
        ]
    ]

    (message,) = _read(browser, FakeJudge(posts=[ScriptedPost(marker="lab has moved")]), settings)

    assert message.author == "Dr Smith"
    assert message.posted_at == datetime(2026, 9, 24, 8, 15, tzinfo=UTC)  # 09:15 IST
    assert message.body == "The lab has moved to Thursday 10am."


def test_a_post_with_no_words_of_its_own_is_dropped_rather_than_summarised(
    browser: FakeBrowser, settings: Settings
):
    """A picture or a sticker has no text to copy, and a summary is not a copy.

    `body` is either the page's own words or nothing at all. What must never
    happen is a stored body the page did not show, so a post whose captured text
    turns out to be only its header is dropped.
    """
    browser.page = FakePage(
        teams={TEAM: [CHANNEL]},
        message_elements=[
            _message_element(author="Dr Smith", stamp="24 September 2026 09:15", box=_box(100))
        ],
    )
    browser.passes = [[_fragment("C001", "Dr Smith24 September 2026 09:15", 20, 110, width=300)]]
    judge = FakeJudge(select_all=True)

    assert _read(browser, judge, settings) == []


def test_a_file_named_in_a_post_is_carried_as_an_attachment(
    browser: FakeBrowser, settings: Settings
):
    """Attachments matter in Phase 4, and the file name is on the page, not inferred."""
    browser.page = _sidebar()
    browser.passes = [
        [
            _fragment("C000", "Dr Smith", 10, 100, width=80),
            _fragment("C001", "24 September 2026 09:15", 400, 100, width=120),
            _fragment("C002", "The brief is attached.", 10, 140, width=200),
            _fragment("C003", "Project brief v2.pdf", 10, 160, width=160),
        ]
    ]

    (message,) = _read(
        browser, FakeJudge(posts=[ScriptedPost(marker="brief is attached")]), settings
    )

    assert message.attachments == ["Project brief v2.pdf"]


# --- one channel must not cost the others ----------------------------------------------


def test_a_message_list_that_cannot_be_read_saves_the_page_and_raises(
    browser: FakeBrowser, settings: Settings
):
    """Empty and unreadable are different claims, and only one of them is safe.

    "No messages" is a statement about the user's channels. When the list itself
    is missing, the reader must say it does not know, and leave the evidence for
    a selector fix.
    """
    browser.page = FakePage(teams={TEAM: [CHANNEL]}, has_message_list=False)
    browser.passes = []
    judge = FakeJudge()

    with pytest.raises(BrowserError) as raised:
        _read(browser, judge, settings)

    assert browser.diagnostics == ["teams-CS301_Algorithms-General"]
    assert browser.saved("teams-CS301_Algorithms-General") in str(raised.value)
    assert judge.calls == []


def test_an_empty_channel_is_empty_rather_than_a_failure(browser: FakeBrowser, settings: Settings):
    """A channel with posts nobody has written yet is not a broken read."""
    browser.page = _sidebar()
    browser.passes = [[]]
    judge = FakeJudge()

    assert _read(browser, judge, settings) == []
    assert browser.diagnostics == []


def test_a_channel_missing_from_the_sidebar_is_refused_rather_than_read(
    browser: FakeBrowser, settings: Settings
):
    """Reading whatever is on screen would file another channel's posts here."""
    browser.page = FakePage(teams={TEAM: ["Announcements"]})
    browser.passes = [[_fragment("C000", "Nope", 10, 10)]]

    with pytest.raises(BrowserError) as raised:
        _read(browser, FakeJudge(select_all=True), settings)

    assert CHANNEL in str(raised.value)
    assert browser.captured == 0


def test_a_channel_that_fails_does_not_stop_the_others(
    browser: FakeBrowser, settings: Settings, caplog: pytest.LogCaptureFixture
):
    """The other nine channels are the reason the tool reads Teams at all."""
    browser.page = FakePage(teams={TEAM: [CHANNEL, "Announcements"]})
    post = "The deadline for assignment 2 is now 5 October."
    browser.by_channel = {
        f"{TEAM}/{CHANNEL}": [[_fragment("C001", post, 10, 110, width=400)]],
    }
    browser.failures = {f"{TEAM}/Announcements": RuntimeError("the page navigated away")}
    judge = FakeJudge(posts=[ScriptedPost(marker="deadline", deadline=0.95)])

    with caplog.at_level(logging.WARNING, logger="pli"):
        messages = read_messages(settings, judge, since=NOW - timedelta(days=7))

    assert [message.body for message in messages] == [post]
    assert any(
        "skipping CS301 Algorithms / Announcements" in record.message for record in caplog.records
    )
    assert any("RuntimeError" in record.getMessage() for record in caplog.records)


def test_a_session_that_dies_mid_read_stops_the_read(browser: FakeBrowser, settings: Settings):
    """A dead session is not one broken channel, and must not be skipped like one.

    Every channel after this one fails the same way, so carrying on and returning
    the posts read before it hands the caller a half-read channel list that looks
    finished - and the caller moves its sync cursor past announcements nobody
    looked at. `pli.browser.session` keeps this failure distinct for exactly this
    reason, and `pli sync` turns it into "not read" rather than "no messages", so
    it has to reach them: the per-channel isolation below is for a channel that
    broke, not for a profile that did.
    """
    browser.page = FakePage(teams={TEAM: [CHANNEL, "Announcements"]})
    post = "The deadline for assignment 2 is now 5 October."
    browser.by_channel = {f"{TEAM}/{CHANNEL}": [[_fragment("C001", post, 10, 110, width=400)]]}
    browser.failures = {f"{TEAM}/Announcements": SessionError("redirected to a sign-in screen")}
    judge = FakeJudge(posts=[ScriptedPost(marker="deadline", deadline=0.95)])

    with pytest.raises(SessionError):
        read_messages(settings, judge, since=NOW - timedelta(days=7))


# --- read-only, and only channels the user is already in ---------------------------------


def test_a_read_clicks_nothing_but_the_sidebar(browser: FakeBrowser, settings: Settings):
    """The reader is READ-ONLY, and a click is its only way to change the page.

    Every other control in a conversation - reply, react, send, "See more" -
    writes to the channel as the user. That is not this tool's to do: it runs
    against a real student account on a schedule, and a reaction or a reply it
    sent cannot be taken back. Nothing about it would show in the output either -
    the posts still read back correctly - so the rule is pinned to the clicks
    that are allowed, not to a symptom of the ones that are not. The sidebar
    entries and the declared "older messages" control only navigate or scroll,
    which is why they are the whole allowed set. Every click site the reader has
    is exercised here, the "load more" one included, so a new one has nowhere to
    hide.
    """
    browser.page = FakePage(
        teams={TEAM: [CHANNEL]},
        message_elements=[
            _message_element(author="Dr Smith", stamp="27 September 2026 14:32", box=_box(100))
        ],
        has_more_messages=True,
    )
    # Already at the top: the list has nothing left to scroll, which is the case
    # the explicit control exists for.
    browser.page.scroll = [0]
    browser.passes = [[_fragment("C001", "The exam is on 5 October.", 20, 110, width=400)]]

    _read(browser, FakeJudge(posts=[ScriptedPost(marker="exam is on", deadline=0.9)]), settings)

    assert set(browser.page.clicked) <= {
        "teams_app_bar",
        "teams_channel_item",
        "teams_more_messages",
    }, f"the reader clicked {browser.page.clicked}, which is not all navigation"


def test_an_older_messages_control_is_used_when_the_view_has_one(
    browser: FakeBrowser, settings: Settings
):
    """Loading older posts is still a read, and a channel that needs the control
    must not come back looking quiet.

    Teams renders this differently by view: some lists scroll, some put an
    explicit control at the top. Only the second kind needs the click, and a
    reader that ignored it would return whatever happened to be on screen - the
    newest few posts - as the whole channel.
    """
    browser.page = FakePage(teams={TEAM: [CHANNEL]}, has_more_messages=True)
    browser.page.scroll = [0]  # the list is already at the top: it cannot scroll
    browser.passes = [[_fragment("C001", "The exam is on 5 October.", 10, 110, width=300)]]

    _read(browser, FakeJudge(select_all=True), settings)

    assert "teams_more_messages" in browser.page.clicked


def test_a_read_navigates_nowhere_but_the_teams_page(browser: FakeBrowser, settings: Settings):
    """Membership is the access control, so the reader never goes looking.

    A channel found by searching, or a "join a team" directory, is not a channel
    the user is in: reading it would file posts from a course they are not
    enrolled in as though they were theirs, and hand the planner work for a
    module that is not theirs to do. The sidebar is the whole universe of
    channels this tool may see, and it reaches one by clicking what the rail
    already offers - so the only address it may open is the Teams page itself.
    """
    browser.page = FakePage(teams={TEAM: [CHANNEL]})
    browser.passes = [[_fragment("C001", "The exam is on 5 October.", 10, 110, width=300)]]

    read_messages(settings, FakeJudge(select_all=True), since=NOW - timedelta(days=7))

    assert set(browser.page.gotos) <= {settings.teams_url}, (
        f"the reader navigated to {browser.page.gotos}; it may only open the Teams page"
    )


# --- the window, and the cap ------------------------------------------------------------


def _two_posts() -> list[Candidate]:
    return [
        _fragment("C000", "Old news from last month.", 10, 110, width=300),
        _fragment("C001", "The exam is on 5 October.", 10, 300, width=300),
    ]


def test_posts_older_than_since_are_not_returned(browser: FakeBrowser, settings: Settings):
    """A cursor that reaches back a week must not re-read the whole channel."""
    browser.page = _sidebar()
    browser.passes = [_two_posts()]
    browser.page.message_elements = [
        _message_element(author="Dr Smith", stamp="2026-08-01 09:00", box=_box(100)),
        _message_element(author="Dr Smith", stamp="2026-09-27 09:00", box=_box(290)),
    ]
    judge = FakeJudge(posts=[ScriptedPost(marker="exam is on", deadline=0.9)])

    messages = read_messages(settings, judge, since=datetime(2026, 9, 20, tzinfo=UTC))

    assert [message.body for message in messages] == ["The exam is on 5 October."]


def test_a_since_with_no_zone_is_refused(browser: FakeBrowser, settings: Settings):
    """An anchor with no zone cannot say which posts are inside the window.

    Every stamp that reaches the comparison was read off the page and resolved
    into UTC, so a naive `since` would be taken as UTC and shift the window by
    hours - the same class of mistake `resolve_relative_date` refuses, and a
    "moved deadline" that silently falls outside the cursor is not recoverable.
    """
    with pytest.raises(ValueError, match="timezone-aware"):
        read_messages(settings, FakeJudge(), since=datetime(2026, 9, 20))


def test_max_per_channel_caps_what_one_channel_returns(browser: FakeBrowser, settings: Settings):
    """A channel with years of history must not decide how long a sync takes."""
    browser.page = _sidebar()
    browser.passes = [_two_posts()]
    judge = FakeJudge(select_all=True)

    messages = read_messages(settings, judge, since=NOW - timedelta(days=3650), max_per_channel=1)

    assert len(messages) == 1


def test_only_the_requested_teams_are_read(browser: FakeBrowser, settings: Settings):
    browser.page = FakePage(teams={TEAM: [CHANNEL], "MA101 Calculus": ["General"]})
    browser.by_channel = {
        f"{TEAM}/{CHANNEL}": [[_fragment("C001", "Algorithms post.", 10, 110, width=300)]],
        "MA101 Calculus/General": [[_fragment("C002", "Calculus post.", 10, 110, width=300)]],
    }
    judge = FakeJudge(select_all=True)

    messages = read_messages(
        settings, judge, since=NOW - timedelta(days=7), teams=["MA101 Calculus"]
    )

    assert [message.body for message in messages] == ["Calculus post."]


# --- ids: the same post must not be stored twice -----------------------------------------


def test_two_identical_reads_produce_identical_external_ids(
    browser: FakeBrowser, settings: Settings
):
    """A nightly sync re-reads the same posts; the id is what stops the duplicates."""
    judge = FakeJudge(posts=[ScriptedPost(marker="Quiz 3")])

    browser.page, browser.passes, _ = _announcement_page()
    first = _read(browser, judge, settings)

    browser.page, browser.passes, _ = _announcement_page()
    second = _read(browser, judge, settings)

    assert [message.external_id for message in first] == [message.external_id for message in second]
    assert first[0].external_id.startswith("teams:")


def test_the_same_text_in_two_channels_is_two_messages(browser: FakeBrowser, settings: Settings):
    """The id is per channel: a shared announcement is still posted twice."""
    body = "Registration closes on Friday."
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", body, 10, 110, width=300)]]
    judge = FakeJudge(select_all=True)

    here = _read(browser, judge, settings)
    there = read_channel(settings, judge, team="MA101 Calculus", channel=CHANNEL, page=browser.page)

    assert here[0].external_id != there[0].external_id
    assert here[0].body == there[0].body == body


# --- the judgements the caller owns --------------------------------------------------------


def test_a_post_with_nothing_about_deadlines_is_returned_with_a_low_probability(
    browser: FakeBrowser, settings: Settings
):
    """The reader does not filter; the caller owns the threshold.

    A post that says nothing about assessment is still a post the user might
    need, and dropping it here would be the reader making a policy decision.
    """
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", "Anyone up for football tonight?", 10, 110, width=300)]]
    judge = FakeJudge(posts=[ScriptedPost(marker="football", deadline=0.02)])

    (message,) = _read(browser, judge, settings)

    judged = last_judgements()[message.external_id]
    assert judged.deadline == 0.02
    assert message.body == "Anyone up for football tonight?"


def test_a_deadline_announcement_keeps_its_own_probability(
    browser: FakeBrowser, settings: Settings
):
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", "Quiz 3 moves to Friday.", 10, 110, width=300)]]
    judge = FakeJudge(posts=[ScriptedPost(marker="Quiz 3", deadline=0.97)])

    (message,) = _read(browser, judge, settings)

    assert last_judgements()[message.external_id].deadline == 0.97


def test_the_course_question_always_offers_a_way_to_say_no_course(
    browser: FakeBrowser, settings: Settings
):
    """A message must never be forced onto a course that does not own it."""
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", "The exam is on 5 October.", 10, 110, width=300)]]
    judge = FakeJudge(posts=[ScriptedPost(marker="exam is on")])

    _read(browser, judge, settings)

    questions = _call_with(judge, "p0.course")
    assert TEAM in questions["p0.course"].criteria
    assert "none" in questions["p0.course"].criteria


def test_a_post_the_judge_calls_unrelated_is_not_given_the_channels_course(
    browser: FakeBrowser, settings: Settings
):
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", "Selling a spare textbook.", 10, 110, width=300)]]
    judge = FakeJudge(posts=[ScriptedPost(marker="textbook", course="none")])

    (message,) = _read(browser, judge, settings)

    assert last_judgements()[message.external_id].course is None


def test_the_date_a_post_names_is_resolved_in_python_not_by_the_model(
    browser: FakeBrowser, settings: Settings
):
    """The model reports the words; the calendar arithmetic happens here.

    "Due next Thursday", posted on Monday 28 September, is the 1st of October -
    a fact no question was asked, and the one thing a model asked for a date
    would most likely get wrong. The anchor is the post's own stamp, not the day
    this read happens to run on.
    """
    browser.page = _sidebar()
    browser.passes = [
        [
            _fragment("C000", "Dr Smith", 10, 60, width=80),
            _fragment("C001", "28 September 2026 09:00", 400, 60, width=120),
            _fragment("C002", "Quiz 3 is next Thursday.", 10, 110, width=300),
        ]
    ]
    judge = FakeJudge(
        posts=[
            ScriptedPost(
                marker="Quiz 3",
                deadline=0.9,
                stated=True,
                weekday="Thursday",
                relative="next_weekday",
            )
        ]
    )

    (message,) = _read(browser, judge, settings)

    judged = last_judgements()[message.external_id]
    assert message.posted_at == datetime(2026, 9, 28, 8, 0, tzinfo=UTC)  # 09:00 IST, a Monday
    assert judged.course is None
    # Midnight on 1 October in Dublin, which is IST (UTC+1).
    assert judged.due_at == datetime(2026, 9, 30, 23, 0, tzinfo=UTC)


def test_a_post_that_names_no_day_has_no_due_at(browser: FakeBrowser, settings: Settings):
    """A guessed date would invent work with a deadline the user never had."""
    browser.page = _sidebar()
    browser.passes = [[_fragment("C001", "Revision session soon.", 10, 110, width=300)]]
    judge = FakeJudge(posts=[ScriptedPost(marker="Revision", deadline=0.6)])

    (message,) = _read(browser, judge, settings)

    assert last_judgements()[message.external_id].due_at is None


# --- what the judge is allowed to be asked --------------------------------------------


def test_a_channel_of_many_posts_never_exceeds_the_judges_limits(
    browser: FakeBrowser, settings: Settings
):
    """One question per post does not scale, and an oversized batch fails the read.

    The options in a single Choice and the questions in a single request both
    have ceilings; blowing past either loses the whole channel, so the reader
    splits its own questions rather than relying on the transport to. Seven
    questions per post means 200 posts is fourteen hundred questions, which has
    to arrive as several requests.
    """
    browser.page = _sidebar()
    count = 200
    browser.passes = [
        [
            _fragment(f"C{index:03d}", f"post {index} " + "x" * 40, 10, index * 220, width=300)
            for index in range(count)
        ]
    ]
    judge = FakeJudge(select_all=True)

    messages = _read(browser, judge, settings, max_messages=count)

    assert len(messages) == count
    for call in judge.calls:
        assert len(call) <= MAX_QUESTIONS_PER_CALL
        for name, question in call.items():
            if name == "is_post":
                assert len(question.criteria) <= MAX_OPTIONS
    asked = {name for call in judge.calls for name in call}
    assert len([name for name in asked if name.endswith(".deadline")]) == count


def test_a_capture_larger_than_the_option_limit_is_trimmed_to_the_longest_fragments(
    browser: FakeBrowser, settings: Settings
):
    """A Choice takes at most 255 options; a post is longer than page furniture."""
    browser.page = _sidebar()
    fragments = [
        _fragment(f"C{index:03d}", f"nav {index}", 10, index * 8, width=60) for index in range(400)
    ]
    fragments.append(_fragment("C999", "The exam is on 5 October, in the main hall.", 10, 6000))
    browser.passes = [fragments]
    judge = FakeJudge(posts=[ScriptedPost(marker="exam is on", deadline=0.9)])

    messages = _read(browser, judge, settings)

    assert [message.body for message in messages] == ["The exam is on 5 October, in the main hall."]
    assert len(judge.calls[0]["is_post"].criteria) == MAX_OPTIONS


# --- the relative-date resolver ---------------------------------------------------------


def _resolved(parts: DateParts, *, now: datetime = NOW, tz: str = "UTC", at: time | None = None):
    return resolve_relative_date(parts, now=now, tz=ZoneInfo(tz), at=at)


def test_today_resolves_to_the_day_the_post_was_written():
    parts = DateParts(stated=True, relative="today")

    assert _resolved(parts) == datetime(2026, 9, 28, tzinfo=UTC)


def test_tomorrow_resolves_to_the_next_day():
    parts = DateParts(stated=True, relative="tomorrow")

    assert _resolved(parts) == datetime(2026, 9, 29, tzinfo=UTC)


def test_next_thursday_said_on_a_thursday_is_a_week_away():
    """The reason "next" is a separate part from the weekday.

    "Next X" means X, never today: a post that says "next Thursday" on a
    Thursday is talking about the Thursday after the one it was written on. The
    model reports the words, and this is the arithmetic that decides the day.
    """
    parts = DateParts(stated=True, weekday="thursday", relative="next_weekday")

    assert _resolved(parts, now=datetime(2026, 10, 1, 12, 0, tzinfo=UTC)) == datetime(
        2026, 10, 8, tzinfo=UTC
    )


def test_next_thursday_said_on_a_monday_is_the_coming_thursday():
    """And on a day that is not that weekday it is the next one to arrive."""
    parts = DateParts(stated=True, weekday="thursday", relative="next_weekday")

    assert _resolved(parts) == datetime(2026, 10, 1, tzinfo=UTC)  # a Monday to a Thursday


def test_a_weekday_already_past_this_week_means_next_week():
    """Nothing due can be in the past, so a weekday already gone means the next one.

    Said on Thursday the 1st, "Monday" is the 5th - and the two days of that
    week that have already happened are not candidates.
    """
    parts = DateParts(stated=True, weekday="monday")

    assert _resolved(parts, now=datetime(2026, 10, 1, 12, 0, tzinfo=UTC)) == datetime(
        2026, 10, 5, tzinfo=UTC
    )


def test_a_weekday_that_is_today_resolves_to_today():
    parts = DateParts(stated=True, weekday="monday")

    assert _resolved(parts) == datetime(2026, 9, 28, tzinfo=UTC)


def test_a_month_and_day_in_the_future_keeps_this_year():
    parts = DateParts(stated=True, month=10, day=5)

    assert _resolved(parts) == datetime(2026, 10, 5, tzinfo=UTC)


def test_a_month_and_day_that_has_just_passed_rolls_into_next_year():
    """A December post naming January is talking about next year."""
    parts = DateParts(stated=True, month=1, day=5)

    assert _resolved(parts, now=datetime(2026, 12, 20, tzinfo=UTC)) == datetime(
        2027, 1, 5, tzinfo=UTC
    )


def test_a_bare_day_number_rolls_into_the_next_month():
    """End of September naming "the 5th" means October's 5th, not a past one."""
    parts = DateParts(stated=True, day=5)

    assert _resolved(parts) == datetime(2026, 10, 5, tzinfo=UTC)


def test_a_bare_day_number_finds_a_month_that_has_that_day():
    """A bare "31st" said in September is October's 31st, the next month with one."""
    parts = DateParts(stated=True, day=31)

    assert _resolved(parts) == datetime(2026, 10, 31, tzinfo=UTC)


def test_a_date_that_does_not_exist_is_no_date():
    """February has no 30th; a rolled-over guess would be an invented deadline."""
    assert _resolved(DateParts(stated=True, month=2, day=30)) is None


def test_nothing_stated_is_no_date():
    assert _resolved(DateParts(stated=False)) is None
    assert _resolved(DateParts(stated=True)) is None


def test_a_stated_clock_time_replaces_local_midnight():
    parts = DateParts(stated=True, month=10, day=5)

    assert _resolved(parts, at=time(17, 0), tz=DUBLIN) == datetime(2026, 10, 5, 16, 0, tzinfo=UTC)


def test_the_hour_before_a_spring_forward_jump_is_still_a_five_hour_offset():
    """Local midnight is a moment in the zone, and the zone changes its offset.

    A naive implementation adds a fixed offset and puts this deadline an hour
    out - which is exactly the kind of error that only shows up twice a year.
    """
    parts = DateParts(stated=True, relative="tomorrow")

    assert _resolved(parts, now=datetime(2026, 3, 7, 17, 0, tzinfo=UTC), tz=NEW_YORK) == (
        datetime(2026, 3, 8, 5, 0, tzinfo=UTC)  # EST, the clocks jump at 02:00
    )


def test_the_hour_after_a_spring_forward_jump_is_a_four_hour_offset():
    """The same local midnight, one day later, is an hour earlier in UTC."""
    parts = DateParts(stated=True, relative="tomorrow")

    assert _resolved(parts, now=datetime(2026, 3, 9, 12, 0, tzinfo=UTC), tz=NEW_YORK) == (
        datetime(2026, 3, 10, 4, 0, tzinfo=UTC)  # EDT
    )


def test_the_fall_back_hour_is_handled_by_the_same_arithmetic():
    parts = DateParts(stated=True, relative="tomorrow")

    before = _resolved(parts, now=datetime(2026, 10, 31, 12, 0, tzinfo=UTC), tz=NEW_YORK)
    after = _resolved(parts, now=datetime(2026, 11, 1, 12, 0, tzinfo=UTC), tz=NEW_YORK)

    assert before == datetime(2026, 11, 1, 4, 0, tzinfo=UTC)  # EDT
    assert after == datetime(2026, 11, 2, 5, 0, tzinfo=UTC)  # EST again


def test_the_day_a_post_names_is_a_day_in_the_users_zone_not_in_utc():
    """23:30 in Dublin is still the 28th, though UTC has not long left of it.

    "Today" has to mean the user's today: resolved against the UTC date instead,
    this deadline would move to the wrong day for anyone east of Greenwich.
    """
    parts = DateParts(stated=True, relative="today")
    dublin = ZoneInfo(DUBLIN)

    resolved = _resolved(parts, now=datetime(2026, 9, 28, 22, 30, tzinfo=UTC), tz=DUBLIN)

    # Midnight on the 28th in Dublin, which is IST (UTC+1) and so the 27th in UTC.
    assert resolved.astimezone(dublin) == datetime(2026, 9, 28, 0, 0, tzinfo=dublin)
    assert resolved == datetime(2026, 9, 27, 23, 0, tzinfo=UTC)


def test_a_naive_now_is_refused():
    """An anchor with no zone cannot say which day a relative word means."""
    with pytest.raises(ValueError, match="timezone-aware"):
        resolve_relative_date(
            DateParts(stated=True, relative="today"), now=NOW.replace(tzinfo=None), tz=UTC
        )


# --- reading the page's own timestamp ----------------------------------------------------


def test_an_absolute_stamp_is_read_through_the_users_zone():
    assert parse_posted_at("12 September 2026 10:03", now=NOW, tz=ZoneInfo(DUBLIN)) == (
        datetime(2026, 9, 12, 9, 3, tzinfo=UTC)
    )


def test_a_relative_age_is_read_against_the_read_clock():
    assert parse_posted_at("12 minutes ago", now=NOW, tz=ZoneInfo(DUBLIN)) == (
        datetime(2026, 9, 28, 11, 48, tzinfo=UTC)
    )


def test_a_stamp_that_says_nothing_is_refused_rather_than_guessed():
    """A guessed stamp silently moves a post out of the `since` window."""
    assert parse_posted_at("Dr Smith", now=NOW, tz=ZoneInfo(DUBLIN)) is None
    assert parse_posted_at("", now=NOW, tz=ZoneInfo(DUBLIN)) is None
