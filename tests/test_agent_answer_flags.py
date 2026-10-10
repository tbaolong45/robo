"""Two things the answer step does for itself, found by questions it had never been tuned on.

Measured on 90 fresh questions in 15 fields (84 good): the answer step was told "you cannot look
anything up in this answer ... tell them they can ask you to search the web", and it obeyed. 19 of
90 answers ended by asking the student to type "search the web for ...", including a law that had
changed on 1 May 2026 ("ask me to search the web for the current Section 21 rules"), and four
questions about papers, treaties and Acts that do not exist got "I can't look it up here" instead
of a look. So when the web is available the model may answer `{"search": true}` instead of an
answer, and the loop then does what a typed "search the web for ..." does.

**Only when the web is there.** With no web lookup the prompt does not offer the flag, and a
`search` reply is ignored like any other answerless reply.

**Only when it gave no answer.** A reply with an answer is the answer, whatever else it holds, and
only a true `search` counts (not "yes", not 1).

Also measured: in 3 of those 90 the reply was valid JSON whose answer simply stopped
("... (arigatō gozaimasu) means ") or was empty. The model began a quoted phrase with a bare `"`,
which closes the JSON string, and the provider's forced-JSON decoding filled in the rest (9 of 32
tries on one question; 0 of 32 when asked without JSON mode). Such a reply - empty, ending in a
space, an unclosed `**` / `(` / code block, or stopping mid-sentence - is asked for once more as
plain text, and whichever of the two is more complete is shown. An ending that is not a sentence
- a list, a formula, a code block, a one-word answer - is not a cut and costs nothing.

Nothing here touches the network: the model is a recording fake.
"""

from __future__ import annotations

import re
from typing import Any

import pytest

from pli.agent.repl import NeedsSearch, answer, answer_prompt
from pli.llm.client import LLMError, LLMFormatError


class FakeLLM:
    """Returns the next scripted reply (a whole JSON object, or an exception to raise)."""

    def __init__(self, *replies: Any, texts: list[Any] | None = None) -> None:
        self.replies = list(replies)
        self.texts = list(texts or [])  # what plain-text requests return, in order
        self.calls: list[tuple[str, str]] = []
        self.text_calls: list[tuple[str, str]] = []
        self.available = True

    def complete_json(self, system: str, user: str, **kwargs: Any) -> dict[str, Any]:
        self.calls.append((system, user))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply

    def complete_text(self, system: str, user: str, **kwargs: Any) -> str:
        self.text_calls.append((system, user))
        reply = self.texts.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


# --- the prompt ------------------------------------------------------------------------------


def test_with_the_web_the_prompt_offers_the_search_reply_and_never_tells_the_student_to_ask() -> (
    None
):
    prompt = answer_prompt(may_search=True)

    assert '"search"' in prompt and "true" in prompt
    assert 'the one key is instead "search": true' in prompt
    assert "that an authority states" in prompt
    assert "out of date in your memory" in prompt  # the cases it is for
    assert "do not recognise" in prompt  # papers, laws and books it has never heard of
    # a fact an authority states is checked against it even when the model thinks it remembers it
    for case in (
        "a law or rule",
        "a rate, fee or threshold",
        "a recommended amount",
        "a standard",
        "an official statistic",
        "a software version",
        "who holds a post",
        "a recent event or result",
    ):
        assert case in prompt
    assert re.search(r"Search even when you think you remember it", prompt)
    assert re.search(r"names a source to consult[^.]*CDC", prompt)  # "according to the CDC"
    # an idea, a method, a piece of writing or a fact that never changes is not looked up
    assert re.search(r"Do not search for explanations[^.]*that never change", prompt)
    assert 'ask you to "search the web for"' not in prompt
    assert "Never tell the student to ask you to search" in prompt


def test_without_the_web_the_prompt_neither_offers_the_reply_nor_points_the_student_to_it() -> None:
    prompt = answer_prompt()

    assert '"search"' not in prompt
    assert "search the web" not in prompt
    assert "cannot look anything up" in prompt
    assert prompt == answer_prompt(may_search=False)


def test_both_prompts_still_ask_for_the_one_answer_key() -> None:
    for may_search in (False, True):
        assert '"answer": your reply as plain text' in answer_prompt(may_search)


# --- the search reply ------------------------------------------------------------------------


def test_a_search_reply_with_no_answer_asks_for_the_web() -> None:
    llm = FakeLLM({"search": True})

    with pytest.raises(NeedsSearch):
        answer(llm, "Can a landlord still use Section 21?", [], None, may_search=True)

    assert len(llm.calls) == 1  # no second try, no lengthening


@pytest.mark.parametrize("empty", [None, "", "   "])
def test_an_empty_answer_next_to_a_search_reply_still_asks_for_the_web(empty: Any) -> None:
    with pytest.raises(NeedsSearch):
        answer(FakeLLM({"answer": empty, "search": True}), "q", [], None, may_search=True)


def test_a_reply_that_has_an_answer_is_the_answer_whatever_else_it_says() -> None:
    llm = FakeLLM({"answer": "Paris.", "search": True})

    assert answer(llm, "Capital of France?", [], None, may_search=True) == "Paris."


@pytest.mark.parametrize("not_true", ["true", "yes", 1, [True], {"a": 1}, False, None, 0])
def test_only_a_true_search_counts(not_true: Any) -> None:
    reply = answer(FakeLLM({"search": not_true}, texts=[""]), "q", [], None, may_search=True)

    assert reply == ""


def test_without_the_web_a_search_reply_is_just_a_reply_with_no_answer() -> None:
    assert answer(FakeLLM({"search": True}, texts=[""]), "q", [], None) == ""
    assert answer(FakeLLM({"search": True}, texts=[""]), "q", [], None, may_search=False) == ""


def test_a_search_reply_is_not_retried_as_a_cut_off_answer() -> None:
    llm = FakeLLM({"search": True}, {"answer": "never asked for"})

    with pytest.raises(NeedsSearch):
        answer(llm, "q", [], None, may_search=True)

    assert len(llm.calls) == 1


def test_the_prompt_the_model_is_sent_is_the_one_for_the_setting() -> None:
    on, off = FakeLLM({"answer": "a"}), FakeLLM({"answer": "a"})

    answer(on, "q", [], None, may_search=True)
    answer(off, "q", [], None)

    assert on.calls[0][0] == answer_prompt(may_search=True)
    assert off.calls[0][0] == answer_prompt()


# --- an answer that stops in the middle, or never started --------------------------------------


CUT = "The categorical imperative is Kant's test for whether an action is morally right. It's"
WHOLE = (
    "The categorical imperative is Kant's test for rightness. "
    "It says to act only on maxims you could will as law."
)


def test_the_plain_prompt_is_the_same_instruction_asking_for_text_not_json() -> None:
    plain = answer_prompt(plain=True)

    assert '"answer"' not in plain and "JSON" not in plain
    assert "plain text" in plain and "nothing else" in plain
    assert "pli" in plain and "never invent" in plain  # the same rules and identity
    assert '"search"' not in plain and "cannot look anything up" in plain
    assert answer_prompt(may_search=True, plain=True) == plain  # a retry never asks for the web


def test_an_answer_cut_off_mid_sentence_is_asked_for_once_more_as_plain_text() -> None:
    llm = FakeLLM({"answer": CUT}, texts=[WHOLE])

    assert answer(llm, "What is the categorical imperative?", [], None) == WHOLE
    assert len(llm.calls) == 1 and len(llm.text_calls) == 1
    system, user = llm.text_calls[0]
    assert system == answer_prompt(plain=True) and user == llm.calls[0][1]  # the same question


@pytest.mark.parametrize(
    "reply",
    [
        {"answer": ""},  # the answer began with a quotation mark
        {"answer": None},
        {"answer": ["Blot it.", "Do not rub."]},  # not text
        {"answer": "   "},
        {},
        {"search": True},  # an offer that was not accepted (no web lookup) is no answer either
    ],
)
def test_a_reply_with_no_answer_is_asked_for_once_more_as_plain_text(reply: Any) -> None:
    llm = FakeLLM(reply, texts=["Blot the stain with cold water and a clean cloth."])

    assert answer(llm, "How do I clean wine off a carpet?", [], None) == (
        "Blot the stain with cold water and a clean cloth."
    )
    assert len(llm.text_calls) == 1


@pytest.mark.parametrize(
    "raw",
    [
        "**ありがとうございます** (arigatō gozaimasu) means ",  # the string closed on a space
        "**Meaning:** ",
        "It means thank you\n",
        "It means thank you\t",
    ],
)
def test_an_answer_whose_string_ends_in_white_space_is_a_cut(raw: str) -> None:
    llm = FakeLLM({"answer": raw}, texts=["It means thank you very much."])

    assert answer(llm, "q", [], None) == "It means thank you very much."


@pytest.mark.parametrize(
    "text",
    [
        "**ありがとうございます** (arigatō gozaimasu) means **",  # a bold opened and never closed
        "Present tense with *seit* where English has the present perfect (",
        "Here is the **short version",
        "Run it like this:\n\n```python\nprint(1)",  # a code block never closed
        "The result (see the table below",
    ],
)
def test_an_unclosed_bold_bracket_or_code_block_is_a_cut(text: str) -> None:
    llm = FakeLLM({"answer": text}, texts=["A complete answer."])

    assert answer(llm, "q", [], None) == "A complete answer."


@pytest.mark.parametrize(
    "text",
    [
        "The **answer** is **Paris**.",
        "Done (see above).",
        "Use `x` here\n\n```python\nprint(1)\n```",
        "1) first 2) second",  # more ")" than "(" is just a list
        "Compute it:\n\n```python\nx = a ** b ** c\nprint(x\n```",  # code is not counted
        "A table:\n\n| a | b |\n| **x** | (y) |",
    ],
)
def test_closed_bold_brackets_and_code_blocks_are_not_a_cut(text: str) -> None:
    llm = FakeLLM({"answer": text}, texts=["must not be asked for"])

    assert answer(llm, "q", [], None) == text
    assert llm.text_calls == []


def test_if_the_plain_try_is_cut_off_too_the_more_complete_one_is_shown() -> None:
    longer = CUT + " also a very much longer stretch of words that stops"
    llm = FakeLLM({"answer": CUT}, texts=[longer])

    assert answer(llm, "q", [], None) == longer
    assert len(llm.text_calls) == 1  # one more try, not a loop


def test_if_the_plain_try_is_shorter_and_cut_the_first_is_kept() -> None:
    llm = FakeLLM({"answer": CUT}, texts=["It is a rule about what is morally right to do"])

    assert answer(llm, "q", [], None) == CUT


def test_a_whole_plain_try_beats_a_longer_one_that_is_cut() -> None:
    first = " ".join(["word"] * 40) + " and then"
    llm = FakeLLM({"answer": first}, texts=["A short but finished answer."])

    assert answer(llm, "q", [], None) == "A short but finished answer."


@pytest.mark.parametrize("second", [LLMError("HTTP 502"), "", "   "])
def test_if_the_plain_try_fails_or_has_nothing_the_first_is_kept(second: Any) -> None:
    assert answer(FakeLLM({"answer": CUT}, texts=[second]), "q", [], None) == CUT


def test_if_the_plain_try_gives_nothing_there_is_no_answer() -> None:
    assert answer(FakeLLM({"answer": ""}, texts=[""]), "q", [], None) == ""
    assert answer(FakeLLM({"answer": ""}, texts=["  "]), "q", [], None) == ""


def test_if_there_is_nothing_to_keep_and_the_plain_try_fails_the_failure_is_shown() -> None:
    with pytest.raises(LLMError, match="HTTP 502"):
        answer(FakeLLM({"answer": ""}, texts=[LLMError("HTTP 502")]), "q", [], None)


def test_a_search_reply_is_not_retried_as_a_cut_answer() -> None:
    llm = FakeLLM({"search": True}, texts=["never asked for"])

    with pytest.raises(NeedsSearch):
        answer(llm, "q", [], None, may_search=True)

    assert llm.text_calls == []


@pytest.mark.parametrize(
    "text",
    [
        "Paris",  # a one-word answer
        "It is Paris",  # three words, no full stop: short answers are not cut
        "It is 42",  # short, not a sentence
        "So x = 3",  # a formula's last line
        "The derivative is 3x^2 + 5",
        "Done.",
        "Is that right?",
        "The answer is 12.5%",
        "This line has no final stop at all\nBut this one ends properly.",  # only the end counts
        "* first, open the file and read it",
        "\u2022 first, open the file and read it",
        "> a quoted line that ends on a plain word",
        "# A heading of several plain words",
        "Steps:\n- first, open the file and read it\n- then close the file when you are done",
        "Steps:\n1. first, open the file and read it\n2. then close the file when you are done",
        "Use this:\n\n```python\nfor line in open(path):\n    print(line)\n```",
        "A table:\n\n| a | b |\n| one two three four | five six seven eight",
        'He said "stop"',
        "Total cost (including tax)",
        "That is the whole story…",
        "Bonjour, comment allez-vous ce matin mon ami.",
        "你好，很高兴见到你。",
        "The result is therefore 0.5",
    ],
)
def test_an_ending_that_is_not_a_cut_costs_no_second_request(text: str) -> None:
    llm = FakeLLM({"answer": text}, texts=["must not be asked for"])

    assert answer(llm, "q", [], None) == text.strip()
    assert llm.text_calls == []


@pytest.mark.parametrize(
    "text",
    [
        "The veil of ignorance is a thought experiment. He asks what people would agree to in an",
        "I don't recognise that act, and I have no reliable recollection of an",
        "The empire had been split on the death of Theodosius I, so there was no single",
        "First, you should consider the following options, and then",
        "The result depends on several factors:",
        "It is a rule that says you must always act as if",
        "First, you should consider the following options, and then,",
        "Check the file first, then rerun the test;",
        "The intro line is fine.\nThe second paragraph stops in the middle of an",
        "`open()` is the function you call to read a file and then",
    ],
)
def test_prose_that_stops_on_a_word_or_a_joining_mark_is_a_cut(text: str) -> None:
    llm = FakeLLM({"answer": text}, texts=["A complete second answer."])

    assert answer(llm, "q", [], None) == "A complete second answer."
    assert len(llm.text_calls) == 1


def test_an_empty_first_answer_is_asked_for_but_never_lengthened() -> None:
    llm = FakeLLM({"answer": ""}, texts=[""])

    assert answer(llm, "Write a 300-word essay.", [], None) == ""
    assert len(llm.calls) == 1 and len(llm.text_calls) == 1


def test_a_cut_answer_is_made_whole_before_it_is_checked_against_the_target_length() -> None:
    short_cut = " ".join(["word"] * 150) + " and then"
    whole = " ".join(["word"] * 295) + "."
    llm = FakeLLM({"answer": short_cut}, texts=[whole])

    assert answer(llm, "Write a 300-word essay on Rome.", [], None) == whole
    assert len(llm.calls) == 1 and len(llm.text_calls) == 1  # 295 of 300 needs no lengthening


# --- a reply that is not the object asked for ----------------------------------------------------


@pytest.mark.parametrize("error", [LLMFormatError("returned list"), LLMFormatError("not JSON")])
def test_a_reply_that_was_not_a_json_object_is_asked_for_again_as_plain_text(
    error: Exception,
) -> None:
    """The model answered `[{"answer": "..."}]`, or `["..."]`, and the student saw an error."""
    llm = FakeLLM(error, texts=["Article 21 protects the right to life and personal liberty."])

    assert answer(llm, "Which article?", [], None) == (
        "Article 21 protects the right to life and personal liberty."
    )
    assert llm.text_calls[0][0] == answer_prompt(plain=True)


def test_a_format_error_and_a_plain_try_with_nothing_is_no_answer() -> None:
    assert answer(FakeLLM(LLMFormatError("list"), texts=[""]), "q", [], None) == ""


def test_a_format_error_and_a_failing_plain_try_shows_the_failure() -> None:
    with pytest.raises(LLMError, match="HTTP 502"):
        answer(FakeLLM(LLMFormatError("list"), texts=[LLMError("HTTP 502")]), "q", [], None)


@pytest.mark.parametrize("error", [LLMError("HTTP 502"), LLMError("request failed: timeout")])
def test_any_other_failure_is_not_retried(error: Exception) -> None:
    llm = FakeLLM(error, texts=["never asked for"])

    with pytest.raises(LLMError):
        answer(llm, "q", [], None)

    assert llm.text_calls == []


def test_a_format_error_is_not_turned_into_a_web_search() -> None:
    llm = FakeLLM(LLMFormatError("list"), texts=["A plain answer."])

    assert answer(llm, "q", [], None, may_search=True) == "A plain answer."


# --- the language of the question ----------------------------------------------------------------


def test_with_earlier_turns_the_question_says_to_be_answered_in_its_own_language() -> None:
    """After Vietnamese and French questions an English one about a falling ball was answered in
    Vietnamese (12 of 30 tries; a Vietnamese maths question then a chemistry one: 2 of 30). A rule
    in the system prompt changed nothing (5 of 12); the same words beside the question: 3 of 30
    and 1 of 30."""
    llm = FakeLLM({"answer": "Fine."})

    answer(llm, "A ball is dropped from 45 m. How long?", [("Động năng?", "Là 9 J.")], None)

    user = llm.calls[0][1]
    note = "(reply in the language this question is written in; earlier messages may be in another"
    assert note in user
    assert user.splitlines()[-1].endswith(": A ball is dropped from 45 m. How long?")
    assert user.splitlines()[-1].index(note) < user.splitlines()[-1].index("A ball")


def test_with_no_earlier_turns_the_question_is_plain() -> None:
    llm = FakeLLM({"answer": "Fine."})

    answer(llm, "What is 2+2?", [], None)

    assert llm.calls[0][1].splitlines()[-1] == "Question: What is 2+2?"


def test_the_plain_try_asks_the_same_question_in_the_same_words() -> None:
    llm = FakeLLM({"answer": CUT}, texts=[WHOLE])

    answer(llm, "What is it?", [("Hỏi", "Đáp")], None)

    assert llm.text_calls[0][1] == llm.calls[0][1]
