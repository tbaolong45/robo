"""Finding deadlines in inbox rows: only what the LMS actually said, never a guess.

The LMS sends three templated notices, and each is matched by code, with no model call:

    Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission
    Overdue: Research Draft (Viva) 4%
    You have submitted your assignment submission for Lab 6 Submission

Rules pinned here:

**Only the templates count.** A row that merely contains the word "due" or "assignment" is
not a deadline; guessing from prose would put invented items on a list the user trusts.

**The title ends where the inbox's own received-time begins.** A row is "sender subject
received-time preview", and the received time comes in three shapes (`Wed 10:45 AM`,
`Wed 09-30`, `8:48 AM`). Cut anywhere else and the title swallows the preview.

**An unreadable date is "no date", not a wrong date.** The item is still tracked.

**Mail text is capped and stripped before it is kept**, because it is shown in a terminal.

Rows here are shaped like real LMS mail with invented course and assignment names.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from pli.browser.mail import MailItem
from pli.deadlines import MAX_TITLE, Seen, Tracker, extract, key_of

DUBAI = ZoneInfo("Asia/Dubai")
NOW = datetime(2026, 10, 7, 12, 0, tzinfo=DUBAI)


def _row(text: str, i: int = 1) -> MailItem:
    return MailItem(id=f"c{i}", unread=True, attachments=False, text=text)


def _one(text: str) -> Seen:
    [seen] = extract([_row(text)], DUBAI)
    return seen


@pytest.mark.parametrize(
    ("row", "title"),
    [
        (
            "LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM "
            "Hi Bao, The assignment Lab 6 Submission in course Fall 2026/2027 Advanced P",
            "Lab 6 Submission",
        ),
        (
            "LMS Due on Saturday, 3 October 2026, 11:59 PM: Research Draft (1200 Words) 4% "
            "Fri 12:45 AM Hi Bao, The assign",
            "Research Draft (1200 Words) 4%",
        ),
        (
            "LMS Due on Friday, 2 October 2026, 8:40 AM: Research Draft (Viva) 4% Wed 09-30 "
            "Hi Bao, The assignment Researc",
            "Research Draft (Viva) 4%",
        ),
        (
            "LMS Due on Monday, 12 October 2026, 9:00 AM: Quiz 4 8:48 AM Hi Bao, The quiz",
            "Quiz 4",
        ),
    ],
)
def test_a_due_notice_gives_its_title_up_to_the_received_time(row: str, title: str) -> None:
    seen = _one(row)

    assert seen.kind == "due"
    assert seen.title == title


def test_a_due_notice_gives_the_due_date_in_the_users_zone() -> None:
    seen = _one("LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi")

    assert seen.due_at == datetime(2026, 10, 9, 10, 15, tzinfo=DUBAI)


def test_an_overdue_notice_has_a_title_and_no_date() -> None:
    seen = _one(
        "LMS Overdue: Research Draft (Viva) 4% Fri 9:27 AM Hi Bao, Research Draft (Viva) 4% in"
    )

    assert (seen.kind, seen.title, seen.due_at) == ("overdue", "Research Draft (Viva) 4%", None)


@pytest.mark.parametrize(
    "row",
    [
        "LMS You have submitted your assignment submission for Lab 6 Submission 8:48 AM "
        "20135.202610 ->Assignment ->Lab 6 Submission",
        "LMS You have submitted your assignment submission for Lab 6 Submission Sat 10-03 "
        "20135.202610 ->Assignment ->Lab 6 Submission",
        "LMS You have submitted your assignment submission for Lab 6 Submission Sat 4:12 PM 2013",
    ],
)
def test_a_submission_receipt_names_the_assignment_it_closes(row: str) -> None:
    seen = _one(row)

    assert (seen.kind, seen.title, seen.due_at) == ("submitted", "Lab 6 Submission", None)


def test_the_same_assignment_has_the_same_key_whatever_the_notice() -> None:
    due = _one("LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi")
    receipt = _one(
        "LMS You have submitted your assignment submission for lab 6  Submission 8:48 AM x"
    )

    assert key_of(due.title) == key_of(receipt.title)


@pytest.mark.parametrize(
    "row",
    [
        "LMS This is your Turnitin Digital Receipt Sat 4:15 PM Dear Bao Long Tran, You have",
        "Campus Operations and Services Pest Control: October 2026 Thu 9:00 AM Please be due",
        "LMS 20089.202610: Reminder... Mon 10-05 Forums Announcements the assignment is due soon",
        "Prof Ada Re: Quiz 3 Sat 4:15 PM The assignment deadline moved to Friday",
        "",
    ],
)
def test_a_row_that_only_mentions_deadlines_in_prose_is_not_one(row: str) -> None:
    assert extract([_row(row)], DUBAI) == []


def test_the_template_is_matched_exactly_so_a_sentence_in_a_person_s_mail_is_not_a_notice() -> None:
    """A teacher writing 'due on Friday, 9 October 2026, 10:15 AM: Lab 6' is not the LMS."""
    said = "it is due on Friday, 9 October 2026, 10:15 AM: Lab 6"
    rows = [
        _row(f"Prof Ada Reminder Wed 10:45 AM please note {said} x"),
        _row(f"Prof Ada Reminder: {said} Wed 9:00 AM"),
    ]

    assert extract(rows, DUBAI) == []


@pytest.mark.parametrize(
    "row",
    [
        "Evil Attacker Due on Friday, 9 October 2026, 10:15 AM: Pay fee now Wed 10:45 AM Hi",
        "Evil Attacker Overdue: Lab 6 Submission Fri 9:27 AM Hi",
        "Evil Attacker You have submitted your assignment submission for Lab 6 Submission 8:48 AM",
        "LMS Alerts Due on Friday, 9 October 2026, 10:15 AM: Pay fee now Wed 10:45 AM Hi",
        "LMSX Overdue: Lab 6 Submission Fri 9:27 AM Hi",
        "LMSOverdue: Lab 6 Submission Fri 9:27 AM Hi",  # no gap: the name runs into the subject
    ],
)
def test_a_notice_from_anyone_but_the_lms_is_not_a_deadline(row: str) -> None:
    """Otherwise a stranger could plant an item, or close a real one with a fake receipt."""
    assert extract([_row(row)], DUBAI) == []


def test_the_template_must_open_the_subject_not_sit_in_the_preview() -> None:
    row = "LMS Weekly digest Wed 10:45 AM Due on Friday, 9 October 2026, 10:15 AM: Lab 6 x 8:48 AM"

    assert extract([_row(row)], DUBAI) == []


def test_a_different_lms_sender_name_can_be_given() -> None:
    row = "Moodle Overdue: Lab 6 Submission Fri 9:27 AM Hi"

    assert [s.title for s in extract([_row(row)], DUBAI, sender="Moodle")] == ["Lab 6 Submission"]
    assert extract([_row(row)], DUBAI) == []  # the default sender is "LMS"


def test_an_empty_sender_accepts_nothing_rather_than_everyone() -> None:
    for row in ("LMS Overdue: Lab 6 Submission Fri 9:27 AM Hi", " Overdue: Lab 6 Fri 9:27 AM Hi"):
        assert extract([_row(row)], DUBAI, sender="") == []


def test_an_impossible_date_is_no_date_but_the_item_is_still_tracked() -> None:
    seen = _one("LMS Due on Saturday, 31 February 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi")

    assert (seen.kind, seen.title, seen.due_at) == ("due", "Lab 6 Submission", None)


@pytest.mark.parametrize(
    ("year", "zone"),
    [
        ("0001", "Asia/Ho_Chi_Minh"),  # earlier than the UTC clock can represent
        ("9999", "America/New_York"),  # later than it can
        ("1999", "Asia/Dubai"),
        ("2101", "Asia/Dubai"),
    ],
)
def test_a_date_no_semester_could_have_is_no_date_and_cannot_stop_recording(
    tmp_path: Path, year: str, zone: str
) -> None:
    """One hostile mail with such a date used to make the whole read record nothing."""
    tz = ZoneInfo(zone)
    row = _row(f"LMS Due on Monday, 1 January {year}, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi")

    [seen] = extract([row], tz)

    assert (seen.kind, seen.title, seen.due_at) == ("due", "Lab 6 Submission", None)
    tracker = Tracker(tmp_path / "deadlines.db", tz, clock=lambda: datetime(2026, 10, 7, tzinfo=tz))
    assert tracker.record_rows([row]) == (1, 1)


def test_a_date_inside_a_plausible_span_is_kept() -> None:
    seen = _one("LMS Due on Friday, 31 December 2100, 11:59 PM: Thesis Wed 10:45 AM Hi")

    assert seen.due_at == datetime(2100, 12, 31, 23, 59, tzinfo=DUBAI)


def test_the_same_notice_twice_is_one_item() -> None:
    row = "LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi"

    assert len(extract([_row(row, 1), _row(row, 2)], DUBAI)) == 1


def test_a_due_notice_and_a_receipt_for_the_same_assignment_are_both_reported() -> None:
    rows = [
        _row("LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi", 1),
        _row("LMS You have submitted your assignment submission for Lab 6 Submission 8:48 AM x", 2),
    ]

    assert sorted(s.kind for s in extract(rows, DUBAI)) == ["due", "submitted"]


def test_a_very_long_title_is_capped_and_control_characters_are_dropped() -> None:
    long = "A" * 400
    seen = _one(
        f"LMS Due on Friday, 9 October 2026, 10:15 AM: Bad\x1b[2J\x07 {long} Wed 10:45 AM Hi"
    )

    assert len(seen.title) <= MAX_TITLE
    assert "\x1b" not in seen.title and "\x07" not in seen.title


def test_a_title_that_is_only_control_characters_is_not_an_item() -> None:
    assert (
        extract(
            [_row("LMS Due on Friday, 9 October 2026, 10:15 AM: \x1b\x07 Wed 10:45 AM Hi")], DUBAI
        )
        == []
    )


def test_extraction_reads_only_the_row_text_it_is_given() -> None:
    """No clock and no network: the same rows always give the same items."""
    rows = [_row("LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Hi")]

    assert extract(rows, DUBAI) == extract(rows, DUBAI)
