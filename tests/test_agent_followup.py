"""Follow-ups like "and yesterday?": the router may see the PREVIOUS typed line, nothing more.

A bare follow-up cannot be routed from its own words, so the tool choice is also given the
line typed just before it. Measured with the real router: bare follow-ups routed 6 of 12
correctly without it and 12 of 12 with it, and unrelated previous lines did not hijack 12
independent requests either way.

What stays true is what the tool-choice step is for: it sees only what the *user typed*.
The previous request is a line the user typed (or said), never a mail row, a summary, an
activity count or something a model wrote, so a hostile message still cannot steer the
choice of tool.

Nothing here touches a network: the router is a recording fake.
"""

from __future__ import annotations

import io
from collections.abc import Iterator
from typing import Any

from rich.console import Console
from typesafe_sdk import ChoiceAnswer, SystemOneResponse, Usage

from pli.agent.repl import run
from pli.browser.mail import MailItem
from pli.config import Settings
from pli.judge import Judge

MAIL_ROW = "Prof Ada Quiz 3 moved to Friday Sat 4:15 PM Please note"


class RecordingJev:
    """Routes by the current line and records every tool-choice request it was shown."""

    def __init__(self, tool_for: dict[str, str] | None = None) -> None:
        self.tool_for = tool_for or {}
        self.states: list[dict[str, Any]] = []
        self.instructions: list[str] = []

    def system_one(self, state: Any, questions: Any, **_: Any) -> SystemOneResponse:
        if "__tool__" not in questions:  # a mail row being labelled
            answers = {
                "category": ChoiceAnswer(
                    choice="important", confidence=0.9, probabilities={"important": 0.9}
                ),
                "needs_action": __import__("typesafe_sdk").NoulAnswer(noul=0.1),
            }
        else:
            self.states.append(dict(state))
            self.instructions.append(questions["__tool__"].instructions)
            tool = self.tool_for.get(state["request"], "ask")
            answers = {
                "__tool__": ChoiceAnswer(choice=tool, confidence=0.95, probabilities={tool: 0.95}),
                "show_mail.category": ChoiceAnswer(
                    choice="all", confidence=0.95, probabilities={"all": 0.95}
                ),
            }
        return SystemOneResponse(
            model="jev-test", usage=Usage(input_tokens=1, output_tokens=1), answers=answers
        )


class FakeLLM:
    available = True

    def complete_json(self, system: str, user: str, **_: Any) -> dict[str, Any]:
        if '"answer"' in system:
            return {"answer": "MODEL-ANSWER-XYZ"}
        return {"summary": "SUMMARY-XYZ"}


def _drive(lines: list[str], tool_for: dict[str, str] | None = None) -> RecordingJev:
    script: Iterator[str] = iter(lines)

    def input_fn(_prompt: str = "") -> str:
        try:
            return next(script)
        except StopIteration:
            raise EOFError from None

    jev = RecordingJev(tool_for)
    judge = Judge(Settings(_env_file=None, typesafe_api_key="k"), client=jev)
    console = Console(file=io.StringIO(), width=120, force_terminal=False, color_system=None)
    run(
        judge,
        FakeLLM(),
        lambda limit: [MailItem("c1", True, False, MAIL_ROW)],
        limit=5,
        console=console,
        input_fn=input_fn,
    )
    return jev


def test_the_first_request_has_no_previous_one() -> None:
    jev = _drive(["what is a commit", "quit"])

    assert jev.states == [{"request": "what is a commit"}]


def test_a_later_request_carries_the_line_typed_just_before_it() -> None:
    jev = _drive(["what did I work on today", "and yesterday?", "quit"])

    assert jev.states == [
        {"request": "what did I work on today"},
        {"request": "and yesterday?", "previous_request": "what did I work on today"},
    ]


def test_only_the_one_line_before_is_carried_not_the_whole_history() -> None:
    jev = _drive(["one", "two", "three", "quit"])

    assert jev.states[2] == {"request": "three", "previous_request": "two"}


def test_help_and_quit_never_become_the_previous_request() -> None:
    jev = _drive(["what is a commit", "help", "and a branch?", "quit"])

    assert jev.states[-1] == {"request": "and a branch?", "previous_request": "what is a commit"}


def test_the_previous_request_is_what_was_typed_never_a_mail_row_or_a_model_answer() -> None:
    jev = _drive(
        ["check my mail", "what is a commit", "and a branch?", "quit"],
        {"check my mail": "read_mail", "what is a commit": "ask"},
    )

    shown = repr(jev.states)
    assert "MODEL-ANSWER-XYZ" not in shown and "SUMMARY-XYZ" not in shown
    assert MAIL_ROW not in shown
    assert jev.states[2]["previous_request"] == "what is a commit"


def test_the_tool_choice_is_told_how_to_use_the_previous_line_only_when_there_is_one() -> None:
    jev = _drive(["what is a commit", "and a branch?", "quit"])

    first, second = jev.instructions
    assert "previous_request" not in first
    assert "previous_request" in second and "follow-up" in second
