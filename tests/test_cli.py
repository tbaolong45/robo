"""The command line surface: what the user actually sees when something fails.

Two things are pinned here, and they are the two things that broke.

**Brackets survive.** Every diagnostic this tool prints names a selector
(`[data-automationid='CalendarGrid']`) or the marker it writes into event bodies
(`[pli:<key>]`). Rich reads `[...]` as a style tag and silently deletes anything
it does not recognise, so an unescaped diagnostic told the user "the week grid
never appeared at , ." - the one sentence whose whole purpose is to name what was
looked for. These tests are the guard against that returning.

**A failure is a sentence, not a traceback.** `pli plan` with no API key and
`pli plan` against a signed-out profile are the two ways a real user hits this
tool for the first time, and both must exit 1 with instructions.
"""

from __future__ import annotations

import io
import logging
import re
from datetime import UTC, datetime
from pathlib import Path

import pytest
import typer
from rich.console import Console
from typer.testing import CliRunner

from pli import cli
from pli.browser import BrowserError, SessionError
from pli.config import ConfigError, Settings
from pli.db import Store
from pli.models import Block, ChannelMessage, Deadline, RemoteEvent, Task
from pli.planner.pack import PackResult


@pytest.fixture
def captured(monkeypatch):
    """Point every `console.print` in `cli` at a buffer that never wraps.

    `soft_wrap` matters: without it Rich folds a long message at the terminal
    width, and an assertion on a substring would fail for a reason that has
    nothing to do with markup.
    """
    console = Console(file=io.StringIO(), width=400, soft_wrap=True, no_color=True, highlight=False)
    monkeypatch.setattr(cli, "console", console)
    return console


@pytest.fixture
def settings(tmp_path):
    return Settings(
        pli_home=tmp_path / "data",
        browser_profile=tmp_path / "browser",
        typesafe_api_key="",
    )


def _output(console: Console) -> str:
    return console.file.getvalue()


# --- brackets reach the user ----------------------------------------------------


def test_a_failure_message_keeps_its_brackets(captured):
    """The regression. This exact sentence was printed as "at , ."."""
    message = "The week grid never appeared at [data-automationid='CalendarGrid'], [role='grid']."
    with pytest.raises(typer.Exit) as exit_info:
        cli._fail(message)

    assert exit_info.value.exit_code == 1
    assert "[data-automationid='CalendarGrid'], [role='grid']" in _output(captured)


def test_a_failure_hint_keeps_its_brackets(captured):
    with pytest.raises(typer.Exit):
        cli._fail("broken", "Only events whose body contains '[pli:<key>]' are ever touched.")

    assert "[pli:<key>]" in _output(captured)


def test_a_reader_warning_keeps_its_brackets(captured):
    """A reader logs a selector it could not find; that log line goes to the same
    console, so it needs the same treatment as `_fail`."""
    logger = logging.getLogger("pli.test.brackets")
    logger.addHandler(cli._ConsoleLogHandler())
    logger.setLevel(logging.WARNING)
    try:
        logger.warning("no node matched [data-tid='channel-list']")
    finally:
        logger.handlers.clear()

    assert "[data-tid='channel-list']" in _output(captured)


def test_the_cli_own_markup_still_renders(captured):
    """Escaping must be applied to the interpolated value, not the whole line -
    otherwise the colour tags the CLI writes on purpose would be escaped too and
    the user would see `[yellow]warning:[/yellow]` as literal text."""
    logger = logging.getLogger("pli.test.markup")
    logger.addHandler(cli._ConsoleLogHandler())
    logger.setLevel(logging.WARNING)
    try:
        logger.warning("[dim]a selector[/dim]")
    finally:
        logger.handlers.clear()

    out = _output(captured)
    assert "warning:" in out
    assert "[yellow]" not in out
    assert "[dim]a selector[/dim]" in out


# --- the two first-run failures -------------------------------------------------


def test_a_restyled_page_points_at_the_selector_and_the_diagnostics(captured, settings):
    """`BrowserError` is "the page changed". The fix is config, and the captured
    page is what makes that fix possible, so both must be named."""
    with pytest.raises(typer.Exit) as exit_info:
        cli._browser_fail("read your calendar", BrowserError("no grid"), settings)

    out = _output(captured)
    assert exit_info.value.exit_code == 1
    assert "Could not read your calendar: no grid" in out
    assert "config/browser.toml" in out
    assert "diagnostics" in out


def test_a_signed_out_profile_points_at_the_headed_run(captured, settings):
    """An expired session and a restyled page have different fixes, and confusing
    them sends the user hunting for a selector bug when the real answer is that the
    session expired. There is no sign-in command, so the advice has to be the
    headed run."""
    with pytest.raises(typer.Exit):
        cli._browser_fail("read your calendar", SessionError("redirected to login"), settings)

    out = _output(captured)
    assert "BROWSER_HEADLESS=false" in out
    assert "config/browser.toml" not in out


# --- commands, end to end -------------------------------------------------------


def _run(monkeypatch, settings: Settings, *args: str):
    monkeypatch.setattr(cli, "get_settings", lambda: settings)
    return CliRunner().invoke(cli.app, list(args))


def test_clear_state_drops_only_that_source(monkeypatch, settings, captured):
    """The re-read a user does after fixing a selector. It has to actually clear
    the cursor, or the next sync resumes past the messages they are trying to
    re-read."""
    with Store(settings.db_path) as store:
        store.set_state("teams", "messages:since", "2026-09-01T00:00:00+00:00")
        store.set_state("moodle", "materials", "keep me")

    result = _run(monkeypatch, settings, "clear-state", "--source", "teams")

    assert result.exit_code == 0
    with Store(settings.db_path) as store:
        assert store.get_state("teams", "messages:since") is None
        assert store.get_state("moodle", "materials") == "keep me"


def test_status_reports_a_missing_key_without_crashing(monkeypatch, settings, captured):
    """`pli status` is the first command anyone runs and it must never raise -
    not when the key is absent, and not when there is no database yet."""
    result = _run(monkeypatch, settings, "status")

    assert result.exit_code == 0
    out = _output(captured)
    assert "TYPESAFE_API_KEY" in out
    assert "no database yet" in out


def test_status_escapes_a_configured_url(monkeypatch, settings, captured):
    """The Moodle base URL is typed by the user into .env. A bracket in it must not
    be eaten, and must not be able to inject markup into the status output."""
    settings.moodle_base_url = "https://moodle.test/[staging]/"
    _run(monkeypatch, settings, "status")

    assert "https://moodle.test/[staging]/" in _output(captured)


def test_status_escapes_a_profile_path_with_brackets(monkeypatch, settings, captured):
    """The profile directory is wherever the user put it, and a bracket in the
    path is not special to them - but to Rich it is a style tag, and the session
    line printed "/home/ada//profile" with the middle segment silently gone."""
    settings.browser_profile = settings.pli_home / "[work]" / "browser"
    # The path is only printed once the profile looks signed in: with no profile
    # the status line is "not signed in - run with BROWSER_HEADLESS=false", which
    # names no path at all and would let this pass without the escape.
    cookies = settings.profile_dir / "Default" / "Cookies"
    cookies.parent.mkdir(parents=True)
    cookies.write_bytes(b"SQLite format 3\0")

    _run(monkeypatch, settings, "status")

    # The path is printed twice - once on the `browser` line, once inside the
    # session line - and both are escaped. Asserting only that "[work]" appears
    # would pass on the `browser` line alone, so the session line could lose its
    # copy unnoticed; the count is what pins that line.
    assert _output(captured).count("[work]") == 2


def test_the_written_path_report_keeps_its_brackets(monkeypatch, settings, captured, tmp_path):
    """`pli plan --markdown` prints where it wrote the file, and that path is the
    user's to choose. Unescaped, the confirmation named a file that does not
    exist. The plan itself is stubbed: this is about the sentence, not the
    planner, which is exercised in test_planner."""
    target = tmp_path / "[notes]" / "week.md"
    target.parent.mkdir()
    task = Task(
        key="t1",
        title="Problem Set 4",
        course="CS301 Algorithms",
        due_at=datetime(2026, 10, 8, 12, 0, tzinfo=UTC),
        estimated_minutes=120,
        priority=0.8,
    )
    monkeypatch.setattr(
        cli, "_build_plan", lambda **_: ([task], PackResult(blocks=[], unscheduled=[]), [], None)
    )

    result = _run(monkeypatch, settings, "plan", "--markdown", str(target))

    assert result.exit_code == 0, _output(captured)
    assert "[notes]" in _output(captured)
    assert target.exists()


# --- a read that did not happen is not a read that found nothing ---------------


def test_a_teams_read_that_never_ran_is_not_reported_as_no_messages(
    monkeypatch, settings, captured
):
    """`pli sync` with no judge key warned and then printed "0 messages".

    That is the report of a healthy, quiet week. The channels were never opened.
    A user with this in cron has no way to tell the two apart, which is the whole
    reason the reader refuses to answer with an empty list on failure.
    """
    monkeypatch.setattr(cli, "_read_channels", lambda *a, **k: None)

    result = _run(monkeypatch, settings, "sync")

    assert result.exit_code == 0
    out = _output(captured)
    assert "not read" in out
    assert "0 messages" not in out


def test_a_teams_read_that_found_nothing_still_says_zero(monkeypatch, settings, captured):
    """The other half of the distinction: an empty channel list is a real answer
    and must keep reading as one."""
    monkeypatch.setattr(cli, "_read_channels", lambda *a, **k: [])

    _run(monkeypatch, settings, "sync")

    assert "0 messages" in _output(captured)


def test_a_skipped_teams_read_is_not_reported_as_no_messages(monkeypatch, settings, captured):
    """`--source` keeps the browser closed on purpose, so the count is unknown
    rather than zero."""
    _run(monkeypatch, settings, "sync", "--source", "stub")

    assert "not read" in _output(captured)


def test_a_failing_teams_read_returns_none_and_not_an_empty_list(monkeypatch, settings, captured):
    """The tests above replace `_read_channels` outright, which never exercises
    the branch that turns a failure into `None`. That branch is the whole fix, so
    it gets its own test against the real function: a reader that raised must not
    leave a `[]` behind for the summary to count."""

    def boom(*args, **kwargs):
        raise SessionError("the page redirected to a sign-in screen")

    monkeypatch.setattr(cli, "_judge", lambda s: object())
    monkeypatch.setattr("pli.browser.teams.read_messages", boom)

    with Store(settings.db_path) as store:
        assert cli._read_channels(store, settings, datetime.now(UTC)) is None

    assert "warning" in _output(captured)


def test_a_missing_judge_key_returns_none_rather_than_an_empty_list(settings, captured):
    """The real first-run on this machine: no TYPESAFE_API_KEY. `_judge` raises
    before any browser opens, and the caller must be told "not read"."""
    with Store(settings.db_path) as store:
        assert cli._read_channels(store, settings, datetime.now(UTC)) is None

    assert "TYPESAFE_API_KEY" in _output(captured)


def test_a_teams_read_that_succeeds_and_finds_nothing_returns_an_empty_list(monkeypatch, settings):
    """The other side of the same branch: `[]` is a real answer and must stay
    distinguishable from `None`."""
    monkeypatch.setattr(cli, "_judge", lambda s: object())
    monkeypatch.setattr("pli.browser.teams.read_messages", lambda *a, **k: [])

    with Store(settings.db_path) as store:
        assert cli._read_channels(store, settings, datetime.now(UTC)) == []


def test_a_calendar_read_that_failed_is_not_a_plan_for_a_free_week(settings, captured):
    """The same distinction as the Teams read, on the read the planner cannot do
    without.

    `_build_plan` reads the calendar through the browser, and what it gets back
    is the set of hours the packer is allowed to use. A failure folded into `[]`
    does not look like a failure at any later stage: the week reads as empty,
    the packer fills it, and the user is booked over their own lectures. The
    refusal below is the last place that can tell the two apart, and the run
    has to stop here - which is why this asserts an exit rather than a sentence.
    """

    class Unreadable:
        def list_events(self, start, end):  # noqa: ANN001 - only the failing call matters
            raise BrowserError("the week grid never appeared")

    # One deadline is all `_build_plan` needs to get past its "nothing to plan"
    # early return and reach the read.
    now = datetime(2026, 10, 5, 6, 0, tzinfo=UTC)

    with Store(settings.db_path) as store:
        store.upsert_deadline(
            Deadline(
                source="stub",
                external_id="d1",
                course_external_id="CS301",
                course_name="CS301 Algorithms",
                title="Problem Set 4",
                due_at=datetime(2026, 10, 9, 12, 0, tzinfo=UTC),
            )
        )
        with pytest.raises(typer.Exit) as raised:
            cli._build_plan(
                now=now,
                settings=settings,
                cfg=cli.load_study_config(),
                store=store,
                calendar=Unreadable(),
            )

    assert raised.value.exit_code == 1
    assert "read your calendar" in _output(captured)


# --- the whole pipeline, once ------------------------------------------------------


class _OneEventCalendar:
    """A calendar holding exactly one event, and not one of this tool's own."""

    def __init__(self, event: RemoteEvent) -> None:
        self.event = event
        self.reads: list[tuple[datetime, datetime]] = []

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        self.reads.append((start, end))
        return [self.event]


def _utc_settings(settings: Settings) -> Settings:
    """The shared fixture with the timezone pinned.

    Every other test here is about a sentence and does not care where the
    planner thinks it is. These two compare block times against a lecture, so
    the machine's own zone would change what they mean: study hours 8-22 are
    *local*, and on a machine in another zone the free windows land somewhere
    else entirely. Pinned, the arithmetic below is the same everywhere.
    """
    return settings.model_copy(update={"pli_timezone": "UTC"})


def _plan_with_one_deadline(settings, *, now, due, lecture):
    """Run the real `_build_plan` over a store with one deadline and one event.

    No judge and no browser: the calendar is handed in, which is exactly the
    seam `_build_plan` documents, so everything downstream - task building,
    scoring, the free/busy pass, the packer - is the production code.
    """
    calendar = _OneEventCalendar(lecture)
    with Store(settings.db_path) as store:
        store.upsert_deadline(
            Deadline(
                source="stub",
                external_id="d1",
                course_external_id="CS301",
                course_name="CS301 Algorithms",
                title="Problem Set 4",
                due_at=due,
            )
        )
        tasks, result, free, _ = cli._build_plan(
            now=now,
            settings=settings,
            cfg=cli.load_study_config(),
            store=store,
            calendar=calendar,
        )
    return tasks, result, free, calendar


#: A Monday morning of lectures, 08:00-12:00. It is deliberately the *first*
#: thing in the horizon: a planner that forgot the calendar entirely would fill
#: Monday from 08:00, straight through it.
MONDAY_LECTURE = RemoteEvent(
    remote_id="lec-1",
    subject="CS301 Lecture",
    start=datetime(2026, 10, 5, 8, 0, tzinfo=UTC),
    end=datetime(2026, 10, 5, 12, 0, tzinfo=UTC),
)

MONDAY = datetime(2026, 10, 5, 0, 0, tzinfo=UTC)  # a Monday, before study hours


def test_a_stored_deadline_becomes_a_plan_that_avoids_the_users_lecture(settings):
    """The one test that runs the real `_build_plan` all the way through.

    Every other test in this file stubs it out, and the pieces it calls -
    `build_tasks`, `score_tasks`, `free_slots`, `pack` - are each tested on their
    own. That leaves the *wiring between them* with no coverage anywhere, and the
    wiring is what `pli plan` and `pli apply` actually run: the store's deadlines
    handed to the task builder, the calendar's events handed to the packer as
    busy time. A mistake there passes every unit test in the suite and surfaces
    only here - as a week of study booked over the user's own lectures, which is
    the failure this project exists to avoid.

    The lecture starts at the very beginning of study hours so that this claim
    can actually fail. An earlier draft put a lecture in the middle of the day
    and the packer simply placed the block in the morning, before it; the
    assertion passed with the calendar ignored entirely.
    """
    settings = _utc_settings(settings)
    due = datetime(2026, 10, 9, 12, 0, tzinfo=UTC)  # that Friday, lunchtime

    tasks, result, free, calendar = _plan_with_one_deadline(
        settings, now=MONDAY, due=due, lecture=MONDAY_LECTURE
    )

    assert tasks, "the deadline sitting in the store produced no task at all"
    assert result is not None
    [task] = tasks

    # It planned real work rather than an empty week: everything it scheduled
    # belongs to this task, and there was room enough to schedule all of it.
    assert result.blocks, "nothing was scheduled for a week with six free evenings in it"
    assert {block.task_key for block in result.blocks} == {task.key}
    assert result.unscheduled == [], "the week had room - the work should have fitted"

    # The calendar was read, and the event in it was honoured as busy time.
    assert calendar.reads, "the calendar was never read"
    for block in result.blocks:
        overlaps = block.start < MONDAY_LECTURE.end and block.end > MONDAY_LECTURE.start
        assert not overlaps, f"booked study over the lecture: {block.start} - {block.end}"

    # Nothing runs past the deadline it was made for either.
    for block in result.blocks:
        assert block.end <= due, f"a block ends after its own deadline: {block.end}"

    assert free, "no free windows were found in a week with only one lecture"


def test_the_deadlines_own_hour_reaches_the_packer_from_the_store(settings):
    """The other half of the wiring: `due_at` reaching the packer as a ceiling.

    The deadline here cuts through the only free window there is, so a session
    that respected it could not be placed at all. Without the ceiling the packer
    fills that window anyway and the block ends an hour past the deadline - a
    plan that quietly schedules work for after it was due. The week is left
    empty and the shortfall reported, which is what the user needs to see.
    """
    settings = _utc_settings(settings)
    due = datetime(2026, 10, 5, 13, 0, tzinfo=UTC)  # an hour after the lecture ends

    tasks, result, _, _ = _plan_with_one_deadline(
        settings, now=MONDAY, due=due, lecture=MONDAY_LECTURE
    )

    assert tasks
    assert result is not None
    for block in result.blocks:
        assert block.end <= due, (
            f"a block was placed after the deadline it is for: {block.start} - {block.end}"
        )
    assert result.unscheduled, "a block that could not fit before the deadline was not reported"


# --- apply: the one command that writes ------------------------------------------


class _FakeWriterState:
    """What the fake writer recorded, and how it should fail.

    Handed back by the `writer` fixture. `built` is every `CalendarWriter` the
    command constructed - a list, because "did it write at all" and "how many
    times" are both questions worth asking of the only writer in the tool.
    """

    def __init__(self) -> None:
        self.built: list = []
        self.raises: Exception | None = None


@pytest.fixture
def writer(monkeypatch):
    """Stand in for `CalendarWriter`, and record how the command used it.

    `apply` is the only code path in this tool that changes anything upstream, so
    what this fake records *is* the thing under test: the blocks handed to it and
    whether the run was a dry one. `dry_run` is keyword-only with a default of
    `True`, which is why the real call site passes it by name - a dropped
    argument would quietly turn the only writer into a no-op.
    """
    from pli.planner.apply import ApplyResult

    state = _FakeWriterState()

    class Fake:
        def __init__(self, calendar, store, **_kwargs):  # noqa: ANN001 - mirrors the real signature
            self.calendar = calendar
            self.store = store
            self.calls: list[tuple[list, bool]] = []
            self.outcome = ApplyResult(
                created=2, updated=1, deleted=1, unchanged=3, calendar_id="Study Plan"
            )
            state.built.append(self)

        def apply(self, blocks, *, dry_run=True):  # noqa: ANN001
            self.calls.append((list(blocks), dry_run))
            if state.raises is not None:
                raise state.raises
            return self.outcome

    monkeypatch.setattr(cli, "CalendarWriter", Fake)
    return state


def _planned(monkeypatch, *, calendar=None):
    """Stub the shared pipeline so only the command's own behaviour is exercised."""
    block = Block(
        block_key="b1",
        task_key="t1",
        subject="Study · CS301 Algorithms — Problem Set 4",
        start=datetime(2026, 10, 8, 10, 0, tzinfo=UTC),
        end=datetime(2026, 10, 8, 11, 0, tzinfo=UTC),
    )
    task = Task(
        key="t1",
        title="Problem Set 4",
        course="CS301 Algorithms",
        due_at=datetime(2026, 10, 9, 12, 0, tzinfo=UTC),
        estimated_minutes=120,
        priority=0.8,
    )
    monkeypatch.setattr(
        cli, "_build_plan", lambda **_: ([task], PackResult(blocks=[block]), [], calendar)
    )
    return block


def test_plan_does_not_write_and_apply_does(monkeypatch, settings, captured, writer):
    """The dry-run promise, pinned where it can actually break.

    `pli plan` documents "never touches your calendar" and shares its entire
    pipeline with `apply`, so the only thing separating the two is whether a
    writer is built. A test asserting `plan` printed "Dry run" would still pass
    if `plan` had written the calendar as well; this asserts none was built.
    """
    _planned(monkeypatch, calendar=object())

    assert _run(monkeypatch, settings, "plan").exit_code == 0
    assert writer.built == [], "`pli plan` built a calendar writer; the dry run was not dry"

    assert _run(monkeypatch, settings, "apply").exit_code == 0
    assert len(writer.built) == 1, "`pli apply` committed nothing"


def test_apply_commits_rather_than_dry_running(monkeypatch, settings, captured, writer):
    """`dry_run=False` is the difference between writing the week and doing
    nothing at all - and the writer's own default is the safe-looking `True`."""
    block = _planned(monkeypatch, calendar=object())

    result = _run(monkeypatch, settings, "apply")

    assert result.exit_code == 0, _output(captured)
    assert writer.built[0].calls == [([block], False)], writer.built[0].calls


def test_apply_reports_what_it_changed(monkeypatch, settings, captured, writer):
    """The counts are the only receipt the user gets for a change to their own
    calendar, so each one has to come from the writer's result, not a guess."""
    _planned(monkeypatch, calendar=object())

    _run(monkeypatch, settings, "apply")

    out = _output(captured)
    assert "2 created" in out
    assert "1 updated" in out
    assert "1 deleted" in out
    assert "3 unchanged" in out


def test_a_failed_write_is_a_sentence_and_not_a_success(monkeypatch, settings, captured, writer):
    """A write that failed must never print the applied line.

    The session dies mid-write more often than mid-read: the user signs in by
    hand once, and the profile expires while the tool is open. Reporting counts
    here would tell them the week landed when none of it did.
    """
    _planned(monkeypatch, calendar=object())
    writer.raises = SessionError("profile is not signed in")

    result = _run(monkeypatch, settings, "apply")

    assert result.exit_code == 1
    out = _output(captured)
    assert "BROWSER_HEADLESS=false" in out
    assert "Applied" not in out
    assert "Traceback" not in out


def test_apply_with_nothing_to_plan_writes_nothing(monkeypatch, settings, captured, writer):
    """An empty ledger is a first run, not an error - and it must not build a
    writer that could then delete the week."""
    monkeypatch.setattr(cli, "_build_plan", lambda **_: (None, None, None, None))

    result = _run(monkeypatch, settings, "apply")

    assert result.exit_code == 0
    assert "Nothing to plan" in _output(captured)
    assert writer.built == []


# --- which halves of a sync `--source` asks for ----------------------------------


def _message(posted: datetime | None = None) -> ChannelMessage:
    """One Teams post, for the tests that need a read to come back non-empty."""
    return ChannelMessage(
        source="teams",
        external_id="m1",
        team="CS301",
        channel="Announcements",
        author="Dr Ada",
        posted_at=posted or datetime(2026, 9, 20, 9, 0, tzinfo=UTC),
        body="Problem Set 4 is due Friday.",
    )


def test_naming_teams_runs_the_channel_read_and_skips_the_sources(monkeypatch, settings, captured):
    """`pli sync -s teams` is the obvious way to re-read the channels after
    fixing a selector, and it used to be rejected with "available: stub" - a
    message naming an internal placeholder rather than the thing the user asked
    for. The read is what they meant; the sources stay put."""
    monkeypatch.setattr(cli, "_judge", lambda s: object())
    monkeypatch.setattr("pli.browser.teams.read_messages", lambda *a, **k: [_message()])

    result = _run(monkeypatch, settings, "sync", "--source", "teams")

    assert result.exit_code == 0, _output(captured)
    out = _output(captured)
    assert "1 messages" in out
    assert "0 courses" in out, "naming teams must not quietly re-run every source"


def test_the_default_sync_still_runs_both_halves(monkeypatch, settings, captured):
    """The narrowing must not have narrowed the normal run: no `--source` means
    the sources *and* the channels.

    A non-zero course count is the proof the source ran, and it is the exact
    complement of the assertion above - the count is left to the fixture config
    rather than hard-coded, so adding a deadline there cannot break this test.
    """
    monkeypatch.setattr(cli, "_judge", lambda s: object())
    monkeypatch.setattr("pli.browser.teams.read_messages", lambda *a, **k: [_message()])

    result = _run(monkeypatch, settings, "sync")

    assert result.exit_code == 0, _output(captured)
    out = _output(captured)
    assert "0 courses" not in out, f"the sources did not run: {out}"
    assert "1 messages" in out


def test_an_unknown_source_lists_the_names_that_work(monkeypatch, settings, captured):
    """A typo has to be answered with the real options, and `teams` is one of
    them - the earlier message offered only `stub`."""
    result = _run(monkeypatch, settings, "sync", "--source", "moodle")

    assert result.exit_code == 1
    out = _output(captured)
    assert "moodle" in out
    assert "stub, teams" in out


# --- a broken config file is a sentence, not a traceback -------------------------


def _raise(exc: Exception):
    """A stub for a call that has to fail: `lambda: _raise(...)` reads better
    than a `def` whose only statement is a `raise`."""
    raise exc


def test_a_malformed_study_config_is_reported_before_anything_else(monkeypatch, settings, captured):
    """`pli status` is the command a user runs *when something is wrong*, and
    `study.toml` is the file they are invited to edit. Handed a typo, the old
    command died with a pydantic traceback - from the diagnostic command."""
    monkeypatch.setattr(cli, "get_settings", lambda: settings)
    monkeypatch.setattr(
        cli, "load_study_config", lambda *a, **k: _raise(ConfigError("study.toml: horizon.dayz"))
    )

    result = _run(monkeypatch, settings, "status")

    assert result.exit_code == 1
    out = _output(captured)
    assert "horizon.dayz" in out
    assert "Fix config/study.toml" in out
    assert "Traceback" not in out


def test_a_malformed_env_is_reported_before_anything_else(monkeypatch, settings, captured):
    """`.env` is hand-edited too, and `get_settings` runs first in every command:
    an unguarded failure there means every command tracebacks."""
    monkeypatch.setattr(cli, "get_settings", lambda: _raise(ConfigError(".env: BROWSER_HEADLESS")))

    # Invoked directly rather than through `_run`, which installs a working
    # `get_settings` of its own and would overwrite the failing one above.
    result = CliRunner().invoke(cli.app, ["status"])

    assert result.exit_code == 1
    out = _output(captured)
    assert "BROWSER_HEADLESS" in out
    assert "Fix .env" in out
    assert "Traceback" not in out


# --- long-running-process hygiene -------------------------------------------------


def _raise_interrupt():
    """Stands in for `cli.app` mid-command: a Ctrl-C inside a browser read."""
    raise KeyboardInterrupt


def test_the_warning_handler_does_not_leak(captured):
    """`_reader_warnings` is entered once per sync, and a handler left attached
    prints every later warning again: the second sync reports one broken channel
    twice, the fifth five times. The suite and a cron runner share a process, so
    this is a leak that grows rather than one that shows up immediately.
    """
    logger = logging.getLogger("pli")
    level_before = logger.level

    for _ in range(3):
        with cli._reader_warnings():
            logger.warning("a channel could not be read")

    assert _output(captured).count("a channel could not be read") == 3
    assert logger.level == level_before, "the logger level was left raised"
    assert not any(isinstance(h, cli._ConsoleLogHandler) for h in logger.handlers)


def test_an_interrupt_exits_130_and_does_not_traceback(monkeypatch, capsys):
    """This tool waits on a browser. Ctrl-C is the expected way out of a slow
    read, and it has to look like a shell interrupt - not a Python traceback -
    because the scheduled run is watched by a scrollback, not a person."""
    monkeypatch.setattr(cli, "app", _raise_interrupt)

    with pytest.raises(SystemExit) as exit_info:
        cli.main()

    assert exit_info.value.code == 130
    assert "Traceback" not in capsys.readouterr().out


# --- the files a user reads name commands that exist -------------------------------


def test_every_command_the_docs_tell_the_user_to_run_exists():
    """`config/browser.toml` sent the user to `pli browser capture`, which this tool
    has never had.

    That is the file the reader is told to check first when a page changes, and
    its advice named something that does not exist - so the one moment it is
    consulted is the moment it wastes. The code already holds this rule for its
    own messages (`SIGN_IN` in `pli.browser.session`: the advice "cannot drift
    into naming a command that does not exist") but nothing held it for the files
    a user actually reads.

    Only backticked spans are scanned, because that is how these files write a
    command - a plain scan would flag prose like "pli reads the page".
    """
    commands = {
        command.name or command.callback.__name__ for command in cli.app.registered_commands
    }
    repo = Path(cli.__file__).resolve().parents[2]

    documented: set[str] = set()
    for path in [
        repo / "README.md",
        *sorted((repo / "config").glob("*.toml")),
        repo / ".env.example",
    ]:
        if not path.exists():
            continue
        for span in re.findall(r"`([^`]+)`", path.read_text(encoding="utf-8")):
            documented.update(re.findall(r"\bpli ([a-z][a-z-]*)", span))

    assert documented, "the scan matched no commands at all, so it is testing nothing"
    unknown = sorted(documented - commands)
    assert not unknown, f"the docs name commands that do not exist: {unknown}"
