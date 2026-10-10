"""Read and drive the Outlook week view through the browser a person would use.

This is `pli.backend.CalendarBackend` implemented over the real Outlook web UI,
replacing the Graph API. Graph was exact and documented, but it needed an app
registration in a tenant the user does not administer. The browser needs nothing
but the session the user already has - and it is the only way to read a Teams
channel, where a lecturer announces that a deadline moved.

The cost is that the page is undocumented, restyled without notice, and holds
meaning that only a person can read. Two layers keep that survivable:

**Python owns geometry and arithmetic.** `capture_candidates` hands back text
with the screen position it was found at. Code groups those into day columns by
x and into event chips by y, decides which day an event is on, parses the clock
times, applies the timezone, and converts to UTC. All of that is deterministic
and tested here, against a hand-written page.

**The model owns meaning.** Which text is the title, which is the start time,
which is the end time, whether an entry is an all-day banner, and what a column
header like "Mon 6 Oct" says - those go to `pli.judge` as closed-set questions
in one batched call per row. The model never returns a datetime and never does
arithmetic; `parse_clock` turns the text the model pointed at into an (hour,
minute) pair, and `_resolve_header` turns the month/day/weekday the model read
into a `date`.

The rules that matter, and why:

* **A read that finds nothing is an error, not an empty week.** An empty read is
  indistinguishable from a free week, and the planner will fill a free week with
  study blocks - on top of the user's lectures. Every dead end here saves the
  page and raises, so the user can send the files back.
* **An event is ours only if its body carries our marker.** Never inferred from
  a subject line. An event without a marker has `block_key is None` and is never
  updated and never deleted.
* **Only the "Study Plan" calendar is ever addressed.** If it does not exist,
  writing fails loudly rather than creating it - a wrong click here writes into
  the user's real timetable.
* **The window is filtered by overlap, not by start**, so a lecture that begins
  before the window still blocks the time inside it.

Every datetime leaving this module is timezone-aware UTC, per `pli.models`.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from typing import TYPE_CHECKING, Any

from pli.browser import CALENDAR_NAME, BrowserError
from pli.config import Settings
from pli.judge import Candidate, Judge, Verbatim, label_candidates, parse_clock
from pli.models import Block, RemoteEvent
from pli.planner.apply import body_for, read_marker

if TYPE_CHECKING:
    from playwright.sync_api import Page

    from pli.browser.selectors import Selectors

__all__ = [
    "COLUMN_TOLERANCE_PX",
    "OutlookBackend",
    "ROW_TOLERANCE_PX",
    "read_week",
]

# --- geometry constants ---------------------------------------------------------

#: Vertical gap, in CSS pixels, under which two captured texts still belong to
#: one event chip. A chip stacks its title over its time range; the next chip
#: starts below a visibly larger gap. This is the least certain number in this
#: module - it depends on Outlook's current line-height and chip padding - so it
#: is named rather than buried, and it is the first thing to tune on a real page.
ROW_TOLERANCE_PX = 20.0

#: Horizontal gap within which two captured texts describe the same thing. Used
#: to read a column header that the page split into several elements.
COLUMN_TOLERANCE_PX = 24.0

#: How many of the page's topmost visual lines may be a day-header strip before
#: the read gives up. A toolbar and an all-day banner row can sit above it.
HEADER_LINES_TRIED = 3

#: Fewer day columns than this and the geometry cannot say which day anything
#: is on, so the whole read is refused rather than guessed at.
MIN_HEADER_COLUMNS = 2

#: A question answered below this is treated as unanswered. Kept low on purpose:
#: a dropped event lands a study block on a lecture, which is the one outcome
#: this module exists to prevent.
MIN_CONFIDENCE = 0.2

#: Above this the model is considered to have decided that an entry is all-day.
#: All-day entries are excluded from busy time, so a wrong yes here erases real
#: blocked hours - hence a high bar.
ALL_DAY_CONFIDENCE = 0.6

#: Used when the end time is missing or unreadable. Being an hour out on the end
#: of an event can only shave the tail off a free window; dropping the event
#: would schedule study on top of it.
DEFAULT_EVENT_MINUTES = 60

_CAPTURE_LIMIT = 400
_CLICK_TIMEOUT_MS = 20_000
_GRID_TIMEOUT_MS = 30_000

_MONTHS = {
    "January": 1,
    "Jan": 1,
    "February": 2,
    "Feb": 2,
    "March": 3,
    "Mar": 3,
    "April": 4,
    "Apr": 4,
    "May": 5,
    "June": 6,
    "Jun": 6,
    "July": 7,
    "Jul": 7,
    "August": 8,
    "Aug": 8,
    "September": 9,
    "Sep": 9,
    "Sept": 9,
    "October": 10,
    "Oct": 10,
    "November": 11,
    "Nov": 11,
    "December": 12,
    "Dec": 12,
}

_WEEKDAYS = {
    "Monday": 0,
    "Mon": 0,
    "Tuesday": 1,
    "Tue": 1,
    "Tues": 1,
    "Wednesday": 2,
    "Wed": 2,
    "Thursday": 3,
    "Thu": 3,
    "Thur": 3,
    "Thurs": 3,
    "Friday": 4,
    "Fri": 4,
    "Saturday": 5,
    "Sat": 5,
    "Sunday": 6,
    "Sun": 6,
}

#: Status a chip shows in full when it is not a normal busy block. Only a
#: candidate whose entire text is one of these counts: matching a word inside a
#: subject line would mark "Free study session" as free time and let the planner
#: book straight over it.
_STATUS_TEXTS = {
    "free": "free",
    "tentative": "tentative",
    "out of office": "oof",
    "working elsewhere": "workingElsewhere",
    "workingelsewhere": "workingElsewhere",
}

#: Splits "10:00 AM - 11:00 AM" into its two clocks. `parse_clock` then reads
#: each half, so the range is still parsed by `pli.judge` and not re-implemented.
_RANGE_SPLIT_RE = re.compile(r"\s*(?:[-–—]|\bto\b)\s*", re.IGNORECASE)

#: The event body editor. `Selectors` does not name one yet, so it is looked up
#: by attribute first (see `_body_selector`) and falls back to these.
_DEFAULT_BODY_SELECTORS = (
    'div[contenteditable="true"][role="textbox"]',
    'div[aria-label*="description" i][contenteditable="true"]',
    'div[aria-label*="notes" i][contenteditable="true"]',
)

#: Runs in the page to read the geometry of every event the calendar is drawing,
#: so a group of captured texts can be given the calendar's own id for it. The
#: marker `pliDomEvents` is what the tests' fake page keys on.
_DOM_EVENTS_JS = """
(args) => {
  // pliDomEvents
  const [selector] = args;
  return Array.from(document.querySelectorAll(selector)).map((el) => {
    const box = el.getBoundingClientRect();
    return {
      id:
        el.getAttribute('data-event-id') ||
        el.getAttribute('data-eventid') ||
        el.getAttribute('data-itemid') ||
        el.getAttribute('data-ical-uid') ||
        el.id ||
        '',
      text: (el.innerText || el.textContent || '').trim(),
      x: box.left,
      y: box.top,
      width: box.width,
      height: box.height,
    };
  });
}
"""

#: Runs in the page to click the one event the calendar addresses by this id.
_OPEN_EVENT_JS = """
(args) => {
  // pliOpenEvent
  const [selector, wanted] = args;
  const nodes = Array.from(document.querySelectorAll(selector));
  const hit = nodes.find(
    (el) =>
      el.getAttribute('data-event-id') === wanted ||
      el.getAttribute('data-eventid') === wanted ||
      el.getAttribute('data-itemid') === wanted ||
      el.getAttribute('data-ical-uid') === wanted ||
      el.id === wanted
  );
  if (!hit) return false;
  hit.click();
  return true;
}
"""

_ROW_QUESTIONS = {
    "subject": (
        "Which of these texts is the title of this calendar entry - the words the entry is "
        "named by? Not a time, and not a status word."
    ),
    "start": "Which of these texts shows the time this entry begins?",
    "end": "Which of these texts shows the time this entry ends?",
}

_ALL_DAY_QUESTION = (
    "Is this calendar entry an all-day entry - one that covers the whole day rather than a "
    "range of hours - as opposed to something with specific start and end times?"
)


class _Unreadable(BrowserError):
    """A page that could not be read, tagged with the diagnostics label to save.

    Subclasses `BrowserError` purely as a backstop: it is internal, and every
    public entry point converts it through `_failure` so the page is saved and
    the message names the file. If one ever did escape, the CLI would still show
    a sentence rather than a traceback - it would just lose the saved page.
    """

    def __init__(self, label: str, message: str) -> None:
        super().__init__(message)
        self.label = label
        self.message = message


@contextmanager
def _loud(page: Page, settings: Settings, label: str) -> Any:
    """Every way out of a public method is a `BrowserError` that saved the page.

    The failure path is not decoration: a write that fails without saving what
    the page looked like leaves the user with a sentence and nothing to act on.
    The label names the diagnostics file, so it is the operation, not the
    selector, that names the evidence.
    """
    try:
        yield
    except _Unreadable as exc:
        raise _failure(page, settings, label, exc.message) from exc
    except BrowserError:
        raise  # already carries its own saved page
    except Exception as exc:  # noqa: BLE001 - nothing raw may reach the CLI
        raise _failure(page, settings, label, f"The page could not be driven: {exc}") from exc


# --- the public backend ---------------------------------------------------------


class OutlookBackend:
    """Implements `pli.backend.CalendarBackend` over the Outlook web UI.

    `page` is only used by tests and by callers that already hold a session; when
    it is None a fresh signed-in session is opened for each call and closed
    again.
    """

    def __init__(self, settings: Settings, judge: Judge, *, page: Page | None = None) -> None:
        self.settings = settings
        self.judge = judge
        self._page = page

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        return read_week(self.settings, self.judge, start, end, page=self._page)

    def create_event(self, block: Block) -> str:
        """Create `block` in the Study Plan calendar and return its id.

        The id is read back off the page after saving. A made-up id would be
        recorded in the ledger and every later run would fail to find the event
        and create another copy of it, so an unreadable id is an error here
        rather than a guess.
        """
        tz = self.settings.timezone()
        with (
            _open_page(self.settings, self._page) as page,
            _loud(page, self.settings, "create-event"),
        ):
            selectors = _load_selectors()
            _goto_week(page, self.settings, block.start.astimezone(tz))
            _require_calendar(page, selectors, "creating an event")
            _click(page, selectors.outlook_new_event_button)
            _fill(page, selectors.outlook_title_field, block.subject)
            _fill(page, selectors.outlook_start_field, _field_time(block.start, tz))
            _fill(page, selectors.outlook_end_field, _field_time(block.end, tz))
            _fill(page, _body_selector(selectors), body_for(block))
            _click(page, selectors.outlook_save_button)

            remote_id = _read_back_id(page, selectors, block.subject)
            if not remote_id:
                raise _Unreadable(
                    "create-event",
                    f"The event was saved but its id could not be read back from the "
                    f"page. Returning a made-up id would duplicate {block.subject!r} "
                    f"on the next run.",
                )
            return remote_id

    def update_event(self, remote_id: str, block: Block) -> None:
        """Move or rename one of our own blocks.

        Refuses anything that does not carry our marker: `apply` only ever calls
        this for a block in the ledger, but the ledger can be wrong and the
        calendar cannot be un-changed.
        """
        tz = self.settings.timezone()
        with (
            _open_page(self.settings, self._page) as page,
            _loud(page, self.settings, "update-event"),
        ):
            selectors = _load_selectors()
            _goto_week(page, self.settings, block.start.astimezone(tz))
            _require_calendar(page, selectors, "updating an event")
            _claim_ours(page, selectors, remote_id, expect=block.block_key)
            _fill(page, selectors.outlook_title_field, block.subject)
            _fill(page, selectors.outlook_start_field, _field_time(block.start, tz))
            _fill(page, selectors.outlook_end_field, _field_time(block.end, tz))
            _fill(page, _body_selector(selectors), body_for(block))
            _click(page, selectors.outlook_save_button)

    def delete_event(self, remote_id: str) -> None:
        """Delete one of our own blocks, and confirm the page actually did it.

        A delete that silently does nothing is worse than a loud failure: the
        ledger forgets the block while the event survives, and the next run
        creates a second copy of it.
        """
        with (
            _open_page(self.settings, self._page) as page,
            _loud(page, self.settings, "delete-event"),
        ):
            selectors = _load_selectors()
            _goto_week(page, self.settings, datetime.now(UTC))
            _require_calendar(page, selectors, "deleting an event")
            _claim_ours(page, selectors, remote_id, expect=None)
            _click(page, selectors.outlook_delete_button)
            if any(entry.get("id") == remote_id for entry in _dom_events(page, selectors)):
                raise _Unreadable(
                    "delete-event",
                    "The event was still on the page after the delete, so the "
                    "calendar and the ledger would disagree from now on. A "
                    "confirmation dialog may be blocking the delete.",
                )


def read_week(
    settings: Settings,
    judge: Judge,
    start: datetime,
    end: datetime,
    *,
    page: Page | None = None,
) -> list[RemoteEvent]:
    """Every event overlapping [start, end), read from the Outlook week view."""
    return _read(settings, judge, start, end, page)


# --- the read -------------------------------------------------------------------


def _read(
    settings: Settings,
    judge: Judge,
    start: datetime,
    end: datetime,
    page: Page | None,
) -> list[RemoteEvent]:
    tz = settings.timezone()
    window_start = _as_utc(start).astimezone(tz)
    window_end = _as_utc(end).astimezone(tz)
    if window_end <= window_start:
        return []

    with _open_page(settings, page) as active:
        selectors = _load_selectors()
        try:
            _goto_week(active, settings, window_start)
            _wait_for_grid(active, selectors)
            _require_calendar(active, selectors, "reading the calendar")

            candidates = _capture(active, selectors)
            if not candidates:
                raise _Unreadable(
                    "no-content",
                    "Nothing at all was captured from the week grid. The calendar may "
                    "still have been rendering, or the grid selector may have stopped "
                    "matching.",
                )

            columns, fixed_ids = _day_columns(
                judge, candidates, window_start.date(), window_end.date()
            )
            groups = _event_groups(candidates, columns, fixed_ids)
            _attach_ids(groups, _dom_events(active, selectors))

            events = []
            for group in groups:
                event = _event(judge, group, tz)
                # Overlap, not containment: a lecture that starts before the
                # window still occupies time inside it.
                if event is not None and event.end > window_start and event.start < window_end:
                    events.append(event)
        except _Unreadable as exc:
            raise _failure(active, settings, exc.label, exc.message) from exc
        except BrowserError:
            raise  # the empty-week refusal already saved its own page
        except Exception as exc:  # noqa: BLE001 - nothing raw may reach the CLI
            raise _failure(
                active, settings, "read-failed", f"The calendar page could not be read: {exc}"
            ) from exc

        if not events:
            # The one outcome that must never be silent: an empty read looks
            # exactly like a free week, and the planner fills a free week.
            raise _failure(
                active,
                settings,
                "empty-week",
                f"The read found no events between {window_start.isoformat()} and "
                f"{window_end.isoformat()}. That is either a genuinely free week or a "
                f"page this module can no longer read, and it must not be assumed to be "
                f"the former.",
            )

    events.sort(key=lambda e: (e.start, e.end, e.subject))
    return events


# --- day columns -----------------------------------------------------------------


@dataclass(frozen=True)
class _Column:
    """One day of the week grid, as an x interval on the page."""

    day: date
    lo: float
    hi: float

    def holds(self, x: float) -> bool:
        return self.lo <= x < self.hi


def _centre(candidate: Candidate) -> tuple[float, float]:
    return candidate.x + candidate.width / 2, candidate.y + candidate.height / 2


def _bottom(group: Sequence[Candidate]) -> float:
    return max(candidate.y + candidate.height for candidate in group)


def _y_lines(
    candidates: Sequence[Candidate],
    tolerance: float = ROW_TOLERANCE_PX,
) -> list[list[Candidate]]:
    """Captured texts grouped into the visual lines they were drawn on.

    Sorted by vertical position, a line stays open while the next text starts
    within `tolerance` of the lowest text already in it - so a chip's title and
    its time range land in one group and the chip below does not.
    """
    ordered = sorted(candidates, key=lambda c: (_centre(c)[1], c.x))
    lines: list[list[Candidate]] = []
    for candidate in ordered:
        if lines and _centre(candidate)[1] - _bottom(lines[-1]) <= tolerance:
            lines[-1].append(candidate)
        else:
            lines.append([candidate])
    return lines


def _day_columns(
    judge: Judge,
    candidates: Sequence[Candidate],
    window_lo: date,
    window_hi: date,
) -> tuple[list[_Column], set[str]]:
    """The week's day columns, and the ids of the texts that are not events.

    The page's topmost lines are tried in turn: a toolbar or an all-day banner
    row can sit above the day-header strip, and a strip whose labels do not
    resolve to dates is not the strip. Guessing which day an event is on is not
    an option - a wrong day moves a lecture out of the window and frees the time.

    Every line tried on the way - including the one that won - is returned as
    "not an event". They all sit above the day strip, so none of them can be a
    block, and judging a toolbar button as though it were one would cost a
    request and could invent an event out of page furniture.
    """
    fixed_ids: set[str] = set()
    for line in _y_lines(candidates)[:HEADER_LINES_TRIED]:
        fixed_ids |= {candidate.id for candidate in line}
        columns = _columns_from_line(judge, line, window_lo, window_hi)
        if columns is not None:
            return columns, fixed_ids
    raise _Unreadable(
        "headers",
        "No line of the page could be read as the week's day headers, so nothing "
        "can be said about which day any event is on.",
    )


def _columns_from_line(
    judge: Judge,
    line: Sequence[Candidate],
    window_lo: date,
    window_hi: date,
) -> list[_Column] | None:
    bands = _x_bands(line)
    if len(bands) < MIN_HEADER_COLUMNS:
        return None

    state = label_candidates(list(line))
    results = judge.ask(state, _header_questions(bands, window_lo))

    read: list[tuple[float, date | None]] = []
    for index, band in enumerate(bands):
        read.append((_band_centre(band), _resolve_header(results, index, window_lo, window_hi)))

    known = [(x, day) for x, day in read if day is not None]
    if len(known) < MIN_HEADER_COLUMNS:
        return None
    centres = [x for x, _ in known]
    if any(day is None and min(centres) < x < max(centres) for x, day in read):
        # A label we could not read sits between two we could, so the column
        # boundaries either side of it are not trustworthy.
        return None

    known.sort()
    days = [day for _, day in known]
    if len(set(days)) != len(days):
        # Two labels naming the same day means this line is not the day strip.
        return None
    if any(later <= earlier for earlier, later in zip(days, days[1:], strict=False)):
        # A week grid is drawn left to right, earliest day first.
        return None

    columns: list[_Column] = []
    for index, (centre_x, day) in enumerate(known):
        lo = float("-inf") if index == 0 else (known[index - 1][0] + centre_x) / 2
        hi = float("inf") if index == len(known) - 1 else (centre_x + known[index + 1][0]) / 2
        columns.append(_Column(day=day, lo=lo, hi=hi))
    return columns


def _x_bands(
    candidates: Sequence[Candidate],
    tolerance: float = COLUMN_TOLERANCE_PX,
) -> list[list[Candidate]]:
    ordered = sorted(candidates, key=lambda c: (c.x, c.y))
    bands: list[list[Candidate]] = []
    for candidate in ordered:
        if bands and candidate.x - max(c.x + c.width for c in bands[-1]) <= tolerance:
            bands[-1].append(candidate)
        else:
            bands.append([candidate])
    return bands


def _band_centre(band: Sequence[Candidate]) -> float:
    left = min(candidate.x for candidate in band)
    right = max(candidate.x + candidate.width for candidate in band)
    return (left + right) / 2


def _header_questions(bands: Sequence[Sequence[Candidate]], reference: date) -> dict[str, Any]:
    """One closed-set question per part of each day header, batched into one call.

    The model reads what the header says - is it absolute, which month, which
    day number, which weekday - and code turns those answers into a `date`. A
    question whose options are month names cannot come back as a datetime, which
    is the point: the model never does the calendar arithmetic.
    """
    from typesafe_sdk import Choice

    absent = "The header does not say this."
    years = (reference.year - 1, reference.year, reference.year + 1)
    questions: dict[str, Any] = {}
    for index in range(len(bands)):
        prefix = f"h{index}"
        questions[f"{prefix}_mode"] = Choice(
            instructions=(
                "How is this column header written? 'absolute' = it names a calendar date "
                "(e.g. 'Mon 6 Oct', 'October 6'); 'relative' = it is written relative to "
                "today (e.g. 'Today', 'Tomorrow'); 'none' = it is not a day label at all."
            ),
            criteria={"absolute": None, "relative": None, "none": None},
        )
        questions[f"{prefix}_month"] = Choice(
            instructions="If this header names a month, which one is it?",
            criteria={name: None for name in _MONTHS} | {"none": absent},
        )
        questions[f"{prefix}_day"] = Choice(
            instructions="If this header names a day of the month, which number is it?",
            criteria={str(day): None for day in range(1, 32)} | {"none": absent},
        )
        questions[f"{prefix}_weekday"] = Choice(
            instructions="If this header names a weekday, which one is it?",
            criteria={name: None for name in _WEEKDAYS} | {"none": absent},
        )
        questions[f"{prefix}_anchor"] = Choice(
            instructions=(
                "If this header is written relative to today, which day does it mean? "
                "'today', 'tomorrow', or 'weekday' when it names a day of the week."
            ),
            criteria={"today": None, "tomorrow": None, "weekday": None, "none": absent},
        )
        questions[f"{prefix}_year"] = Choice(
            instructions=(
                "If this header states a year, which one is it? Pick 'none' when no year "
                "is written down."
            ),
            criteria={str(year): None for year in years} | {"none": absent},
        )
    return questions


def _resolve_header(results: Any, index: int, window_lo: date, window_hi: date) -> date | None:
    """Turn the parts the model read into a real date, or give up.

    The resulting date must fall inside the window being read. A label that
    resolves to a day the calendar is not showing is a misread, and acting on it
    would place an event on the wrong day.
    """
    prefix = f"h{index}"
    mode = results.choice(f"{prefix}_mode", minimum_confidence=MIN_CONFIDENCE)
    reference = window_lo

    if mode == "absolute":
        month = results.choice(f"{prefix}_month", minimum_confidence=MIN_CONFIDENCE)
        day = results.choice(f"{prefix}_day", minimum_confidence=MIN_CONFIDENCE)
        if month is None or day is None or month not in _MONTHS or not day.isdigit():
            return None
        year = results.choice(f"{prefix}_year", minimum_confidence=MIN_CONFIDENCE)
        try:
            if year is not None and year != "none" and year.isdigit():
                resolved = date(int(year), _MONTHS[month], int(day))
            else:
                # No year written: take the window's own year, and roll forward
                # only when the date is already well past - a January header read
                # in December is next year's.
                resolved = date(reference.year, _MONTHS[month], int(day))
                if resolved < reference - timedelta(days=31):
                    resolved = date(reference.year + 1, _MONTHS[month], int(day))
        except ValueError:
            return None  # e.g. "February 30" - an inconsistent read, not a date.
    elif mode == "relative":
        anchor = results.choice(f"{prefix}_anchor", minimum_confidence=MIN_CONFIDENCE)
        if anchor == "today":
            resolved = reference
        elif anchor == "tomorrow":
            resolved = reference + timedelta(days=1)
        elif anchor == "weekday":
            weekday = results.choice(f"{prefix}_weekday", minimum_confidence=MIN_CONFIDENCE)
            if weekday not in _WEEKDAYS:
                return None
            # A bare weekday means the next one on or after the window's first
            # day, which is the day the grid itself starts from.
            offset = (_WEEKDAYS[weekday] - reference.weekday()) % 7
            resolved = reference + timedelta(days=offset)
        else:
            return None
    else:
        return None

    return resolved if window_lo <= resolved <= window_hi else None


# --- event chips ----------------------------------------------------------------


@dataclass
class _Group:
    """The captured texts that belong to one event."""

    day: date
    candidates: tuple[Candidate, ...]
    remote_id: str = ""
    #: The body text as the page showed it, joined for the marker search.
    body: str = field(default="")

    @property
    def anchor(self) -> Candidate:
        return self.candidates[0]


def _event_groups(
    candidates: Sequence[Candidate],
    columns: Sequence[_Column],
    fixed_ids: set[str],
) -> list[_Group]:
    """Split the captured texts into one group per event chip.

    Column first, then line: the column is the day, and the line is which texts
    were drawn on top of one another. Two events at the same time on different
    days therefore stay apart, which is what stops one of them being dropped.

    Known limit: two events drawn *side by side inside one day column* (Outlook
    does this for a time clash) share a line and share a column, so they arrive
    as one group and only one of them is reported. The page's own event boxes
    would separate them; the captured text alone cannot.
    """
    groups: list[_Group] = []
    for column in columns:
        inside = [
            candidate
            for candidate in candidates
            if candidate.id not in fixed_ids and column.holds(_centre(candidate)[0])
        ]
        for line in _y_lines(inside):
            groups.append(_Group(day=column.day, candidates=tuple(line)))
    return groups


def _attach_ids(groups: Sequence[_Group], dom_events: Sequence[Mapping[str, Any]]) -> None:
    """Give each group the calendar's own id for the event it was drawn from.

    `pli.planner.apply` stores this id in its ledger and hands it back to
    `update_event`/`delete_event`, so it has to address the same event later. The
    captured texts only carry a capture-scoped id; the id the page itself uses
    comes from the event boxes.
    """
    for group in groups:
        x, y = _centre(group.anchor)
        best: Mapping[str, Any] | None = None
        for entry in dom_events:
            if not _contains_point(entry, x, y):
                continue
            if best is None or _area(entry) < _area(best):
                best = entry
        if best is not None and best.get("id"):
            group.remote_id = str(best["id"])
        else:
            # Unique within this read and enough for `discover_events` to key its
            # ledger on, but not something the page can be asked for again - a
            # later update or delete with it fails loudly rather than silently.
            group.remote_id = group.anchor.id


def _contains_point(entry: Mapping[str, Any], x: float, y: float) -> bool:
    try:
        left, top = float(entry["x"]), float(entry["y"])
        right = left + float(entry["width"])
        bottom = top + float(entry["height"])
    except (KeyError, TypeError, ValueError):
        return False
    return left <= x <= right and top <= y <= bottom


def _area(entry: Mapping[str, Any]) -> float:
    return float(entry.get("width") or 0.0) * float(entry.get("height") or 0.0)


def _event(judge: Judge, group: _Group, tz: Any) -> RemoteEvent | None:
    """One event, or None when the page did not say enough to place it.

    Returning None is deliberate for an unreadable start time. Falling back to
    midnight would move a 09:00 lecture to 00:00 and free the whole day for study
    blocks, which is exactly the failure this module exists to prevent.
    """
    members = list(group.candidates)
    state = label_candidates(members)
    answers = judge.asks(
        state,
        questions=_ROW_QUESTIONS,
        candidates=members,
        minimum_confidence=MIN_CONFIDENCE,
    )

    start_text = _answered(answers, "start")
    end_text = _answered(answers, "end")
    times = _times(start_text, end_text)

    all_day = judge.confirm(state, question=_ALL_DAY_QUESTION, name="all_day") >= ALL_DAY_CONFIDENCE
    if all_day and times is not None:
        # A clock on the page is direct evidence against the judgement, and a
        # wrong "all-day" erases real blocked hours from the planner's view.
        all_day = False

    midnight = datetime.combine(group.day, time(0, 0), tzinfo=tz)
    if all_day:
        start = midnight
        end = midnight + timedelta(days=1)
    elif times is not None:
        # Minutes past local midnight rather than a clock time, because 24:00 is
        # not a real `time` and an entry that runs to 01:00 has to land on the
        # next day rather than wrap back to this morning.
        start = midnight + timedelta(minutes=times[0])
        end = midnight + timedelta(minutes=times[1])
        if end <= start:
            end += timedelta(days=1)  # an entry that runs past midnight
    else:
        return None

    body = group.body or "\n".join(candidate.text for candidate in members)
    subject = _answered(answers, "subject") or body.splitlines()[0]
    return RemoteEvent(
        remote_id=group.remote_id,
        subject=subject,
        start=start.astimezone(UTC),
        end=end.astimezone(UTC),
        body=body,
        # The marker is the only thing that may claim an event: a subject line
        # that happens to look like a block key is not evidence of anything.
        block_key=read_marker(body),
        all_day=all_day,
        show_as=_show_as(members),
    )


def _answered(answers: Mapping[str, Verbatim | None], name: str) -> str:
    verbatim = answers.get(name)
    return verbatim.text if verbatim is not None else ""


def _times(start_text: str, end_text: str) -> tuple[int, int] | None:
    """(start, end) as minutes past local midnight, or None if the start is unreadable.

    The end may exceed 24:00, which is how an entry running past midnight is
    carried: 23:00 to 01:00 is 1380 to 1500. Reading an end earlier than the
    start as "the next morning" rather than as a mistake is the safe direction -
    an over-long block keeps the planner off that time, a too-short one hands
    the time back.
    """
    start = parse_clock(start_text)
    end = parse_clock(end_text) if end_text and end_text != start_text else None
    if end is None:
        span = _range_clocks(start_text) or _range_clocks(end_text)
        if span is not None:
            start, end = span
    if start is None:
        return None

    start_minutes = start[0] * 60 + start[1]
    if end is None:
        return start_minutes, start_minutes + DEFAULT_EVENT_MINUTES
    end_minutes = end[0] * 60 + end[1]
    if end_minutes == start_minutes:
        # The same clock read twice is not a range, so fall back to a length.
        end_minutes = start_minutes + DEFAULT_EVENT_MINUTES
    elif end_minutes < start_minutes:
        end_minutes += 24 * 60
    return start_minutes, end_minutes


def _range_clocks(text: str) -> tuple[tuple[int, int], tuple[int, int]] | None:
    """Both halves of a "10:00 - 11:00" range, read by `parse_clock` itself."""
    halves = _RANGE_SPLIT_RE.split(text, maxsplit=1)
    if len(halves) != 2:
        return None
    first, second = parse_clock(halves[0]), parse_clock(halves[1])
    if first is None or second is None:
        return None
    return first, second


def _show_as(members: Sequence[Candidate]) -> str:
    for candidate in members:
        status = _STATUS_TEXTS.get(candidate.text.strip().lower())
        if status is not None:
            return status
    return "busy"


# --- page driving ---------------------------------------------------------------


@contextmanager
def _open_page(settings: Settings, page: Page | None) -> Any:
    """The page to drive: the caller's, or a fresh signed-in session."""
    if page is not None:
        yield page
        return
    from pli.browser.session import session

    with session(settings) as opened:
        yield opened


def _load_selectors() -> Selectors:
    """Imported here so this module still loads while `selectors` is being written."""
    from pli.browser.selectors import load

    return load()


def _capture(page: Page, selectors: Selectors) -> list[Candidate]:
    from pli.browser.capture import capture_candidates

    return list(capture_candidates(page, selectors=selectors, limit=_CAPTURE_LIMIT))


def _diagnostics(page: Page, settings: Settings, label: str) -> Path | str:
    """Save what the page looked like, for the user to send back.

    Never allowed to replace the real error: if the page is too broken to
    screenshot, the message says so and the original failure still surfaces.
    """
    try:
        from pli.browser.capture import diagnostics

        return diagnostics(page, settings, label=label)
    except Exception as exc:  # noqa: BLE001 - the original error matters more
        return f"<diagnostics unavailable: {exc}>"


def _failure(page: Page, settings: Settings, label: str, message: str) -> BrowserError:
    saved = _diagnostics(page, settings, label)
    return BrowserError(
        f"{message} What the page looked like was saved to {saved}; send that back to "
        f"get the reader fixed."
    )


def _goto_week(page: Page, settings: Settings, when: datetime) -> None:
    """Open the week containing `when`, in the user's own timezone."""
    url = f"{settings.outlook_url}?startdt={when.date().isoformat()}"
    try:
        page.goto(url)
    except Exception as exc:
        raise _Unreadable(
            "navigation",
            f"The Outlook calendar at {settings.outlook_url} could not be opened: {exc}",
        ) from exc


def _wait_for_grid(page: Page, selectors: Selectors) -> None:
    """Wait for the week board, telling "signed out" apart from "restyled".

    The check either side of the wait is the point. A profile that has signed out
    does not fail the navigation - Microsoft quietly serves the login page - and a
    login page and a restyled calendar look identical from here: a selector that
    matches nothing. Guessing between them in the message is what sent a user to
    edit a selector when all they needed was to sign in again, so the page is
    asked rather than guessed. `SessionError` also carries the right hint to the
    CLI, and skips saving diagnostics: a login page is not evidence about the
    calendar, and it is the one page with the user's own address on it.
    """
    from pli.browser.session import require_signed_in

    # Before the wait: on a sign-in wall the grid will never appear however long
    # it is waited for, so this fails in a moment instead of after the timeout.
    require_signed_in(page)
    try:
        page.wait_for_selector(selectors.outlook_week_grid, timeout=_GRID_TIMEOUT_MS)
    except Exception as exc:
        # After it too: a session can expire between the navigation and the board
        # rendering, and the redirect lands while the wait is already running.
        require_signed_in(page)
        raise _Unreadable(
            "grid-missing",
            f"The week grid never appeared at {selectors.outlook_week_grid!r}, and the "
            f"page is not a sign-in screen, so the session is intact and the grid "
            f"selector is what stopped matching.",
        ) from exc


def _require_calendar(page: Page, selectors: Selectors, doing: str) -> None:
    """Select the one calendar this tool owns, or refuse to continue.

    Never creates it. A click in the wrong place here writes study blocks into
    the user's real timetable, so a missing calendar stops the run and names the
    thing to create.
    """
    option = _calendar_option(selectors)
    if page.locator(option).count() == 0:
        raise _Unreadable(
            f"calendar-missing-{doing.split()[0]}",
            f"There is no calendar named {CALENDAR_NAME!r}, so there is nowhere safe to "
            f"{doing}. Create a calendar with exactly that name in Outlook and run again; "
            f"this tool will not create it for you, because picking the wrong calendar "
            f"would write into your real timetable.",
        )
    try:
        page.click(f"{option} >> nth=0", timeout=_CLICK_TIMEOUT_MS)
    except Exception:
        # The picker is usually a dropdown that has to be opened first.
        page.click(selectors.outlook_calendar_picker, timeout=_CLICK_TIMEOUT_MS)
        page.click(f"{option} >> nth=0", timeout=_CLICK_TIMEOUT_MS)


def _calendar_option(selectors: Selectors) -> str:
    return f'{selectors.outlook_calendar_picker} >> text="{CALENDAR_NAME}"'


def _body_selector(selectors: Selectors) -> str:
    """The event body editor.

    `Selectors` does not name one, so a future field is honoured first and the
    obvious contenteditable boxes are the fallback. The body is where the
    `[pli:<key>]` marker lives, so this selector is what makes an event
    recognisable as ours at all.
    """
    named = getattr(selectors, "outlook_body_field", None)
    if named:
        return str(named)
    return ", ".join(_DEFAULT_BODY_SELECTORS)


def _dom_events(page: Page, selectors: Selectors) -> list[dict[str, Any]]:
    try:
        found = page.evaluate(_DOM_EVENTS_JS, [selectors.outlook_event])
    except Exception:
        return []
    return [entry for entry in (found or []) if isinstance(entry, dict)]


def _read_back_id(page: Page, selectors: Selectors, subject: str) -> str:
    """The id the calendar gave the event that was just saved.

    Matched on the subject the event was saved with, because that is the only
    thing this module knows for certain about the new event.
    """
    matches = [
        entry
        for entry in _dom_events(page, selectors)
        if subject and subject in str(entry.get("text", "")) and entry.get("id")
    ]
    return str(matches[-1]["id"]) if matches else ""


def _open_event(page: Page, selectors: Selectors, remote_id: str) -> bool:
    try:
        return bool(page.evaluate(_OPEN_EVENT_JS, [selectors.outlook_event, remote_id]))
    except Exception:
        return False


def _claim_ours(page: Page, selectors: Selectors, remote_id: str, *, expect: str | None) -> None:
    """Open one event and prove it carries our marker before touching it.

    `apply` only asks for ids that came from this tool, but a lost ledger or a
    hand-created event in the Study Plan calendar can put a foreign id in its
    place. Opening the event and reading the marker is the only check that can
    tell the difference, and there is no undo for a delete.
    """
    if not remote_id:
        raise _Unreadable("missing-event", "No event id was given, so nothing could be found.")
    if not _open_event(page, selectors, remote_id):
        raise _Unreadable(
            "missing-event",
            f"No event on the page carries the id {remote_id!r}. An id the calendar no "
            f"longer knows about means the ledger and the calendar have drifted apart; "
            f"silently succeeding here would leave them disagreeing forever.",
        )
    block_key = read_marker(_read_body(page, selectors))
    if block_key is None:
        raise _Unreadable(
            "foreign-event",
            f"The event {remote_id!r} does not carry this tool's marker, so it is not "
            f"ours and will not be changed. Only events whose body contains "
            f"'[pli:<key>]' are ever touched.",
        )
    if expect is not None and block_key != expect:
        raise _Unreadable(
            "wrong-event",
            f"The event {remote_id!r} belongs to block {block_key!r}, not {expect!r}.",
        )


def _read_body(page: Page, selectors: Selectors) -> str:
    try:
        return page.inner_text(_body_selector(selectors))
    except Exception:
        return ""


def _click(page: Page, selector: str) -> None:
    try:
        page.click(selector, timeout=_CLICK_TIMEOUT_MS)
    except Exception as exc:
        raise _Unreadable("selector", f"Nothing on the page matched {selector!r}: {exc}") from exc


def _fill(page: Page, selector: str, value: str) -> None:
    try:
        page.fill(selector, value)
    except Exception as exc:
        raise _Unreadable(
            "selector", f"Nothing on the page matched {selector!r} to be filled: {exc}"
        ) from exc


def _field_time(moment: datetime, tz: Any) -> str:
    """A moment as the event form's own date-time field wants it.

    Formatted in the user's zone, never UTC: the form is showing local wall
    clock, and feeding it UTC shifts every block by the offset.
    """
    return moment.astimezone(tz).strftime("%m/%d/%Y %I:%M %p")


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)
