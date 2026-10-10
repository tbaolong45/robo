"""Split Hermes's `[[feel:x]]` emotion tags out of streamed reply text."""

from __future__ import annotations

import re

from robo.events import EMOTIONS, Delta, Event, Feeling

_TAG = re.compile(r"\[\[feel:([^\[\]]*)\]\]")
_OPEN = "[[feel:"
_CAP = 40  # longest text held while it might still become a tag


def _emotion(raw: str) -> str:
    e = raw.strip().lower()
    return e if e in EMOTIONS else "neutral"


def _partial(s: str) -> bool:
    """True if `s` could still grow into a complete tag."""
    if len(s) >= _CAP:
        return False
    if len(s) <= len(_OPEN):
        return _OPEN.startswith(s)
    return re.fullmatch(r"\[\[feel:[^\[\]]*\]?", s) is not None


class FeelingFilter:
    """Turn reply deltas into one leading `Feeling`, then tag-free `Delta`s (plus mood shifts)."""

    def __init__(self) -> None:
        self._buf = ""
        self._mood: str | None = None  # None until the leading Feeling is out
        self._skip = False  # drop one space/newline after the leading tag

    def feed(self, delta: str) -> list[Event]:
        self._buf += delta
        return self._drain(final=False)

    def finish(self) -> list[Event]:
        return self._drain(final=True)

    def _drain(self, final: bool) -> list[Event]:
        out: list[Event] = []
        if self._mood is None:
            s = self._buf.lstrip()
            m = _TAG.match(s)
            if m:
                self._buf, self._skip = s[m.end():], True
                self._mood = _emotion(m.group(1))
            elif _partial(s) and not final:
                return out
            else:
                self._mood = "neutral"
            out.append(Feeling(self._mood))
        if self._skip and self._buf:
            if self._buf[0] in " \n":
                self._buf = self._buf[1:]
            self._skip = False
        return out + self._body(final)

    def _body(self, final: bool) -> list[Event]:
        out: list[Event] = []
        buf, pos = self._buf, 0
        for m in _TAG.finditer(buf):
            if m.start() > pos:
                out.append(Delta(buf[pos:m.start()]))
            pos = m.end()
            mood = m.group(1).strip().lower()
            if mood in EMOTIONS and mood != self._mood:
                self._mood = mood
                out.append(Feeling(mood))
        rest = buf[pos:]
        cut = len(rest) if final else next(
            (i for i, c in enumerate(rest) if c == "[" and _partial(rest[i:])), len(rest))
        if cut:
            out.append(Delta(rest[:cut]))
        self._buf = rest[cut:]
        return out


def strip_tags(text: str) -> str:
    """Remove every feel tag from a complete reply."""
    return _TAG.sub("", text).strip()
