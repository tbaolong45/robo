"""Typed judgements about whatever the browser captured.

This is the module that makes reading Microsoft's web UI survivable. The pages
are undocumented, restyled without notice, and full of content that only makes
sense to a person: "Quiz 3 moved to Friday" is a deadline change, "lol" is not,
and both are just text in a div. Selectors break on the first redesign; a
judgement about meaning does not.

Two rules keep this honest:

**The model reads, code computes.** Ask which candidate text is a start time and
what month it names; never ask "what datetime is this". Calendar arithmetic,
timezones and DST belong to Python, where they are testable and correct.

**The model points, it does not write.** A question is answered by naming one of
a closed set of options that code supplied. Nothing here can invent a subject
line or a date that was not on the page.

Every question is a `Choice` or a `Noul` over state that code assembled, and the
answers are probabilities, so a caller can decline to act rather than guess.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from pli.config import Settings

__all__ = [
    "MAX_OPTIONS",
    "MAX_QUESTIONS_PER_CALL",
    "Candidate",
    "Judge",
    "JudgeError",
    "JudgeUnavailable",
    "Judgements",
    "Verbatim",
    "label_candidates",
    "parse_clock",
]

#: Jev's per-request ceiling on a Choice question's options.
MAX_OPTIONS = 255
#: Choice questions are cheaper to batch than to sequence - one request with
#: many questions beats many requests with one. Past this many questions the
#: call is split, so a single oversized request cannot fail the whole read.
MAX_QUESTIONS_PER_CALL = 120


class JudgeError(RuntimeError):
    """The judgement could not be made; the message says what to do."""


class JudgeUnavailable(JudgeError):
    """No API key, or the service could not be reached.

    Callers must treat this as "cannot judge", never as "judged no". A calendar
    read that silently returns nothing because the judge was down would tell the
    planner the week is empty and fill it with study blocks.
    """


@dataclass(frozen=True)
class Candidate:
    """One piece of text captured from a page, with where it sat on screen.

    `text` is verbatim: the model points at candidates, and code reads the
    answer back out of `text`. Anything normalised or paraphrased here would be
    a value the model chose rather than one the page showed.
    """

    id: str
    text: str
    #: Screen geometry in CSS pixels, used by code to group candidates into
    #: rows and columns. The model never sees these.
    x: float = 0.0
    y: float = 0.0
    width: float = 0.0
    height: float = 0.0

    @property
    def row(self) -> int:
        """A coarse row band, so items on one line can be compared."""
        return int(self.y // 8)


@dataclass(frozen=True)
class Verbatim:
    """A value copied out of a candidate, with the evidence for it.

    `text` is sliced from the original candidate rather than regenerated, and
    `confidence` is the model's own - so a caller can require certainty before
    letting the value reach the planner.
    """

    text: str
    candidate_id: str
    confidence: float

    def __str__(self) -> str:
        return self.text


@dataclass
class Judgements:
    """Answers from one call, keyed by the names the caller chose."""

    choices: dict[str, Any] = field(default_factory=dict)
    nouls: dict[str, float] = field(default_factory=dict)
    scores: dict[str, Any] = field(default_factory=dict)
    model: str = ""
    usage: dict[str, int] = field(default_factory=dict)

    def choice(self, name: str, *, minimum_confidence: float = 0.0) -> str | None:
        """The chosen option, or None when the model was not sure enough.

        Returning None is the point: an unsure answer must reach the caller as
        "no answer", not as a plausible-looking wrong one.
        """
        answer = self.choices.get(name)
        if answer is None or answer.confidence < minimum_confidence:
            return None
        return answer.choice

    def probability(self, name: str, option: str) -> float:
        answer = self.choices.get(name)
        if answer is None:
            return 0.0
        return float(answer.probabilities.get(option, 0.0))

    def ranked(self, name: str, *, minimum: float = 0.0) -> list[tuple[str, float]]:
        """Every option above `minimum`, most likely first.

        Used where the question is "which of these" and more than one may
        qualify - the candidates that clear the bar, not a single winner.
        """
        answer = self.choices.get(name)
        if answer is None:
            return []
        pairs = [(opt, float(p)) for opt, p in answer.probabilities.items() if p >= minimum]
        return sorted(pairs, key=lambda pair: (-pair[1], pair[0]))

    def yes(self, name: str) -> float:
        return float(self.nouls.get(name, 0.0))

    def is_yes(self, name: str, *, minimum: float = 0.5) -> bool:
        return self.yes(name) >= minimum

    def score(self, name: str) -> float | None:
        """The probability-weighted level on an ordered scale, or None.

        Returned as a number rather than a label because the legend belongs to
        the question, not to the answer, and only the caller knows what its own
        levels mean.
        """
        answer = self.scores.get(name)
        return None if answer is None else float(answer.score)


def label_candidates(candidates: Sequence[Candidate]) -> str:
    """Render candidates as an id-prefixed block for the model to point into.

    The `C000| ` prefix is the whole mechanism: it gives the model something to
    name and gives code something to match, without the text being touched. The
    format is deliberately awkward to produce by accident, so a line the page
    happens to start with "C000|" cannot be mistaken for a label.
    """
    return "\n".join(f"{c.id}|{c.text}" for c in candidates)


def _option_map(candidates: Sequence[Candidate], *, descriptions: bool = False) -> dict[str, Any]:
    """Choice options keyed by candidate id.

    Descriptions are omitted by default - the text is already in the state, and
    repeating it in the criteria doubles the tokens for no extra signal.
    """
    if not descriptions:
        return {c.id: None for c in candidates}
    return {c.id: c.text for c in candidates}


def _absorb(response: Any, into: Judgements) -> None:
    """Merge one response's answers into `into`, each type into its own dict.

    The SDK returns ONE dict of answers discriminated by `type`. Splitting it
    here is what keeps a lost answer class from looking like a model that
    declined to answer: a ScoreAnswer read as a Choice would leave `choice()` at
    None, and callers are required to read None as "cannot judge" - which for a
    calendar read means "the week is free". Token counts accumulate, because a
    split call really did cost all of its requests.
    """
    into.model = response.model or ""
    usage = response.usage
    into.usage = {
        "input_tokens": into.usage.get("input_tokens", 0)
        + int(getattr(usage, "input_tokens", 0) or 0),
        "output_tokens": into.usage.get("output_tokens", 0)
        + int(getattr(usage, "output_tokens", 0) or 0),
    }
    for name, answer in (response.answers or {}).items():
        kind = getattr(answer, "type", "")
        if kind == "choice":
            into.choices[name] = answer
        elif kind == "noul":
            into.nouls[name] = float(answer.noul)
        elif kind == "score":
            into.scores[name] = answer


class Judge:
    """Asks Jev typed questions about captured page content.

    Constructed once per run. Holds no state between calls: every question is
    answered from the `state` passed with it, so a judgement can always be
    re-derived from what the page showed.
    """

    def __init__(self, settings: Settings, *, client: Any | None = None) -> None:
        self.settings = settings
        self._client = client

    # --- transport --------------------------------------------------------------

    def _build_client(self) -> Any:
        if self._client is not None:
            return self._client
        if not self.settings.typesafe_api_key:
            raise JudgeUnavailable(
                "TYPESAFE_API_KEY is not set, so page content cannot be judged. "
                "Create a key at https://console.typesafe.ai/keys and put it in "
                ".env as TYPESAFE_API_KEY=<key>."
            )
        try:
            from typesafe_sdk import TypeSafeClient
        except ImportError as exc:  # pragma: no cover - dependency is declared
            raise JudgeUnavailable(f"typesafe-sdk is not installed: {exc}") from exc
        self._client = TypeSafeClient(
            api_key=self.settings.typesafe_api_key,
            model=self.settings.typesafe_model,
            timeout=self.settings.typesafe_timeout,
        )
        return self._client

    def ask(
        self,
        state: Any,
        questions: Mapping[str, Any],
    ) -> Judgements:
        """One request, many questions.

        Batching is not an optimisation to add later: the model ingests the
        state once and evaluates every question against it in parallel, so
        asking twenty questions in one call is dramatically cheaper and faster
        than asking them one at a time.
        """
        from typesafe_sdk import TypeSafeError

        client = self._build_client()
        merged = Judgements()
        items = list(questions.items())
        # One request per MAX_QUESTIONS_PER_CALL questions. A read that asks one
        # question per captured message can exceed what a single request accepts,
        # and an oversized request fails the whole batch - so it is split rather
        # than sent and hoped for. Under the limit this loop runs exactly once.
        for offset in range(0, len(items), MAX_QUESTIONS_PER_CALL):
            batch = dict(items[offset : offset + MAX_QUESTIONS_PER_CALL])
            try:
                response = client.system_one(state, batch)
            except TypeSafeError as exc:
                raise JudgeUnavailable(f"TypeSafe call failed: {exc}") from exc
            _absorb(response, merged)
        return merged

    # --- the shape used by the browser readers ----------------------------------

    def locate(
        self,
        state: Any,
        *,
        question: str,
        candidates: Sequence[Candidate],
        name: str = "target",
        minimum_confidence: float = 0.0,
    ) -> Verbatim | None:
        """Ask which candidate is the one the question describes.

        The answer is looked up back in `candidates` and the original text
        returned, so the value is the page's own and not a paraphrase. An
        answer naming an id that was not offered is discarded rather than
        trusted - that would mean the model invented it.
        """
        if not candidates:
            return None
        if len(candidates) > MAX_OPTIONS:
            raise JudgeError(
                f"{len(candidates)} candidates exceeds the {MAX_OPTIONS}-option limit; "
                "narrow the window before asking"
            )
        from typesafe_sdk import Choice

        result = self.ask(
            state,
            {
                name: Choice(instructions=question, criteria=_option_map(candidates)),
            },
        )
        chosen = result.choice(name, minimum_confidence=minimum_confidence)
        if chosen is None:
            return None
        by_id = {c.id: c for c in candidates}
        match = by_id.get(chosen)
        if match is None:
            return None
        answer = result.choices.get(name)
        return Verbatim(
            text=match.text,
            candidate_id=match.id,
            confidence=float(getattr(answer, "confidence", 0.0)),
        )

    def asks(
        self,
        state: Any,
        *,
        questions: Mapping[str, str],
        candidates: Sequence[Candidate],
        minimum_confidence: float = 0.0,
    ) -> dict[str, Verbatim | None]:
        """Several `which candidate` questions in one call.

        This is how a calendar row is read: subject, start, end and date are
        four independent questions over the same handful of candidates, so they
        cost one request between them rather than four.
        """
        if not candidates:
            return dict.fromkeys(questions)
        from typesafe_sdk import Choice

        result = self.ask(
            state,
            {
                name: Choice(instructions=text, criteria=_option_map(candidates))
                for name, text in questions.items()
            },
        )
        by_id = {c.id: c for c in candidates}
        found: dict[str, Verbatim | None] = {}
        for name in questions:
            chosen = result.choice(name, minimum_confidence=minimum_confidence)
            match = by_id.get(chosen) if chosen else None
            answer = result.choices.get(name)
            found[name] = (
                Verbatim(
                    text=match.text,
                    candidate_id=match.id,
                    confidence=float(getattr(answer, "confidence", 0.0)),
                )
                if match
                else None
            )
        return found

    def confirm(
        self,
        state: Any,
        *,
        question: str,
        name: str = "confirm",
    ) -> float:
        """A yes/no judgement, returning the probability of yes.

        The raw probability is returned rather than a bool so the caller owns
        the threshold. What counts as certain enough to move a deadline is a
        policy decision, not this module's.
        """
        from typesafe_sdk import Noul

        return self.ask(state, {name: Noul(instructions=question)}).yes(name)


#: Matches a clock time as a page would show it, so code can tell "the model
#: pointed at something that is not a time" from a usable reading.
_CLOCK_RE = re.compile(r"(?<!\d)(\d{1,2})[:.](\d{2})\s*(am|pm)?", re.IGNORECASE)


def parse_clock(text: str) -> tuple[int, int] | None:
    """Read an hour and minute out of a candidate's text.

    Deliberately narrow: it accepts what a calendar shows and nothing else. A
    candidate that does not parse is not a start time, and the caller treats it
    that way rather than falling back to midnight - which would silently move a
    class to 00:00 and free the whole day for study blocks.
    """
    match = _CLOCK_RE.search(text or "")
    if match is None:
        return None
    hour, minute = int(match.group(1)), int(match.group(2))
    meridiem = (match.group(3) or "").lower()
    if meridiem == "pm" and hour != 12:
        hour += 12
    elif meridiem == "am" and hour == 12:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return hour, minute
