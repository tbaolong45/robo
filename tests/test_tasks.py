"""Deadline -> Task: deduplication, key stability, duration seeding."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from pli.config import StudyConfig
from pli.models import Deadline, Material
from pli.planner.tasks import FUZZY_MIN_CHARS, build_tasks

NOW = datetime(2026, 9, 28, 9, 0, tzinfo=UTC)
CFG = StudyConfig()


def _deadline(
    *,
    external_id: str,
    title: str,
    days: float = 3,
    source: str = "stub",
    course: str = "CS301",
    course_name: str = "CS301 Algorithms",
    url: str | None = None,
) -> Deadline:
    return Deadline(
        source=source,
        external_id=external_id,
        course_external_id=course,
        course_name=course_name,
        title=title,
        due_at=NOW + timedelta(days=days),
        url=url,
    )


def _material(course: str, hours: float, external_id: str = "m") -> Material:
    return Material(
        source="stub",
        external_id=external_id,
        course_external_id=course,
        name="notes.pdf",
        rel_path=f"{course}/notes.pdf",
        estimated_hours=hours,
    )


def _build(deadlines, materials=()):
    return build_tasks(list(deadlines), list(materials), now=NOW, study_config=CFG)


# --- filtering -----------------------------------------------------------------


def test_past_deadlines_are_dropped():
    tasks = _build([_deadline(external_id="old", title="Overdue", days=-1)])
    assert tasks == []


def test_a_deadline_due_exactly_now_is_dropped():
    assert _build([_deadline(external_id="now", title="Due now", days=0)]) == []


def test_upcoming_deadlines_become_tasks():
    tasks = _build([_deadline(external_id="a", title="Problem Set 1")])
    assert len(tasks) == 1
    assert tasks[0].title == "Problem Set 1"
    assert tasks[0].course == "CS301 Algorithms"


def test_tasks_are_ordered_by_due_date():
    tasks = _build(
        [
            _deadline(external_id="c", title="Third", days=9),
            _deadline(external_id="a", title="First", days=1),
            _deadline(external_id="b", title="Second", days=4),
        ]
    )
    assert [t.title for t in tasks] == ["First", "Second", "Third"]


# --- deduplication -------------------------------------------------------------


def test_same_work_from_two_sources_collapses_to_one_task():
    """Moodle and Teams both announce the same assignment - student sees one."""
    tasks = _build(
        [
            _deadline(
                external_id="m1",
                title="Problem Set 1",
                source="moodle",
                url="https://moodle.test/1",
            ),
            _deadline(
                external_id="t1", title="Problem Set 1", source="teams", url="https://teams.test/1"
            ),
        ]
    )
    assert len(tasks) == 1
    assert set(tasks[0].urls) == {"https://moodle.test/1", "https://teams.test/1"}


def test_dedup_keeps_the_earliest_due_time_on_the_same_day():
    """An earlier announcement must never be silently relaxed by a later one.

    Two sources rarely quote the same clock time for one assignment (23:59 vs
    17:00), so within a matching day the earliest wins.
    """
    tasks = _build(
        [
            _deadline(external_id="early", title="Problem Set 1", source="moodle").model_copy(
                update={"due_at": NOW.replace(hour=14)}
            ),
            _deadline(external_id="late", title="Problem Set 1", source="teams").model_copy(
                update={"due_at": NOW.replace(hour=23, minute=59)}
            ),
        ]
    )
    assert len(tasks) == 1
    assert tasks[0].due_at == NOW.replace(hour=14)


def test_dedup_requires_the_same_day():
    """Sources quoting different dates are kept apart.

    Merging across days would mean guessing which source is right, and guessing
    wrong silently deletes a real deadline. Showing one task too many is the
    safe failure; showing one too few is not.
    """
    tasks = _build(
        [
            _deadline(external_id="early", title="Problem Set 1", days=2, source="moodle"),
            _deadline(external_id="late", title="Problem Set 1", days=6, source="teams"),
        ]
    )
    assert len(tasks) == 2


def test_same_title_in_different_courses_stays_separate():
    """Two courses can set identically-titled work on the same day."""
    tasks = _build(
        [
            _deadline(external_id="a", title="Essay draft", course="CS301", course_name="CS301"),
            _deadline(external_id="b", title="Essay draft", course="PHY101", course_name="PHY101"),
        ]
    )
    assert len(tasks) == 2


def test_same_title_on_different_days_stays_separate():
    tasks = _build(
        [
            _deadline(external_id="a", title="Weekly quiz", days=2),
            _deadline(external_id="b", title="Weekly quiz", days=9),
        ]
    )
    assert len(tasks) == 2


def test_course_labels_match_across_formatting():
    """The same course is labelled differently by different systems."""
    tasks = _build(
        [
            _deadline(
                external_id="a",
                title="Problem Set 1",
                source="moodle",
                course_name="CS301 Algorithms",
            ),
            _deadline(
                external_id="b",
                title="Problem Set 1",
                source="teams",
                course_name="Algorithms (CS301)",
            ),
        ]
    )
    assert len(tasks) == 1


def test_a_deadline_with_no_course_label_matches_any_course():
    """An unlabelled source cannot name its course, so it cannot contradict one.

    A Teams post often carries no course code at all. Comparing "" against
    "CS301 Algorithms" as course identities would keep every unlabelled deadline
    as a second task for work the other source already announced - and the
    student schedules the same assignment twice.
    """
    tasks = _build(
        [
            _deadline(
                external_id="a",
                title="Problem Set 1",
                source="moodle",
                course_name="CS301 Algorithms",
            ),
            _deadline(
                external_id="b", title="Problem Set 1", source="teams", course="", course_name=""
            ),
        ]
    )
    assert len(tasks) == 1


def test_near_identical_long_titles_collapse():
    tasks = _build(
        [
            _deadline(external_id="a", title="Problem Set 4: Dynamic Programming"),
            _deadline(external_id="b", title="Problem Set 4  Dynamic Programme"),
        ]
    )
    assert len(tasks) == 1


def test_short_titles_are_never_fuzzy_merged():
    """`SequenceMatcher("quiz 3", "quiz 4")` scores 0.83 - well past the
    threshold - so without a length floor these two distinct quizzes would
    silently become one task and one of them would never be scheduled."""
    tasks = _build(
        [
            _deadline(external_id="a", title="Quiz 3"),
            _deadline(external_id="b", title="Quiz 4"),
        ]
    )
    assert len(tasks) == 2
    assert {t.title for t in tasks} == {"Quiz 3", "Quiz 4"}


def test_a_title_at_the_fuzzy_floor_is_still_compared_fuzzily():
    """`FUZZY_MIN_CHARS` is a floor, not a strict inequality.

    Both titles here are exactly 12 characters - the first length at which the
    ratio carries signal - and differ by one letter. Read as an exclusive floor
    they would stop being compared and the same assignment announced twice would
    stay as two tasks, doubling the work on the calendar.
    """
    assert len("reading week") == FUZZY_MIN_CHARS
    tasks = _build(
        [
            _deadline(external_id="a", title="reading week"),
            _deadline(external_id="b", title="reading weeb"),
        ]
    )
    assert len(tasks) == 1


def test_similarly_named_long_titles_stay_separate():
    tasks = _build(
        [
            _deadline(external_id="a", title="Lab report on pendulum motion"),
            _deadline(external_id="b", title="Essay on epistemology and knowledge"),
        ]
    )
    assert len(tasks) == 2


def test_dedup_keeps_the_longest_title():
    """A terse announcement and a descriptive one: show the descriptive one."""
    tasks = _build(
        [
            _deadline(external_id="a", title="Problem Set 1: Greedy"),
            _deadline(external_id="b", title="Problem Set 1 - greedy algorithms"),
        ]
    )
    assert len(tasks) == 1
    assert tasks[0].title == "Problem Set 1 - greedy algorithms"


def test_an_abbreviated_title_is_not_merged_with_its_expansion():
    """A known and accepted cost of the length floor.

    "PS1" and "Problem Set 1: Greedy" are the same work, but no length floor can
    tell that apart from "Quiz 3" vs "Quiz 4". The suite keeps the pair as two
    tasks on purpose: a duplicate block on the calendar is a nuisance, a
    suppressed deadline a student never sees is a disaster.
    """
    tasks = _build(
        [
            _deadline(external_id="a", title="PS1"),
            _deadline(external_id="b", title="Problem Set 1: Greedy"),
        ]
    )
    assert len(tasks) == 2


# --- task keys -----------------------------------------------------------------


def test_keys_are_stable_across_runs():
    deadlines = [_deadline(external_id="a", title="Problem Set 1")]
    assert [t.key for t in _build(deadlines)] == [t.key for t in _build(deadlines)]


def test_keys_do_not_depend_on_input_order():
    a = _deadline(external_id="a", title="Alpha work", days=2)
    b = _deadline(external_id="b", title="Beta work", days=5)
    assert {t.key for t in _build([a, b])} == {t.key for t in _build([b, a])}


def test_keys_are_distinct_per_task():
    tasks = _build(
        [
            _deadline(external_id="a", title="Alpha work", days=2),
            _deadline(external_id="b", title="Beta work", days=3),
        ]
    )
    assert len({t.key for t in tasks}) == 2


def test_key_is_16_hex_characters():
    (task,) = _build([_deadline(external_id="a", title="Problem Set 1")])
    assert len(task.key) == 16
    int(task.key, 16)  # raises if not hex


def test_key_is_independent_of_materials():
    deadlines = [_deadline(external_id="a", title="Problem Set 1")]
    plain = _build(deadlines)
    enriched = _build(deadlines, [_material("CS301", 4.0)])
    assert plain[0].key == enriched[0].key


def test_a_corrected_clock_time_keeps_the_task_key():
    """The key names the work by course, title and *day* - not by the clock.

    A source correcting a due time from 14:00 to 17:00 on the same day is the
    same piece of work, and the calendar writer matches a replan by this key.
    A key that moved with the clock would create a second event for the task and
    orphan the first, which is exactly the duplication the key exists to stop.
    """
    morning = _deadline(external_id="a", title="Problem Set 1").model_copy(
        update={"due_at": NOW.replace(hour=14)}
    )
    evening = _deadline(external_id="a", title="Problem Set 1").model_copy(
        update={"due_at": NOW.replace(hour=17)}
    )

    assert _build([morning])[0].key == _build([evening])[0].key


# --- duration seeding ----------------------------------------------------------


def test_estimate_falls_back_to_the_session_ceiling():
    (task,) = _build([_deadline(external_id="a", title="Problem Set 1")])
    assert task.estimated_minutes == CFG.study.session_max_minutes


def test_material_estimate_seeds_the_task_duration():
    """Phase 4's `estimated_hours` is what makes durations realistic."""
    (task,) = _build([_deadline(external_id="a", title="Problem Set 1")], [_material("CS301", 4.0)])
    assert task.estimated_minutes == 240


def test_largest_material_estimate_wins():
    (task,) = _build(
        [_deadline(external_id="a", title="Problem Set 1")],
        [_material("CS301", 1.5, "m1"), _material("CS301", 6.0, "m2")],
    )
    assert task.estimated_minutes == 360


def test_a_merged_pair_does_not_double_count_its_materials():
    """One course read through two sources still has one estimate.

    The two deadlines merge (same day, same title, same course label) but they
    carry different `course_external_id`s - Moodle's code against a Teams team
    id - so the group resolves to two material estimates for one piece of work.
    The largest is the seed; adding them books both sources' hours as though two
    assignments were set.
    """
    tasks = _build(
        [
            _deadline(external_id="a", title="Problem Set 1", source="moodle", course="CS301"),
            _deadline(external_id="b", title="Problem Set 1", source="teams", course="teams-77"),
        ],
        [_material("CS301", 2.0, "m1"), _material("teams-77", 3.0, "m2")],
    )

    assert len(tasks) == 1
    assert tasks[0].estimated_minutes == 180


def test_material_estimate_only_applies_to_its_own_course():
    (task,) = _build(
        [_deadline(external_id="a", title="Problem Set 1")], [_material("PHY101", 9.0)]
    )
    assert task.estimated_minutes == CFG.study.session_max_minutes


@pytest.mark.parametrize("hours", [0.0, 0.25])
def test_tiny_material_estimate_still_yields_a_positive_duration(hours):
    (task,) = _build(
        [_deadline(external_id="a", title="Problem Set 1")], [_material("CS301", hours)]
    )
    assert task.estimated_minutes >= 1


def test_deadline_with_no_course_name_falls_back_to_the_id():
    (task,) = _build(
        [_deadline(external_id="a", title="Problem Set 1", course="CS999", course_name="")]
    )
    assert task.course == "CS999"


def test_blank_title_becomes_untitled():
    (task,) = _build([_deadline(external_id="a", title="   ")])
    assert task.title == "(untitled)"
