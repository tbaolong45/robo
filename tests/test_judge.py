"""The judgement layer: what the model is allowed to decide, and what it is not.

This module asks a model about pages nobody documented, so the interesting
failures are not crashes - they are answers that look fine. Three rules are
pinned here because each one, broken, silently corrupts a calendar read:

**Batching is the interface.** One request carries every question. A question
asked alone is not merely slower; splitting a read across calls is how the same
state gets judged twice with different answers.

**A low-confidence answer must arrive as no answer.** `choice()` returning None
is the safety mechanism: the caller is required to read None as "cannot judge",
so a guess that leaks through here becomes a study block over a lecture. The same
goes the other way - an answer that is *dropped* rather than reported is
indistinguishable from a model that declined, so the response's one dict of
answers must be split by type without losing any of them.

**The model points, code reads.** `locate` returns the candidate's own text, not
the model's paraphrase of it, and an id that was never offered is discarded - the
model cannot put a subject line on the calendar that the page never showed.

Nothing here touches the network: the SDK is replaced by a canned client that
records what it was asked.
"""

from __future__ import annotations

from typing import Any

import pytest
from typesafe_sdk import (
    Choice,
    ChoiceAnswer,
    Noul,
    NoulAnswer,
    NoulCriteria,
    Score,
    ScoreAnswer,
    SystemOneResponse,
    TypeSafeError,
    Usage,
)

from pli.config import Settings
from pli.judge import (
    MAX_OPTIONS,
    MAX_QUESTIONS_PER_CALL,
    Candidate,
    Judge,
    JudgeError,
    Judgements,
    JudgeUnavailable,
    label_candidates,
    parse_clock,
)


def _settings(key: str = "test-key") -> Settings:
    return Settings(_env_file=None, typesafe_api_key=key, typesafe_model="jev-test")


class FakeTypeSafeClient:
    """A canned System One that records every question it was asked.

    The reply is built from the real SDK classes rather than a hand-rolled
    lookalike, so the shape `Judge` reads is the shape the service actually
    returns - including the single `answers` dict discriminated by `type`, which
    is the detail that decides whether an answer is found or silently dropped.
    """

    def __init__(
        self,
        *,
        answers: dict[str, Any] | None = None,
        model: str = "jev-test",
        error: Exception | None = None,
    ) -> None:
        self.answers = answers or {}
        self.model = model
        self.error = error
        self.calls: list[tuple[Any, dict[str, Any]]] = []

    def system_one(self, state: Any, questions: Any, **kwargs: Any) -> SystemOneResponse:
        self.calls.append((state, dict(questions)))
        if self.error is not None:
            raise self.error
        return SystemOneResponse(
            model=self.model,
            usage=Usage(input_tokens=100, output_tokens=5),
            answers=dict(self.answers),
        )

    @property
    def questions_asked(self) -> list[dict[str, Any]]:
        return [questions for _, questions in self.calls]


def _choice_answer(
    choice: str, confidence: float, probabilities: dict[str, float] | None = None
) -> ChoiceAnswer:
    return ChoiceAnswer(
        choice=choice,
        confidence=confidence,
        probabilities=probabilities if probabilities is not None else {choice: 1.0},
    )


def _candidate(id_: str, text: str, **geometry: float) -> Candidate:
    return Candidate(id=id_, text=text, **geometry)


# --- refusing to judge ------------------------------------------------------------


def test_a_missing_key_raises_unavailable_and_not_a_generic_error():
    """A caller that catches JudgeError must still see this as "cannot judge",
    but a caller distinguishing the two must be able to tell them apart."""
    judge = Judge(_settings(""))

    with pytest.raises(JudgeUnavailable) as caught:
        judge.ask("state", {"subject": Choice(instructions="which?", criteria={"C000": None})})

    assert type(caught.value) is JudgeUnavailable
    assert isinstance(caught.value, JudgeError)


def test_the_unavailable_message_says_which_key_and_where_to_get_one():
    judge = Judge(_settings(""))

    with pytest.raises(JudgeUnavailable) as caught:
        judge.ask("state", {})

    message = str(caught.value)
    assert "TYPESAFE_API_KEY" in message
    assert "console.typesafe.ai" in message


def test_a_library_error_becomes_unavailable_rather_than_leaking():
    """A 502 from the service is an outage, not a judgement - and a caller that
    had to handle TypeSafeError would eventually forget to."""
    client = FakeTypeSafeClient(error=TypeSafeError("502 from upstream"))
    judge = Judge(_settings(), client=client)

    with pytest.raises(JudgeUnavailable) as caught:
        judge.ask("state", {"subject": Choice(instructions="which?", criteria={"C000": None})})

    assert "TypeSafe call failed" in str(caught.value)
    assert isinstance(caught.value.__cause__, TypeSafeError)


# --- one request, many questions --------------------------------------------------


def test_ask_carries_every_question_in_a_single_call():
    """The state is ingested once and every question judged against it; twenty
    calls would cost twenty states and could disagree with each other."""
    client = FakeTypeSafeClient()
    judge = Judge(_settings(), client=client)
    questions = {
        name: Choice(instructions=f"which is the {name}?", criteria={"C000": None})
        for name in ("subject", "start", "end", "date")
    }

    judge.ask({"page": "calendar"}, questions)

    assert len(client.calls) == 1
    state, asked = client.calls[0]
    assert state == {"page": "calendar"}
    assert set(asked) == set(questions)


def test_questions_beyond_the_per_call_limit_are_split_not_dropped():
    """An oversized request fails as a whole, so it is split; every question
    must still be asked, and their answers still merged into one result."""
    client = FakeTypeSafeClient()
    judge = Judge(_settings(), client=client)
    total = MAX_QUESTIONS_PER_CALL + 3

    judge.ask("state", {f"q{i}": Noul(instructions="yes?") for i in range(total)})

    assert len(client.calls) == 2
    asked = [name for questions in client.questions_asked for name in questions]
    assert len(asked) == total
    assert set(asked) == {f"q{i}" for i in range(total)}


def test_usage_accumulates_across_the_split_calls():
    """The bill is the sum of what was sent; reporting only the last batch would
    understate the cost of every large read."""
    client = FakeTypeSafeClient()
    judge = Judge(_settings(), client=client)

    result = judge.ask(
        "state", {f"q{i}": Noul(instructions="yes?") for i in range(MAX_QUESTIONS_PER_CALL + 1)}
    )

    assert result.usage == {"input_tokens": 200, "output_tokens": 10}


# --- answers land in the right place ----------------------------------------------


def test_each_answer_type_lands_in_its_own_dict():
    """The SDK returns one `answers` dict discriminated by `type`. Reading it as
    the wrong answer class makes a real answer look like a model that declined,
    and a caller required to read "no answer" as "cannot judge" then plans study
    over a lecture - which is exactly the silent failure this pins down."""
    client = FakeTypeSafeClient(
        answers={
            "subject": _choice_answer("C003", 0.92, {"C003": 0.92, "C004": 0.08}),
            "allday": NoulAnswer(noul=0.11),
            "difficulty": ScoreAnswer(
                score=2.4, confidence=0.6, legend={1: "easy", 2: "hard"}, probabilities={2: 0.7}
            ),
        }
    )
    questions = {
        "subject": Choice(instructions="which?", criteria={"C003": None}),
        "allday": Noul(instructions="is it all day?"),
        "difficulty": Score(
            instructions="how hard is this material to study?",
            # Each level must stand on its own as a described situation; the SDK
            # rejects bare labels, and a level nobody can interpret is a level
            # the model has to guess at.
            criteria=[
                "easy: recalling a fact stated in the text is enough",
                "moderate: a method from the text has to be applied",
                "hard: it has to be derived from first principles",
            ],
        ),
    }

    result = Judge(_settings(), client=client).ask("state", questions)

    assert set(result.choices) == {"subject"}
    assert set(result.nouls) == {"allday"}
    assert set(result.scores) == {"difficulty"}
    assert result.choice("subject", minimum_confidence=0.9) == "C003"
    assert result.yes("allday") == 0.11
    assert result.score("difficulty") == 2.4


def test_a_score_answer_is_not_read_as_a_choice():
    """Cross-contamination is the same bug from the other side: a ScoreAnswer in
    `choices` would answer `choice()` with a rubric level the caller can use."""
    client = FakeTypeSafeClient(
        answers={
            "difficulty": ScoreAnswer(
                score=2.4, confidence=0.9, legend={1: "easy", 2: "hard"}, probabilities={2: 0.9}
            )
        }
    )

    result = Judge(_settings(), client=client).ask("state", {})

    assert result.choice("difficulty") is None
    assert result.ranked("difficulty") == []
    assert result.yes("difficulty") == 0.0


def test_the_model_and_usage_are_reported_back():
    client = FakeTypeSafeClient(answers={"q": NoulAnswer(noul=0.9)}, model="jev-latest")

    result = Judge(_settings(), client=client).ask("state", {"q": Noul(instructions="yes?")})

    assert result.model == "jev-latest"
    assert result.usage == {"input_tokens": 100, "output_tokens": 5}


def test_asking_nothing_costs_nothing():
    """A read that captures no candidates must not send an empty batch.

    The batch is the unit the user is billed for, so a request that cannot
    return an answer is a request that should not be made. The empty result it
    produces is the honest one, and callers already have to read "no answer" as
    "cannot judge"."""
    client = FakeTypeSafeClient()

    result = Judge(_settings(), client=client).ask("state", {})

    assert client.calls == []
    assert result.choice("anything") is None
    assert result.model == ""


def test_an_empty_response_is_an_empty_result_and_not_an_error():
    result = Judge(_settings(), client=FakeTypeSafeClient()).ask("state", {})

    assert result.choices == {}
    assert result.nouls == {}
    assert result.scores == {}


# --- the confidence floor ---------------------------------------------------------


def test_a_choice_below_the_floor_is_reported_as_no_answer():
    """The whole safety mechanism: an unsure answer must not reach the planner,
    because once it is a datetime there is nothing left to be unsure about."""
    result = Judgements(choices={"start": _choice_answer("C001", 0.41, {"C001": 0.41})})

    assert result.choice("start", minimum_confidence=0.8) is None
    assert result.choice("start", minimum_confidence=0.4) == "C001"


def test_an_exactly_confident_answer_clears_the_floor():
    """The floor is inclusive; otherwise a caller asking for 1.0 could never be
    satisfied by a model that is certain."""
    result = Judgements(choices={"start": _choice_answer("C001", 1.0)})

    assert result.choice("start", minimum_confidence=1.0) == "C001"


def test_a_question_that_was_never_answered_has_no_choice():
    assert Judgements().choice("start", minimum_confidence=0.0) is None


def test_ranked_lists_every_option_above_the_floor_most_likely_first():
    result = Judgements(
        choices={
            "slot": _choice_answer(
                "C001", 0.7, {"C003": 0.1, "C001": 0.7, "C002": 0.5, "C004": 0.05}
            )
        }
    )

    assert result.ranked("slot", minimum=0.2) == [("C001", 0.7), ("C002", 0.5)]
    assert result.ranked("slot", minimum=0.0)[0] == ("C001", 0.7)
    assert [name for name, _ in result.ranked("slot")] == ["C001", "C002", "C003", "C004"]


def test_ranked_is_empty_when_there_is_no_answer():
    assert Judgements().ranked("slot", minimum=0.0) == []


def test_probability_of_an_unanswered_question_is_zero():
    result = Judgements(choices={"slot": _choice_answer("C001", 0.7, {"C001": 0.7})})

    assert result.probability("slot", "C001") == 0.7
    assert result.probability("slot", "C009") == 0.0
    assert result.probability("nothing", "C001") == 0.0


# --- yes/no and score -------------------------------------------------------------


def test_yes_reads_the_noul_probability_rather_than_deciding():
    """The caller owns the threshold; what counts as certain enough to move a
    deadline is policy, not this module's call."""
    result = Judgements(nouls={"moved": 0.73, "cancelled": 0.2})

    assert result.yes("moved") == 0.73
    assert result.is_yes("moved", minimum=0.7) is True
    assert result.is_yes("moved", minimum=0.8) is False
    assert result.is_yes("cancelled") is False


def test_a_missing_noul_name_is_zero_rather_than_an_error():
    """A question the model skipped is "no evidence of yes", not a crash in the
    middle of a read."""
    result = Judgements()

    assert result.yes("never-asked") == 0.0
    assert result.is_yes("never-asked") is False


def test_score_returns_the_rubric_level_or_none():
    result = Judgements(
        scores={
            "difficulty": ScoreAnswer(
                score=2.4, confidence=0.6, legend={1: "easy", 2: "hard"}, probabilities={2: 0.7}
            )
        }
    )

    assert result.score("difficulty") == 2.4
    assert result.score("never-asked") is None


def test_confirm_returns_the_raw_probability():
    client = FakeTypeSafeClient(answers={"confirm": NoulAnswer(noul=0.88)})

    assert Judge(_settings(), client=client).confirm("state", question="did it move?") == 0.88


# --- locate: the model points, code reads -----------------------------------------


def test_locate_returns_the_candidates_own_text_verbatim():
    """A paraphrase is a value the model wrote; only the candidate's text is a
    value the page showed."""
    candidates = [
        _candidate("C000", "Mon 5 Oct", x=0, y=0),
        _candidate("C001", "2:00 pm", x=0, y=40),
    ]
    client = FakeTypeSafeClient(
        answers={"target": _choice_answer("C001", 0.91, {"C001": 0.91, "C000": 0.09})}
    )

    found = Judge(_settings(), client=client).locate(
        "state", question="which is the start time?", candidates=candidates
    )

    assert found is not None
    assert found.text == "2:00 pm"
    assert found.candidate_id == "C001"
    assert found.confidence == 0.91
    assert str(found) == "2:00 pm"


def test_locate_offers_the_candidate_ids_as_the_options():
    """The model can only name what it was given, so the option map is the
    entire space of answers."""
    candidates = [_candidate("C000", "Mon 5 Oct"), _candidate("C001", "2:00 pm")]
    client = FakeTypeSafeClient(answers={"target": _choice_answer("C001", 0.9)})

    Judge(_settings(), client=client).locate(
        "state", question="which is the start time?", candidates=candidates
    )

    state, questions = client.calls[0]
    assert state == "state"
    assert set(questions["target"].criteria) == {"C000", "C001"}


def test_locate_discards_an_id_that_was_never_offered():
    """The model invented it - trusting that is how a subject line the page
    never showed gets onto the calendar."""
    candidates = [_candidate("C000", "Mon 5 Oct"), _candidate("C001", "2:00 pm")]
    client = FakeTypeSafeClient(answers={"target": _choice_answer("C999", 1.0)})

    assert (
        Judge(_settings(), client=client).locate(
            "state", question="which is the start time?", candidates=candidates
        )
        is None
    )


def test_locate_honours_the_confidence_floor():
    candidates = [_candidate("C000", "Mon 5 Oct"), _candidate("C001", "2:00 pm")]
    client = FakeTypeSafeClient(answers={"target": _choice_answer("C001", 0.3)})

    found = Judge(_settings(), client=client).locate(
        "state",
        question="which is the start time?",
        candidates=candidates,
        minimum_confidence=0.9,
    )

    assert found is None


def test_locate_asks_nothing_at_all_without_candidates():
    """An empty window is a normal state of the page, not a question."""
    client = FakeTypeSafeClient()

    assert (
        Judge(_settings(), client=client).locate(
            "state", question="which is the start time?", candidates=[]
        )
        is None
    )
    assert client.calls == []


def test_locate_refuses_more_candidates_than_the_service_accepts():
    """Jev caps a Choice question's options; sending more would be rejected
    after paying for the request, so it is refused here."""
    candidates = [_candidate(f"C{i:03d}", f"row {i}") for i in range(MAX_OPTIONS + 1)]

    with pytest.raises(JudgeError, match=str(MAX_OPTIONS)):
        Judge(_settings(), client=FakeTypeSafeClient()).locate(
            "state", question="which is the start time?", candidates=candidates
        )


def test_locate_accepts_exactly_the_option_limit():
    """Off-by-one in either direction loses a real question or sends a doomed
    one, so the boundary is checked rather than assumed."""
    candidates = [_candidate(f"C{i:03d}", f"row {i}") for i in range(MAX_OPTIONS)]
    client = FakeTypeSafeClient(answers={"target": _choice_answer("C254", 0.9)})

    found = Judge(_settings(), client=client).locate(
        "state", question="which is the start time?", candidates=candidates
    )

    assert found is not None
    assert found.candidate_id == "C254"


# --- label_candidates -------------------------------------------------------------


def test_label_candidates_prefixes_each_line_with_its_id():
    rendered = label_candidates([_candidate("C000", "Mon 5 Oct"), _candidate("C001", "2:00 pm")])

    assert rendered == "C000|Mon 5 Oct\nC001|2:00 pm"


def test_label_candidates_does_not_alter_the_text():
    """The label is added, the text is not touched - a normalised candidate
    would make `locate`'s verbatim guarantee meaningless."""
    awkward = _candidate("C007", "Q1: 50% | Q2: 50%\nand the answer is 42")

    rendered = label_candidates([awkward])

    assert rendered == "C007|Q1: 50% | Q2: 50%\nand the answer is 42"
    assert awkward.text in rendered


def test_label_candidates_of_nothing_is_empty():
    assert label_candidates([]) == ""


# --- parse_clock: deliberately narrow ---------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("10:00 AM", (10, 0)),
        ("14:30", (14, 30)),
        ("2:00pm", (14, 0)),
        ("9.15", (9, 15)),
        ("12:00 AM", (0, 0)),  # midnight, not noon
        ("12:00 PM", (12, 0)),  # noon, not midnight
        ("12:30am", (0, 30)),
        ("Starts 11:45 sharp", (11, 45)),
    ],
)
def test_parse_clock_reads_what_a_calendar_shows(text, expected):
    assert parse_clock(text) == expected


@pytest.mark.parametrize("text", ["10:0", "25:00", "", "tomorrow", "0:99", "10:60", ":30"])
def test_parse_clock_returns_none_for_anything_else(text):
    """None, never midnight. A silent default would move a class to 00:00 and
    hand the whole day to the packer as free time."""
    assert parse_clock(text) is None


def test_parse_clock_is_none_rather_than_midnight_for_a_missing_string():
    assert parse_clock(None) is None  # type: ignore[arg-type]


def test_parse_clock_does_not_read_a_time_out_of_a_longer_number():
    """A room number or a percentage is not a start time; `(?<!\\d)` is what
    keeps "1234:56" from being read as 34:56."""
    assert parse_clock("Room 1100") is None
    assert parse_clock("50:5050") is None


def test_parse_clock_never_returns_an_out_of_range_hour():
    """Whatever the regex accepts must still be a real clock time, since the
    caller builds a datetime out of it."""
    for hour in range(0, 30):
        for text in (f"{hour}:00", f"{hour}:30 AM", f"{hour}.45 PM"):
            parsed = parse_clock(text)
            if parsed is not None:
                assert 0 <= parsed[0] <= 23
                assert 0 <= parsed[1] <= 59


def test_noul_criteria_can_be_built_for_a_confirm_question():
    """`confirm` asks a Noul with no criteria; the SDK allows that, and a
    required criteria mapping here would make every yes/no question a crash."""
    assert NoulCriteria is not None
