"""The tracker the agent talks to: record from mail, show a numbered list, mark by number.

**Numbers mean what was last shown.** "Mark 2 done" is only safe if both of you mean the
same item 2, so nothing is marked until a list has been shown, and recording new notices in
between does not renumber it.

**Only a mail read creates the file.** Looking at an empty list never writes anything.

**Messages say what happened to which title**, and only your own marks can be undone.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from pli.browser.mail import MailItem
from pli.deadlines import Tracker

DUBAI = ZoneInfo("Asia/Dubai")
NOW = datetime(2026, 10, 7, 12, 0, tzinfo=DUBAI)

DUE_LAB = "LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi Bao, The"
DUE_QUIZ = "LMS Due on Sunday, 11 October 2026, 9:00 AM: Quiz 4 Thu 8:48 AM Hi Bao, The quiz"
OVERDUE = "LMS Overdue: Research Draft (Viva) 4% Fri 9:27 AM Hi Bao, Research Draft (Viva) 4% in"
RECEIPT = "LMS You have submitted your assignment submission for Quiz 4 8:48 AM 2013"
PROSE = "Prof Ada Re: Quiz 3 Sat 4:15 PM The assignment deadline moved to Friday"


def _rows(*texts: str) -> list[MailItem]:
    return [
        MailItem(id=f"c{i}", unread=True, attachments=False, text=t) for i, t in enumerate(texts)
    ]


@pytest.fixture
def path(tmp_path: Path) -> Path:
    return tmp_path / "data" / "deadlines.db"


@pytest.fixture
def tracker(path: Path) -> Tracker:
    return Tracker(path, DUBAI, clock=lambda: NOW)


def test_recording_reports_how_many_notices_were_found_and_how_many_were_new(
    tracker: Tracker,
) -> None:
    assert tracker.record_rows(_rows(DUE_LAB, DUE_QUIZ, PROSE)) == (2, 2)
    assert tracker.record_rows(_rows(DUE_LAB, OVERDUE)) == (2, 1)


def test_only_notices_from_the_given_sender_are_recorded(path: Path) -> None:
    moodle = Tracker(path, DUBAI, clock=lambda: NOW, sender="Moodle")
    from_moodle = OVERDUE.replace("LMS", "Moodle", 1)

    assert moodle.record_rows(_rows(DUE_LAB)) == (0, 0)  # sent by "LMS", not "Moodle"
    assert moodle.record_rows(_rows(from_moodle)) == (1, 1)


def test_marking_something_that_has_left_the_file_does_not_claim_success(
    tracker: Tracker, path: Path
) -> None:
    from datetime import timedelta

    from pli.deadlines import DeadlineStore

    tracker.record_rows(_rows(DUE_LAB))
    tracker.show()
    with DeadlineStore(path) as store:
        store.purge(NOW + timedelta(days=200))  # long after it was due and last seen

    message = tracker.mark(1)

    assert "no longer" in message and "Marked" not in message


def test_a_mail_read_with_no_deadline_notices_creates_no_file(tracker: Tracker, path: Path) -> None:
    assert tracker.record_rows(_rows(PROSE, "Pest Control: October 2026 Thu 9:00 AM")) == (0, 0)

    assert not path.exists()


def test_showing_the_list_before_anything_was_recorded_writes_nothing_and_says_what_to_do(
    tracker: Tracker, path: Path
) -> None:
    view = tracker.show()

    assert "read my mail" in "\n".join(view.lines)
    assert not path.exists()


def test_the_list_is_numbered_with_progress_for_the_week(tracker: Tracker) -> None:
    tracker.record_rows(_rows(OVERDUE, DUE_LAB, DUE_QUIZ, RECEIPT))

    text = "\n".join(tracker.show().lines)

    assert "1. Research Draft (Viva) 4%" in text
    assert "2. Lab 6 Submission" in text
    assert "3. Quiz 4" in text and "submitted (LMS receipt)" in text
    assert "This week: 1 of 3 handled." in text


def test_nothing_is_marked_until_a_list_has_been_shown(tracker: Tracker) -> None:
    tracker.record_rows(_rows(DUE_LAB))

    reply = tracker.mark(1)

    assert "what is due" in reply
    assert "1. Lab 6 Submission" in "\n".join(tracker.show().lines)  # still open


def test_marking_by_number_marks_that_item_and_the_next_list_shows_it_handled(
    tracker: Tracker,
) -> None:
    tracker.record_rows(_rows(OVERDUE, DUE_LAB))
    tracker.show()

    reply = tracker.mark(2)

    assert reply == "Marked 'Lab 6 Submission' done."
    text = "\n".join(tracker.show().lines)
    assert "marked done by you" in text and "This week: 1 of 2 handled." in text


def test_a_number_that_is_not_on_the_list_is_refused_and_changes_nothing(
    tracker: Tracker,
) -> None:
    tracker.record_rows(_rows(DUE_LAB))
    tracker.show()

    assert "no item 5" in tracker.mark(5).lower()
    assert "no item 0" in tracker.mark(0).lower()
    assert "This week: 0 of 1 handled." in "\n".join(tracker.show().lines)


def test_marking_something_already_handled_says_so(tracker: Tracker) -> None:
    tracker.record_rows(_rows(DUE_QUIZ, RECEIPT))
    tracker.show()

    assert "already handled" in tracker.mark(1)


def _numbers(tracker: Tracker) -> dict[str, int]:
    return {item.title: n for n, item in enumerate(tracker.show().numbered, 1)}


def test_your_own_mark_can_be_undone_but_a_receipt_cannot(tracker: Tracker) -> None:
    tracker.record_rows(
        _rows(DUE_LAB, DUE_QUIZ, RECEIPT)
    )  # the lab is open, the quiz has a receipt
    tracker.show()
    tracker.mark(1)  # you say the lab is done

    numbers = _numbers(tracker)
    assert tracker.mark(numbers["Lab 6 Submission"], undo=True) == "Reopened 'Lab 6 Submission'."

    numbers = _numbers(tracker)
    assert "receipt" in tracker.mark(numbers["Quiz 4"], undo=True)
    assert "This week: 1 of 2 handled." in "\n".join(tracker.show().lines)


def test_an_undo_right_after_a_mark_still_means_the_item_just_marked(tracker: Tracker) -> None:
    """The numbers stay what was last shown, so 'mark 1 done' then 'undo 1' is the same item."""
    tracker.record_rows(_rows(DUE_LAB))
    tracker.show()
    tracker.mark(1)

    assert tracker.mark(1, undo=True) == "Reopened 'Lab 6 Submission'."


def test_new_notices_recorded_after_a_list_do_not_renumber_it(tracker: Tracker) -> None:
    tracker.record_rows(_rows(DUE_LAB))
    tracker.show()

    tracker.record_rows(_rows(OVERDUE))  # would sort first if the list were rebuilt
    reply = tracker.mark(1)

    assert reply == "Marked 'Lab 6 Submission' done."
