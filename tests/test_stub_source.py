"""The Phase 1 source: the hand-written deadline file.

This is the only thing producing deadlines today - there is no Moodle reader
yet - so `config/stub_deadlines.toml` *is* the user's data, and its header tells
them to "replace these with your real upcoming work". Everything here is about
what happens when they do.

The file is hand-edited TOML, so the failures are hand-made too: a forgotten
offset, a missing key, a date typed as prose. The rule the reader follows for
channels applies here for the same reason - **one bad entry must not cost the
others**. Before this, a single entry with no timezone aborted the whole parse,
so a file with nine good deadlines and one naive date ingested nothing at all,
and the plan that resulted looked like a week with no work in it.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from pli.sources.base import iter_all
from pli.sources.stub import DEFAULT_PATH, StubSource


def _write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "stub_deadlines.toml"
    path.write_text(text)
    return path


def _entry(**fields: str) -> str:
    return "[[deadline]]\n" + "".join(f'{k} = "{v}"\n' for k, v in fields.items()) + "\n"


GOOD = _entry(course="CS301 Algorithms", title="Problem Set 4", due="2026-10-08T17:00:00+00:00")


# --- the file that ships -----------------------------------------------------------


def test_the_shipped_file_ingests_without_a_single_error():
    """If this fails the tool has no data at all on a fresh checkout - every
    other test in the suite is built on this file parsing."""
    result = StubSource(DEFAULT_PATH).ingest()

    assert result.errors == []
    assert result.deadlines
    assert result.courses


def test_every_shipped_deadline_is_timezone_aware():
    """The planner places blocks on a UTC timeline; a naive `due` is read as the
    machine's zone and silently lands at the wrong hour."""
    for deadline in StubSource(DEFAULT_PATH).ingest().deadlines:
        assert deadline.due_at.tzinfo is not None


# --- a good file -------------------------------------------------------------------


def test_an_entry_becomes_a_deadline_and_its_course(tmp_path):
    result = StubSource(_write(tmp_path, GOOD)).ingest()

    assert result.errors == []
    [(deadline,)] = [result.deadlines]
    assert deadline.title == "Problem Set 4"
    assert deadline.course_name == "CS301 Algorithms"
    assert deadline.course_external_id == "CS301"
    assert deadline.due_at == datetime(2026, 10, 8, 17, 0, tzinfo=UTC)

    [(course,)] = [result.courses]
    assert course.external_id == "CS301"
    assert course.short_name == "CS301"


def test_two_deadlines_in_one_course_share_one_course_row(tmp_path):
    """The course code is derived from the first word of the course name, and a
    duplicate here means a phantom second course in every listing."""
    path = _write(
        tmp_path,
        _entry(course="CS301 Algorithms", title="A", due="2026-10-08T17:00:00+00:00")
        + _entry(course="CS301 Algorithms", title="B", due="2026-10-09T17:00:00+00:00"),
    )

    result = StubSource(path).ingest()

    assert len(result.deadlines) == 2
    assert len(result.courses) == 1


def test_two_courses_are_two_rows(tmp_path):
    path = _write(
        tmp_path,
        _entry(course="CS301 Algorithms", title="A", due="2026-10-08T17:00:00+00:00")
        + _entry(course="GEN101 Academic Writing", title="B", due="2026-10-09T17:00:00+00:00"),
    )

    result = StubSource(path).ingest()

    assert {c.external_id for c in result.courses} == {"CS301", "GEN101"}


def test_the_external_id_is_the_same_on_every_read(tmp_path):
    """It is the key `upsert_deadline` reconciles on. An id that changed between
    two syncs would insert a second row for the same piece of work every time,
    and the planner would schedule it once per sync."""
    path = _write(tmp_path, GOOD)

    first = StubSource(path).ingest().deadlines
    second = StubSource(path).ingest().deadlines

    assert [d.external_id for d in first] == [d.external_id for d in second]


def test_a_native_toml_datetime_is_accepted_too(tmp_path):
    """TOML has its own datetime type, so `due` reaches this code as a `datetime`
    rather than a `str` for an unquoted value. Both spellings are in the wild."""
    path = _write(
        tmp_path,
        '[[deadline]]\ncourse = "CS301 Algorithms"\ntitle = "PS4"\ndue = 2026-10-08T17:00:00Z\n',
    )

    result = StubSource(path).ingest()

    assert result.errors == []
    assert result.deadlines[0].due_at == datetime(2026, 10, 8, 17, 0, tzinfo=UTC)


def test_kind_and_url_carry_through(tmp_path):
    path = _write(
        tmp_path,
        _entry(
            course="CS301 Algorithms",
            title="Midterm",
            due="2026-10-08T09:00:00+00:00",
            kind="exam",
            url="https://moodle.example/mod/assign?id=1",
        ),
    )

    deadline = StubSource(path).ingest().deadlines[0]

    assert deadline.kind == "exam"
    assert deadline.url == "https://moodle.example/mod/assign?id=1"


def test_kind_defaults_to_assignment(tmp_path):
    assert StubSource(_write(tmp_path, GOOD)).ingest().deadlines[0].kind == "assignment"


def test_a_comment_and_an_unknown_key_are_both_ignored(tmp_path):
    """`estimated_hours` is in the shipped file and is not a `Deadline` field -
    the file's header says so. It must not become an error."""
    path = _write(
        tmp_path,
        '# a note\n[[deadline]]\ncourse = "CS301 Algorithms"\ntitle = "PS4"\n'
        'due = "2026-10-08T17:00:00+00:00"\nestimated_hours = 5.0\n',
    )

    result = StubSource(path).ingest()

    assert result.errors == []
    assert len(result.deadlines) == 1


# --- one bad entry must not cost the others -----------------------------------------


def test_a_missing_offset_is_reported_without_losing_the_other_entries(tmp_path):
    """The regression. The file's own header asks for an offset, and before this
    a single entry without one took the entire file down with it."""
    path = _write(
        tmp_path,
        GOOD + _entry(course="CS301 Algorithms", title="Naive", due="2026-10-09T17:00:00"),
    )

    result = StubSource(path).ingest()

    assert len(result.deadlines) == 1, "the good entry was thrown away with the bad one"
    assert result.deadlines[0].title == "Problem Set 4"
    [error] = result.errors
    assert "Naive" in error, "the error has to name the entry"
    # Not `"offset" in error`. pytest names `tmp_path` after the test, so every
    # message from this file already contains `.../test_a_missing_offset_is_.../
    # stub_deadlines.toml` - the word was coming from the test's own name and the
    # assertion could not fail whatever the reader said. Pinning the sentence the
    # reader writes, and that the sentence is the reader's, is what makes this a
    # test of the reader rather than of its own filename.
    assert "add an offset" in error
    assert "validation error" not in error, "the reader's sentence, not pydantic's"
    # `startswith`: the message has to begin by naming the source, the way every
    # other error from this module does, so `pli sync` can be read as a list.
    assert error.startswith("stub:")


def test_a_missing_title_is_a_sentence_and_not_a_keyerror(tmp_path):
    """It used to surface as a bare `KeyError: 'title'` from inside the loop."""
    path = _write(tmp_path, _entry(course="CS301 Algorithms", due="2026-10-08T17:00:00+00:00"))

    result = StubSource(path).ingest()

    assert result.deadlines == []
    [error] = result.errors
    assert "no `title`" in error, "the reader's own sentence, named for the key"
    assert "KeyError" not in error


def test_a_due_that_is_not_a_date_is_reported(tmp_path):
    path = _write(tmp_path, _entry(course="CS301", title="X", due="next Friday"))

    result = StubSource(path).ingest()

    assert result.deadlines == []
    [error] = result.errors
    assert "next Friday" in error
    assert "X" in error


def test_an_entry_with_no_due_is_reported(tmp_path):
    result = StubSource(_write(tmp_path, _entry(course="CS301", title="X"))).ingest()

    assert result.deadlines == []
    assert "no `due`" in result.errors[0]


def test_a_bad_entry_does_not_invent_a_course(tmp_path):
    """The course row was registered before the entry was validated, so a deadline
    that never parsed still put its course in the list - a subject with no work
    underneath it, which is exactly what a phantom course looks like."""
    path = _write(tmp_path, _entry(course="Ghost Subject", title="X", due="not a date"))

    result = StubSource(path).ingest()

    assert result.courses == []
    assert result.deadlines == []


def test_a_whole_file_of_bad_entries_reports_every_one(tmp_path):
    """One error per entry, not one for the file: the user fixes them in one pass
    instead of re-running and discovering the next one each time."""
    path = _write(
        tmp_path,
        _entry(course="A", title="one", due="nope")
        + _entry(course="B", title="two", due="also nope")
        + _entry(course="C", title="three", due="nope again"),
    )

    result = StubSource(path).ingest()

    assert len(result.errors) == 3
    # Each error names its own entry, so the user can find all three at once
    # rather than fixing one, re-running, and being told about the next.
    assert [
        name in error for name, error in zip(("one", "two", "three"), result.errors, strict=True)
    ] == [True] * 3


# --- files that are wrong in whole --------------------------------------------------


def test_a_missing_file_is_one_error_and_not_a_crash(tmp_path):
    """A fresh checkout with no deadline file yet."""
    result = StubSource(tmp_path / "absent.toml").ingest()

    assert result.deadlines == []
    assert len(result.errors) == 1
    assert "absent.toml" in result.errors[0]


def test_a_file_that_is_not_toml_is_one_sentence(tmp_path):
    """The user is editing this file by hand; a missing quote is the likeliest
    mistake in it, and a `TOMLDecodeError` traceback says nothing about which."""
    path = _write(tmp_path, '[[deadline]]\ncourse = "CS301\ntitle = "PS4"\n')

    result = StubSource(path).ingest()

    assert result.deadlines == []
    assert len(result.errors) == 1
    assert "not valid TOML" in result.errors[0]


def test_an_empty_file_is_an_empty_result_and_not_an_error(tmp_path):
    """Deleting the placeholder entries is the documented first step."""
    result = StubSource(_write(tmp_path, "# nothing yet\n")).ingest()

    assert result.errors == []
    assert result.deadlines == []
    assert result.courses == []


# --- through the layer that runs it --------------------------------------------------


def test_a_broken_file_does_not_stop_the_sync(tmp_path):
    """`iter_all` is the boundary a source failure must not escape: the Teams
    half and everything already stored stay usable."""
    path = _write(tmp_path, '[[deadline]]\ncourse = "CS301\ntitle = "PS4"\n')

    result = iter_all([StubSource(path)], store=None)

    assert result.errors
    # `startswith`, not `in`: the path in the message is `stub_deadlines.toml`,
    # so `"stub" in error` would hold even if the source never named itself.
    assert result.errors[0].startswith("stub:")


def test_the_horizon_of_a_shipped_file_is_in_the_future():
    """A placeholder file whose dates have all passed still parses and still
    produces tasks - it just quietly plans nothing. Worth noticing at a glance."""
    now = datetime.now(UTC)
    deadline = max(d.due_at for d in StubSource(DEFAULT_PATH).ingest().deadlines)

    assert deadline > now - timedelta(days=365), (
        "every deadline in config/stub_deadlines.toml is over a year old - "
        "replace the placeholders with your real work"
    )


@pytest.mark.parametrize("blank", ["", "   "])
def test_a_blank_title_is_still_a_title_and_not_an_error(tmp_path, blank):
    """`title` present but empty is the user's own doing and is carried through;
    only a *missing* key is the mistake this module reports. Pinned because the
    two are one `if` apart."""
    path = _write(
        tmp_path,
        f'[[deadline]]\ncourse = "CS301 Algorithms"\ntitle = "{blank}"\n'
        'due = "2026-10-08T17:00:00+00:00"\n',
    )

    result = StubSource(path).ingest()

    assert result.errors == []
    assert result.deadlines[0].title == blank
