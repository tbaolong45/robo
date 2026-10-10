"""The status window's wiring: what the agent tells it, and that it never depends on it.

`pli.display` is the window itself (tested on its own). These tests pin how the agent
and the voice reader feed it:

**The window follows the conversation.** A line you typed or said is shown as heard,
the agent says it is thinking while it works, and the outcome - an answer, a count, a
"not sure", an error - arrives as the reply.

**The REPL does not own the window.** It only sends; opening and closing belong to the
command, so a crash in the loop still closes the window.

**No window is the default.** Without `--window` nothing is imported or started.

**A window that cannot open is a note, not a failure.** The user is told how to see why,
and the agent carries on in the terminal.

Nothing here opens a window: the display is a recording fake.
"""

from __future__ import annotations

import io
import sys
from array import array
from collections.abc import Callable, Iterator
from typing import Any

import pytest
from rich.console import Console
from typer.testing import CliRunner
from typesafe_sdk import ChoiceAnswer, NoulAnswer, SystemOneResponse, Usage

from pli import cli
from pli.agent.repl import run
from pli.browser import BrowserError
from pli.browser.mail import MailItem
from pli.config import Settings
from pli.judge import Judge
from pli.voice import SAMPLE_RATE, voice_input

ROW = "Prof Ada Quiz 3 moved to Friday Sat 4:15 PM Please note"


class FakeDisplay:
    def __init__(self, alive: bool = True) -> None:
        self.sent: list[tuple[str, str]] = []
        self.started = False
        self.closed = False
        self._alive = alive

    def start(self) -> bool:
        self.started = True
        return True

    @property
    def alive(self) -> bool:
        return self._alive

    def send(self, state: str, text: str = "") -> None:
        self.sent.append((state, text))

    def close(self) -> None:
        self.closed = True

    @property
    def states(self) -> list[str]:
        return [state for state, _ in self.sent]


class FakeJev:
    """Routes a typed line to a tool by a lookup; a mail row is labelled important."""

    def __init__(
        self,
        tool_for: dict[str, str],
        labels: dict[str, str] | None = None,
        show_category: str = "all",
    ) -> None:
        self.tool_for = tool_for
        self.labels = labels or {}
        self.show_category = show_category

    def system_one(self, state: Any, questions: Any, **_: Any) -> SystemOneResponse:
        if "__tool__" in questions:
            tool = self.tool_for.get(state["request"], "none")
            answers = {
                "__tool__": ChoiceAnswer(choice=tool, confidence=0.95, probabilities={tool: 0.95}),
                "show_mail.category": ChoiceAnswer(
                    choice=self.show_category,
                    confidence=0.95,
                    probabilities={self.show_category: 0.95},
                ),
            }
        else:
            label = self.labels.get(state, "important")
            sure = 0.3 if label == "unsure" else 0.9  # "unsure" = a label under the 0.7 floor
            choice = "important" if label == "unsure" else label
            answers = {
                "category": ChoiceAnswer(
                    choice=choice, confidence=sure, probabilities={choice: sure}
                ),
                "needs_action": NoulAnswer(noul=0.1),
            }
        return SystemOneResponse(
            model="jev-test", usage=Usage(input_tokens=1, output_tokens=1), answers=answers
        )


class FakeLLM:
    def __init__(self, answer: str = "Paris.") -> None:
        self.answer = answer
        self.available = True

    def complete_json(self, system: str, user: str, **_: Any) -> dict[str, Any]:
        if '"answer"' in system:
            return {"answer": self.answer}
        return {"summary": "Quiz moved."}


def _drive(
    lines: list[str],
    display: FakeDisplay | None,
    tool_for: dict[str, str] | None = None,
    read: Callable[[int], list[MailItem]] | None = None,
    labels: dict[str, str] | None = None,
    show_category: str = "all",
) -> None:
    script: Iterator[str] = iter(lines)

    def input_fn(_prompt: str = "") -> str:
        try:
            return next(script)
        except StopIteration:
            raise EOFError from None

    def default_read(limit: int) -> list[MailItem]:
        return [MailItem(id="c1", unread=True, attachments=False, text=ROW)]

    judge = Judge(
        Settings(_env_file=None, typesafe_api_key="k"),
        client=FakeJev(tool_for or {}, labels, show_category),
    )
    out = Console(file=io.StringIO(), width=120, force_terminal=False, color_system=None)
    run(
        judge,
        FakeLLM(),
        read or default_read,
        limit=5,
        console=out,
        input_fn=input_fn,
        display=display,
    )


# --- the window follows the conversation ------------------------------------------------------


def test_a_question_shows_what_was_heard_then_thinking_then_the_answer():
    display = FakeDisplay()

    _drive(
        ["what is the capital of France", "quit"], display, {"what is the capital of France": "ask"}
    )

    assert display.sent[0] == ("heard", "what is the capital of France")
    assert display.states == ["heard", "thinking", "reply"]
    assert display.sent[-1][1] == "Paris."


def test_reading_the_mail_shows_a_count_not_the_mail():
    display = FakeDisplay()

    _drive(["read my mail", "quit"], display, {"read my mail": "read_mail"})

    assert display.states == ["heard", "thinking", "reply"]
    reply = display.sent[-1][1]
    assert "1 message" in reply
    assert "Prof Ada" not in reply and "Quiz" not in reply  # no mail text on the window


def test_showing_a_category_reports_how_many_were_shown():
    display = FakeDisplay()

    _drive(
        ["read my mail", "show everything", "quit"],
        display,
        {"read my mail": "read_mail", "show everything": "show_mail"},
    )

    assert display.sent[-1][0] == "reply"
    assert "1" in display.sent[-1][1]


def test_reading_the_mail_also_reports_how_many_were_unsure():
    display = FakeDisplay()
    rows = [MailItem(f"c{i}", True, False, text) for i, text in enumerate(["Odd mail", ROW])]

    _drive(
        ["read my mail", "quit"],
        display,
        {"read my mail": "read_mail"},
        read=lambda limit: rows,
        labels={"Odd mail": "unsure"},
    )

    assert display.sent[-1] == ("reply", "2 messages read, 1 unsure.")


def test_showing_a_category_reports_the_size_of_that_category_not_of_the_whole_digest():
    display = FakeDisplay()
    ads = ["Shop Co 50 percent off", "Shop Co free shipping"]
    rows = [MailItem(f"c{i}", True, False, text) for i, text in enumerate([*ads, ROW])]

    _drive(
        ["read my mail", "show the ads", "quit"],
        display,
        {"read my mail": "read_mail", "show the ads": "show_mail"},
        read=lambda limit: rows,
        labels=dict.fromkeys(ads, "promotion"),
        show_category="promotion",
    )

    assert display.sent[-1] == ("reply", "2 shown (promotion).")


def test_an_unrecognised_request_says_it_is_not_sure_and_does_not_pretend_to_think():
    display = FakeDisplay()

    _drive(["blah", "quit"], display)

    assert display.states == ["heard", "reply"]
    assert "not sure" in display.sent[-1][1].lower()


def test_a_failed_read_shows_the_failure_as_the_reply():
    display = FakeDisplay()

    def broken(limit: int) -> list[MailItem]:
        raise BrowserError("list never appeared")

    _drive(["read my mail", "quit"], display, {"read my mail": "read_mail"}, read=broken)

    assert display.sent[-1][0] == "reply"
    assert "list never appeared" in display.sent[-1][1]


def test_quitting_sends_nothing_and_the_loop_does_not_close_the_window():
    display = FakeDisplay()

    _drive(["quit"], display)

    assert display.sent == []
    assert not display.closed  # the command owns the window, not the loop


def test_no_window_is_the_default_and_the_loop_runs_without_one():
    _drive(
        ["what is the capital of France", "quit"], None, {"what is the capital of France": "ask"}
    )


# --- the voice reader tells the window when it starts listening --------------------


class _Recorder:
    def __init__(self, start_error: Exception | None = None) -> None:
        self.start_error = start_error

    def start(self) -> None:
        if self.start_error:
            raise self.start_error

    def stop(self) -> array:
        return array("h", [8000, -8000] * (SAMPLE_RATE // 2))


def _voice(lines: list[str], on_listen: Callable[[], None], recorder: Any = None) -> Callable:
    script = iter(lines)
    console = Console(file=io.StringIO(), force_terminal=False)
    return voice_input(
        lambda _p="": next(script),
        recorder or _Recorder(),
        lambda samples: "read my mail",
        console,
        on_listen=on_listen,
    )


def test_the_voice_reader_announces_listening_once_when_the_microphone_opens():
    calls: list[str] = []

    _voice(["", ""], lambda: calls.append("listening"))("pli> ")

    assert calls == ["listening"]


def test_a_typed_line_does_not_announce_listening():
    calls: list[str] = []

    _voice(["show the deadlines"], lambda: calls.append("listening"))("pli> ")

    assert calls == []


def test_a_microphone_that_cannot_open_does_not_announce_listening():
    from pli.voice import VoiceError

    calls: list[str] = []

    _voice(["", ""], lambda: calls.append("listening"), _Recorder(VoiceError("no mic")))("pli> ")

    assert calls == []


# --- the command ------------------------------------------------------------


def _settings() -> Settings:
    return Settings(_env_file=None, typesafe_api_key="", llm_api_key="")


def test_without_the_window_flag_the_display_module_is_never_imported(monkeypatch):
    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.delitem(sys.modules, "pli.display", raising=False)

    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert "pli.display" not in sys.modules


def test_the_window_flag_starts_the_window_and_closes_it_when_the_agent_ends(monkeypatch):
    import pli.display

    display = FakeDisplay()
    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.display, "Display", lambda: display)
    monkeypatch.setattr(cli.time, "sleep", lambda s: None)

    result = CliRunner().invoke(cli.app, ["agent", "--window"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert display.started and display.closed


def test_the_window_is_closed_even_when_the_loop_crashes(monkeypatch):
    import pli.agent.repl as repl
    import pli.display

    display = FakeDisplay()

    def boom(*args: Any, **kwargs: Any) -> None:
        raise RuntimeError("loop crashed")

    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.display, "Display", lambda: display)
    monkeypatch.setattr(cli.time, "sleep", lambda s: None)
    monkeypatch.setattr(repl, "run", boom)

    result = CliRunner().invoke(cli.app, ["agent", "--window"], input="quit\n")

    assert result.exit_code != 0
    assert display.closed


def test_a_window_that_cannot_open_is_a_note_and_the_agent_carries_on(monkeypatch):
    import pli.display

    display = FakeDisplay(alive=False)
    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.display, "Display", lambda: display)
    monkeypatch.setattr(cli.time, "sleep", lambda s: None)

    result = CliRunner().invoke(cli.app, ["agent", "--window"], input="quit\n")

    assert result.exit_code == 0, result.output
    assert "python -m pli.display" in result.output  # how to see why
    assert display.closed


def test_voice_and_window_together_tell_the_voice_reader_to_signal_the_window(monkeypatch):
    import pli.display
    import pli.voice

    display = FakeDisplay()
    seen: dict[str, Any] = {}

    def fake_builder(settings: Settings, console: Any, on_listen: Any = None) -> Callable:
        seen["on_listen"] = on_listen
        return lambda prompt: "quit"

    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.display, "Display", lambda: display)
    monkeypatch.setattr(pli.voice, "build_voice_input", fake_builder)
    monkeypatch.setattr(cli.time, "sleep", lambda s: None)

    result = CliRunner().invoke(cli.app, ["agent", "--voice", "--window"])

    assert result.exit_code == 0, result.output
    seen["on_listen"]()
    assert ("listening", "") in display.sent


@pytest.mark.parametrize("flag", [[], ["--voice"]])
def test_voice_alone_passes_no_signal_to_the_voice_reader(monkeypatch, flag):
    import pli.voice

    seen: dict[str, Any] = {}

    def fake_builder(settings: Settings, console: Any, on_listen: Any = None) -> Callable:
        seen["on_listen"] = on_listen
        return lambda prompt: "quit"

    monkeypatch.setattr(cli, "_settings", _settings)
    monkeypatch.setattr(pli.voice, "build_voice_input", fake_builder)

    result = CliRunner().invoke(cli.app, ["agent", *flag], input="quit\n")

    assert result.exit_code == 0, result.output
    assert seen.get("on_listen") is None
