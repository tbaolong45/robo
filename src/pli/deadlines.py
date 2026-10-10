"""Deadlines the LMS told you about, kept so you can see what is due and tick it off.

A "goal" here is "everything due this week handled". The source is the inbox the agent
already reads: the LMS sends three templated notices, and each is matched by code - no model
reads them, so nothing is guessed:

    Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission
    Overdue: Research Draft (Viva) 4%
    You have submitted your assignment submission for Lab 6 Submission

Rules:

1. **Only the templates count, and only from the LMS.** A row that merely mentions "due" or
   "assignment" is not a deadline, and neither is a notice from any other sender: otherwise a
   stranger could plant an item or close a real one with a fake receipt. The row carries the
   sender's display name, not the address, so a mail that copies that name is still accepted;
   the list is a note on this computer and changes nothing in the mailbox. An unreadable date
   is "no date", never a wrong one.
2. **Kept apart from the planner.** These rows are never written to the `deadlines` table:
   `pli plan` schedules study blocks for every row there, and the project's rule is that
   mail is not turned into planned work behind your back.
3. **Done has a reason.** `receipt` = the LMS said you submitted it; `manual` = you said so.
   Only a manual mark can be undone; a receipt is evidence, not an opinion.
4. **What is kept is a title (capped, control characters removed), a due time and
   timestamps**, in a file only you can read (mode 0600, created that way).
"""

from __future__ import annotations

import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, tzinfo
from pathlib import Path

from pli.browser.mail import MailItem
from pli.db import connect_private

__all__ = [
    "MAX_TITLE",
    "DeadlineStore",
    "Listing",
    "Seen",
    "Tracked",
    "Tracker",
    "extract",
    "key_of",
    "listing",
    "progress",
]

MAX_TITLE = 100

#: Where a title stops: the inbox row is "sender subject received-time preview", and the
#: received time comes as `Wed 10:45 AM`, `Wed 09-30` or just `8:48 AM`.
_RECEIVED = (
    r"(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(?:\d{1,2}:\d{2}\s?[AP]M|\d{1,2}-\d{1,2})"
    r"|\d{1,2}:\d{2}\s?[AP]M)"
)
_DUE = re.compile(
    r"Due on (?P<date>[A-Za-z]+, \d{1,2} [A-Za-z]+ \d{4}, \d{1,2}:\d{2} [AP]M): "
    rf"(?P<title>.+?)\s+{_RECEIVED}\b"
)
_OVERDUE = re.compile(rf"Overdue: (?P<title>.+?)\s+{_RECEIVED}\b")
_SUBMITTED = re.compile(
    rf"You have submitted your assignment submission for (?P<title>.+?)\s+{_RECEIVED}\b"
)
_DATE_FORMAT = "%A, %d %B %Y, %I:%M %p"
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


@dataclass(frozen=True)
class Seen:
    """One notice found in a row. `due_at` is only set for a `due` notice with a real date."""

    kind: str  # "due" | "overdue" | "submitted"
    title: str
    due_at: datetime | None = None


def key_of(title: str) -> str:
    """The identity of an assignment: its title, case and spacing ignored."""
    return " ".join(title.casefold().split())


def _clean(title: str) -> str:
    text = " ".join(_CONTROL.sub("", title).split())
    return text[:MAX_TITLE].rstrip()


#: Years a deadline can have. Outside them a date is "no date": year 1 or 9999 would
#: overflow the UTC clock the store keeps and stop the whole read from being recorded.
_YEARS = range(2000, 2101)


def _due_at(text: str, tz: tzinfo) -> datetime | None:
    try:
        when = datetime.strptime(text, _DATE_FORMAT)
    except ValueError:
        return None
    return when.replace(tzinfo=tz) if when.year in _YEARS else None


def _subject(text: str, sender: str) -> str | None:
    """What follows `sender` in a row ("sender subject ..."), or None if someone else sent it.

    The sender must be the whole first word(s), so "LMS Alerts" and "LMSX" are not "LMS".
    """
    rest = text.removeprefix(sender)
    return rest.lstrip() if rest != text and rest[:1].isspace() else None


def extract(rows: Sequence[MailItem], tz: tzinfo, sender: str = "LMS") -> list[Seen]:
    """The deadline notices `sender` sent in `rows`, each assignment-and-kind once.

    A notice counts only as the row's subject: the same words in a preview do not.
    """
    found: dict[tuple[str, str], Seen] = {}
    for row in rows:
        subject = _subject(row.text, sender)
        if subject is None:
            continue
        for kind, pattern in (("due", _DUE), ("overdue", _OVERDUE), ("submitted", _SUBMITTED)):
            match = pattern.match(subject)
            if not match:
                continue
            title = _clean(match["title"])
            if not title:
                continue
            due = _due_at(match["date"], tz) if kind == "due" else None
            found.setdefault((kind, key_of(title)), Seen(kind, title, due))
    return list(found.values())


# --- the store ------------

_SCHEMA = """
CREATE TABLE IF NOT EXISTS tracked (
    key          TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    due_at       TEXT,
    overdue_seen INTEGER NOT NULL DEFAULT 0,
    first_seen   TEXT NOT NULL,
    last_seen    TEXT NOT NULL,
    done_at      TEXT,
    done_by      TEXT
)
"""


@dataclass(frozen=True)
class Tracked:
    """One assignment. `overdue` is not stored: it is worked out against `now`."""

    key: str
    title: str
    due_at: datetime | None
    overdue: bool
    done_at: datetime | None
    done_by: str | None  # "receipt" | "manual" | None


def _stamp(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat()


def _parse(text: str | None) -> datetime | None:
    return datetime.fromisoformat(text) if text else None


class DeadlineStore:
    """The tracked assignments. One file, mode 0600 from the moment it exists."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._conn = connect_private(self.path)
        with self._conn:
            self._conn.execute(_SCHEMA)

    def record(self, seen: Sequence[Seen], now: datetime) -> int:
        """Remember these notices. Returns how many assignments were new."""
        stamp, new = _stamp(now), 0
        with self._conn:
            for item in seen:
                key = key_of(item.title)
                known = self._conn.execute(
                    "SELECT done_by FROM tracked WHERE key = ?", (key,)
                ).fetchone()
                if known is None:
                    new += 1
                    self._insert(key, item, stamp)
                else:
                    self._update(key, item, stamp, known[0])
        return new

    def _insert(self, key: str, item: Seen, stamp: str) -> None:
        receipt = item.kind == "submitted"
        self._conn.execute(
            "INSERT INTO tracked (key, title, due_at, overdue_seen, first_seen, last_seen, "
            "done_at, done_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                key,
                item.title,
                _stamp(item.due_at) if item.due_at else None,
                int(item.kind == "overdue"),
                stamp,
                stamp,
                stamp if receipt else None,
                "receipt" if receipt else None,
            ),
        )

    def _update(self, key: str, item: Seen, stamp: str, done_by: str | None) -> None:
        self._conn.execute("UPDATE tracked SET last_seen = ? WHERE key = ?", (stamp, key))
        if item.kind == "submitted" and done_by != "receipt":
            self._conn.execute(
                "UPDATE tracked SET done_at = ?, done_by = 'receipt' WHERE key = ?", (stamp, key)
            )
        elif item.kind == "overdue":
            self._conn.execute("UPDATE tracked SET overdue_seen = 1 WHERE key = ?", (key,))
        elif item.kind == "due" and item.due_at is not None:
            self._conn.execute(
                "UPDATE tracked SET due_at = ?, overdue_seen = 0 WHERE key = ?",
                (_stamp(item.due_at), key),
            )

    def items(self, now: datetime) -> list[Tracked]:
        """Open overdue first, then open by due date (undated last), then done, newest first."""
        rows = self._conn.execute(
            "SELECT key, title, due_at, overdue_seen, done_at, done_by FROM tracked"
        ).fetchall()
        tracked = [
            Tracked(
                key,
                title,
                due := _parse(due_at),
                done_by is None and (bool(seen) or (due is not None and due < now)),
                _parse(done_at),
                done_by,
            )
            for key, title, due_at, seen, done_at, done_by in rows
        ]
        far = datetime.max.replace(tzinfo=UTC)

        def order(item: Tracked) -> tuple[int, float | datetime, str]:
            if item.done_by is not None:
                return 2, -(item.done_at or far).timestamp(), item.key
            if item.overdue:
                return 0, (item.due_at or datetime.min.replace(tzinfo=UTC)), item.key
            return 1, (item.due_at or far), item.key

        return sorted(tracked, key=order)

    def mark_done(self, key: str, now: datetime) -> bool:
        """You say it is done. A receipt already there is kept as it is."""
        with self._conn:
            cursor = self._conn.execute(
                "UPDATE tracked SET done_at = ?, done_by = 'manual' WHERE key = ? "
                "AND done_by IS NULL",
                (_stamp(now), key),
            )
        if cursor.rowcount:
            return True
        row = self._conn.execute("SELECT 1 FROM tracked WHERE key = ?", (key,)).fetchone()
        return row is not None

    def reopen(self, key: str) -> bool:
        """Undo your own mark. A receipt cannot be undone."""
        with self._conn:
            cursor = self._conn.execute(
                "UPDATE tracked SET done_at = NULL, done_by = NULL WHERE key = ? "
                "AND done_by = 'manual'",
                (key,),
            )
        return cursor.rowcount > 0

    def purge(self, now: datetime, days: int = 60) -> int:
        """Forget assignments not seen in a mail for `days` days, unless still due ahead:
        a deadline months away is mentioned once and must outlast the quiet. Returns how many."""
        cutoff = _stamp(now - timedelta(days=days))
        with self._conn:
            cursor = self._conn.execute(
                "DELETE FROM tracked WHERE last_seen < ? AND (due_at IS NULL OR due_at < ?)",
                (cutoff, _stamp(now)),
            )
        return cursor.rowcount

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> DeadlineStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


# --- progress and the listing ------------


def _week(now: datetime, tz: tzinfo) -> tuple[datetime, datetime]:
    """Monday 00:00 to the next Monday 00:00 in the user's own timezone."""
    local = now.astimezone(tz)
    start = (local - timedelta(days=local.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return start, start + timedelta(days=7)


def progress(items: Sequence[Tracked], now: datetime, tz: tzinfo) -> tuple[int, int]:
    """(handled, total) for this week: what is due Monday-Sunday, plus every open overdue
    item - leaving those out would make an unfinished week look finished."""
    start, end = _week(now, tz)
    handled = total = 0
    for item in items:
        in_week = item.due_at is not None and start <= item.due_at.astimezone(tz) < end
        if in_week or item.overdue:
            total += 1
            handled += item.done_by is not None
    return handled, total


@dataclass(frozen=True)
class Listing:
    """What is shown: the lines, and the open items in the order they are numbered."""

    lines: list[str]
    numbered: list[Tracked]


def _when(item: Tracked, tz: tzinfo) -> str:
    if item.due_at is None:
        return "no date in the notice"
    local = item.due_at.astimezone(tz).strftime("%a %d %b %H:%M")
    return f"was due {local}" if item.overdue else f"due {local}"


def listing(items: Sequence[Tracked], now: datetime, tz: tzinfo) -> Listing:
    """Every item numbered - open ones first (overdue first), then handled ones - so any of them
    can be named, then the week's progress."""
    if not items:
        return Listing(
            ["No deadlines tracked yet - say 'read my mail' so I can look for LMS notices."], []
        )
    open_items = [i for i in items if i.done_by is None]
    done = [i for i in items if i.done_by is not None]
    lines: list[str] = []
    number = 0
    for heading, group in (
        ("Overdue", [i for i in open_items if i.overdue]),
        ("Due soon", [i for i in open_items if not i.overdue]),
    ):
        if group:
            lines.append(heading)
        for item in group:
            number += 1
            lines.append(f"  {number}. {item.title} - {_when(item, tz)}")
    if done:
        lines.append("Handled")
        for item in done:
            number += 1
            how = "submitted (LMS receipt)" if item.done_by == "receipt" else "marked done by you"
            lines.append(f"  {number}. {item.title} - {how}")
    handled, total = progress(items, now, tz)
    lines.append(f"This week: {handled} of {total} handled.")
    return Listing(lines, [*open_items, *done])


# --- what the agent talks to -----------------------------------------------------------------


class Tracker:
    """Record from mail, show a numbered list, mark by number. Opens the file per call.

    **Numbers mean what was last shown.** "Mark 2 done" is only safe if you and the agent mean
    the same item 2, so nothing is marked before a list has been shown, and recording new
    notices in between does not renumber it. **Only a mail read creates the file**: showing
    an empty list writes nothing.
    """

    def __init__(
        self,
        path: Path,
        tz: tzinfo,
        clock: Callable[[], datetime] | None = None,
        sender: str = "LMS",
    ) -> None:
        self._path, self._tz, self._sender = Path(path), tz, sender
        self._clock = clock or (lambda: datetime.now(tz))
        self._numbered: list[Tracked] | None = None

    def record_rows(self, rows: Sequence[MailItem]) -> tuple[int, int]:
        """(notices found, assignments that were new)."""
        seen = extract(rows, self._tz, self._sender)
        if not seen:
            return 0, 0
        now = self._clock()
        with DeadlineStore(self._path) as store:
            new = store.record(seen, now)
            store.purge(now)
        return len(seen), new

    def show(self) -> Listing:
        now = self._clock()
        if self._path.exists():
            with DeadlineStore(self._path) as store:
                view = listing(store.items(now), now, self._tz)
        else:
            view = listing([], now, self._tz)
        self._numbered = view.numbered
        return view

    def mark(self, number: int, undo: bool = False) -> str:
        """One sentence saying what happened to which assignment."""
        if self._numbered is None:
            return f"Say 'what is due' first, so we both mean the same item {number}."
        if not 1 <= number <= len(self._numbered):
            return f"There is no item {number}: the list has {len(self._numbered)}."
        item = self._numbered[number - 1]
        with DeadlineStore(self._path) as store:
            if undo:
                if store.reopen(item.key):
                    return f"Reopened '{item.title}'."
                if item.done_by == "receipt":
                    return f"'{item.title}' has a receipt: the LMS says you submitted it."
                return f"'{item.title}' is not marked done."
            if item.done_by is not None:
                return f"'{item.title}' is already handled."
            if not store.mark_done(item.key, self._clock()):
                return f"'{item.title}' is no longer on the list."
            return f"Marked '{item.title}' done."
