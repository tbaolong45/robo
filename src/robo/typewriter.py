"""Typewriter reveal of Robo's reply. Qt-free and pure: the class never reads a clock.

A reply is a Markdown string that grows while Hermes streams it. `Typewriter` decides how much of
it is on screen at each moment; `markdown_prefix` turns "the first k characters" into a Markdown
string that renders cleanly (no `**` or empty bullets flashing by).

Schedule: every character gets a reveal time r[i] (seconds of "base pace"):
  * visible characters cost 1/cps (code-block characters 1/(cps*code_speed));
  * Markdown syntax costs nothing. An opening mark (`**`, a backtick, `[`, `- `, `## `, a ```fence
    line) is revealed WITH the next visible character, a closing mark (`**`, `](url)`, the closing
    fence) WITH the previous one, so a prefix never ends inside a mark;
  * pauses (added before the NEXT character): after . ? ! and an ellipsis 0.20 s, after , ; :
    0.07 s, after a newline 0.08 s, after a blank line 0.18 s; none inside code blocks.
Playback: a position `played` (schedule seconds) moves at 1x, faster when Hermes is ahead of the
reveal: speed = clamp(backlog / time constant, 1, cap). One rule, an exponential catch-up, so a
long reply eases back to base pace instead of ending in a flash.
"""

from __future__ import annotations

import bisect
import math
import os
import re
import unicodedata
from dataclasses import dataclass


@dataclass(frozen=True)
class Pace:
    cps: float = 55.0  # visible characters per second; 0 = instant
    sentence: float = 0.20  # extra seconds after . ? ! … (when followed by a break or a closer)
    clause: float = 0.07  # after , ; : followed by a space
    line: float = 0.08  # after a newline
    para: float = 0.18  # after a blank line
    code_speed: float = 2.2  # code blocks type this many times faster
    lag: float = 2.0  # time constant of the catch-up while Hermes streams (s)
    max_stream: float = 6.0  # speed cap while streaming (x base)
    finish: float = 1.0  # time constant once the run has ended (s)
    max_finish: float = 8.0  # speed cap once the run has ended (x base)
    talk_gap: float = 0.11  # s after a visible character the mouth keeps moving


# kinds of character
VISIBLE, OPENING, CLOSING = 0, 1, 2

_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_BLOCK = re.compile(r"^(?: {0,3}(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d{1,9}[.)][ \t]+))+")
_LINK = re.compile(r"\[[^\]\n]*\]\([^)\n]*\)?|\[[^\]\n]*$")
_INLINE = re.compile(r"\*\*|__|~~|`|\*(?=[^\s*])|(?<=[^\s*])\*")


def classify(text: str) -> tuple[list[int], list[bool]]:
    """(kind, in_code) per character of `text`."""
    n = len(text)
    kind, code = [VISIBLE] * n, [False] * n
    pos, in_fence, fence_mark = 0, False, ""
    for line in text.split("\n"):
        end = pos + len(line) + 1  # the line and its newline (the last line has none)
        span = range(pos, min(end, n))
        m = _FENCE.match(line)
        closes = bool(
            in_fence and m and m.group(1)[0] == fence_mark[0]
            and len(m.group(1)) >= len(fence_mark) and not line.strip(" `~")
        )
        if (m and not in_fence) or closes:
            in_fence = not in_fence
            fence_mark = m.group(1) if in_fence else ""
            for i in span:
                kind[i], code[i] = (OPENING if in_fence else CLOSING), True
        elif in_fence:
            for i in span:
                code[i] = True
        else:
            bm = _BLOCK.match(line)
            start = bm.end() if bm else 0
            for i in range(pos, pos + start):
                kind[i] = OPENING
            taken = [False] * len(line)  # characters already claimed by a link
            for lm in _LINK.finditer(line):
                a, z = lm.start(), lm.end()
                close = line.find("](", a, z)
                kind[pos + a] = OPENING
                taken[a] = True
                if close >= 0:
                    for j in range(close, z):
                        kind[pos + j], taken[j] = CLOSING, True
            state: dict[str, bool] = {}
            for im in _INLINE.finditer(line, start):
                a = im.start()
                if taken[a] or (im.group() == "*" and bm and a < start):
                    continue
                tok = im.group()
                if state.get("`") and tok != "`":
                    continue  # literal inside a code span
                state[tok] = not state.get(tok, False)
                role = OPENING if state[tok] else CLOSING
                for j in range(a, im.end()):
                    kind[pos + j] = role
        pos = end
    return kind, code


_ZWJ = "\u200d"
_PARTIAL = frozenset("*_~`#>+-")  # could be the first half of a Markdown mark


def _glue(ch: str, prev: str, ri: int) -> bool:
    """Marks, skin tones, ZWJ, what follows a ZWJ and the 2nd half of a flag ride with the previous
    character. `ri` = length of the run of regional indicators that ends with `ch`."""
    return (
        unicodedata.category(ch) in ("Mn", "Me", "Cf", "Sk")
        or prev == _ZWJ
        or (0x1F1E6 <= ord(ch) <= 0x1F1FF and ri % 2 == 0)
    )


def schedule(text: str, pace: Pace, final: bool) -> tuple[list[float], list[int], list[bool]]:
    """(reveal time, kind, in_code) per character. Times never decrease; math.inf = not before
    more text arrives. Needs pace.cps > 0 (Typewriter handles 0 itself)."""
    kind, code = classify(text)
    n = len(text)
    if not final:  # the other half of a mark may still be on its way: `-` of `- `, `*` of `**`
        i = n
        while i and text[i - 1] in _PARTIAL and kind[i - 1] == VISIBLE:
            i -= 1
            kind[i] = OPENING
    r = [0.0] * n
    t, carry, prev, ri = 0.0, 0.0, "", 0
    for i, ch in enumerate(text):
        if kind[i]:
            continue
        ri = ri + 1 if 0x1F1E6 <= ord(ch) <= 0x1F1FF else 0
        step = 1.0 / pace.cps / (pace.code_speed if code[i] else 1.0)
        if _glue(ch, prev, ri):
            step = 0.0
        t += step + carry
        r[i] = t
        nxt = text[i + 1] if i + 1 < n else " "  # the stream's end counts as a break
        carry = 0.0
        if code[i]:
            carry = 0.03 if ch == "\n" else 0.0
        elif ch == "\n":
            carry = 0.0 if nxt == "\n" else (pace.para if prev == "\n" else pace.line)
        elif ch in ".?!…" and (nxt.isspace() or nxt in "\"')*_"):
            carry = pace.sentence
        elif ch in ",;:" and nxt.isspace():
            carry = pace.clause
        prev = ch
    ahead = math.inf  # opening marks wait for the next visible character
    for i in range(n - 1, -1, -1):
        if kind[i] == VISIBLE:
            ahead = r[i]
        elif kind[i] == OPENING:
            r[i] = ahead
    back = 0.0  # closing marks go with the previous visible character
    for i in range(n):
        if kind[i] == VISIBLE:
            back = r[i]
        elif kind[i] == CLOSING:
            r[i] = back
    top = 0.0
    for i in range(n):  # keep it non-decreasing (adjacent closing + opening marks)
        top = r[i] = max(top, r[i])
    if final:  # nothing more will come: marks that waited are revealed at the end
        m = bisect.bisect_left(r, math.inf)
        last = r[m - 1] if m else 0.0
        r = [last if x == math.inf else x for x in r]
    return r, kind, code


# --- Markdown of a prefix --------------------------------------------------------------------

_OPEN_LINK = re.compile(r"\[[^\]\n]*$")
_OPEN_URL = re.compile(r"\]\([^)\n]*$")
_FENCE_LINE = re.compile(r"(?m)^ {0,3}(?:```|~~~)")
WORD_MAX = 16  # characters of the current word that are laid out in advance (hidden)


def _closers(prefix: str) -> str:
    """Delimiters that make the unfinished last line of `prefix` well-formed."""
    if len(_FENCE_LINE.findall(prefix)) % 2:
        return ""  # inside a code block: the importer closes it at the end
    line = prefix.rsplit("\n", 1)[-1]
    stack: list[str] = []
    for m in _INLINE.finditer(line):
        tok = m.group()
        if "`" in stack and tok != "`":
            continue
        if tok in stack:
            del stack[stack.index(tok):]
        else:
            stack.append(tok)
    out = "".join(reversed(stack))
    if _OPEN_LINK.search(line):
        out = "](#)" + out if not stack else out + "](#)"
    elif _OPEN_URL.search(line):
        out = ")" + out
    return out


def markdown_prefix(text: str, kind: list[int], k: int) -> tuple[str, int]:
    """(markdown, hidden): `text[:k]` made renderable. The renderer lays out `hidden` more UTF-16
    units (the rest of the current word) and paints them transparent, so a word that will not fit
    the line wraps when its first letter appears, not when its last one does."""
    tail = []
    i = k
    while i < len(text) and kind[i] == VISIBLE and not text[i].isspace() and len(tail) < WORD_MAX:
        tail.append(text[i])
        i += 1
    rest = "".join(tail)
    body = text[:k] + rest
    close = _closers(body)
    cut = len(body.rstrip(" \t")) if close else len(body)  # `**bo **` is not a closed bold
    return body[:cut] + close + body[cut:], len(rest.encode("utf-16-le")) // 2  # UTF-16 units


# --- the player ------------------------------------------------------------------------------


class Typewriter:
    """Feed it the text received so far; call `advance(dt)` from a ~30 Hz timer."""

    def __init__(self, pace: Pace | None = None):
        self.pace = pace or Pace()
        self.clock = 0.0  # accumulated from advance(); the class never reads time
        self.reset()

    def reset(self) -> None:
        """A new exchange."""
        self.text = ""
        self.k = 0  # characters of `text` shown
        self.ended = self.skipped = False
        self.last_vis = -math.inf  # clock when a visible character last appeared
        self.played = self.total = 0.0  # schedule seconds played / planned
        self.r: list[float] = []  # reveal time per character
        self.kind: list[int] = []
        self._m = 0  # characters that have a finite reveal time

    @property
    def instant(self) -> bool:
        return self.skipped or self.pace.cps <= 0

    @property
    def started(self) -> bool:
        return self.k > 0

    @property
    def pending(self) -> bool:
        return self.k < len(self.text)

    @property
    def done(self) -> bool:
        return self.ended and not self.pending

    @property
    def waiting(self) -> bool:
        """Caught up with Hermes but the run goes on: the caret blinks."""
        return not self.ended and self.k >= self._m

    @property
    def revealing(self) -> bool:
        """A visible character appeared in the last `talk_gap` s: the mouth moves."""
        return self.clock - self.last_vis <= self.pace.talk_gap

    @property
    def fraction(self) -> float:
        return self.k / len(self.text) if self.text else 1.0

    def feed(self, text: str) -> None:
        """ALL the reply received so far (not just the new chunk)."""
        self._replan(text)

    def end(self, text: str | None = None) -> None:
        """The run is over; `text` is the final reply when it may differ from what streamed."""
        self.ended = True
        self._replan(self.text if text is None else text)

    def skip(self) -> None:
        """Click: show everything now, and everything that still arrives."""
        self.skipped = True
        self._replan(self.text)

    def set_pace(self, pace: Pace) -> None:
        """New speed (theme switch): re-plan and carry on from the character shown now."""
        self.pace = pace
        self._replan(self.text, anchor=True)

    def _replan(self, text: str, anchor: bool = False) -> None:
        old, self.text = self.text, text
        if not text.startswith(old):  # not an extension: re-type from the first difference
            self.k = min(self.k, len(os.path.commonprefix([old, text])))
            anchor = True
        if self.instant:
            self.k, self._m = len(text), len(text)
            self.r, self.kind, self.total = [], [], 0.0
            return
        self.r, self.kind, _ = schedule(text, self.pace, self.ended)
        self._m = bisect.bisect_left(self.r, math.inf)
        self.total = self.r[self._m - 1] if self._m else 0.0
        if anchor:  # the schedule moved under us: play from the last character shown
            self.played = min(self.total, self.r[self.k - 1]) if self.k else 0.0

    def advance(self, dt: float) -> bool:
        """Move `dt` seconds on; True when more text is now visible."""
        self.clock += dt
        if self.k >= self._m:
            return False
        p = self.pace
        backlog = self.total - self.played
        if self.ended:
            speed = min(p.max_finish, max(1.0, backlog / p.finish))
        else:
            speed = min(p.max_stream, max(1.0, backlog / p.lag))
        self.played = min(self.total, self.played + dt * speed)
        k = bisect.bisect_right(self.r, self.played)
        if k <= self.k:
            return False
        if VISIBLE in self.kind[self.k:k]:
            self.last_vis = self.clock
        self.k = k
        return True

    def view(self) -> tuple[str, int]:
        """(markdown, hidden UTF-16 units) to render now. The finished reply is returned as is."""
        if self.done or self.pace.cps <= 0:
            return self.text, 0
        return markdown_prefix(self.text, self.kind, self.k)
