"""The Outlook browser reader: what it must never get wrong.

The calendar read is the input to every scheduling decision the tool makes. If
it drops an event, the planner books study on top of a lecture; if it invents
one, it blocks time the user actually has. There is no way to notice either from
the output, so the properties tested here are the ones whose failure is silent:

* every event on the page is returned, and two events at the same time on
  different days stay two events;
* a row whose time cannot be read produces *nothing* - never a midnight event,
  which would free the whole day;
* an event is only ever treated as ours when its body carries our marker;
* a read that finds nothing raises and saves what the page looked like, so an
  unreadable page can never be mistaken for a free week;
* the id handed back by `create_event` is read off the page, never made up.

No browser is launched and no network is touched. The page and the judge are
hand-written fakes: a page that records what it was asked to do and answers from
a script, and a judge that returns canned values. Both read more clearly here
than a mock, and neither can accidentally become a real integration test.
"""

from __future__ import annotations

import sys
import types
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import pytest

from pli.browser import CALENDAR_NAME, BrowserError, SessionError
from pli.browser import session as real_session
from pli.browser.outlook import OutlookBackend, read_week
from pli.config import Settings
from pli.judge import Candidate, Verbatim
from pli.models import Block, RemoteEvent
from pli.planner.apply import body_for, read_marker

DUBLIN = "Europe/Dublin"
#: A Monday in Irish Summer Time (UTC+1), so a local 10:00 is 09:00 UTC and any
#: naive handling of the zone shows up immediately.
WEEK_START = datetime(2026, 10, 5, 0, 0, tzinfo=ZoneInfo(DUBLIN))
WEEK_END = WEEK_START + timedelta(days=7)

MONDAY_10AM = datetime(2026, 10, 5, 9, 0, tzinfo=UTC)
TUESDAY_10AM = datetime(2026, 10, 6, 9, 0, tzinfo=UTC)

BLOCK_KEY = "a1b2c3d4e5f60718"


# --- the fake page ---------------------------------------------------------------


class FakeSelectors:
    """The selector set this module codes against, spelled out for the tests."""

    outlook_week_grid = "div[role='grid'][aria-label='Calendar']"
    outlook_event = "div[role='button'][data-event-id]"
    outlook_event_subject = "[class*='subject']"
    outlook_event_time = "[class*='time']"
    outlook_new_event_button = "button[name='new-event']"
    outlook_title_field = "input[name='title']"
    outlook_start_field = "input[name='start']"
    outlook_end_field = "input[name='end']"
    outlook_calendar_picker = "div[role='listbox'][aria-label='Calendars']"
    outlook_save_button = "button[name='save']"
    outlook_delete_button = "button[name='delete']"


class _FakeLocator:
    def __init__(self, page: FakePage, selector: str) -> None:
        self._page = page
        self._selector = selector

    def count(self) -> int:
        if CALENDAR_NAME in self._selector:
            return 1 if self._page.has_calendar else 0
        return 0


class FakePage:
    """A Playwright `Page` that records calls and answers from a script.

    Everything this module is allowed to do to a real page is here and nothing
    else, so a test that passes really has exercised the whole interaction.
    """

    def __init__(
        self,
        *,
        has_calendar: bool = True,
        dom_events: list[dict[str, Any]] | None = None,
        openable: tuple[str, ...] = (),
        body: str = "",
        sticky_delete: bool = False,
    ) -> None:
        self.has_calendar = has_calendar
        self.dom_events = [dict(entry) for entry in (dom_events or [])]
        self.openable = set(openable)
        self.body = body
        #: A delete that the page silently declined to carry out - a
        #: confirmation dialog still waiting, for instance.
        self.sticky_delete = sticky_delete
        self.fills: list[tuple[str, str]] = []
        self.clicks: list[str] = []
        self.gotos: list[str] = []
        self.opened = ""
        #: Where the page has landed. The real read asks this to tell an expired
        #: session from a restyled calendar; the default is the calendar itself,
        #: so only a test that sets a login URL sees the refusal.
        self.url = "https://outlook.office.com/calendar/view/week"

    def goto(self, url: str) -> None:
        self.gotos.append(url)

    def wait_for_selector(self, selector: str, timeout: int | None = None) -> None:
        return None

    def locator(self, selector: str) -> _FakeLocator:
        return _FakeLocator(self, selector)

    def click(self, selector: str, timeout: int | None = None) -> None:
        self.clicks.append(selector)
        if "delete" in selector and not self.sticky_delete:
            self.dom_events = [e for e in self.dom_events if e.get("id") != self.opened]

    def fill(self, selector: str, value: str) -> None:
        self.fills.append((selector, value))

    def input_value(self, selector: str) -> str:
        return dict(self.fills).get(selector, "")

    def inner_text(self, selector: str) -> str:
        return self.body

    def evaluate(self, expression: str, arg: Any = None) -> Any:
        if "pliDomEvents" in expression:
            return [dict(entry) for entry in self.dom_events]
        if "pliOpenEvent" in expression:
            self.opened = str(arg[1])
            return self.opened in self.openable
        raise AssertionError(f"the reader ran a script it should not have: {expression[:60]}")


# --- the fake judge --------------------------------------------------------------


@dataclass
class _Answer:
    choice: str
    confidence: float = 0.99
    probabilities: dict[str, float] = field(default_factory=dict)


@dataclass
class _Judgements:
    choices: dict[str, _Answer]

    def choice(self, name: str, *, minimum_confidence: float = 0.0) -> str | None:
        answer = self.choices.get(name)
        if answer is None or answer.confidence < minimum_confidence:
            return None
        return answer.choice


class FakeJudge:
    """A `pli.judge.Judge` with canned answers, recording what it was asked.

    `header` holds one canned answer set per day-header call, in order, so a test
    can make the first line of a page answer nothing at all. `rows` maps a word
    that appears in the row's state to the answers for that row.
    """

    def __init__(
        self,
        *,
        header: list[dict[str, str]] | None = None,
        rows: dict[str, dict[str, str]] | None = None,
        all_day: float = 0.0,
    ) -> None:
        self.header = list(header or [{}])
        self.rows = dict(rows or {})
        self.all_day = all_day
        self.header_states: list[str] = []
        self.row_states: list[str] = []
        self.confirms = 0

    def ask(self, state: Any, questions: Any) -> _Judgements:
        self.header_states.append(str(state))
        index = min(len(self.header_states) - 1, len(self.header) - 1)
        answers = self.header[index] if self.header else {}
        return _Judgements({name: _Answer(answers[name]) for name in questions if name in answers})

    def asks(
        self,
        state: Any,
        *,
        questions: Any,
        candidates: list[Candidate],
        minimum_confidence: float = 0.0,
    ) -> dict[str, Verbatim | None]:
        self.row_states.append(str(state))
        answers = self._answers_for(str(state))
        by_text = {candidate.text: candidate for candidate in candidates}
        found: dict[str, Verbatim | None] = {}
        for name in questions:
            match = by_text.get(answers.get(name, ""))
            found[name] = (
                Verbatim(text=match.text, candidate_id=match.id, confidence=0.99)
                if match is not None
                else None
            )
        return found

    def confirm(self, state: Any, *, question: str, name: str = "confirm") -> float:
        self.confirms += 1
        return self.all_day

    def locate(self, state: Any, **kwargs: Any) -> Verbatim | None:  # pragma: no cover
        raise AssertionError("this reader must not locate candidates one at a time")

    def _answers_for(self, state: str) -> dict[str, str]:
        for key, answers in self.rows.items():
            if key in state:
                return answers
        # A single row is unambiguous: the test only has one event in play.
        return next(iter(self.rows.values())) if len(self.rows) == 1 else {}


# --- wiring ----------------------------------------------------------------------


@dataclass
class FakeBrowser:
    """The three sibling modules, faked, plus what they recorded."""

    tmp_path: Any
    candidates: list[Candidate] = field(default_factory=list)
    diagnostics: list[str] = field(default_factory=list)
    page: FakePage = field(default_factory=FakePage)

    def saved(self, label: str) -> str:
        return str(self.tmp_path / f"{label}.txt")


@pytest.fixture
def settings() -> Settings:
    return Settings(pli_timezone=DUBLIN)


@pytest.fixture
def browser(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> FakeBrowser:
    """Install fake session/capture/selectors modules.

    They are injected into `sys.modules` rather than imported, because the real
    ones open a browser and read config - and because this module imports them
    lazily, which is what makes the injection possible at all.
    """
    fake = FakeBrowser(tmp_path=tmp_path)

    def capture_candidates(
        page: Any, *, selectors: Any = None, limit: int = 400
    ) -> list[Candidate]:
        return list(fake.candidates)

    def diagnostics(page: Any, settings: Any, *, label: str) -> Any:
        fake.diagnostics.append(label)
        path = tmp_path / f"{label}.txt"
        path.write_text("what the page looked like")
        return path

    capture = types.ModuleType("pli.browser.capture")
    capture.capture_candidates = capture_candidates
    capture.diagnostics = diagnostics

    selectors = types.ModuleType("pli.browser.selectors")

    def load(path: Any = None) -> Any:
        # Mirrors the real `selectors.load`, whose `path` is optional: the
        # reader calls it with no argument, so a required parameter here
        # would reject the real call shape and fail every read.
        return FakeSelectors()

    selectors.load = load

    session = types.ModuleType("pli.browser.session")

    @contextmanager
    def _session(settings: Any, *, headless: bool | None = None) -> Any:
        yield fake.page

    session.session = _session
    # Mirrored from the real module, not stubbed: the read now asks whether the
    # page is a sign-in wall before waiting for the grid, and whether a URL
    # counts as one is the rule under test - a stub would answer whatever the
    # test expected rather than what the tool would do.
    session.require_signed_in = real_session.require_signed_in

    monkeypatch.setitem(sys.modules, "pli.browser.capture", capture)
    monkeypatch.setitem(sys.modules, "pli.browser.selectors", selectors)
    monkeypatch.setitem(sys.modules, "pli.browser.session", session)
    return fake


# --- building a page -------------------------------------------------------------


def _text(
    id: str, text: str, x: float, y: float, *, width: float = 80.0, height: float = 18.0
) -> Candidate:
    return Candidate(id=id, text=text, x=x, y=y, width=width, height=height)


def _day_headers(
    labels: tuple[str, ...] = ("Mon 5 Oct", "Tue 6 Oct"),
    *,
    x: float = 50.0,
    step: float = 200.0,
    width: float = 120.0,
    y: float = 20.0,
) -> list[Candidate]:
    """A header strip: label centres 200px apart, so the day boundary is midway."""
    return [
        _text(f"H{index}", label, x + index * step, y, width=width)
        for index, label in enumerate(labels)
    ]


def _header_answers(days: list[tuple[str, int, str]]) -> dict[str, str]:
    answers: dict[str, str] = {}
    for index, (month, day, weekday) in enumerate(days):
        answers[f"h{index}_mode"] = "absolute"
        answers[f"h{index}_month"] = month
        answers[f"h{index}_day"] = str(day)
        answers[f"h{index}_weekday"] = weekday
        answers[f"h{index}_year"] = "none"
    return answers


MONDAY_AND_TUESDAY = _header_answers([("Oct", 5, "Mon"), ("Oct", 6, "Tue")])


def _block(**overrides: Any) -> Block:
    fields: dict[str, Any] = {
        "block_key": BLOCK_KEY,
        "task_key": "task-1",
        "subject": "Calculus: problem sheet 3",
        "start": MONDAY_10AM,
        "end": MONDAY_10AM + timedelta(hours=1),
    }
    fields.update(overrides)
    return Block(**fields)


def _chip(id: str, subject: str, time: str, *, x: float, y: float) -> list[Candidate]:
    """One event chip: a title line with its time range under it."""
    return [
        _text(id, subject, x, y, width=110.0),
        _text(f"{id}t", time, x, y + 20, width=90.0),
    ]


# --- geometry: rows and columns --------------------------------------------------


def test_two_events_at_the_same_time_on_different_days_are_two_events(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Two chips on one visual line must not collapse into one event.

    This is the shape of a normal timetable - the same 10:00 lecture on Monday
    and Tuesday - and merging them would drop a class.
    """
    browser.candidates = [
        *_day_headers(),
        *_chip("M", "Calculus", "10:00 AM", x=60, y=100),
        *_chip("T", "Physics", "10:00 AM", x=260, y=100),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"},
            "Physics": {"subject": "Physics", "start": "10:00 AM", "end": "11:00 AM"},
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert [event.subject for event in events] == ["Calculus", "Physics"]
    assert [event.start for event in events] == [MONDAY_10AM, TUESDAY_10AM]


def test_two_events_stacked_in_one_day_are_two_events(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Two chips in one day column must not merge, even though they share an x."""
    browser.candidates = [
        *_day_headers()[0:2],
        *_chip("A", "Calculus", "10:00 AM", x=60, y=100),
        *_chip("B", "Physics", "2:00 PM", x=60, y=200),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"},
            "Physics": {"subject": "Physics", "start": "2:00 PM", "end": "4:00 PM"},
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert [event.subject for event in events] == ["Calculus", "Physics"]
    assert [event.start for event in events] == [
        MONDAY_10AM,
        MONDAY_10AM + timedelta(hours=4),
    ]


def test_an_event_straddling_a_day_boundary_is_placed_by_where_its_middle_falls(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A chip drawn across the column edge still belongs to exactly one day.

    The label centres are 200px apart, so the boundary is at x=210. This chip
    starts left of it and ends right of it; its centre decides.
    """
    browser.candidates = [
        *_day_headers(),
        _text("X1", "Calculus", 185, 100, width=60.0),
        _text("X2", "10:00 AM", 185, 120, width=60.0),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert len(events) == 1
    assert events[0].start == TUESDAY_10AM


def test_page_furniture_above_the_day_headers_is_not_read_as_an_event(
    browser: FakeBrowser, settings: Settings
) -> None:
    """The reader tries the topmost lines in turn, and keeps only the day strip."""
    toolbar = [
        _text("F0", "Today", 50, 0.0, width=60.0),
        _text("F1", "Work week", 250, 0.0, width=80.0),
        _text("F2", "New event", 450, 0.0, width=80.0),
    ]
    browser.candidates = [
        *toolbar,
        *_day_headers(y=40.0),
        *_chip("M", "Calculus", "10:00 AM", x=60, y=120),
    ]
    judge = FakeJudge(
        header=[{}, MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert [event.subject for event in events] == ["Calculus"]


def test_a_line_of_page_furniture_costs_no_row_judgement(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Toolbar text is never asked about as if it might be a block."""
    toolbar = [
        _text("F0", "Today", 50, 0.0, width=60.0),
        _text("F1", "Work week", 250, 0.0, width=80.0),
    ]
    browser.candidates = [
        *toolbar,
        *_day_headers(y=40.0),
        *_chip("M", "Calculus", "10:00 AM", x=60, y=120),
    ]
    judge = FakeJudge(
        header=[{}, MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    read_week(settings, judge, WEEK_START, WEEK_END)

    assert len(judge.row_states) == 1
    assert "Today" not in judge.row_states[0]


# --- times ------------------------------------------------------------------------


def test_a_ten_am_row_becomes_ten_am_in_the_users_own_timezone(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].start == MONDAY_10AM  # 10:00 in Dublin is 09:00 UTC
    assert events[0].end == MONDAY_10AM + timedelta(hours=1)


def test_an_unreadable_start_time_yields_no_event_rather_than_midnight(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A row whose time cannot be read is dropped, not moved to 00:00.

    Midnight would erase the whole day from the busy set and hand it to the
    planner as free time.
    """
    browser.candidates = [
        *_day_headers(),
        *_chip("M", "Calculus", "10:00 AM", x=60, y=100),
        *_chip("B", "Tutorial", "TBD", x=60, y=300),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"},
            "Tutorial": {"subject": "Tutorial", "start": "TBD", "end": "TBD"},
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert [event.subject for event in events] == ["Calculus"]
    assert all(event.start != MONDAY_10AM - timedelta(hours=9) for event in events)


def test_an_event_that_runs_past_midnight_ends_on_the_next_day(
    browser: FakeBrowser, settings: Settings
) -> None:
    # The chip shows one range, so both questions point at the same text - the
    # model names a candidate, and the candidate is "11:00 PM - 1:00 AM".
    browser.candidates = [
        *_day_headers(),
        *_chip("M", "Revision", "11:00 PM - 1:00 AM", x=60, y=100),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "Revision": {
                "subject": "Revision",
                "start": "11:00 PM - 1:00 AM",
                "end": "11:00 PM - 1:00 AM",
            }
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].start == datetime(2026, 10, 5, 22, 0, tzinfo=UTC)
    assert events[0].end == datetime(2026, 10, 6, 0, 0, tzinfo=UTC)


def test_an_unreadable_end_time_falls_back_to_an_hour_rather_than_losing_the_event(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Losing the end is a small error; losing the event is a scheduling bug."""
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": ""}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].end == MONDAY_10AM + timedelta(hours=1)


# --- ownership --------------------------------------------------------------------


def test_an_event_without_our_marker_is_never_claimed_as_ours(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A foreign event is read so the planner avoids it, and never touched."""
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].block_key is None
    assert events[0].is_ours is False
    assert not any("delete" in click for click in browser.page.clicks)


def test_an_event_carrying_our_marker_round_trips_through_body_for(
    browser: FakeBrowser, settings: Settings
) -> None:
    """The marker written by `body_for` is the only thing that makes an event ours."""
    block = _block()
    # What capture sees: the chip's title, its time range, and the event
    # element's own text - which is where a body preview, and the marker, show up.
    shown = f"Calculus: problem sheet 3\n10:00 AM - 11:00 AM\n{body_for(block)}"
    browser.candidates = [
        *_day_headers(),
        _text("M1", "Calculus: problem sheet 3", 60, 100, width=200.0),
        _text("M2", "10:00 AM - 11:00 AM", 60, 120, width=150.0),
        _text("M3", shown, 60, 100, width=240.0, height=60.0),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "problem sheet": {
                "subject": "Calculus: problem sheet 3",
                "start": "10:00 AM - 11:00 AM",
                "end": "10:00 AM - 11:00 AM",
            }
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].block_key == BLOCK_KEY
    assert events[0].is_ours is True
    assert read_marker(events[0].body) == BLOCK_KEY


def test_a_subject_that_looks_like_a_block_key_is_not_treated_as_one(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Only the body decides ownership; a title is not evidence."""
    browser.candidates = [
        *_day_headers(),
        *_chip("M", f"pli:{BLOCK_KEY}", "10:00 AM", x=60, y=100),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            f"pli:{BLOCK_KEY}": {
                "subject": f"pli:{BLOCK_KEY}",
                "start": "10:00 AM",
                "end": "11:00 AM",
            }
        },
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].block_key is None


# --- all-day ----------------------------------------------------------------------


def test_an_entry_with_no_clock_that_the_model_calls_all_day_is_flagged_all_day(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = [*_day_headers(), _text("A1", "Reading week", 60, 100, width=120.0)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Reading week": {"subject": "Reading week"}},
        all_day=0.95,
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].all_day is True
    assert events[0].start == datetime(2026, 10, 4, 23, 0, tzinfo=UTC)  # local midnight


def test_a_clock_on_the_page_beats_a_claim_that_the_entry_is_all_day(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A visible clock is direct evidence, and a wrong all-day erases real hours.

    `busy_from` skips all-day entries on purpose, so believing the judgement
    over the page would quietly free the whole day for study blocks.
    """
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
        all_day=0.95,
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].all_day is False
    assert events[0].start == MONDAY_10AM


def test_a_chip_that_only_shows_a_status_word_is_not_assumed_busy(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = [
        *_day_headers(),
        *_chip("M", "Study block", "10:00 AM", x=60, y=100),
        _text("Ms", "Free", 60, 140, width=40.0),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Study block": {"subject": "Study block", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].show_as == "free"


def test_an_event_with_nothing_to_say_about_status_is_busy(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={"Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"}},
    )

    events = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events[0].show_as == "busy"


# --- the read is loud when it fails -----------------------------------------------


def test_a_week_with_no_events_saves_the_page_and_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    """An empty read must never come back as a free week.

    Nothing downstream can tell "the calendar is empty" from "the reader is
    broken", and the planner fills a free week with study blocks.
    """
    browser.candidates = _day_headers()
    judge = FakeJudge(header=[MONDAY_AND_TUESDAY])

    with pytest.raises(BrowserError) as raised:
        read_week(settings, judge, WEEK_START, WEEK_END)

    assert browser.diagnostics == ["empty-week"]
    assert browser.saved("empty-week") in str(raised.value)


def test_a_page_that_captures_nothing_saves_the_page_and_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = []
    judge = FakeJudge(header=[MONDAY_AND_TUESDAY])

    with pytest.raises(BrowserError) as raised:
        read_week(settings, judge, WEEK_START, WEEK_END)

    assert browser.diagnostics == ["no-content"]
    assert browser.saved("no-content") in str(raised.value)


def test_a_page_whose_headers_cannot_be_read_saves_the_page_and_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Without day headers there is no way to say which day an event is on."""
    browser.candidates = [*_day_headers(), *_chip("M", "Calculus", "10:00 AM", x=60, y=100)]
    judge = FakeJudge(header=[{}])

    with pytest.raises(BrowserError) as raised:
        read_week(settings, judge, WEEK_START, WEEK_END)

    assert browser.diagnostics == ["headers"]
    assert browser.saved("headers") in str(raised.value)


def test_a_window_that_starts_after_it_ends_is_a_programming_error_not_a_read(
    browser: FakeBrowser, settings: Settings
) -> None:
    judge = FakeJudge(header=[MONDAY_AND_TUESDAY])

    assert read_week(settings, judge, WEEK_END, WEEK_START) == []
    assert browser.diagnostics == []


def test_a_signed_out_profile_is_a_session_error_not_a_selector_error(
    browser: FakeBrowser, settings: Settings
) -> None:
    """The refusal this test pins was missing, and a live run proved it.

    Outlook does not fail the navigation when the session has expired: it serves
    the Microsoft login page, `wait_for_selector` finds no grid, and the read
    reported "the week grid never appeared ... the fix is a selector in
    config/browser.toml". Every word of that was wrong - the session was the
    problem - and it sent the user to edit config for the one failure that a
    headed run and a sign-in would have fixed. The page is now asked directly.
    """
    browser.page.url = (
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=abc"
    )
    judge = FakeJudge(header=[MONDAY_AND_TUESDAY])

    with pytest.raises(SessionError) as raised:
        read_week(settings, judge, WEEK_START, WEEK_END)

    message = str(raised.value)
    assert "sign-in" in message
    assert "BROWSER_HEADLESS=false" in message
    # A login page is not evidence about the calendar, and it is the one page
    # carrying the user's own address - so nothing is written to diagnostics.
    assert browser.diagnostics == []


# --- everything crossing the boundary is UTC --------------------------------------


def test_every_time_the_reader_returns_is_timezone_aware_utc(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.candidates = [
        *_day_headers(),
        *_chip("M", "Calculus", "10:00 AM", x=60, y=100),
        *_chip("T", "Physics", "2:00 PM", x=260, y=100),
    ]
    judge = FakeJudge(
        header=[MONDAY_AND_TUESDAY],
        rows={
            "Calculus": {"subject": "Calculus", "start": "10:00 AM", "end": "11:00 AM"},
            "Physics": {"subject": "Physics", "start": "2:00 PM", "end": "4:00 PM"},
        },
    )

    events: list[RemoteEvent] = read_week(settings, judge, WEEK_START, WEEK_END)

    assert events
    for event in events:
        assert event.start.tzinfo is not None
        assert event.end.tzinfo is not None
        assert event.start.utcoffset() == timedelta(0)
        assert event.end.utcoffset() == timedelta(0)


# --- writing ----------------------------------------------------------------------


def test_creating_a_block_writes_our_marker_into_the_event_body(
    browser: FakeBrowser, settings: Settings
) -> None:
    block = _block()
    browser.page = FakePage(
        dom_events=[
            {"id": "AAMkAG-42", "text": block.subject, "x": 0, "y": 0, "width": 10, "height": 10}
        ]
    )
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    remote_id = backend.create_event(block)

    assert remote_id == "AAMkAG-42"
    written = [value for _, value in browser.page.fills]
    assert any(block.subject == value for value in written)
    assert any(f"[pli:{BLOCK_KEY}]" in value for value in written)
    assert browser.page.gotos  # the week containing the block was opened first


def test_creating_a_block_raises_when_the_new_id_cannot_be_read_back(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A made-up id would make the next run create a duplicate of the same block."""
    browser.page = FakePage(dom_events=[])
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.create_event(_block())

    assert "id could not be read back" in str(raised.value)
    assert browser.diagnostics == ["create-event"]
    assert browser.saved("create-event") in str(raised.value)


def test_creating_a_block_refuses_when_the_study_plan_calendar_does_not_exist(
    browser: FakeBrowser, settings: Settings
) -> None:
    """It will not create the calendar, and it will not write anywhere else."""
    browser.page = FakePage(has_calendar=False)
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.create_event(_block())

    assert CALENDAR_NAME in str(raised.value)
    assert not any("new-event" in click for click in browser.page.clicks)


def test_updating_an_event_the_page_does_not_have_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Silently succeeding would leave the ledger and the calendar disagreeing."""
    browser.page = FakePage(openable=())
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.update_event("AAMkAG-99", _block())

    assert "AAMkAG-99" in str(raised.value)
    assert browser.diagnostics == ["update-event"]
    assert browser.saved("update-event") in str(raised.value)


def test_deleting_an_event_the_page_does_not_have_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.page = FakePage(openable=())
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.delete_event("AAMkAG-99")

    assert "AAMkAG-99" in str(raised.value)
    assert browser.diagnostics == ["delete-event"]
    assert browser.saved("delete-event") in str(raised.value)


def test_an_event_without_our_marker_is_never_updated(
    browser: FakeBrowser, settings: Settings
) -> None:
    """The ledger can be wrong; the calendar cannot be un-changed."""
    browser.page = FakePage(
        openable=("AAMkAG-42",), body="Calculus, every Monday, no marker in sight"
    )
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.update_event("AAMkAG-42", _block())

    assert "marker" in str(raised.value)
    assert not any("save" in click for click in browser.page.clicks)


def test_an_event_without_our_marker_is_never_deleted(
    browser: FakeBrowser, settings: Settings
) -> None:
    browser.page = FakePage(openable=("AAMkAG-42",), body="Calculus, every Monday")
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.delete_event("AAMkAG-42")

    assert "marker" in str(raised.value)
    assert not any("delete" in click for click in browser.page.clicks)


def test_our_own_block_can_be_updated_and_then_deleted(
    browser: FakeBrowser, settings: Settings
) -> None:
    block = _block()
    browser.page = FakePage(
        dom_events=[
            {"id": "AAMkAG-42", "text": block.subject, "x": 0, "y": 0, "width": 1, "height": 1}
        ],
        openable=("AAMkAG-42",),
        body=body_for(block),
    )
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    backend.update_event("AAMkAG-42", _block(subject="Calculus: problem sheet 4"))
    assert any("problem sheet 4" in value for _, value in browser.page.fills)

    backend.delete_event("AAMkAG-42")
    assert browser.page.dom_events == []


def test_a_delete_that_the_page_did_not_carry_out_raises(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A delete that quietly does nothing duplicates the block on the next run."""
    block = _block()
    browser.page = FakePage(
        dom_events=[
            {"id": "AAMkAG-42", "text": block.subject, "x": 0, "y": 0, "width": 1, "height": 1}
        ],
        openable=("AAMkAG-42",),
        body=body_for(block),
        sticky_delete=True,
    )
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.delete_event("AAMkAG-42")

    assert browser.diagnostics == ["delete-event"]
    assert browser.saved("delete-event") in str(raised.value)
    assert "still on the page" in str(raised.value)


# --- the one calendar, on the way in as well as the way out ----------------------


def test_updating_an_event_refuses_when_the_study_plan_calendar_does_not_exist(
    browser: FakeBrowser, settings: Settings
) -> None:
    """Only `create_event` was pinned; the other two ways in were not.

    With no Study Plan calendar the picker has nothing to select, and the event
    form that opens is the one for whatever calendar the page happens to be
    showing - the user's real timetable. The refusal is the only thing standing
    between a moved block and that, and it has to hold on every path that
    writes, not just the one a test happened to cover.
    """
    browser.page = FakePage(has_calendar=False)
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.update_event("AAMkAG-42", _block())

    assert CALENDAR_NAME in str(raised.value)
    assert browser.diagnostics == ["update-event"]
    assert browser.page.fills == []


def test_deleting_an_event_refuses_when_the_study_plan_calendar_does_not_exist(
    browser: FakeBrowser, settings: Settings
) -> None:
    """The destructive path most of all: a delete aimed at the wrong calendar
    takes an event out of the user's real week."""
    browser.page = FakePage(has_calendar=False)
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.delete_event("AAMkAG-42")

    assert CALENDAR_NAME in str(raised.value)
    assert browser.diagnostics == ["delete-event"]
    assert not any("delete" in click for click in browser.page.clicks)


def test_the_week_is_not_read_from_the_wrong_calendar(
    browser: FakeBrowser, settings: Settings
) -> None:
    """A read, not a write - and still the same double-booking.

    The week the reader returns is the set of hours the planner treats as taken.
    Read from the wrong calendar it is the wrong set, and every study block
    placed against it can land on a lecture the reader never saw. Failing here
    costs a message; not failing here costs an afternoon.
    """
    browser.page = FakePage(has_calendar=False)
    judge = FakeJudge(header=[MONDAY_AND_TUESDAY])

    with pytest.raises(BrowserError) as raised:
        read_week(settings, judge, WEEK_START, WEEK_END)

    assert CALENDAR_NAME in str(raised.value)
    assert browser.diagnostics == ["calendar-missing-reading"]
    assert browser.saved("calendar-missing-reading") in str(raised.value)


def test_an_event_belonging_to_another_block_is_never_updated(
    browser: FakeBrowser, settings: Settings
) -> None:
    """ "Ours" is not enough; it has to be *this* block's event.

    `apply` hands over an id it took from the ledger, and the ledger can be
    wrong - that is the drift this whole layer exists to catch. A row pointing
    at a sibling block's event passes the marker check, so the marker cannot be
    what refuses it. Without the expectation the block's title and times are
    written onto the wrong event, the block it belongs to stays as it was, and
    the calendar is corrupted in a way no later run can detect.
    """
    other = _block(block_key="ffffffffffffffff")
    browser.page = FakePage(openable=("AAMkAG-42",), body=body_for(other))
    backend = OutlookBackend(settings, FakeJudge(), page=browser.page)

    with pytest.raises(BrowserError) as raised:
        backend.update_event("AAMkAG-42", _block())

    assert "belongs to block" in str(raised.value)
    assert browser.page.fills == []
