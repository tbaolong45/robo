"""Renderers.

These take whatever the producers actually return, so the tests feed them the
real types rather than convenient ones. `render_slots` shipped broken because
it was written against a type `free_slots` never returns and nothing checked.
"""

from __future__ import annotations

import io
import re
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from rich.console import Console

from pli import report as report_module
from pli.models import Block, Slot, Task
from pli.planner.pack import PackResult
from pli.report import render_plan, render_slots, render_tasks, to_markdown

TZ = ZoneInfo("Asia/Dubai")
START = datetime(2026, 10, 5, 6, 0, tzinfo=UTC)


@pytest.fixture(autouse=True)
def console(monkeypatch):
    """Pin the output console, and hand it back so a test can read what printed.

    `report.console` is a bare `Console()`, so its width is whatever terminal
    pytest happens to run under. At 80 columns a long course name pushes the
    Task column into wrapping, and a wrapped title looks exactly like a value
    Rich deleted - the failure these tests exist to catch. Fixing the width
    removes the ambiguity; `no_color` and `highlight=False` mean the buffer is
    plain text and an assertion cannot pass or fail on styling.
    """
    pinned = Console(file=io.StringIO(), width=200, soft_wrap=True, no_color=True, highlight=False)
    monkeypatch.setattr(report_module, "console", pinned)
    return pinned


def _slot(minutes: int = 60) -> Slot:
    return Slot(start=START, end=START + timedelta(minutes=minutes))


def _block(key: str = "b1", minutes: int = 60, task_key: str = "t1") -> Block:
    return Block(
        block_key=key,
        task_key=task_key,
        subject="Study · CS301 Algorithms — Problem Set 4",
        start=START,
        end=START + timedelta(minutes=minutes),
        body="line one\nline two",
    )


def _task(key: str = "t1", minutes: int = 120) -> Task:
    return Task(
        key=key,
        title="Problem Set 4",
        course="CS301 Algorithms",
        due_at=START + timedelta(days=3),
        estimated_minutes=minutes,
        priority=0.8,
    )


# --- free windows (the regression) ---------------------------------------------


def test_render_slots_accepts_slots():
    """`free_slots` returns `Slot`s - the exact type that used to crash.

    A pydantic model iterates as (field, value) pairs, so an `else item`
    fallback unpacked ("start", datetime) and blew up on `.astimezone`.
    """
    render_slots([_slot(90), _slot(45)], tz=TZ)


def test_render_slots_accepts_blocks():
    render_slots([_block(minutes=90)], tz=TZ)


def test_render_slots_accepts_plain_tuples():
    render_slots([(START, START + timedelta(minutes=30))], tz=TZ)


def test_render_slots_accepts_a_mix():
    render_slots([_slot(), _block(), (START, START + timedelta(minutes=30))], tz=TZ)


def test_render_slots_handles_an_empty_list():
    render_slots([], tz=TZ)


# --- the week --------------------------------------------------------------------


def test_render_plan_accepts_a_real_pack_result():
    result = PackResult(blocks=[_block("a"), _block("b", task_key="t2")], unscheduled=[])
    render_plan(result, tz=TZ, title="Study week")


def test_render_plan_reports_unscheduled_work_without_crashing():
    """The shortfall path is only reachable when the week is genuinely full."""
    result = PackResult(blocks=[_block()], unscheduled=[(_task(), 45)])
    render_plan(result, tz=TZ)


def test_a_scheduled_block_keeps_its_course_in_the_week_table(console):
    """`Block.subject` is the course and title joined, shown in a table cell."""
    subject = "Study · [revision] Probability — Problem Set 4"
    block = _block().model_copy(update={"subject": subject})
    render_plan(PackResult(blocks=[block], unscheduled=[]), tz=TZ)

    out = _plain(console.file.getvalue())
    assert "[revision] Probability" in out
    assert "Problem Set 4" in out


def test_a_course_named_with_brackets_survives_into_the_shortfall_list(console):
    """The one list the user most needs to read must not lose text to Rich.

    This line is an f-string, so Rich parses it for markup, and a bracketed run
    that looks like a style tag is deleted rather than printed. The rule is
    narrower than it first appears and the inputs here are chosen to hit it:
    Rich's tag pattern starts at a **lowercase** letter, so "[STATS101]" is left
    alone while "[revision]" - and the tool's own "[pli:<key>]" marker - is
    eaten. A test written with the uppercase form passes with the escape removed
    and guards nothing, which is exactly what this one used to do.

    Lowercase bracket runs are not contrived: Moodle task titles carry them
    ("[resit]", "[group work]"), and they are the case the escape exists for.
    """
    task = Task(
        key="t1",
        title="[resit] Tutorial sheet 3",
        course="[revision] Probability",
        due_at=START + timedelta(days=1),
        estimated_minutes=120,
        priority=0.9,
    )
    render_plan(PackResult(blocks=[], unscheduled=[(task, 45)]), tz=TZ)

    # Styles are stripped before matching: Rich *highlights* an escaped bracket
    # run rather than deleting it, and the colour codes fall between the
    # characters. Deleting is the failure being guarded against, not colouring.
    out = _plain(console.file.getvalue())
    assert "[revision] Probability" in out
    assert "[resit] Tutorial sheet 3" in out
    assert "45m short" in out


#: Everything from an ESC up to the `m` that ends an SGR sequence.
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def _plain(text: str) -> str:
    return _ANSI.sub("", text)


def test_render_plan_handles_an_empty_week():
    render_plan(PackResult(), tz=TZ)


def test_render_tasks_accepts_tasks():
    render_tasks([_task("t1"), _task("t2", minutes=60)], tz=TZ)


def test_a_task_table_cell_does_not_eat_a_bracketed_course(console):
    """A Rich table cell parses markup exactly as an f-string does.

    This was assumed safe on the grounds that "Table cells do not parse markup".
    They do. The course below printed as a bare " Probability" until it was
    escaped, and the eye reads the empty column as a task with no course.
    """
    task = Task(
        key="t1",
        title="[resit] Tutorial sheet 3",
        course="[revision] Probability",
        due_at=START + timedelta(days=1),
        estimated_minutes=120,
        priority=0.9,
    )
    render_tasks([task], tz=TZ)

    out = _plain(console.file.getvalue())
    assert "[revision] Probability" in out
    assert "[resit] Tutorial sheet 3" in out


def test_render_tasks_handles_an_empty_list():
    render_tasks([], tz=TZ)


# --- markdown ----------------------------------------------------------------------


def test_markdown_contains_every_block():
    result = PackResult(blocks=[_block("a"), _block("b", task_key="t2")])
    text = to_markdown(result, tz=TZ, title="My week")

    assert text.startswith("# My week")
    assert text.count("| 10:00-11:00 |") == 2
    assert "CS301 Algorithms" in text


def test_markdown_reports_the_shortfall():
    result = PackResult(blocks=[], unscheduled=[(_task(), 90)])
    text = to_markdown(result, tz=TZ)

    assert "## Could not fit" in text
    assert "90 min short" in text


def test_markdown_of_an_empty_week_is_still_valid():
    text = to_markdown(PackResult(), tz=TZ)
    assert "# Study week" in text
    assert "0 blocks" in text


@pytest.mark.parametrize("title", ["Study week", "Week of 5 October", "Ünïcôdé week"])
def test_markdown_handles_any_title(title):
    assert title in to_markdown(PackResult(), tz=TZ, title=title)
