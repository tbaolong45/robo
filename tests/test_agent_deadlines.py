"""The `deadlines` tool: what is due, ticked off by number, kept on this computer.

A sixth tool lets the typed line reach a local deadline tracker the command provides (a
`DeadlinesPort`). The tracker reads the LMS notices in the inbox rows; this loop only hands it
the rows the read tool fetched, asks it for the list, and passes on "mark 2 done". Rules
pinned here:

**No model touches the deadline list.** The tool is chosen from the typed line alone; what
to do with it - list, mark, undo - is decided in code from that same line; and the list is
printed, never sent to Jev or to DeepSeek. It works with no LLM key and makes no request.

**A number alone is not a mark.** Marking needs a number AND a done verb; undoing needs a
number AND an undo word, and undo wins when both are there. Anything else shows the list.

**Mail-derived titles are untrusted text.** Every line and sentence is stripped of control
characters and escaped before it is printed. Whatever the tracker returns is also never
fed back into a tool choice.

**A deadline problem never costs the mail or the session.** A tracker that fails while
recording leaves the digest on screen; one that fails on a list or a mark is reported.

Nothing here touches a network, a browser or a database: the models and the tracker are fakes.
"""

from __future__ import annotations

import io
import sqlite3
from collections.abc import Iterable, Iterator
from typing import Any

import pytest
from rich.console import Console
from typesafe_sdk import ChoiceAnswer, NoulAnswer, SystemOneResponse, Usage

from pli.agent import repl
from pli.agent.repl import run
from pli.browser.mail import MailItem
from pli.config import Settings
from pli.judge import Judge

TITLE = "SENTINEL-TITLE-5521"
SUMMARY_LINE = "This week: 1 of 3 handled."
LISTING = [
    "Overdue",
    f"  1. {TITLE} - was due Mon 05 Oct 09:00",
    "Due soon",
    "  2. Lab 6 Submission - due Fri 09 Oct 10:15",
    SUMMARY_LINE,
]
MARKED = "Marked 2. Lab 6 Submission as done."
NO_KEY = "LLM_API_KEY is not set"
NOT_AVAILABLE = "Deadline tracking is not available in this session."
ROW_DUE = "LMS Due on Friday, 9 October 2026, 10:15 AM: Lab 6 Submission Wed 10:45 AM Reminder"
ROW_QUIZ = "Prof Ada Quiz 3 moved to Friday Sat 4:15 PM Please note"
MAIL_SUMMARY = "SENTINEL-MAIL-SUMMARY quiz moved"
_UNSET: Any = object()


class FakeJev:
    """Routes a typed line to a tool by lookup, records what it was shown, labels mail."""

    def __init__(
        self, tool_for: dict[str, str], default: str = "deadlines", confidence: float = 0.95
    ) -> None:
        self.tool_for, self.default, self.confidence = tool_for, default, confidence
        self.states: list[Any] = []

    def system_one(self, state: Any, questions: Any, **_: Any) -> SystemOneResponse:
        self.states.append(state)
        if "__tool__" in questions:
            tool = self.tool_for.get(state["request"], self.default)
            answers: dict[str, Any] = {
                "__tool__": ChoiceAnswer(
                    choice=tool, confidence=self.confidence, probabilities={tool: 0.9}
                ),
                "show_mail.category": ChoiceAnswer(
                    choice="all", confidence=0.95, probabilities={"all": 0.95}
                ),
            }
        else:
            answers = {
                "category": ChoiceAnswer(
                    choice="deadline", confidence=0.95, probabilities={"deadline": 0.95}
                ),
                "needs_action": NoulAnswer(noul=0.1),
            }
        return SystemOneResponse(
            model="jev-test", usage=Usage(input_tokens=1, output_tokens=1), answers=answers
        )


class FakeLLM:
    """Counts every request. A question is told from a mail summary by `"answer"`."""

    def __init__(self, *, available: bool = True) -> None:
        self.available = available
        self.calls: list[tuple[str, str]] = []

    def complete_json(self, system: str, user: str, **_: Any) -> dict[str, Any]:
        self.calls.append((system, user))
        if '"answer"' in system:
            return {"answer": "An answer."}
        return {"summary": MAIL_SUMMARY}

    @property
    def users(self) -> list[str]:
        return [user for _, user in self.calls]

    @property
    def ask_users(self) -> list[str]:
        return [user for system, user in self.calls if '"answer"' in system]


class FakeDisplay:
    def __init__(self) -> None:
        self.sent: list[tuple[str, str]] = []

    def send(self, state: str, text: str = "") -> None:
        self.sent.append((state, text))


class View:
    def __init__(self, lines: list[str]) -> None:
        self.lines = lines


class FakeDeadlines:
    """The tracker the command provides: records every call, returns canned text."""

    def __init__(
        self,
        *,
        lines: list[str] | None = None,
        found: tuple[int, int] = (0, 0),
        sentence: str = MARKED,
        record_error: Exception | None = None,
        error: Exception | None = None,
    ) -> None:
        self.lines = LISTING if lines is None else lines
        self.found, self.sentence = found, sentence
        self.record_error, self.error = record_error, error
        self.records: list[list[MailItem]] = []
        self.shows = 0
        self.marks: list[tuple[int, bool]] = []

    def record_rows(self, rows: Any) -> tuple[int, int]:
        self.records.append(list(rows))
        if self.record_error:
            raise self.record_error
        return self.found

    def show(self) -> View:
        self.shows += 1
        if self.error:
            raise self.error
        return View(list(self.lines))

    def mark(self, number: int, undo: bool = False) -> str:
        self.marks.append((number, undo))
        if self.error:
            raise self.error
        return self.sentence

    @property
    def untouched(self) -> bool:
        return not (self.records or self.shows or self.marks)


class Result:
    def __init__(self, out: str, jev: FakeJev, llm: FakeLLM, reads: list[int]) -> None:
        self.out, self.jev, self.llm, self.reads = out, jev, llm, reads
        self.marks: list[int] = []


def _drive(
    lines: Iterable[str],
    *,
    tool_for: dict[str, str] | None = None,
    default: str = "deadlines",
    confidence: float = 0.95,
    llm: FakeLLM | None = None,
    deadlines: Any = _UNSET,
    display: FakeDisplay | None = None,
    mail: list[MailItem] | None = None,
) -> Result:
    script: Iterator[str] = iter(lines)
    marks: list[int] = []
    buffer = io.StringIO()

    def input_fn(_prompt: str = "") -> str:
        marks.append(buffer.tell())
        try:
            return next(script)
        except StopIteration:
            raise EOFError from None

    reads: list[int] = []

    def read(limit: int) -> list[MailItem]:
        reads.append(limit)
        if mail is not None:
            return mail
        return [MailItem("c1", True, False, ROW_QUIZ), MailItem("c2", False, False, ROW_DUE)]

    jev = FakeJev(tool_for or {}, default, confidence)
    llm = llm or FakeLLM()
    judge = Judge(Settings(_env_file=None, typesafe_api_key="k"), client=jev)
    console = Console(file=buffer, width=300, force_terminal=False, color_system=None)
    extra: dict[str, Any] = {} if deadlines is _UNSET else {"deadlines": deadlines}
    run(judge, llm, read, limit=5, console=console, input_fn=input_fn, display=display, **extra)
    result = Result(buffer.getvalue(), jev, llm, reads)
    result.marks = marks
    return result


def _turn(result: Result, n: int) -> str:
    """The output printed between prompt `n` and the next one."""
    end = result.marks[n + 1] if n + 1 < len(result.marks) else len(result.out)
    return result.out[result.marks[n] : end]


# --- the tool list -------------------------------------------------------------------------


def test_deadlines_has_its_own_tool_line_and_show_mail_keeps_to_emails():
    deadlines = repl.TOOLS["deadlines"].lower()
    for word in ("due", "overdue", "done", "number"):
        assert word in deadlines
    assert "deadline emails" in repl.TOOLS["show_mail"]
    assert "show the deadlines" not in repl.TOOLS["show_mail"]
    for action in ("send", "reply", "delete", "move", "open"):
        assert action in repl.TOOLS["none"]
    assert "general knowledge" in repl.TOOLS["ask"]


# --- the list ------------------------------------------------------------------------------


def test_a_deadline_question_prints_the_list_and_runs_no_model():
    deadlines, display = FakeDeadlines(), FakeDisplay()

    result = _drive(["what is due", "quit"], deadlines=deadlines, display=display)

    assert deadlines.shows == 1 and deadlines.marks == [] and deadlines.records == []
    for row in LISTING:
        assert row in result.out
    assert result.llm.calls == [] and result.reads == []
    assert display.sent == [("heard", "what is due"), ("reply", SUMMARY_LINE)]


def test_the_list_works_with_no_llm_key_and_does_not_mention_one():
    result = _drive(
        ["what is due", "quit"], deadlines=FakeDeadlines(), llm=FakeLLM(available=False)
    )

    assert SUMMARY_LINE in result.out
    assert NO_KEY not in result.out
    assert result.llm.calls == []


@pytest.mark.parametrize(
    "line",
    [
        "what is due this week",
        "show the deadlines",
        "how am I doing this week",
        "what is overdue",
        "what do I still have to hand in",
        "what is due in 2 days",  # a number, but no done verb
        "show me item 3",
        "list the deadlines for 9 October",
        "what have I finished",  # a done verb, but no number
        "mark everything done",
        "I am done",
        "someone finished",  # "one" inside a word is not a number
        "none of them",
        "mark 100 done",  # only 1-99
        "mark 0 done",
        "mark 07 done",
        # a number that belongs to a title, not to the list: "lab 6" is not item 6
        "I finished lab 6",
        "mark lab 6 done",
        "quiz 4 is done",
        # negations never mark
        "I haven't finished 3",
        "don't mark 3 done",
        "I havent finished 3",  # typed without the apostrophe
        "dont mark 3 done",
        "I haven\u2019t finished 3",  # a curly apostrophe, as phones and word processors type it
        "I cannot mark 3 done",
        # a number that is not next to the verb
        "what do I still have to finish in 2 days",
    ],
)
def test_anything_that_is_not_a_number_and_a_verb_shows_the_list(line):
    deadlines = FakeDeadlines()

    _drive([line, "quit"], deadlines=deadlines)

    assert deadlines.shows == 1
    assert deadlines.marks == []


# --- marking and undoing -------------------------------------------------------------------


@pytest.mark.parametrize(
    ("line", "number"),
    [
        ("mark 2 as done", 2),
        ("mark 2 done", 2),
        ("Mark 2 Done", 2),
        ("tick off number one", 1),
        ("mark number two as done", 2),
        ("I have handled 12", 12),
        ("submitted 3", 3),
        ("3 is complete", 3),
        ("number 4 completed", 4),
        ("2 finished", 2),
        ("please finish 5", 5),
        ("ticked 7", 7),
        ("marked 8", 8),
        ("done with ten", 10),
        ("mark 99 done", 99),
        ("2 done", 2),  # a bare "N done" at the start of the line
        ("and 3 is done", 3),
        ("mark item 2 done", 2),
        ("done with 4", 4),
        ("I have finished #2", 2),
    ],
)
def test_a_number_and_a_done_verb_marks_that_item(line, number):
    deadlines, display = FakeDeadlines(), FakeDisplay()

    result = _drive([line, "quit"], deadlines=deadlines, display=display)

    assert deadlines.marks == [(number, False)]
    assert deadlines.shows == 0
    assert MARKED in result.out
    assert display.sent == [("heard", line), ("reply", MARKED)]
    assert result.llm.calls == []


@pytest.mark.parametrize("line", ["mark 2 and 3 done", "On 9 October I finished lab 6", "done 1 2"])
def test_several_numbers_with_a_marking_verb_are_refused_one_at_a_time(line):
    deadlines, display = FakeDeadlines(), FakeDisplay()

    result = _drive([line, "quit"], deadlines=deadlines, display=display)

    assert deadlines.marks == [] and deadlines.shows == 0
    assert "One at a time" in _turn(result, 0)
    assert display.sent[-1][0] == "reply" and "One at a time" in display.sent[-1][1]


@pytest.mark.parametrize("line", ["I finished lab 6", "mark lab 6 done", "I haven't finished 3"])
def test_a_marking_attempt_that_names_no_list_item_shows_the_list_and_how_to_mark(line):
    deadlines = FakeDeadlines()

    result = _drive([line, "quit"], deadlines=deadlines)

    assert deadlines.shows == 1 and deadlines.marks == []
    assert "mark 2 done" in _turn(result, 0)  # the how-to for this turn, not the greeting


@pytest.mark.parametrize("line", ["what is due this week", "show the deadlines", "what is overdue"])
def test_a_plain_question_about_the_list_gets_no_marking_how_to(line):
    result = _drive([line, "quit"], deadlines=FakeDeadlines())

    assert "mark 2 done" not in _turn(result, 0)


@pytest.mark.parametrize(
    ("line", "number"),
    [
        ("undo 3", 3),
        ("reopen number four", 4),
        ("unmark 5", 5),
        ("mark 3 as not done", 3),  # both words: undo wins
        ("item 2 is not done", 2),
        ("mark 2 undone", 2),
        ("undo marking 6 as done", 6),
        ("UNDO 9", 9),
    ],
)
def test_a_number_and_an_undo_word_reopens_that_item(line, number):
    deadlines = FakeDeadlines()

    _drive([line, "quit"], deadlines=deadlines)

    assert deadlines.marks == [(number, True)]
    assert deadlines.shows == 0


def test_the_sentence_the_tracker_returns_is_what_is_printed_and_shown():
    deadlines, display = FakeDeadlines(sentence="Nothing to undo for 3."), FakeDisplay()

    result = _drive(["undo 3", "quit"], deadlines=deadlines, display=display)

    assert "Nothing to undo for 3." in result.out
    assert display.sent[-1] == ("reply", "Nothing to undo for 3.")


# --- untrusted text ------------------------------------------------------------------------


def test_titles_in_the_list_are_not_printed_raw():
    hostile = "  1. \x1b[2J[bold red]WIPED[/bold red] [link=http://x]click[/link] - due Fri 09 Oct"
    deadlines = FakeDeadlines(lines=[hostile, SUMMARY_LINE])

    result = _drive(["show the deadlines", "quit"], deadlines=deadlines)

    assert "\x1b" not in result.out
    assert "[bold red]WIPED[/bold red]" in result.out  # printed as text, not styled
    assert "[link=http://x]click[/link]" in result.out


def test_the_marked_sentence_is_not_printed_raw():
    deadlines = FakeDeadlines(sentence="Marked \x07\x1b[31m[bold red]X[/bold red] as done.")

    result = _drive(["mark 1 done", "quit"], deadlines=deadlines)

    assert "\x1b" not in result.out and "\x07" not in result.out
    assert "[bold red]X[/bold red]" in result.out


def test_a_long_title_does_not_lose_its_due_date_to_the_row_cut():
    line = f"  12. {'x' * repl.ROW_WIDTH} - was due Wed 09 Sep 10:15"
    deadlines = FakeDeadlines(lines=[line, SUMMARY_LINE])

    result = _drive(["show the deadlines", "quit"], deadlines=deadlines)

    assert "was due Wed 09 Sep 10:15" in result.out


def test_a_line_is_still_cut_at_some_limit():
    deadlines = FakeDeadlines(lines=["y" * 1000, SUMMARY_LINE])

    result = _drive(["show the deadlines", "quit"], deadlines=deadlines)

    assert "y" * 1000 not in result.out
    assert "…" in result.out


def test_a_line_break_in_a_title_cannot_fake_a_second_row():
    deadlines = FakeDeadlines(lines=["  1. Lab\n  2. Fake - due soon", SUMMARY_LINE])

    result = _drive(["show the deadlines", "quit"], deadlines=deadlines)

    assert "  1. Lab  2. Fake - due soon" in result.out
    assert "\n  2. Fake" not in result.out


# --- no tracker, or a tracker that fails ---------------------------------------------------


@pytest.mark.parametrize("passed", [None, _UNSET])
def test_with_no_tracker_it_says_so_and_runs_nothing(passed):
    display = FakeDisplay()

    result = _drive(["what is due", "quit"], deadlines=passed, display=display)

    assert NOT_AVAILABLE in result.out
    assert result.llm.calls == [] and result.reads == []
    assert display.sent == [("heard", "what is due"), ("reply", NOT_AVAILABLE)]


@pytest.mark.parametrize("line", ["what is due", "mark 2 done", "undo 2"])
def test_a_tracker_that_fails_is_reported_and_the_session_carries_on(line):
    display = FakeDisplay()
    deadlines = FakeDeadlines(error=sqlite3.OperationalError("database is locked [x]"))

    result = _drive([line, line, "quit"], deadlines=deadlines, display=display)

    assert result.out.count("Could not read the deadline list: database is locked [x]") == 2
    assert [state for state, _ in display.sent] == ["heard", "reply", "heard", "reply"]
    assert "database is locked" in display.sent[-1][1]
    assert result.llm.calls == []


def test_an_error_message_is_not_printed_raw_either():
    deadlines = FakeDeadlines(error=OSError("bad \x1b[2J[bold red]path[/bold red]"))

    result = _drive(["what is due", "quit"], deadlines=deadlines)

    assert "\x1b" not in result.out
    assert "[bold red]path[/bold red]" in result.out


# --- the tracker is only used for its tool -------------------------------------------------


@pytest.mark.parametrize("tool", ["ask", "show_mail", "activity", "none"])
def test_the_tracker_is_never_touched_for_another_tool(tool):
    deadlines = FakeDeadlines()

    _drive(
        ["read my mail", "a request", "quit"],
        tool_for={"read my mail": "ask", "a request": tool},
        deadlines=deadlines,
    )

    assert deadlines.untouched


def test_an_unsure_choice_does_not_touch_the_tracker():
    deadlines = FakeDeadlines()

    result = _drive(["what is due", "mark 2 done", "quit"], confidence=0.3, deadlines=deadlines)

    assert deadlines.untouched
    assert "not sure" in result.out.lower()


def test_leaving_the_argument_out_does_not_change_mail_reading():
    result = _drive(["read my mail", "quit"], tool_for={"read my mail": "read_mail"})

    assert "2 messages." in result.out
    assert "Deadline" not in result.out


# --- recording from the mail ---------------------------------------------------------------


def _read(**kwargs: Any) -> Result:
    return _drive(["read my mail", "quit"], tool_for={"read my mail": "read_mail"}, **kwargs)


def test_reading_mail_hands_the_fetched_rows_to_the_tracker_once():
    deadlines = FakeDeadlines()

    _read(deadlines=deadlines)

    assert len(deadlines.records) == 1
    rows = deadlines.records[0]
    assert all(isinstance(r, MailItem) for r in rows)
    assert {(r.id, r.text) for r in rows} == {("c1", ROW_QUIZ), ("c2", ROW_DUE)}
    assert deadlines.shows == 0 and deadlines.marks == []


def test_found_notices_are_counted_in_one_dim_line_and_the_window_hears_nothing_extra():
    display = FakeDisplay()

    result = _read(deadlines=FakeDeadlines(found=(3, 2)), display=display)

    assert "Deadline notices found: 3 (2 new). Say 'what is due' to see them." in result.out
    assert result.out.count("Deadline notices found") == 1
    assert display.sent == [
        ("heard", "read my mail"),
        ("thinking", ""),
        ("reply", "2 messages read."),
    ]


def test_no_notices_means_no_line():
    result = _read(deadlines=FakeDeadlines(found=(0, 0)))

    assert "Deadline notices" not in result.out
    assert ROW_QUIZ in result.out  # the digest itself is untouched


def test_the_digest_is_printed_exactly_as_without_a_tracker():
    with_tracker = _read(deadlines=FakeDeadlines(found=(1, 1))).out
    without = _read().out

    assert with_tracker.startswith(without.rstrip("\n"))


def test_a_tracker_that_fails_while_recording_keeps_the_digest_and_the_session():
    """A locked or unwritable database must cost the deadline notes, never the mail."""
    display = FakeDisplay()
    deadlines = FakeDeadlines(record_error=sqlite3.OperationalError("database is locked"))

    result = _drive(
        ["read my mail", "show everything", "quit"],
        tool_for={"read my mail": "read_mail", "show everything": "show_mail"},
        deadlines=deadlines,
        display=display,
    )

    first = _turn(result, 0)
    assert ROW_QUIZ in first and ROW_DUE in first  # the digest was printed
    assert "database is locked" in first and "Deadline notices" not in first
    assert ROW_QUIZ in _turn(result, 1)  # the mail was kept: `show everything` found it
    assert ("reply", "2 messages read.") in display.sent
    assert "Traceback" not in result.out


def test_a_recording_error_message_is_not_printed_raw():
    deadlines = FakeDeadlines(record_error=OSError("bad \x1b[2J[bold red]path[/bold red]"))

    result = _read(deadlines=deadlines)

    assert "\x1b" not in result.out
    assert "[bold red]path[/bold red]" in result.out


def test_a_failed_read_records_nothing():
    from pli.browser import BrowserError

    deadlines = FakeDeadlines()
    script = iter(["read my mail", "quit"])
    judge = Judge(
        Settings(_env_file=None, typesafe_api_key="k"),
        client=FakeJev({"read my mail": "read_mail"}),
    )

    def broken(limit: int) -> list[MailItem]:
        raise BrowserError("not signed in")

    buffer = io.StringIO()
    run(
        judge,
        FakeLLM(),
        broken,
        limit=5,
        console=Console(file=buffer, width=300, color_system=None),
        input_fn=lambda _prompt="": next(script),
        deadlines=deadlines,
    )

    assert "not signed in" in buffer.getvalue()
    assert deadlines.untouched


# --- privacy: the list goes nowhere but the screen -----------------------------------------


def test_the_tool_choice_sees_only_the_typed_line_never_a_title():
    deadlines = FakeDeadlines(sentence=f"Marked 1. {TITLE} as done.", found=(2, 2))

    result = _drive(
        ["read my mail", "what is due", "mark 1 done", "show everything", "quit"],
        tool_for={
            "read my mail": "read_mail",
            "what is due": "deadlines",
            "mark 1 done": "deadlines",
            "show everything": "show_mail",
        },
        deadlines=deadlines,
    )

    decisions = [s for s in result.jev.states if isinstance(s, dict)]
    assert decisions == [
        {"request": "read my mail"},
        {"request": "what is due", "previous_request": "read my mail"},
        {"request": "mark 1 done", "previous_request": "what is due"},
        {"request": "show everything", "previous_request": "mark 1 done"},
    ]
    assert TITLE not in repr(result.jev.states)
    assert "This week" not in repr(result.jev.states)


def test_the_list_and_the_marked_sentence_are_never_sent_to_the_answering_model():
    deadlines = FakeDeadlines(sentence=f"Marked 1. {TITLE} as done.", found=(2, 2))

    result = _drive(
        ["read my mail", "what is due", "mark 1 done", "which emails need action", "quit"],
        tool_for={
            "read my mail": "read_mail",
            "what is due": "deadlines",
            "mark 1 done": "deadlines",
            "which emails need action": "ask",
        },
        deadlines=deadlines,
    )

    assert len(result.llm.ask_users) == 1
    assert TITLE not in "".join(result.llm.users)
    assert "This week" not in "".join(result.llm.users)
    assert "Assistant:" not in result.llm.ask_users[0]  # the list is not remembered as a chat
    assert "Deadline notices" not in "".join(result.llm.users)


def test_the_tracker_is_not_given_what_the_models_wrote():
    deadlines = FakeDeadlines(found=(1, 1))

    _read(deadlines=deadlines)

    assert MAIL_SUMMARY not in repr(deadlines.records)


# --- the greeting --------------------------------------------------------------------------


def test_the_greeting_mentions_deadlines_and_keeps_the_read_only_promise():
    result = _drive(["help", "quit"], deadlines=FakeDeadlines())
    greeting = " ".join(_turn(result, 0).split())  # however the console wrapped it

    assert "mail agent" in greeting and "only read" in greeting
    assert "what is due" in greeting and "mark 2 done" in greeting
    assert "note" in greeting and "this computer" in greeting
    assert "mailbox" in greeting
