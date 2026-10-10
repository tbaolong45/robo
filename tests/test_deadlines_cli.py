"""`pli agent` gets a deadline tracker, and looking at it never creates its file.

The tracker is wired in by the command (the loop only talks to it), points at the settings'
private file, and uses the user's own timezone for "this week".
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from pli import cli
from pli.config import Settings
from pli.deadlines import Tracker


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None,
        pli_home=tmp_path / "data",
        pli_timezone="Asia/Dubai",
        typesafe_api_key="",
        llm_api_key="",
    )


def test_the_deadlines_file_lives_next_to_the_other_private_data(settings: Settings) -> None:
    assert settings.deadlines_db_path == settings.home / "deadlines.db"


def test_the_agent_is_given_a_tracker_for_that_file_and_the_users_timezone(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    import pli.agent.repl as repl

    seen: dict[str, Any] = {}

    def fake_run(*args: Any, **kwargs: Any) -> None:
        seen["deadlines"] = kwargs.get("deadlines")

    monkeypatch.setattr(cli, "_settings", lambda: settings)
    monkeypatch.setattr(repl, "run", fake_run)

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    tracker = seen["deadlines"]
    assert isinstance(tracker, Tracker)
    assert tracker._path == settings.deadlines_db_path
    assert str(tracker._tz) == "Asia/Dubai"


def test_the_sender_the_tracker_trusts_is_a_setting_and_defaults_to_the_lms(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    import pli.agent.repl as repl

    assert settings.deadline_sender == "LMS"
    assert Settings(_env_file=None, deadline_sender="Moodle").deadline_sender == "Moodle"
    seen: dict[str, Any] = {}
    monkeypatch.setattr(
        cli, "_settings", lambda: settings.model_copy(update={"deadline_sender": "Moodle"})
    )
    monkeypatch.setattr(repl, "run", lambda *a, **k: seen.update(deadlines=k.get("deadlines")))

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert seen["deadlines"]._sender == "Moodle"


def test_starting_the_agent_creates_no_deadlines_file(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(cli, "_settings", lambda: settings)

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert not settings.deadlines_db_path.exists()
