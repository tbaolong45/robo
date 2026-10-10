"""A small status window that follows the voice agent: idle, listening, heard, thinking, reply.

The terminal REPL blocks on `input()` and on 30-120 s browser reads, so a window cannot
share its thread. The window is therefore a separate child process (`python -m pli.display`,
run by the same interpreter as the terminal, because only the project's venv has Tk) and
the terminal stays the main program: it writes one JSON line per state change to the
child's stdin and carries on.

The window has no controls and shows one circle, one word and two short texts: what was
heard and what the agent answered. Its position and stacking are the window manager's
business - a plain app cannot pin itself on top under Wayland - so the user places it once.

Rules:

1. **Nothing untrusted reaches the window raw.** Mail and model text go through `clean`
   (control characters removed, so an escape sequence cannot do anything; blank-line runs
   collapsed; cut to a length) before `encode` puts it on the wire, and `parse_line`
   cleans it again on arrival.
2. **The window can never break the terminal.** `Display.start`, `send` and `close` never
   raise. No Tk, no display, a closed window, a broken pipe or a child that has exited
   each turn the display off for good, silently; the REPL carries on as if there were no
   window.
3. **A message is one line, and a bad one is ignored.** `parse_line` returns `None` for
   anything that is not a well-formed message, so a garbled line cannot kill the window.
   An unknown state means "idle" on both sides.
4. **Importing this module needs no Tk and no display.** `tkinter` is imported inside
   `main`, which only the child runs. Without Tk or a display the child writes one line
   to stderr and exits 1, with no traceback.
5. **The window never outlives the terminal.** It closes when its stdin reaches EOF, which
   `Display.close` causes (and the OS causes if the terminal dies). The child ignores
   Ctrl-C, which the terminal's process group would otherwise deliver to it as well; its
   lifetime is the terminal's decision, not the keyboard's.

What each state does to the text is `apply_state`; how the circle breathes is
`pulse_radius`. Both are plain functions so they are tested without Tk.
"""

from __future__ import annotations

import contextlib
import json
import math
import queue
import re
import signal
import subprocess
import sys
import threading
from collections.abc import Callable, Iterable
from dataclasses import dataclass, replace
from typing import Any

__all__ = [
    "HEARD_LIMIT",
    "PULSE_AMPLITUDE",
    "PULSING",
    "REPLY_LIMIT",
    "STATES",
    "Display",
    "View",
    "apply_state",
    "clean",
    "encode",
    "main",
    "parse_line",
    "pulse_radius",
    "pump",
    "style_for",
]

STATES = ("idle", "listening", "heard", "thinking", "reply")

#: (colour, label) per state. Grey is "doing nothing"; the rest read like a traffic light
#: for a conversation: blue = your turn, teal = got it, amber = working, green = answer.
_STYLES = {
    "idle": ("#8a8f98", "idle"),
    "listening": ("#4aa3ff", "listening"),
    "heard": ("#2ec4b6", "heard"),
    "thinking": ("#ffb020", "thinking"),
    "reply": ("#3ecf6e", "reply"),
}

#: Longest text put on the wire. A status window is not a reader; this only bounds a very
#: long mail summary or answer.
TEXT_LIMIT = 400
#: What actually fits in the 300x340 window at 11 pt (about 38 characters a line).
HEARD_LIMIT = 90
REPLY_LIMIT = 200

#: Control characters except newline (\x0a) and space; C1 controls (\x80-\x9f) include the
#: one-byte CSI (\x9b). Lone surrogates cannot be drawn and make Tk raise.
_CONTROL = re.compile(r"[\x00-\x09\x0b-\x1f\x7f-\x9f\ud800-\udfff]")
_BLANK_LINES = re.compile(r"\n(?: *\n)+")

#: The circle breathes while the agent is waiting on you or on a model, and is still
#: otherwise.
PULSING = frozenset({"listening", "thinking"})
PULSE_BASE = 30
PULSE_AMPLITUDE = 6


def _known(state: object) -> str:
    return state if isinstance(state, str) and state in _STYLES else "idle"


def style_for(state: object) -> tuple[str, str]:
    """(colour hex, short label) for a state; anything unknown looks idle."""
    return _STYLES[_known(state)]


def clean(text: object, limit: int = TEXT_LIMIT) -> str:
    """Make untrusted text safe to draw: no control characters, tidy, at most `limit` long."""
    if not isinstance(text, str) or limit < 1:
        return ""
    text = _CONTROL.sub("", text)
    text = _BLANK_LINES.sub("\n\n", text).strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def encode(state: object, text: object = "") -> str:
    """One JSON line (ASCII, so no stray newline can sit inside it) for the child."""
    return json.dumps({"state": _known(state), "text": clean(text)}) + "\n"


def parse_line(line: object) -> tuple[str, str] | None:
    """(state, text) for a valid message line, else None. Never raises."""
    if not isinstance(line, str):
        return None
    try:
        message = json.loads(line)
    except (ValueError, RecursionError):  # not JSON / nested too deep to read
        return None
    if not isinstance(message, dict):
        return None
    state, text = message.get("state"), message.get("text")
    if not isinstance(state, str) or not isinstance(text, str):
        return None
    return _known(state), clean(text)


@dataclass(frozen=True)
class View:
    """What the window shows: the state and the two texts."""

    state: str = "idle"
    heard: str = ""
    reply: str = ""


def apply_state(current: View, state: str, text: str) -> View:
    """The view after a message. A new turn (`listening`, `heard`) drops the old answer;
    `thinking` and `idle` only change the state; `reply` keeps what was heard."""
    state = _known(state)
    if state == "listening":
        return View(state)
    if state == "heard":
        return View(state, heard=clean(text, HEARD_LIMIT))
    if state == "reply":
        return replace(current, state=state, reply=clean(text, REPLY_LIMIT))
    return replace(current, state=state)


def pulse_radius(tick: int, pulsing: bool) -> int:
    """Circle radius for animation frame `tick`: a slow swell while pulsing, else fixed."""
    if not pulsing:
        return PULSE_BASE
    return PULSE_BASE + round(PULSE_AMPLITUDE * math.sin(tick / 6))


def pump(stream: Iterable[str], out: queue.Queue[tuple[str, str] | None]) -> None:
    """Child thread body: queue each valid line, then `None` when the stream ends or breaks."""
    try:
        for line in stream:
            parsed = parse_line(line)
            if parsed is not None:
                out.put(parsed)
    except (OSError, ValueError):  # stdin closed under us - same as EOF
        pass
    finally:
        out.put(None)


class Display:
    """The terminal's end: starts the window and feeds it. Never raises, never blocks long."""

    def __init__(self, popen: Callable[..., Any] = subprocess.Popen) -> None:
        self._popen = popen
        self._proc: Any = None
        self._off = False  # failed, broken, exited or closed: no further messages

    def start(self) -> bool:
        """Open the window. False (and the display stays off) if it cannot be spawned."""
        if self._proc is not None or self._off:
            return self.alive
        try:
            self._proc = self._popen(
                # -P: `-m` would put the current folder first on the import path, so a file there
                # named like a standard module (queue.py) would run inside the window.
                [sys.executable, "-P", "-m", "pli.display"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError:
            self._off = True
            return False
        return True

    @property
    def alive(self) -> bool:
        """True while a window process is running and messages are still being sent."""
        if self._proc is None or self._off:
            return False
        if self._proc.poll() is not None:  # it left: no display, or the user closed it
            self._off = True
        return not self._off

    def send(self, state: str, text: str = "") -> None:
        """Tell the window the new state. Silent no-op if there is no window."""
        if not self.alive:
            return
        try:
            self._proc.stdin.write(encode(state, text))
            self._proc.stdin.flush()
        except (OSError, ValueError):  # BrokenPipeError is an OSError; ValueError = closed file
            self._off = True

    def close(self) -> None:
        """Close the pipe so the window closes itself; terminate it if it does not."""
        proc, self._proc = self._proc, None
        self._off = True
        if proc is None:
            return
        with contextlib.suppress(OSError, ValueError):
            proc.stdin.close()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(OSError):
                proc.terminate()


# --- the child: the window itself ----------------------------------------------------------

_BG = "#1e2127"
_HEARD_FG = "#9aa1ad"
_REPLY_FG = "#f2f4f7"
_WIDTH, _HEIGHT, _DOT_AREA = 300, 340, 100


def _build(tk: Any, root: Any) -> tuple[Any, Any, Any, Any, Any]:
    """Create the widgets: the canvas, its circle, the state word, heard and reply labels."""
    root.title("pli")
    root.geometry(f"{_WIDTH}x{_HEIGHT}")
    root.resizable(False, False)
    root.configure(bg=_BG)
    canvas = tk.Canvas(root, width=_WIDTH, height=_DOT_AREA, bg=_BG, highlightthickness=0)
    canvas.pack(pady=(14, 0))
    dot = canvas.create_oval(0, 0, 0, 0, width=0)
    word = tk.Label(root, bg=_BG, font=("Helvetica", 14, "bold"))
    word.pack(pady=(4, 8))
    texts = []
    for colour in (_HEARD_FG, _REPLY_FG):
        label = tk.Label(
            root, bg=_BG, fg=colour, font=("Helvetica", 11), wraplength=270, justify="left"
        )
        label.pack(fill="x", padx=15, pady=(0, 8))
        label.configure(anchor="w")
        texts.append(label)
    return canvas, dot, word, texts[0], texts[1]


def main() -> None:
    """Run the window until stdin reaches EOF. One stderr line and exit 1 if it cannot start."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        import tkinter as tk

        root = tk.Tk()
    except Exception as exc:  # ImportError: no Tk; TclError: no display
        sys.stderr.write("pli display unavailable: " + " ".join(str(exc).split()) + "\n")
        sys.exit(1)
    canvas, dot, word, heard, reply = _build(tk, root)
    updates: queue.Queue[tuple[str, str] | None] = queue.Queue()
    threading.Thread(target=pump, args=(sys.stdin, updates), daemon=True).start()
    view, tick = View(), 0

    def show() -> None:
        colour, label = style_for(view.state)
        canvas.itemconfigure(dot, fill=colour)
        word.configure(text=label, fg=colour)
        heard.configure(text=view.heard)
        reply.configure(text=view.reply)
        # Grow to fit the text, never below the minimum: measured with real Tk, long words
        # needed 338 of 340 px and wide text 446, so a fixed height would clip a reply.
        root.update_idletasks()
        root.geometry(f"{_WIDTH}x{max(_HEIGHT, root.winfo_reqheight())}")

    def animate() -> None:
        nonlocal tick
        root.after(60, animate)
        tick += 1
        r = pulse_radius(tick, view.state in PULSING)
        canvas.coords(dot, _WIDTH / 2 - r, _DOT_AREA / 2 - r, _WIDTH / 2 + r, _DOT_AREA / 2 + r)

    def poll() -> None:
        nonlocal view
        root.after(50, poll)  # first, so one bad update cannot stop the loop
        while not updates.empty():
            item = updates.get_nowait()
            if item is None:  # stdin ended: the terminal is gone or closed us
                root.destroy()
                return
            view = apply_state(view, *item)
            show()

    show()
    animate()
    poll()
    root.mainloop()


if __name__ == "__main__":
    main()
