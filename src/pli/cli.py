"""Command line entry point.

pli status       what is configured and what is stored locally
pli sync         pull courses, deadlines, materials and Teams channel posts
pli plan         dry run - print the week, change nothing
pli apply        commit the week to the Study Plan calendar
pli clear-state  forget a source's sync cursors
pli watch        opt-in local activity counts (active minutes, commits, files, sites);
                 --pause/--resume/--status
pli agent        interactive, read-only: read, sort and summarise your Outlook inbox,
                 and answer questions; --voice adds local push-to-talk speech input,
                 --window a small status window

Every read and write goes through the browser, driving the same web UI a person
would use (see `pli.browser`). Nothing here talks to Microsoft Graph: there is no
app registration, no tenant admin consent and no Microsoft credential stored
anywhere. What the tool borrows is the persistent Chromium profile at
`BROWSER_PROFILE` - whatever session already lives there is the session it uses.

There is deliberately no sign-in command. If that profile is not signed in, the
first read fails with a `SessionError` that says so and says how to fix it: run
once with `BROWSER_HEADLESS=false`, complete the sign-in in the window that
opens, and every later run - including the headless scheduled one - reuses the
profile it leaves behind.
"""

from __future__ import annotations

import logging
import signal
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, NoReturn

import typer
from rich.console import Console
from rich.markup import escape

from pli.backend import CalendarBackend
from pli.browser import BrowserError, SessionError
from pli.config import (
    ConfigError,
    Settings,
    StudyConfig,
    get_settings,
    load_study_config,
    system_timezone_name,
)
from pli.db import Store
from pli.judge import Judge, JudgeUnavailable
from pli.models import ChannelMessage, Slot, Task
from pli.planner.apply import CalendarWriter
from pli.planner.pack import PackResult, pack
from pli.report import console, render_plan, render_slots, render_tasks, to_markdown
from pli.sources.base import IngestResult, iter_all

app = typer.Typer(add_completion=False, help="Personal Learning Intelligence.")

#: How far back the first Teams read reaches. Every later run resumes from the
#: newest post the previous one saw, so this only bounds the very first sync:
#: deep enough to pick up a deadline announced last week, shallow enough not to
#: walk a year of channel history through a browser.
FIRST_MESSAGE_WINDOW_DAYS = 14

#: The `--source` name for the Teams channel read. Not an ingest source - see
#: `_sources` - but a name a user will pass, so it is a first-class one here.
CHANNEL_SOURCE = "teams"


# --- failure handling -----------------------------------------------------------


def _fail(message: str, hint: str | None = None) -> NoReturn:
    console.print(f"[red]{escape(message)}[/red]")
    if hint:
        console.print(f"[dim]{escape(hint)}[/dim]")
    raise typer.Exit(1)


def _browser_hint(exc: Exception, settings: Settings) -> str:
    """One actionable sentence for a browser failure.

    An expired session and a restyled page have different fixes, so they get
    different hints. A reader that could not parse a page has already put the
    path it saved diagnostics to in its own message; naming the directory here
    keeps that visible even when nothing could be captured.
    """
    if isinstance(exc, SessionError):
        return (
            "The Chromium profile this tool reuses is not signed in. Sign in once by "
            "setting BROWSER_HEADLESS=false in .env and re-running this command: a "
            "window opens, you complete the sign-in there, and every later run reuses "
            "the profile it leaves behind."
        )
    diagnostics = settings.home / "diagnostics"
    return (
        "The page may have been restyled - the fix is a selector in config/browser.toml, "
        f"not a code change. Diagnostics are saved under {diagnostics}."
    )


def _browser_fail(what: str, exc: Exception, settings: Settings) -> NoReturn:
    """Turn a browser failure into a clean exit, never a Python traceback."""
    _fail(f"Could not {what}: {exc}", _browser_hint(exc, settings))


# --- the two failure shapes ------------------------------------------------------


def _settings() -> Settings:
    """Machine-local settings, or a clean exit.

    A malformed `.env` - `BROWSER_HEADLESS=maybe`, a typo in a port - raises
    inside pydantic, and every command starts here, so an unguarded call means
    every command dies with a traceback from a file the user edited by hand.
    """
    try:
        return get_settings()
    except ConfigError as exc:
        _fail(f"Cannot read your settings: {exc}", "Fix .env and re-run.")


def _config() -> StudyConfig:
    """Study preferences, or a clean exit. Same reasoning as `_settings`: this
    file is hand-edited, and `pli status` must survive being handed a bad one."""
    try:
        return load_study_config()
    except ConfigError as exc:
        _fail(f"Cannot read your study config: {exc}", "Fix config/study.toml and re-run.")


# --- the browser seam ---------------------------------------------------------------------


def _judge(settings: Settings) -> Judge:
    """The Judge for this run, with its key checked.

    `Judge` is cheap to construct and only discovers a missing key on its first
    call, so the client is forced here: an absent TYPESAFE_API_KEY has to fail
    before a browser opens, with a message about the key, and never as a
    traceback from inside a page read. One instance is built per command and
    handed to every reader.
    """
    judge = Judge(settings)
    judge._build_client()  # noqa: SLF001 - the one place that owns the message
    return judge


def _calendar(settings: Settings, judge: Judge) -> CalendarBackend:
    """The Outlook calendar, reached by driving the web UI. No I/O until called."""
    from pli.browser.outlook import OutlookBackend

    return OutlookBackend(settings, judge)


class _ConsoleLogHandler(logging.Handler):
    """Route the readers' warnings into the same console as everything else."""

    def emit(self, record: logging.LogRecord) -> None:
        console.print(f"[yellow]warning:[/yellow] {escape(record.getMessage())}")


@contextmanager
def _reader_warnings() -> Iterator[None]:
    """Show the warnings the readers log while reading.

    A channel that could not be read is logged by the reader and skipped there -
    `read_messages` isolates per-channel failures by design - so it never
    reaches this module as an exception. Without a handler those records would
    surface as bare lines on stderr; with one they read exactly like an
    `IngestResult` error, which is what they are.
    """
    logger = logging.getLogger("pli")
    handler = _ConsoleLogHandler()
    previous = logger.level
    logger.addHandler(handler)
    logger.setLevel(logging.WARNING)
    try:
        yield
    finally:
        logger.removeHandler(handler)
        logger.setLevel(previous)


# --- sources --------------------------------------------------------------------


def _sources(names: list[str] | None = None) -> list[object]:
    """The ingest sources to run.

    `teams` is accepted and dropped here. It is not an ingest source - the
    channel read is its own path, and returns `ChannelMessage`s rather than an
    `IngestResult` - but it is one of the two things a sync refreshes, and it is
    what a user who wants only the channels will type. Refusing it with
    "available: stub" would name an internal placeholder and teach them nothing.
    """
    from pli.sources.stub import StubSource

    available: dict[str, object] = {"stub": StubSource()}
    allowed = [*available, CHANNEL_SOURCE]
    chosen = names if names else list(available)
    unknown = [n for n in chosen if n not in allowed]
    if unknown:
        _fail(f"unknown source(s): {', '.join(unknown)}", f"available: {', '.join(allowed)}")
    return [available[n] for n in chosen if n in available]


def _wants_channels(source: list[str] | None) -> bool:
    """Whether this run should read the Teams channels.

    No `--source` means everything, channels included. `--source stub` narrows
    the run to the sources and keeps the browser closed; `--source teams` is the
    opposite - the channels and nothing else.
    """
    return source is None or CHANNEL_SOURCE in source


# --- status ---------------------------------------------------------------------


def _session_line(settings: Settings) -> str:
    """What the browser profile looks like, for `pli status`.

    Information, not a verdict: only a real navigation proves a session still
    works, so this reports what is on disk and leaves the judgement to the read
    that needs it. Never fails the command.
    """
    from pli.browser.session import status

    try:
        answer = status(settings)
    except Exception:  # noqa: BLE001 - a status read must never fail the command
        return "[yellow]unreadable[/yellow]"
    return str(answer)


@app.command()
def status() -> None:
    """Show configuration and local state."""
    settings = _settings()
    cfg = _config()

    console.print("[bold]Configuration[/bold]")
    console.print(f"  timezone      {escape(settings.pli_timezone or system_timezone_name())}")
    console.print(f"  LLM           {escape(settings.llm_model)} @ {escape(settings.llm_base_url)}")
    console.print(
        f"  LLM key       {'set' if settings.llm_api_key else '[yellow]missing[/yellow]'}"
    )
    console.print(
        "  judge key     "
        + (
            "set"
            if settings.typesafe_api_key
            else "[yellow]missing TYPESAFE_API_KEY[/yellow] "
            "[dim]- page content cannot be judged; get one at "
            "https://console.typesafe.ai/keys[/dim]"
        )
    )
    console.print(f"  browser       {escape(str(settings.profile_dir))}")
    console.print(f"  headless      {settings.browser_headless}")
    console.print(f"  session       [dim]{escape(_session_line(settings))}[/dim]")
    console.print(
        "  Moodle        "
        + (
            escape(settings.moodle_base_url)
            if settings.moodle_base_url
            else "[yellow]missing[/yellow]"
        )
    )
    console.print(f"  horizon       {cfg.horizon.days} days")
    console.print(
        f"  study hours   {cfg.study.earliest_hour}:00-{cfg.study.latest_hour}:00, "
        f"{cfg.study.session_min_minutes}-{cfg.study.session_max_minutes} min sessions"
    )

    console.print(f"  activity      {_activity_status(settings)}")

    console.print("\n[bold]Local state[/bold]")
    if not settings.db_path.exists():
        console.print("  [dim]no database yet - run `pli sync`[/dim]")
        return

    with Store(settings.db_path) as store:
        courses = store.conn.execute("SELECT COUNT(*) AS n FROM courses").fetchone()["n"]
        materials = store.conn.execute("SELECT COUNT(*) AS n FROM materials").fetchone()["n"]
        messages = store.conn.execute("SELECT COUNT(*) AS n FROM messages").fetchone()["n"]
        deadlines = store.deadlines()
        upcoming = [d for d in deadlines if d.due_at > datetime.now(UTC)]
        console.print(f"  database      {escape(str(settings.db_path))}")
        console.print(f"  courses       {courses}")
        console.print(f"  materials     {materials}")
        console.print(f"  deadlines     {len(deadlines)} ({len(upcoming)} upcoming)")
        console.print(f"  messages      {messages} Teams posts")


# --- sync -----------------------------------------------------------------------


def _messages_since(store: Store, now: datetime) -> datetime:
    """Where the last Teams read got to, or a sensible first-run window."""
    stored = store.get_state("teams", "messages:since")
    if stored:
        try:
            return datetime.fromisoformat(stored)
        except ValueError:
            pass  # A hand-edited cursor is not worth failing a sync over.
    return now - timedelta(days=FIRST_MESSAGE_WINDOW_DAYS)


def _read_channels(store: Store, settings: Settings, now: datetime) -> list[ChannelMessage] | None:
    """Read the Teams channels; a failure anywhere is a warning, not an abort.

    A channel that could not be read is skipped by the reader itself, which logs
    it (see `_reader_warnings`) and carries on with the rest - one restyled
    channel must not cost the announcements in the other nine. A failure that
    stops the whole read, such as a profile that is not signed in, is reported
    the same way rather than raised: `pli sync` has already stored the courses
    and deadlines it fetched, and throwing them away over the Teams half would
    be the worse outcome.

    Returns `None` when the read did not happen at all - a missing judge key, an
    expired session, a restyled page - and `[]` when it happened and there was
    nothing new. The two are collapsed nowhere: a caller that printed "0
    messages" for a read that never ran would report a broken reader as a quiet
    week, which is the one failure nobody notices until an announcement is
    missed.
    """
    from pli.browser.teams import read_messages

    since = _messages_since(store, now)
    try:
        messages = read_messages(settings, _judge(settings), since=since)
    except (BrowserError, SessionError) as exc:
        console.print(f"[yellow]warning:[/yellow] teams: {escape(str(exc))}")
        console.print(f"[dim]{escape(_browser_hint(exc, settings))}[/dim]")
        return None
    except JudgeUnavailable as exc:
        console.print(f"[yellow]warning:[/yellow] teams: {escape(str(exc))}")
        return None

    # The cursor moves only as far as the newest post actually seen. A run that
    # read nothing - every channel broken, or none visible - leaves it where it
    # was, so the next sync still reaches back over the gap.
    if messages:
        store.set_state("teams", "messages:since", max(m.posted_at for m in messages).isoformat())
    return messages


@app.command()
def sync(
    source: list[str] = typer.Option(
        None, "--source", "-s", help="Limit to one source: stub, or teams for the channel read."
    ),
    full: bool = typer.Option(False, "--full", help="Ignore sync cursors and refetch everything."),
) -> None:
    """Pull courses, deadlines and materials from the sources, plus Teams posts."""
    settings = _settings()
    settings.home.mkdir(parents=True, exist_ok=True)
    now = datetime.now(UTC)

    with Store(settings.db_path) as store, _reader_warnings():
        result: IngestResult = iter_all(_sources(source), store=store, full=full)

        for course in result.courses:
            store.upsert_course(course)
        for deadline in result.deadlines:
            store.upsert_deadline(deadline)
        for material in result.materials:
            store.upsert_material(material)

        # No `--source` refreshes everything; `--source stub` narrows the run to
        # the sources and keeps the browser closed; `--source teams` is the
        # channels alone. See `_wants_channels`.
        messages = _read_channels(store, settings, now) if _wants_channels(source) else None
        for message in messages or []:
            store.upsert_message(message)

    # `None` is "the Teams read did not run" - either it was skipped by
    # `--source` or it failed and warned above. Printing a count for it would
    # claim the channels were read and empty, which is exactly what a reader
    # that never opened a browser must not be allowed to say.
    counted = "not read" if messages is None else f"{len(messages)} messages"
    console.print(
        f"[green]Synced[/green] {len(result.courses)} courses · "
        f"{len(result.deadlines)} deadlines · {len(result.materials)} materials · "
        f"{counted}"
    )
    for error in result.errors:
        console.print(f"[yellow]warning:[/yellow] {escape(str(error))}")


# --- plan -----------------------------------------------------------------------


def _build_plan(
    *,
    now: datetime,
    settings: Settings,
    cfg: StudyConfig,
    store: Store,
    calendar: CalendarBackend | None = None,
) -> tuple[list[Task] | None, PackResult | None, list[Slot] | None, CalendarBackend | None]:
    """Shared pipeline for `plan` and `apply`: tasks -> score -> free -> pack.

    The calendar is read here, through the browser, and handed back so `apply`
    can write with the same session instead of opening a second browser.
    """
    from pli.planner.freebusy import busy_from, free_slots
    from pli.planner.score import score_tasks
    from pli.planner.tasks import build_tasks

    tasks = build_tasks(store.deadlines(), store.materials(), now=now, study_config=cfg)
    if not tasks:
        return None, None, None, None

    tasks = score_tasks(tasks, settings=settings, study_config=cfg, now=now)

    tz = settings.timezone()
    start = now.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=cfg.horizon.days)

    if calendar is None:
        try:
            calendar = _calendar(settings, _judge(settings))
        except JudgeUnavailable as exc:
            # A missing key is a configuration fact, not a page-read failure. It
            # must surface as one sentence naming the variable, before a browser
            # opens - not as a traceback from inside the reader.
            _fail("Cannot read your calendar: TYPESAFE_API_KEY is not set.", str(exc))

    try:
        # Every event in the horizon, not just this tool's own: this one read is
        # both the free/busy input and the reconcile input.
        events = calendar.list_events(start, end)
    except (BrowserError, SessionError) as exc:
        _browser_fail("read your calendar", exc, settings)

    free = free_slots(busy_from(events), cfg, tz, start, end)
    result: PackResult = pack(tasks, free, cfg=cfg, tz=tz, now=now)
    return tasks, result, free, calendar


@app.command()
def plan(
    days: int = typer.Option(None, "--days", "-d", help="Override the planning horizon."),
    markdown: Path = typer.Option(None, "--markdown", "-m", help="Also write the plan to a file."),
    slots: bool = typer.Option(False, "--slots", help="Show the free windows detected."),
    show_tasks: bool = typer.Option(False, "--tasks", help="Show the scored task list first."),
) -> None:
    """Dry run: work out the week and print it. Never touches your calendar."""
    settings = _settings()
    cfg = _config()
    if days:
        cfg.horizon.days = days

    now = datetime.now(UTC)
    with Store(settings.db_path) as store:
        tasks, result, free, _ = _build_plan(now=now, settings=settings, cfg=cfg, store=store)

    if tasks is None:
        console.print("[yellow]Nothing to plan.[/yellow] Run `pli sync` first.")
        return

    tz = settings.timezone()
    if show_tasks:
        render_tasks(tasks, tz=tz)
    if slots:
        render_slots(free or [], tz=tz)

    render_plan(result, tz=tz, title=f"Study week from {now.astimezone(tz):%d %B}")

    if markdown:
        markdown.write_text(to_markdown(result, tz=tz), encoding="utf-8")
        console.print(f"[dim]written to {escape(str(markdown))}[/dim]")

    console.print("[dim]Dry run - nothing was written. Use `pli apply` to commit.[/dim]")


@app.command()
def apply() -> None:
    """Commit the planned week to the dedicated Study Plan calendar."""
    settings = _settings()
    cfg = _config()
    now = datetime.now(UTC)

    with Store(settings.db_path) as store:
        tasks, result, _, calendar = _build_plan(now=now, settings=settings, cfg=cfg, store=store)
        if tasks is None or result is None or calendar is None:
            console.print("[yellow]Nothing to plan.[/yellow] Run `pli sync` first.")
            return

        writer = CalendarWriter(calendar, store)
        try:
            outcome = writer.apply(result.blocks, dry_run=False)
        except (BrowserError, SessionError) as exc:
            _browser_fail("write to your calendar", exc, settings)

    console.print(
        f"[green]Applied[/green] {outcome.created} created · "
        f"{outcome.updated} updated · {outcome.deleted} deleted · "
        f"{outcome.unchanged} unchanged"
    )
    if outcome.calendar_id:
        console.print("[dim]Calendar: Study Plan[/dim]")


@app.command("clear-state")
def clear_state(
    source: str = typer.Option(..., "--source", "-s", help="Source whose cursors to drop."),
) -> None:
    """Forget a source's sync cursors so the next sync refetches everything."""
    settings = _settings()
    with Store(settings.db_path) as store:
        store.clear_state(source)
    console.print(f"[green]Cleared sync cursors for[/green] {source}")


#: One idle sample per cycle; the git, file and browser scans every this many cycles
#: (5 cycles of 60 s = every 5 minutes).
SCAN_EVERY_CYCLES = 5
#: Seconds between samples. Not a setting: every active sample adds exactly one minute.
SAMPLE_SECONDS = 60


def _activity_status(settings: Settings) -> str:
    """One line for `pli status` and `pli watch --status`. Never creates the database."""
    if not settings.activity_db_path.exists():
        return "[dim]not started - `pli watch` is opt-in[/dim]"
    from pli import activity

    with activity.ActivityStore(settings.activity_db_path) as store:
        rows, last = store.summary()
    paused = activity.is_paused(settings.activity_pause_path)
    state = "[yellow]paused[/yellow]" if paused else "[green]collecting[/green]"
    plural = "" if rows == 1 else "s"
    return f"{state}, {rows} row{plural}" + (f", last update {last}:00" if last else "")


def _activity_reader(settings: Settings) -> Callable[[], str]:
    """What the agent calls to get the per-day counts. It only reads what `pli watch` wrote:
    with no database it returns "" and creates nothing."""

    def read() -> str:
        if not settings.activity_db_path.exists():
            return ""
        from pli import activity

        with activity.ActivityStore(settings.activity_db_path) as store:
            return activity.digest(store, datetime.now(settings.timezone()))

    return read


def _watch_notice(settings: Settings) -> str:
    domains = ", ".join(settings.activity_domain_list)
    return (
        "[bold]pli watch[/bold] - local activity counts, opt-in. Stop with Ctrl-C.\n"
        "Counted: active minutes (keyboard or mouse input in the last 2 minutes), git "
        "commits per repository folder, files edited, and visits to: " + escape(domains) + ".\n"
        "Never stored: page titles, URLs, search terms, file names, commit messages, "
        "shell commands, screenshots.\n"
        f"Kept in {escape(str(settings.activity_db_path))} (readable only by you) for "
        f"{settings.activity_retention_days} days, then deleted. Questions you ask the agent "
        "about your activity send a per-day summary to the language model: the counts, "
        "plus the repository folder and site names.\n"
        "Pause any time: `uv run pli watch --pause` (and `--resume`); `--status` shows the state."
    )


@contextmanager
def _sigterm_as_interrupt() -> Iterator[None]:
    """A stop request (systemd, `kill`) unwinds like Ctrl-C, so `finally` blocks run: a scan
    stopped halfway then deletes its copy of the browser history instead of leaving it."""
    previous = signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


@app.command()
def watch(
    pause: bool = typer.Option(False, "--pause", help="Stop collecting (a running watcher idles)."),
    resume: bool = typer.Option(False, "--resume", help="Collect again."),
    status: bool = typer.Option(False, "--status", help="Show whether it is collecting."),
) -> None:
    """Count your activity locally (opt-in): active minutes, commits, files, a few sites."""
    from pli import activity

    if sum((pause, resume, status)) > 1:
        _fail("Choose only one of --pause, --resume and --status.")
    settings = _settings()
    if pause:
        activity.pause(settings.activity_pause_path)
        console.print("Paused: nothing is collected until `uv run pli watch --resume`.")
        return
    if resume:
        activity.resume(settings.activity_pause_path)
        console.print(
            "Resumed: a running watcher samples again within a minute; the git, file and "
            "site counts refresh every 5 minutes."
        )
        return
    if status:
        if settings.activity_db_path.exists():
            console.print(_activity_status(settings))
        else:
            console.print("The watcher has not been started: run `uv run pli watch`.")
        return

    console.print(_watch_notice(settings))
    paused_said = False
    with _sigterm_as_interrupt(), activity.ActivityStore(settings.activity_db_path) as store:
        cycle = 0
        try:
            while True:
                try:
                    state = activity.collect_once(
                        store,
                        settings,
                        datetime.now(settings.timezone()),
                        scan=cycle % SCAN_EVERY_CYCLES == 0,
                    )
                except Exception as exc:  # noqa: BLE001 - a 24/7 loop reports and carries on
                    console.print(
                        f"[yellow]A cycle failed ({escape(str(exc))}); carrying on.[/yellow]"
                    )
                    state = "error"
                if state == "paused" and not paused_said:
                    console.print("[yellow]Paused:[/yellow] nothing is collected until --resume.")
                    paused_said = True
                elif state != "paused" and paused_said:
                    console.print("Collecting again.")
                    paused_said = False
                cycle += 1
                time.sleep(SAMPLE_SECONDS)
        except KeyboardInterrupt:
            console.print("\nStopped.")


@app.command()
def agent(
    limit: int = typer.Option(
        15, "--limit", "-n", min=1, max=60, help="How many inbox messages to read each time."
    ),
    voice: bool = typer.Option(
        False,
        "--voice",
        help="Talk instead of typing (local speech-to-text). Needs `uv sync --extra voice`.",
    ),
    window: bool = typer.Option(
        False,
        "--window",
        help="Show a small status window: listening, thinking, and the reply.",
    ),
) -> None:
    """Chat with a small read-only agent that reads, sorts and summarises your Outlook inbox."""
    from pli.agent.repl import run
    from pli.browser.mail import read_inbox
    from pli.deadlines import Tracker
    from pli.llm.client import LLMClient
    from pli.web import lookup_web, site_search

    settings = _settings()
    display = _open_window() if window else None
    try:
        input_fn = input
        if voice:
            from pli.voice import build_voice_input

            on_listen = (lambda: display.send("listening")) if display is not None else None
            input_fn = build_voice_input(settings, console, on_listen)
            console.print(
                "[dim]Voice is on: press Enter on an empty line to talk, Enter again to stop. "
                "Typing still works.[/dim]"
            )
        run(
            Judge(settings),
            LLMClient(settings),
            lambda n: read_inbox(settings, limit=n),
            limit=limit,
            console=console,
            input_fn=input_fn,
            display=display,
            activity=_activity_reader(settings),
            deadlines=Tracker(
                settings.deadlines_db_path, settings.timezone(), sender=settings.deadline_sender
            ),
            web=(lambda target: lookup_web(settings, target)) if settings.web_enabled else None,
            site_search=site_search if settings.web_enabled else None,
        )
    finally:
        if display is not None:
            display.close()


#: How long to give the window process to fail before saying it opened. Tk needs a moment
#: to find the display; without one it exits at once.
WINDOW_START_WAIT = 0.8


def _open_window() -> Any:
    """Start the status window. A window that cannot open is a note, never an error."""
    from pli.display import Display

    display = Display()
    display.start()
    time.sleep(WINDOW_START_WAIT)
    if not display.alive:
        console.print(
            "[yellow]The status window could not open; carrying on in the terminal.[/yellow] "
            "[dim]Run `uv run python -m pli.display` to see why.[/dim]"
        )
    return display


def main() -> None:
    """The console-script entry point.

    `SystemExit`, not `typer.Exit`, for the interrupt. Inside a command typer
    catches `KeyboardInterrupt` itself and exits 130 through `sys.exit`; this
    handler covers the interrupts it does not - during startup, or in a callback
    outside its frame - and there is nothing above `main` to convert a
    `typer.Exit` into an exit code. `typer.Exit` is a `RuntimeError`, so raising
    it here produced the traceback and exit 1 this handler exists to prevent.
    """
    try:
        app()
    except KeyboardInterrupt:
        Console().print("\n[dim]interrupted[/dim]")
        raise SystemExit(130) from None


if __name__ == "__main__":
    main()
