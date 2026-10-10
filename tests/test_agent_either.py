"""A router torn between `ask` and `web` still answers.

Measured live: "Summarize the 2019 Nature paper '...' by Okonkwo and Lindqvist" is an `ask` at
confidence 0.65-0.71 (odds ask 0.7, web 0.25) when typed alone, but with any other question typed
just before it the confidence fell to 0.45-0.49 (ask 0.53, web 0.41), under the 0.6 floor, and the
student got "I'm not sure what you meant" for a perfectly clear question (24 of 24, against 0 of 8
alone). Over 360 calls on 180 questions a line typed before moved the unsure share only from 0.6%
to 1.1%, so it is rare - but `ask` and `web` are the two ways to answer, neither touches mail or
anything else, and an `ask` that is not sure of its facts searches the web by itself, so a split
between just those two is no reason to refuse.

**Only a split between those two.** The odds on `ask` and `web` together must be at least 0.9;
a router torn between `ask` and `none` ("Fix my code."), or that leans to a mail tool, is still
"not sure", and a confident choice is untouched.
"""

from __future__ import annotations

from typing import Any

import pytest
from typesafe_sdk import ChoiceAnswer, SystemOneResponse, Usage

from pli.agent.repl import Decision, decide
from pli.config import Settings
from pli.judge import Judge


class FakeJev:
    """Answers every tool question with the given choice, confidence and odds."""

    def __init__(self, choice: str, confidence: float, odds: dict[str, float]) -> None:
        self.answer = ChoiceAnswer(choice=choice, confidence=confidence, probabilities=odds)

    def system_one(self, state: Any, questions: Any, **_: Any) -> SystemOneResponse:
        answers: dict[str, Any] = {"__tool__": self.answer}
        if "show_mail.category" in questions:
            answers["show_mail.category"] = ChoiceAnswer(
                choice="all", confidence=0.95, probabilities={"all": 0.95}
            )
        return SystemOneResponse(
            model="jev-test", usage=Usage(input_tokens=1, output_tokens=1), answers=answers
        )


def _decide(choice: str, confidence: float, odds: dict[str, float], previous: str | None = None):
    judge = Judge(
        Settings(_env_file=None, typesafe_api_key="k"), client=FakeJev(choice, confidence, odds)
    )
    return decide(judge, "Summarize the 2019 Nature paper by Okonkwo and Lindqvist.", previous)


@pytest.mark.parametrize("previous", [None, "What is the capital of France?"])
def test_a_split_between_ask_and_web_answers_with_the_one_that_led(previous: str | None) -> None:
    assert _decide("ask", 0.45, {"ask": 0.53, "web": 0.41, "none": 0.06}, previous) == Decision(
        "ask"
    )
    assert _decide("web", 0.40, {"web": 0.50, "ask": 0.45, "none": 0.05}, previous) == Decision(
        "web"
    )


def test_the_two_must_hold_nine_tenths_of_the_odds() -> None:
    assert _decide("ask", 0.30, {"ask": 0.50, "web": 0.40, "none": 0.10}) == Decision("ask")
    assert _decide("ask", 0.30, {"ask": 0.50, "web": 0.39, "none": 0.11}) is None
    assert _decide("ask", 0.30, {"ask": 0.45, "web": 0.30, "none": 0.25}) is None


@pytest.mark.parametrize(
    ("choice", "odds"),
    [
        ("ask", {"ask": 0.55, "none": 0.45}),  # "Fix my code." - it should ask what code
        ("none", {"none": 0.5, "ask": 0.3, "web": 0.2}),
        ("read_mail", {"read_mail": 0.5, "ask": 0.25, "web": 0.25}),
        ("show_mail", {"show_mail": 0.40, "ask": 0.30, "web": 0.30}),
        ("deadlines", {"deadlines": 0.5, "ask": 0.3, "web": 0.2}),
        ("activity", {"activity": 0.5, "ask": 0.3, "web": 0.2}),
    ],
)
def test_any_other_doubt_is_still_not_sure(choice: str, odds: dict[str, float]) -> None:
    assert _decide(choice, 0.4, odds) is None


def test_a_leaning_to_a_tool_that_acts_is_not_overruled_by_ask_and_web_adding_up() -> None:
    """ask + web = 0.9 here, but the router's own choice was a mail tool."""
    assert _decide("read_mail", 0.1, {"read_mail": 0.1, "ask": 0.45, "web": 0.45}) is None


def test_a_confident_choice_is_what_it_was() -> None:
    assert _decide("ask", 0.9, {"ask": 0.9}) == Decision("ask")
    assert _decide("web", 0.9, {"web": 0.9}) == Decision("web")
    assert _decide("show_mail", 0.9, {"show_mail": 0.9}) == Decision("show_mail", "all")
    assert _decide("none", 0.9, {"none": 0.9}) is None


def test_a_missing_odds_table_is_not_a_guess() -> None:
    assert _decide("ask", 0.3, {}) is None
