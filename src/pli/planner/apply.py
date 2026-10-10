"""Reconcile planned blocks against the calendar.

Three protections, in order of importance:

1. **A dedicated calendar.** Everything is written to a "Study Plan" calendar the
   tool owns, and only there. A regeneration is therefore structurally incapable
   of damaging your real timetable - not because the code is careful, but
   because it never addresses anything else.
2. **A marker, not a guess.** Every event this tool writes carries
   `[pli:<block_key>]` in its body, and only events carrying that marker may be
   updated or deleted. An event the user created by hand is invisible to the
   delete pass even if it sits in the Study Plan calendar.
3. **A reconciliation ledger.** `block_key` is stable across replans, so a block
   that moves is updated rather than duplicated. If the local database is lost,
   `discover_events` rebuilds the mapping from the events themselves.

The calendar is reached through `pli.backend.CalendarBackend`, so this module
holds no I/O and no knowledge of the surface being driven.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime

from pli.backend import CalendarBackend
from pli.db import Store
from pli.models import Block

CALENDAR_NAME = "Study Plan"
CATEGORY = "Study Plan"

#: The marker that identifies this tool's own events. `block_key` is
#: `sha1(task_key|session_index)[:16]`, so the charset is hex - matching a
#: tighter pattern would silently fail to recognise real blocks.
MARKER_RE = re.compile(r"\[pli:([0-9a-f]{16})\]")


def marker(block_key: str) -> str:
    """The line appended to every block body so the event is recognisable."""
    return f"[pli:{block_key}]"


def read_marker(body: str | None) -> str | None:
    """Recover the block_key from an event body, or None if it is not ours."""
    if not body:
        return None
    match = MARKER_RE.search(body)
    return match.group(1) if match else None


@dataclass
class ApplyResult:
    created: int = 0
    updated: int = 0
    deleted: int = 0
    unchanged: int = 0
    dry_run: bool = True
    calendar_id: str | None = None

    @property
    def total_changes(self) -> int:
        return self.created + self.updated + self.deleted


def body_for(block: Block) -> str:
    """The event body: what the user reads, plus the marker line.

    The marker is last so it is out of the way, and present exactly once - a
    block that has been updated repeatedly would otherwise accumulate copies.
    """
    text = MARKER_RE.sub("", block.body or "").rstrip()
    return f"{text}\n\n{marker(block.block_key)}" if text else marker(block.block_key)


class CalendarWriter:
    def __init__(self, backend: CalendarBackend, store: Store) -> None:
        self.backend = backend
        self.store = store

    # --- ledger ----------------------------------------------------------------

    def discover_events(self, start: datetime, end: datetime) -> dict[str, str]:
        """Rebuild block_key -> event_id from the calendar itself.

        Used when the local database has been lost or the ledger is empty.
        Without this, a wiped database would duplicate every existing block
        instead of adopting it.

        `start`/`end` bound the scan. Blocks are only ever planned within the
        horizon, so scanning it is enough and keeps the read cheap.
        """
        found: dict[str, str] = {}
        for event in self.backend.list_events(start, end):
            if event.block_key:
                found[event.block_key] = event.remote_id
        return found

    # --- the reconcile pass ----------------------------------------------------

    def apply(self, blocks: list[Block], *, dry_run: bool = True) -> ApplyResult:
        result = ApplyResult(dry_run=dry_run)

        if dry_run:
            # A dry run must not touch the backend at all: no creating, and no
            # reading either if the ledger can answer. It reports what *would*
            # happen, counted against the ledger.
            ledger = self.store.block_ledger(CALENDAR_NAME)
            for block in blocks:
                row = ledger.get(block.block_key)
                if row is None or not row["remote_event_id"]:
                    result.created += 1
                elif self._drifted(row, block):
                    result.updated += 1
                else:
                    result.unchanged += 1
            for key in ledger:
                if key not in {b.block_key for b in blocks}:
                    result.deleted += 1
            result.calendar_id = CALENDAR_NAME
            return result

        result.calendar_id = CALENDAR_NAME
        ledger = self.store.block_ledger(CALENDAR_NAME)

        # Adopt anything already in the calendar before creating a copy of it.
        # The condition used to be "is the whole ledger empty", which covers a
        # lost database and misses the case that actually happens: a run killed
        # between saving an event and recording its id leaves *one* block whose
        # key now exists only on the calendar, and the next run wrote a second
        # copy of it. Asking the calendar whenever any planned block is
        # unrecorded closes that window; a ledger with an id for every block -
        # the steady state - still costs no read at all.
        if self._unrecorded(ledger, blocks):
            span = _span(blocks)
            if span is not None:
                for key, event_id in self.discover_events(*span).items():
                    self.store.adopt_block(key, calendar_id=CALENDAR_NAME, remote_event_id=event_id)
                ledger = self.store.block_ledger(CALENDAR_NAME)

        desired = {block.block_key: block for block in blocks}

        for key, block in desired.items():
            row = ledger.get(key)
            if row is None or not row["remote_event_id"]:
                created_id = self.backend.create_event(block)
                self.store.record_block(
                    block, calendar_id=CALENDAR_NAME, remote_event_id=created_id
                )
                result.created += 1
                continue

            if self._drifted(row, block):
                self.backend.update_event(row["remote_event_id"], block)
                self.store.record_block(
                    block, calendar_id=CALENDAR_NAME, remote_event_id=row["remote_event_id"]
                )
                result.updated += 1
            else:
                result.unchanged += 1

        for key, row in ledger.items():
            if key in desired:
                continue
            # One of our blocks is no longer planned - remove it, and only it.
            # `key` came from the ledger, which only ever holds keys this tool
            # wrote, so this can never address a foreign event.
            if row["remote_event_id"]:
                self.backend.delete_event(row["remote_event_id"])
            self.store.forget_block(key)
            result.deleted += 1

        return result

    @staticmethod
    def _unrecorded(ledger: dict[str, sqlite3.Row], blocks: list[Block]) -> list[Block]:
        """The blocks this run has no event id for - what a `create` would target."""
        return [
            block
            for block in blocks
            if ledger.get(block.block_key) is None or not ledger[block.block_key]["remote_event_id"]
        ]

    @staticmethod
    def _drifted(row: sqlite3.Row, block: Block) -> bool:
        """Has the planned block moved or been renamed since we last wrote it?"""
        try:
            start = datetime.fromisoformat(row["start_utc"])
            end = datetime.fromisoformat(row["end_utc"])
        except (TypeError, ValueError):
            return True  # Adopted or unknown provenance - refresh it.
        return start != block.start or end != block.end or row["subject"] != block.subject


def _span(blocks: list[Block]) -> tuple[datetime, datetime] | None:
    """The window the planned blocks cover, or None when there are none."""
    if not blocks:
        return None
    return min(b.start for b in blocks), max(b.end for b in blocks)
