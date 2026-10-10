"""`pli watch`: an opt-in collector that says what it collects and can always be paused.

The data it keeps is about the user's behaviour, so the command's job is as much to be
honest as to collect:

**It says what it does before it does it.** Starting prints what is counted, what is
never stored, where it lives, how long it is kept and how to pause - a person who typed
the command should not have to read the source to know.

**Pause is real and cheap.** `--pause` and `--resume` flip one flag file, and a paused
watcher keeps running but collects nothing; `--status` says which it is.

**A 24/7 loop must not die quietly.** An unexpected error in one cycle is reported on one
line and the loop carries on; Ctrl-C ends it cleanly with the store closed.

**Asking the agent never creates the database.** The agent only reads what `pli watch`
already wrote.

Nothing here touches D-Bus, git, a browser or the clock: the collector and the sleep are
replaced.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from pli import cli
from pli.config import Settings


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(_env_file=None, pli_home=tmp_path / "data", typesafe_api_key="", llm_api_key="")


@pytest.fixture(autouse=True)
def _use(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    monkeypatch.setattr(cli, "_settings", lambda: settings)


class Loop:
    """Replaces `pli.activity.collect_once` and `time.sleep` so a few cycles run instantly."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, cycles: int, fail_on: int | None = None):
        import pli.activity as activity

        self.calls: list[dict[str, Any]] = []
        self.sleeps: list[float] = []
        self.closed = 0
        self.cycles, self.fail_on = cycles, fail_on
        loop = self

        class FakeStore:
            def __init__(self, path: Path) -> None:
                loop.path = path

            def close(self) -> None:
                loop.closed += 1

            def __enter__(self) -> FakeStore:
                return self

            def __exit__(self, *exc: object) -> None:
                self.close()

        def collect_once(store: Any, settings: Settings, now: Any, **kwargs: Any) -> str:
            loop.calls.append(kwargs)
            if loop.fail_on is not None and len(loop.calls) == loop.fail_on:
                raise RuntimeError("scan blew up")
            return "ok"

        def sleep(seconds: float) -> None:
            loop.sleeps.append(seconds)
            if len(loop.sleeps) >= loop.cycles:
                raise KeyboardInterrupt

        monkeypatch.setattr(activity, "ActivityStore", FakeStore)
        monkeypatch.setattr(activity, "collect_once", collect_once)
        monkeypatch.setattr(cli.time, "sleep", sleep)


def _invoke(*args: str) -> Any:
    return CliRunner().invoke(cli.app, ["watch", *args])


# --- pause and resume --------------------


def test_pause_creates_the_flag_and_resume_removes_it(settings: Settings) -> None:
    assert _invoke("--pause").exit_code == 0
    assert settings.activity_pause_path.exists()

    assert _invoke("--resume").exit_code == 0
    assert not settings.activity_pause_path.exists()


def test_pause_and_resume_are_idempotent(settings: Settings) -> None:
    for flag in ("--resume", "--pause", "--pause", "--resume", "--resume"):
        assert _invoke(flag).exit_code == 0


def test_pausing_says_nothing_is_collected_until_resumed() -> None:
    assert "paused" in _invoke("--pause").output.lower()
    assert "resume" in _invoke("--pause").output.lower()


def test_more_than_one_action_flag_is_refused_before_anything_changes(
    settings: Settings,
) -> None:
    result = _invoke("--pause", "--resume")

    assert result.exit_code != 0
    assert not settings.activity_pause_path.exists()


# --- stopping --------------------


def test_a_stop_request_unwinds_like_ctrl_c_so_cleanup_runs_and_is_undone_after(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """systemd stops a service with SIGTERM, which by default ends Python with no cleanup and
    would leave a half-made copy of the browser history on disk. Called directly, never
    raised as a real signal, so a broken handler cannot stop the test run."""
    import signal

    before = signal.getsignal(signal.SIGTERM)
    seen: dict[str, Any] = {}
    Loop(monkeypatch, cycles=1)

    def sleep(seconds: float) -> None:
        seen["handler"] = signal.getsignal(signal.SIGTERM)
        raise KeyboardInterrupt

    monkeypatch.setattr(cli.time, "sleep", sleep)

    result = _invoke()

    assert result.exit_code == 0, result.output
    assert callable(seen["handler"])
    with pytest.raises(KeyboardInterrupt):
        seen["handler"](signal.SIGTERM, None)
    assert signal.getsignal(signal.SIGTERM) == before


# --- status --------------------


def test_status_before_the_watcher_ever_ran_says_so_and_creates_nothing(
    settings: Settings,
) -> None:
    result = _invoke("--status")

    assert result.exit_code == 0, result.output
    assert "not been started" in result.output
    assert not settings.activity_db_path.exists()


def test_status_reports_rows_and_the_last_update_and_whether_it_is_paused(
    settings: Settings,
) -> None:
    from datetime import datetime

    import pli.activity as activity

    with activity.ActivityStore(settings.activity_db_path) as store:
        store.add_active_minute(datetime(2026, 10, 9, 14, 5, tzinfo=settings.timezone()))
    assert "1 row" in _invoke("--status").output
    assert "collecting" in _invoke("--status").output

    _invoke("--pause")

    assert "paused" in _invoke("--status").output


# --- the loop --------------------


def test_start_says_what_is_collected_and_what_is_not_before_it_collects(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    loop = Loop(monkeypatch, cycles=1)

    result = _invoke()

    text = result.output.lower()
    assert result.exit_code == 0, result.output
    assert "commits" in text and "files" in text and "visits" in text and "minutes" in text
    assert "never" in text and "titles" in text and "urls" in text
    assert "activity.db" in "".join(text.split())  # a long path wraps; ignore the line breaks
    assert "--pause" in result.output
    assert loop.calls  # and then it did collect


def test_the_first_cycle_scans_and_scans_repeat_only_every_few_cycles(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    loop = Loop(monkeypatch, cycles=12)

    _invoke()

    scans = [i for i, kw in enumerate(loop.calls) if kw.get("scan")]
    assert scans[0] == 0
    assert 0 < scans[1] - scans[0] <= 5
    assert len(scans) < len(loop.calls)  # most cycles are the cheap idle sample only


def test_the_loop_samples_once_a_minute_and_ctrl_c_ends_it_cleanly_with_the_store_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    loop = Loop(monkeypatch, cycles=3)

    result = _invoke()

    assert result.exit_code == 0, result.output
    assert loop.sleeps == [60, 60, 60]
    assert loop.closed == 1
    assert "Traceback" not in result.output


def test_the_sampling_interval_is_not_a_setting_because_a_sample_is_one_minute() -> None:
    """Each active sample adds one minute, so `--interval 5` would record an hour as 720."""
    result = _invoke("--interval", "5")

    assert result.exit_code != 0


def test_an_unexpected_error_in_one_cycle_is_reported_and_the_loop_carries_on(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    loop = Loop(monkeypatch, cycles=4, fail_on=2)

    result = _invoke()

    assert result.exit_code == 0, result.output
    assert "scan blew up" in result.output
    assert len(loop.calls) == 4  # the cycle after the failure still ran


def test_a_paused_watcher_keeps_running_but_says_it_is_paused_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import pli.activity as activity

    answers = iter(["ok", "paused", "paused", "paused", "ok"])
    loop = Loop(monkeypatch, cycles=5)
    monkeypatch.setattr(activity, "collect_once", lambda *a, **k: next(answers))

    result = _invoke()

    # Count the message, not the word: pytest's temp folder is named after this test.
    assert result.output.count("Paused: nothing is collected") == 1
    assert result.output.count("Collecting again.") == 1
    assert loop.closed == 1


# --- `pli status` and the agent --------------------


def test_pli_status_shows_the_activity_line_without_creating_the_database(
    settings: Settings,
) -> None:
    result = CliRunner().invoke(cli.app, ["status"])

    assert result.exit_code == 0, result.output
    assert "activity" in result.output.lower()
    assert not settings.activity_db_path.exists()


def test_the_agent_is_given_an_activity_reader_that_never_creates_the_database(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    import pli.agent.repl as repl

    seen: dict[str, Any] = {}

    def fake_run(*args: Any, **kwargs: Any) -> None:
        seen["activity"] = kwargs.get("activity")

    monkeypatch.setattr(repl, "run", fake_run)

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert callable(seen["activity"])
    assert seen["activity"]() == ""  # no database yet: no data, and still none created
    assert not settings.activity_db_path.exists()
