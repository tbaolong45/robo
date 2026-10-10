"""Calendar reconciliation: the idempotency guarantee and the safety rails.

Three things here can destroy the user's week if they are wrong, so each one is
pinned by name: a rerun must not duplicate the plan, a block that moved must be
updated in place, and nothing this tool did not write may ever be touched. Those
guarantees live in the reconcile loop, not in the transport - the loop now
reaches the calendar through `pli.backend.CalendarBackend`.

So the calendar is a dictionary behind that seam (`FakeBackend`) rather than a
network or a browser. The fake is deliberately dumb and deliberately literal: it
recovers a block's identity from the marker in the event body with `read_marker`,
exactly as the browser backend must, because a fake handed the key directly would
never exercise the marker that the whole delete pass depends on.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from pli.db import Store
from pli.models import Block, RemoteEvent
from pli.planner.apply import (
    CALENDAR_NAME,
    CATEGORY,
    MARKER_RE,
    CalendarWriter,
    body_for,
    read_marker,
)
from pli.planner.pack import block_key_for

BASE = datetime(2026, 10, 5, 8, 0, tzinfo=UTC)


def _key(name: str) -> str:
    """A real block key, made the way the planner makes them.

    Not a convenience string: `block_key_for` is `sha1(task|session)[:16]`, and
    the marker pattern only accepts that shape, so a test using "a" would be
    testing a key the production code cannot produce.
    """
    return block_key_for(name, 0)


def _block(
    name: str,
    *,
    hour: int = 8,
    minutes: int = 60,
    subject: str = "Study",
    body: str = "Read chapter 3",
) -> Block:
    start = BASE.replace(hour=hour)
    return Block(
        block_key=_key(name),
        task_key=f"task-{name}",
        subject=subject,
        start=start,
        end=start + timedelta(minutes=minutes),
        body=body,
    )


class _CalendarUnreadable(RuntimeError):
    """What a backend raises when the calendar could not be read at all.

    Deliberately not a `pli.browser` error: the reconcile loop above the seam
    must not care which surface failed, only that the read did not answer.
    """


class FakeBackend:
    """A calendar in a dictionary, answering the four `CalendarBackend` calls.

    Every call is recorded, including reads, so a test can assert not just what
    happened but that nothing happened at all.
    """

    def __init__(self) -> None:
        self.events: dict[str, RemoteEvent] = {}
        self.calls: list[tuple[Any, ...]] = []
        self._seq = 0

    # --- the four calls ---------------------------------------------------------

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        self.calls.append(("list", start, end))
        return [self._as_seen(e) for e in self.events.values() if e.end > start and e.start < end]

    def create_event(self, block: Block) -> str:
        self.calls.append(("create", block.block_key))
        # Adopts on `block_key` so a duplicate is impossible here whatever the
        # writer does. Belt and braces on purpose: the writer now discovers
        # before creating, and this keeps the double from being *more* forgiving
        # than the real backend in a way that hides a bug - `OutlookBackend`
        # has no lookup of its own.
        for existing in self.events.values():
            if read_marker(existing.body) == block.block_key:
                return existing.remote_id
        self._seq += 1
        remote_id = f"event-{self._seq}"
        self.events[remote_id] = RemoteEvent(
            remote_id=remote_id,
            subject=block.subject,
            start=block.start,
            end=block.end,
            body=body_for(block),
            all_day=False,
            show_as="busy",
            categories=[CATEGORY],
        )
        return remote_id

    def update_event(self, remote_id: str, block: Block) -> None:
        self.calls.append(("update", remote_id))
        self._replace(
            remote_id,
            subject=block.subject,
            start=block.start,
            end=block.end,
            body=body_for(block),
        )

    def delete_event(self, remote_id: str) -> None:
        self.calls.append(("delete", remote_id))
        self.events.pop(remote_id, None)

    # --- test helpers -----------------------------------------------------------

    def seed_foreign(
        self,
        *,
        subject: str,
        start: datetime,
        minutes: int = 60,
        body: str = "",
        all_day: bool = False,
        show_as: str = "busy",
    ) -> str:
        """Add an event the user made by hand: same calendar, no marker."""
        self._seq += 1
        remote_id = f"hand-made-{self._seq}"
        self.events[remote_id] = RemoteEvent(
            remote_id=remote_id,
            subject=subject,
            start=start,
            end=start + timedelta(minutes=minutes),
            body=body,
            all_day=all_day,
            show_as=show_as,
        )
        return remote_id

    def event_for(self, name: str) -> RemoteEvent:
        """The stored event carrying `name`'s marker."""
        key = _key(name)
        found = [e for e in self.events.values() if read_marker(e.body) == key]
        assert len(found) == 1, f"expected exactly one event for {name!r}, found {len(found)}"
        return found[0]

    def writes(self) -> list[tuple[Any, ...]]:
        """Every call that would change the calendar."""
        return [c for c in self.calls if c[0] in {"create", "update", "delete"}]

    def kinds(self) -> list[str]:
        return [c[0] for c in self.writes()]

    def _replace(self, remote_id: str, **fields: Any) -> None:
        self.events[remote_id] = self.events[remote_id].model_copy(update=fields)

    @staticmethod
    def _as_seen(event: RemoteEvent) -> RemoteEvent:
        """What a read returns, with identity recovered from the body.

        The web UI offers nowhere to store a custom property, so this recovery
        is the only way an event can be recognised as ours. Modelling that here
        means the tests fail if `body_for`/`read_marker` ever stop round-tripping.
        """
        return event.model_copy(update={"block_key": read_marker(event.body)})


@pytest.fixture
def store(tmp_path):
    with Store(tmp_path / "state.db") as s:
        yield s


# --- a dry run is inert ----------------------------------------------------------


def test_the_writer_defaults_to_a_dry_run(store):
    """The destructive branch is opt-in, so the flag's default is the safe half.

    Every other test here passes `dry_run` explicitly, which means the default
    itself is what a caller that forgets the flag gets - a new command, a
    helper, a future caller. Flipping it would turn each of those into a write
    to the user's calendar without a line changing at those call sites, and
    nothing in this file would notice.
    """
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)

    result = writer.apply([_block("a")])

    assert result.dry_run is True
    assert backend.events == {}
    assert backend.writes() == []


def test_a_dry_run_writes_nothing_and_touches_nothing(store):
    """It is shown to the user as a preview; it must be safe to run at any time."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)

    result = writer.apply([_block("a"), _block("b")], dry_run=True)

    assert (result.created, result.updated, result.deleted) == (2, 0, 0)
    assert result.dry_run is True
    assert backend.events == {}


def test_a_dry_run_never_calls_the_backend_at_all(store):
    """Not even a read, and not even to check the ledger still exists."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a")], dry_run=False)
    backend.calls.clear()

    writer.apply([_block("a", hour=11)], dry_run=True)

    assert backend.calls == []


def test_a_dry_run_reports_the_drift_it_would_apply(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a")], dry_run=False)
    backend.calls.clear()

    result = writer.apply([_block("a", hour=11)], dry_run=True)

    assert (result.created, result.updated, result.deleted) == (0, 1, 0)
    assert backend.writes() == []


def test_a_dry_run_counts_the_orphan_blocks_it_would_delete(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b")], dry_run=False)
    backend.calls.clear()

    result = writer.apply([_block("a")], dry_run=True)

    assert (result.created, result.updated, result.deleted) == (0, 0, 1)
    assert _key("b") in store.block_ledger(CALENDAR_NAME)  # a preview must not forget
    assert backend.writes() == []


# --- the idempotency guarantee ---------------------------------------------------


def test_a_second_apply_reports_no_changes(store):
    """The plan's core promise: re-running apply must be a no-op."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    blocks = [_block("a"), _block("b"), _block("c")]

    first = writer.apply(blocks, dry_run=False)
    snapshot = {k: v.model_copy() for k, v in backend.events.items()}
    backend.calls.clear()

    second = writer.apply(blocks, dry_run=False)

    assert first.created == 3
    assert (second.created, second.updated, second.deleted) == (0, 0, 0)
    assert second.unchanged == 3
    assert backend.writes() == []
    assert backend.events == snapshot


def test_a_replan_touches_only_what_moved(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b"), _block("c")], dry_run=False)

    result = writer.apply([_block("a"), _block("b", hour=15), _block("d")], dry_run=False)

    assert (result.created, result.updated, result.deleted) == (1, 1, 1)
    assert result.unchanged == 1


def test_an_empty_plan_against_an_empty_calendar_is_harmless(store):
    backend = FakeBackend()
    result = CalendarWriter(backend, store).apply([], dry_run=False)
    assert (result.created, result.updated, result.deleted) == (0, 0, 0)
    assert backend.calls == []


# --- drift is an update, never a duplicate ---------------------------------------


def test_a_moved_start_updates_the_existing_event_in_place(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a")], dry_run=False)

    writer.apply([_block("a", hour=14)], dry_run=False)

    assert len(backend.events) == 1
    assert backend.kinds() == ["create", "update"]
    assert backend.event_for("a").start == BASE.replace(hour=14)


def test_a_moved_end_updates_the_existing_event_in_place(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a")], dry_run=False)

    writer.apply([_block("a", minutes=90)], dry_run=False)

    assert len(backend.events) == 1
    assert backend.event_for("a").end == BASE + timedelta(minutes=90)


def test_a_renamed_subject_updates_the_existing_event_in_place(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a", subject="Old")], dry_run=False)

    writer.apply([_block("a", subject="New")], dry_run=False)

    assert len(backend.events) == 1
    assert backend.event_for("a").subject == "New"


# --- nothing that is not ours is ever touched ------------------------------------


def test_an_event_without_our_marker_is_never_updated(store):
    """A hand-made event in the Study Plan calendar is not a block to correct."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    dentist = backend.seed_foreign(
        subject="Dentist", start=BASE.replace(hour=14), body="bring the form"
    )

    writer.apply([_block("a", hour=14)], dry_run=False)

    assert backend.events[dentist].subject == "Dentist"
    assert backend.events[dentist].body == "bring the form"
    assert backend.kinds() == ["create"]


def test_an_event_without_our_marker_is_never_deleted(store):
    """The tool must be structurally incapable of touching anything else."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a")], dry_run=False)
    dentist = backend.seed_foreign(subject="Dentist", start=BASE.replace(hour=14))

    result = writer.apply([], dry_run=False)

    assert result.deleted == 1  # only "a", whose key is in the ledger
    assert dentist in backend.events
    assert backend.kinds() == ["create", "delete"]


def test_a_block_that_leaves_the_plan_is_deleted_and_only_it(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b")], dry_run=False)

    result = writer.apply([_block("a")], dry_run=False)

    assert result.deleted == 1
    assert set(backend.events) == {backend.event_for("a").remote_id}
    assert set(store.block_ledger(CALENDAR_NAME)) == {_key("a")}


def test_an_empty_plan_deletes_the_ledgers_orphans(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b")], dry_run=False)
    backend.calls.clear()

    result = writer.apply([], dry_run=False)

    assert result.deleted == 2
    assert backend.events == {}
    assert store.block_ledger(CALENDAR_NAME) == {}


# --- ledger recovery -------------------------------------------------------------


def test_a_wiped_ledger_adopts_existing_events_instead_of_duplicating(store):
    """A lost database must cost a refresh, not a second copy of the week."""
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b")], dry_run=False)
    assert len(backend.events) == 2

    for key in list(store.block_ledger(CALENDAR_NAME)):
        store.forget_block(key)
    backend.calls.clear()

    result = writer.apply([_block("a"), _block("b")], dry_run=False)

    assert result.created == 0
    assert len(backend.events) == 2  # adopted, not duplicated
    assert backend.calls[0][0] == "list"  # the calendar was consulted, not trusted
    assert backend.kinds() == ["update", "update"]  # refreshed in place


class _UnreadableBackend(FakeBackend):
    """A double whose calendar cannot be read at all.

    Only the read is broken; every other call answers as `FakeBackend` does, so
    a test using it is testing the failed read and nothing else.
    """

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        raise _CalendarUnreadable("the week grid never appeared")


# --- a failed read is not an empty calendar --------------------------------------


def test_a_read_that_failed_is_not_a_calendar_holding_nothing(store):
    """`discover_events` returning `{}` is an answer, not an absence of one.

    The writer acts on it: an empty answer means "none of our blocks are in the
    calendar", so it goes on to create every block it was given. A read failure
    allowed to answer `{}` therefore puts a second copy of the whole week into
    the calendar, which is the duplicate the ledger exists to prevent - so the
    failure has to come back out instead.
    """
    writer = CalendarWriter(_UnreadableBackend(), store)

    with pytest.raises(_CalendarUnreadable):
        writer.discover_events(BASE, BASE + timedelta(days=1))


def test_a_failed_read_stops_the_write_pass_instead_of_duplicating_the_week(store):
    """The same failure, at the point where it would do damage.

    With the ledger empty `apply` adopts from the calendar before creating, so
    it is a failed read here that decides whether the week is adopted or
    written twice.
    """
    backend = _UnreadableBackend()
    writer = CalendarWriter(backend, store)

    with pytest.raises(_CalendarUnreadable):
        writer.apply([_block("a"), _block("b")], dry_run=False)

    assert backend.events == {}


def test_discover_events_adopts_only_events_carrying_a_block_key(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    writer.apply([_block("a"), _block("b")], dry_run=False)
    backend.seed_foreign(subject="Dentist", start=BASE)

    found = writer.discover_events(BASE - timedelta(days=1), BASE + timedelta(days=1))

    assert set(found) == {_key("a"), _key("b")}
    assert set(found.values()) <= set(backend.events)


def test_discover_events_over_a_span_with_only_foreign_events_finds_nothing(store):
    backend = FakeBackend()
    writer = CalendarWriter(backend, store)
    backend.seed_foreign(subject="Dentist", start=BASE)

    assert writer.discover_events(BASE - timedelta(days=1), BASE + timedelta(days=1)) == {}


# --- the marker mechanism --------------------------------------------------------


def test_body_for_appends_the_marker_after_the_users_own_text(store):
    body = body_for(_block("a", body="Read chapter 3"))
    assert body == f"Read chapter 3\n\n[pli:{_key('a')}]"


def test_read_marker_recovers_the_key_that_body_for_wrote(store):
    assert read_marker(body_for(_block("a"))) == _key("a")


def test_body_for_does_not_accumulate_a_second_marker(store):
    """An event updated on every replan would otherwise grow a marker a day."""
    once = body_for(_block("a", body="Read chapter 3"))
    twice = body_for(_block("a", body=once))

    assert twice == once
    assert len(MARKER_RE.findall(twice)) == 1


def test_body_for_replaces_a_stale_marker_rather_than_keeping_both(store):
    """The body is the only record of identity, so it must name the live key."""
    body = body_for(_block("a", body=f"Read chapter 3\n\n[pli:{_key('b')}]"))
    assert body == f"Read chapter 3\n\n[pli:{_key('a')}]"


def test_body_for_on_a_block_with_no_body_is_just_the_marker(store):
    assert body_for(_block("a", body="")) == f"[pli:{_key('a')}]"


@pytest.mark.parametrize(
    "body",
    [
        None,
        "",
        "   ",
        "Dentist at 14:00",
        "[pli:not-a-key]",
        # The same shape, in the case this tool never writes: `block_key` is
        # `sha1(...)[:16]`, and hexdigest is lowercase. A pattern that accepted
        # it would claim an event nobody here created, and a claimed event is
        # one the delete pass is allowed to touch.
        "[pli:A1B2C3D4E5F60718]",
    ],
)
def test_read_marker_is_none_for_a_body_that_is_not_ours(body):
    assert read_marker(body) is None


@pytest.mark.parametrize("length", [15, 17])
def test_the_marker_pattern_rejects_keys_of_the_wrong_length(length):
    """`block_key` is exactly 16 hex chars; a looser pattern would match junk,
    and a tighter one would silently fail to recognise real blocks."""
    wrong_length = "0123456789abcdef0"[:length]
    assert len(wrong_length) == length
    assert MARKER_RE.search(f"[pli:{wrong_length}]") is None


def test_the_marker_pattern_accepts_a_real_block_key():
    key = _key("a")  # sha1(task|0)[:16]
    assert len(key) == 16
    assert MARKER_RE.search(f"[pli:{key}]").group(1) == key


def test_the_marker_is_found_anywhere_in_a_body_the_user_has_edited():
    """Nothing stops the user typing above it in the web UI's body field."""
    body = f"Bring the lab coat\n\n[pli:{_key('a')}]\n\nadded by hand"
    assert read_marker(body) == _key("a")


def test_a_block_the_ledger_forgot_is_adopted_and_not_duplicated(store):
    """The crash window, which is narrower than a wiped database and likelier.

    Adoption used to be triggered by the *whole* ledger being empty. A run killed
    between saving an event and recording its id leaves one block whose key
    survives only on the calendar, and the next run created a second copy of it -
    the failure `CalendarBackend.create_event` calls "the most visible possible
    failure". The fake backend hides it, because it implements the adoption the
    real browser backend never did.
    """
    backend = FakeBackend()
    alpha, beta = _block("alpha"), _block("beta", hour=10)
    forgotten = backend.create_event(alpha)  # written by an earlier run...
    recorded = backend.create_event(beta)
    # ...but only one of the two reached the ledger before that run died.
    store.record_block(beta, calendar_id=CALENDAR_NAME, remote_event_id=recorded)
    assert forgotten not in {
        row["remote_event_id"] for row in store.block_ledger(CALENDAR_NAME).values()
    }
    before = len(backend.events)
    backend.calls.clear()

    outcome = CalendarWriter(backend, store).apply([alpha, beta], dry_run=False)

    assert len(backend.events) == before, "the forgotten block was written a second time"
    assert ("create", alpha.block_key) not in backend.calls
    assert outcome.created == 0
    assert outcome.updated == 1  # adopted from the calendar, then refreshed in place
    assert outcome.unchanged == 1


def test_a_complete_ledger_costs_no_calendar_read(store):
    """The check above must not turn every run into an extra page read."""
    backend = FakeBackend()
    blocks = [_block("a"), _block("b", hour=10)]
    CalendarWriter(backend, store).apply(blocks, dry_run=False)
    backend.calls.clear()

    CalendarWriter(backend, store).apply(blocks, dry_run=False)

    assert backend.kinds() == [], "a settled week should not be read again"
