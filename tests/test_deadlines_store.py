"""The deadline list: what it remembers, what "done" means, and how progress is counted.

**A receipt closes an assignment and stays closed.** Re-reading old "due" mail must never
reopen something the LMS said you submitted.

**Only your own mark can be undone.** A receipt is evidence, not an opinion.

**"This week" is Monday to Sunday in the user's own timezone**, and an open overdue item
always counts: leaving it out would make a week look finished that is not.

**The file is private from the moment it exists** (mode 0600, not chmod-ed afterwards).

No clock is read here: every function is given `now`.
"""

from __future__ import annotations

import os
import stat
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from pli.deadlines import DeadlineStore, Seen, key_of, listing, progress

DUBAI = ZoneInfo("Asia/Dubai")
NOW = datetime(2026, 10, 7, 12, 0, tzinfo=DUBAI)  # a Wednesday
LAB = "Lab 6 Submission"
DRAFT = "Research Draft (Viva) 4%"


def _due(title: str, days: float, hour: int = 10) -> Seen:
    when = (NOW + timedelta(days=days)).replace(hour=hour, minute=0)
    return Seen("due", title, when)


@pytest.fixture
def store(tmp_path: Path) -> DeadlineStore:
    with DeadlineStore(tmp_path / "deadlines.db") as s:
        yield s


# --- the file ------------


def test_the_file_is_created_readable_only_by_its_owner(tmp_path: Path) -> None:
    path = tmp_path / "private" / "deadlines.db"

    DeadlineStore(path).close()

    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_a_file_made_earlier_with_looser_rights_is_tightened(tmp_path: Path) -> None:
    path = tmp_path / "deadlines.db"
    path.touch(mode=0o644)

    DeadlineStore(path).close()

    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


# --- recording ------------


def test_a_due_notice_is_remembered_with_its_date_and_counted_as_new(store: DeadlineStore) -> None:
    assert store.record([_due(LAB, 2)], NOW) == 1

    [item] = store.items(NOW)
    assert (item.title, item.due_at, item.done_by) == (LAB, _due(LAB, 2).due_at, None)


def test_the_same_notice_again_is_not_new_and_changes_nothing_else(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)

    assert store.record([_due(LAB, 2)], NOW + timedelta(hours=1)) == 0

    assert len(store.items(NOW)) == 1


def test_an_extended_deadline_replaces_the_old_date(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)

    store.record([_due(LAB, 5)], NOW)

    [item] = store.items(NOW)
    assert item.due_at == _due(LAB, 5).due_at


def test_a_notice_without_a_date_keeps_the_date_already_known(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)

    store.record([Seen("overdue", LAB)], NOW)

    [item] = store.items(NOW)
    assert item.due_at == _due(LAB, 2).due_at


def test_an_overdue_notice_alone_is_an_overdue_item_with_no_date(store: DeadlineStore) -> None:
    store.record([Seen("overdue", DRAFT)], NOW)

    [item] = store.items(NOW)
    assert item.due_at is None and item.overdue is True and item.done_by is None


def test_a_receipt_marks_the_assignment_done_by_receipt(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)

    store.record([Seen("submitted", "lab 6  submission")], NOW)  # case and spacing differ

    [item] = store.items(NOW)
    assert item.done_by == "receipt" and item.done_at is not None


def test_old_due_mail_read_again_does_not_reopen_a_submitted_assignment(
    store: DeadlineStore,
) -> None:
    store.record([_due(LAB, 2), Seen("submitted", LAB)], NOW)

    store.record([_due(LAB, 2)], NOW + timedelta(days=1))

    assert store.items(NOW)[0].done_by == "receipt"


def test_a_receipt_for_an_assignment_never_seen_due_is_kept_as_done(store: DeadlineStore) -> None:
    assert store.record([Seen("submitted", LAB)], NOW) == 1

    [item] = store.items(NOW)
    assert (item.title, item.done_by) == (LAB, "receipt")


# --- marking ------------


def test_marking_done_by_hand_is_recorded_as_manual(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)

    assert store.mark_done(key_of(LAB), NOW) is True

    assert store.items(NOW)[0].done_by == "manual"


def test_marking_an_unknown_assignment_does_nothing(store: DeadlineStore) -> None:
    assert store.mark_done("no such thing", NOW) is False


def test_a_manual_mark_can_be_undone(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2)], NOW)
    store.mark_done(key_of(LAB), NOW)

    assert store.reopen(key_of(LAB)) is True

    assert store.items(NOW)[0].done_by is None


def test_a_receipt_cannot_be_undone(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2), Seen("submitted", LAB)], NOW)

    assert store.reopen(key_of(LAB)) is False

    assert store.items(NOW)[0].done_by == "receipt"


def test_marking_a_receipt_done_does_not_turn_it_into_a_manual_mark(store: DeadlineStore) -> None:
    store.record([_due(LAB, 2), Seen("submitted", LAB)], NOW)

    store.mark_done(key_of(LAB), NOW)

    assert store.items(NOW)[0].done_by == "receipt"


# --- order and overdue ------------


def test_items_come_overdue_first_then_by_due_date_then_done_last(store: DeadlineStore) -> None:
    store.record(
        [
            _due("Later", 5),
            _due("Soon", 1),
            Seen("overdue", "Missed"),
            _due("Past", -2),
            _due("Finished", 1),
            Seen("submitted", "Finished"),
        ],
        NOW,
    )

    assert [i.title for i in store.items(NOW)] == ["Missed", "Past", "Soon", "Later", "Finished"]


def test_something_due_in_the_past_and_not_done_is_overdue_but_a_done_one_is_not(
    store: DeadlineStore,
) -> None:
    store.record([_due("Past", -2), _due("Done past", -2), Seen("submitted", "Done past")], NOW)

    overdue = {i.title: i.overdue for i in store.items(NOW)}

    assert overdue == {"Past": True, "Done past": False}


# --- progress ------------


def test_progress_counts_what_is_due_this_week_and_what_is_handled(store: DeadlineStore) -> None:
    # Wed 7 Oct: the week is Mon 5 Oct - Sun 11 Oct.
    store.record(
        [
            _due("Fri", 2),  # Fri 9 Oct, this week
            _due("Mon", -2),  # Mon 5 Oct, this week, and now past
            _due("Sun", 4),  # Sun 11 Oct, this week
            _due("Next week", 6),  # Mon 12 Oct: not this week
            Seen("submitted", "Mon"),
        ],
        NOW,
    )

    assert progress(store.items(NOW), NOW, DUBAI) == (1, 3)


def test_an_open_overdue_item_always_counts_even_from_last_week(store: DeadlineStore) -> None:
    store.record([_due("Old", -10), Seen("overdue", "Undated")], NOW)

    assert progress(store.items(NOW), NOW, DUBAI) == (0, 2)


def test_a_done_old_item_does_not_count_toward_this_week(store: DeadlineStore) -> None:
    store.record([_due("Old", -10), Seen("submitted", "Old")], NOW)

    assert progress(store.items(NOW), NOW, DUBAI) == (0, 0)


def test_the_week_boundary_follows_the_users_timezone_not_utc(store: DeadlineStore) -> None:
    # 02:00 Monday in Dubai is still Sunday in UTC. A FINISHED item is used on purpose: an open
    # one would count (as overdue) whichever week it fell in and prove nothing about the boundary.
    monday_early = datetime(2026, 10, 5, 2, 0, tzinfo=DUBAI)
    store.record([Seen("due", "Early", monday_early), Seen("submitted", "Early")], NOW)

    assert progress(store.items(NOW), NOW, DUBAI) == (1, 1)


# --- the listing the user sees ------------


def test_the_listing_numbers_open_items_first_then_handled_ones_so_either_can_be_named(
    store: DeadlineStore,
) -> None:
    store.record([_due("Soon", 1), Seen("overdue", "Missed"), _due("Done", 1)], NOW)
    store.record([Seen("submitted", "Done")], NOW)

    view = listing(store.items(NOW), NOW, DUBAI)

    assert [i.title for i in view.numbered] == ["Missed", "Soon", "Done"]
    text = "\n".join(view.lines)
    assert "1. Missed" in text and "2. Soon" in text and "3. Done" in text
    assert "handled" in text.lower()


def test_an_empty_list_says_so_and_how_to_fill_it(store: DeadlineStore) -> None:
    view = listing(store.items(NOW), NOW, DUBAI)

    assert view.numbered == []
    assert "read my mail" in "\n".join(view.lines)


# --- retention ------------


def test_a_deadline_still_ahead_is_kept_however_long_since_a_mail_mentioned_it(
    store: DeadlineStore,
) -> None:
    store.record([_due("Capstone", 90), Seen("overdue", "Missed")], NOW)

    removed = store.purge(NOW + timedelta(days=61), days=60)

    assert removed == 1  # "Missed" has no date and was not mentioned again: forgotten
    assert [i.title for i in store.items(NOW)] == ["Capstone"]


def test_old_items_are_purged_but_recent_ones_stay(store: DeadlineStore) -> None:
    store.record([_due("Ancient", -100)], NOW - timedelta(days=100))
    store.record([_due("Recent", 1)], NOW)

    removed = store.purge(NOW, days=60)

    assert removed == 1
    assert [i.title for i in store.items(NOW)] == ["Recent"]
