"""`pli agent --voice`: the flag must change where lines come from and nothing else.

**Off by default.** Without the flag the agent reads the keyboard exactly as before
and never imports the voice module, so a machine without the voice extra or
PortAudio loses nothing.

**On, it swaps only the input.** The voice reader is built from the settings and the
shared console, handed to the loop as its input, and the user is told how to talk.

Nothing here touches a microphone or a model: the voice builder is replaced.
"""

from __future__ import annotations

import sys
from collections.abc import Callable
from typing import Any

from typer.testing import CliRunner

from pli import cli
from pli.config import Settings


def _settings() -> Settings:
    return Settings(_env_file=None, typesafe_api_key="", llm_api_key="", stt_model="tiny.en")


def test_voice_is_off_by_default_and_the_voice_module_is_never_imported(monkeypatch):
    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.delitem(sys.modules, "pli.voice", raising=False)

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert "pli.voice" not in sys.modules
    assert "press Enter" not in result.output


def test_the_voice_flag_feeds_the_loop_from_the_voice_reader(monkeypatch):
    import pli.voice

    built: list[Any] = []
    lines = iter(["quit"])

    def fake_builder(
        settings: Settings, console: Any, on_listen: Any = None
    ) -> Callable[[str], str]:
        built.append((settings.stt_model, console))
        return lambda prompt: next(lines)

    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.voice, "build_voice_input", fake_builder)

    result = CliRunner().invoke(cli.app, ["agent", "--voice"])

    assert result.exit_code == 0, result.output
    assert built and built[0][0] == "tiny.en" and built[0][1] is cli.console
    assert "empty line" in result.output  # told how to talk


def test_the_voice_flag_still_accepts_typed_lines_through_the_voice_reader(monkeypatch):
    """The voice reader is the loop's only input, so it must still carry typing."""
    import pli.voice

    seen: list[str] = []
    script = iter(["help", "quit"])

    def fake_builder(
        settings: Settings, console: Any, on_listen: Any = None
    ) -> Callable[[str], str]:
        def read(prompt: str) -> str:
            seen.append(prompt)
            return next(script)

        return read

    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.voice, "build_voice_input", fake_builder)

    result = CliRunner().invoke(cli.app, ["agent", "--voice"])

    assert result.exit_code == 0, result.output
    assert seen == ["pli> ", "pli> "]
