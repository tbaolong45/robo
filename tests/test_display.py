"""The status window: what the terminal may send it, and what it refuses to pass on.

The window is a separate child process (`python -m pli.display`); the terminal stays the
main program and writes one JSON line per state change to the child's stdin. Rules pinned
here:

**Nothing untrusted reaches the window raw.** Mail and model text are stripped of control
characters (an escape sequence cannot redraw anything) and cut to a length before they are
sent, and the child cleans them again on arrival.

**The window can never break the terminal.** Starting it, writing to it and closing it
never raise: no `tkinter`, no display, a window the user closed, a pipe that broke - each
just turns the display off. The terminal carries on exactly as if there were no window.

**A line is one line.** Whatever the text holds, the message is a single JSON line, and the
child ignores anything that is not a well-formed message instead of dying.

**Importing the module needs no Tk and no display.** `tkinter` is imported only inside the
child's `main`.

**The window never outlives the terminal.** Closing the terminal's end of the pipe is the
window's cue to close.

Nothing here opens a window: the child process is a fake, except for two runs with the
display variables removed, where Tk cannot connect and must say so in one line.
"""

from __future__ import annotations

import colorsys
import io
import json
import os
import queue
import subprocess
import sys
import time
import types
from pathlib import Path
from typing import Any

import pytest

from pli import display

IDLE = display.View()


# --- style --------------------------------------------------------------------------------


def _hue_sat(colour: str) -> tuple[float, float]:
    r, g, b = (int(colour[i : i + 2], 16) / 255 for i in (1, 3, 5))
    h, s, _ = colorsys.rgb_to_hsv(r, g, b)
    return h * 360, s


@pytest.mark.parametrize("state", display.STATES)
def test_every_state_has_a_hex_colour_and_a_short_label(state: str) -> None:
    colour, label = display.style_for(state)

    assert len(colour) == 7 and colour.startswith("#")
    int(colour[1:], 16)
    assert 0 < len(label) <= 12


def test_the_five_states_are_the_spec_ones_in_order() -> None:
    assert display.STATES == ("idle", "listening", "heard", "thinking", "reply")


def test_state_colours_are_the_agreed_hues() -> None:
    _, idle_sat = _hue_sat(display.style_for("idle")[0])
    assert idle_sat < 0.15  # grey

    hue, sat = _hue_sat(display.style_for("listening")[0])
    assert 200 <= hue <= 250 and sat > 0.4  # blue
    hue, sat = _hue_sat(display.style_for("heard")[0])
    assert 160 <= hue <= 195 and sat > 0.4  # teal
    hue, sat = _hue_sat(display.style_for("thinking")[0])
    assert 30 <= hue <= 50 and sat > 0.4  # amber
    hue, sat = _hue_sat(display.style_for("reply")[0])
    assert 100 <= hue <= 150 and sat > 0.4  # green


def test_the_states_are_told_apart_by_colour() -> None:
    colours = [display.style_for(s)[0] for s in display.STATES]

    assert len(set(colours)) == len(colours)


@pytest.mark.parametrize("bogus", ["dance", "", "LISTENING", None, 42, [], {}])
def test_an_unknown_state_gets_the_idle_style_and_never_raises(bogus: Any) -> None:
    assert display.style_for(bogus) == display.style_for("idle")


# --- clean --------------------------------------------------------------------------------


def test_clean_strips_escape_sequences_and_the_bell() -> None:
    out = display.clean("a\x1b[2Jb\x07c")

    assert "\x1b" not in out
    assert "\x07" not in out
    assert out.startswith("a") and out.endswith("c")


@pytest.mark.parametrize(
    "ch", ["\x00", "\x08", "\x0b", "\x0c", "\r", "\t", "\x7f", "\x9b", "\ud800"]
)
def test_clean_strips_every_other_control_character(ch: str) -> None:
    assert display.clean(f"a{ch}b") == "ab"


def test_clean_keeps_newlines_spaces_and_ordinary_unicode() -> None:
    assert display.clean("line one\nline two é 日本") == "line one\nline two é 日本"


def test_clean_collapses_runs_of_blank_lines_to_one() -> None:
    assert display.clean("a\n\n\n\nb") == "a\n\nb"
    assert display.clean("a\n  \n \n\nb") == "a\n\nb"
    assert display.clean("a\n\nb") == "a\n\nb"


def test_clean_trims_the_ends() -> None:
    assert display.clean("\n\n  hello  \n\n") == "hello"


def test_clean_truncates_with_an_ellipsis_at_the_limit() -> None:
    out = display.clean("a" * 500)

    assert len(out) == 400
    assert out == "a" * 399 + "…"


def test_clean_leaves_text_at_exactly_the_limit_alone() -> None:
    assert display.clean("a" * 400) == "a" * 400
    assert display.clean("abcdefghij", limit=10) == "abcdefghij"


def test_clean_takes_a_custom_limit() -> None:
    assert display.clean("abcdefghij", limit=5) == "abcd…"


def test_clean_with_no_room_returns_nothing() -> None:
    assert display.clean("abc", limit=0) == ""


def test_clean_cuts_after_removing_control_characters() -> None:
    # 399 real characters hidden among control characters must not be cut short.
    assert display.clean("\x1b" * 100 + "a" * 399) == "a" * 399


@pytest.mark.parametrize("not_text", [None, 5, 1.5, b"bytes", ["a"], {"a": 1}])
def test_clean_returns_empty_for_anything_that_is_not_a_string(not_text: Any) -> None:
    assert display.clean(not_text) == ""


# --- encode -------------------------------------------------------------------------------


def test_encode_is_one_json_line_that_round_trips() -> None:
    line = display.encode("reply", "hello é 日本")

    assert line.endswith("\n")
    assert line.count("\n") == 1
    assert json.loads(line) == {"state": "reply", "text": "hello é 日本"}


def test_encode_defaults_to_empty_text() -> None:
    assert json.loads(display.encode("listening")) == {"state": "listening", "text": ""}


def test_encode_keeps_multiline_text_on_one_line() -> None:
    line = display.encode("reply", "one\ntwo\n\n\nthree")

    assert line.count("\n") == 1
    assert json.loads(line)["text"] == "one\ntwo\n\nthree"


def test_encode_cleans_the_text_before_it_leaves() -> None:
    line = display.encode("reply", "\x1b[2Jhi\x07" + "x" * 1000)
    text = json.loads(line)["text"]

    assert "\x1b" not in line
    assert "\x07" not in line
    assert len(text) == 400
    assert text.endswith("…")


@pytest.mark.parametrize("state", display.STATES)
def test_encode_keeps_every_known_state(state: str) -> None:
    assert json.loads(display.encode(state, "x"))["state"] == state


@pytest.mark.parametrize("bogus", ["dance", "", None, 42, []])
def test_encode_sends_an_unknown_state_as_idle(bogus: Any) -> None:
    assert json.loads(display.encode(bogus, "x"))["state"] == "idle"


def test_encode_sends_empty_text_for_a_non_string() -> None:
    assert json.loads(display.encode("reply", None))["text"] == ""  # type: ignore[arg-type]


# --- parse_line ---------------------------------------------------------------------------


def test_parse_line_reads_what_encode_wrote() -> None:
    assert display.parse_line(display.encode("heard", "read my mail")) == ("heard", "read my mail")


def test_parse_line_tolerates_a_missing_trailing_newline() -> None:
    assert display.parse_line('{"state": "reply", "text": "ok"}') == ("reply", "ok")


@pytest.mark.parametrize(
    "junk",
    [
        "",
        "\n",
        "not json",
        "{",
        "[1, 2]",
        "42",
        "null",
        '"just a string"',
        '{"state": "reply"}',
        '{"text": "x"}',
        "{}",
        '{"state": 1, "text": "x"}',
        '{"state": null, "text": "x"}',
        '{"state": ["reply"], "text": "x"}',
        '{"state": "reply", "text": 5}',
        '{"state": "reply", "text": null}',
        '{"state": "reply", "text": ["x"]}',
        "[" * 100_000,
        '{"state": "reply", "text": "x"' + "}" * 3,
    ],
)
def test_parse_line_returns_none_for_anything_but_a_valid_message(junk: str) -> None:
    assert display.parse_line(junk) is None


@pytest.mark.parametrize("not_text", [None, 5, b'{"state": "reply", "text": "x"}', ["x"]])
def test_parse_line_returns_none_for_a_non_string_line(not_text: Any) -> None:
    assert display.parse_line(not_text) is None


def test_parse_line_maps_an_unknown_state_to_idle_and_keeps_the_text() -> None:
    assert display.parse_line('{"state": "dance", "text": "hi"}') == ("idle", "hi")


def test_parse_line_cleans_the_text_again() -> None:
    line = json.dumps({"state": "reply", "text": "\x1b[2Jhi\x07" + "y" * 1000})
    state, text = display.parse_line(line)  # type: ignore[misc]

    assert state == "reply"
    assert "\x1b" not in text and "\x07" not in text
    assert len(text) == 400


def test_parse_line_ignores_extra_keys() -> None:
    assert display.parse_line('{"state": "reply", "text": "x", "extra": 1}') == ("reply", "x")


# --- apply_state --------------------------------------------------------------------------

BUSY = display.View(state="reply", heard="read my mail", reply="three new")


def test_a_fresh_view_is_idle_and_empty() -> None:
    assert (IDLE.state, IDLE.heard, IDLE.reply) == ("idle", "", "")


def test_listening_clears_heard_and_reply() -> None:
    assert display.apply_state(BUSY, "listening", "") == display.View("listening", "", "")


def test_heard_shows_the_text_as_heard() -> None:
    out = display.apply_state(IDLE, "heard", "show deadlines")

    assert out.state == "heard"
    assert out.heard == "show deadlines"


def test_a_new_request_replaces_the_stale_reply() -> None:
    out = display.apply_state(BUSY, "heard", "show deadlines")

    assert out == display.View("heard", "show deadlines", "")


def test_thinking_keeps_what_was_heard() -> None:
    mid = display.View(state="heard", heard="show deadlines", reply="")

    assert display.apply_state(mid, "thinking", "ignored") == display.View(
        "thinking", "show deadlines", ""
    )


def test_reply_shows_the_reply_and_keeps_what_was_heard() -> None:
    mid = display.View(state="thinking", heard="show deadlines", reply="")

    assert display.apply_state(mid, "reply", "two due today") == display.View(
        "reply", "show deadlines", "two due today"
    )


def test_idle_clears_nothing() -> None:
    assert display.apply_state(BUSY, "idle", "ignored") == display.View(
        "idle", "read my mail", "three new"
    )


def test_an_unknown_state_acts_like_idle() -> None:
    assert display.apply_state(BUSY, "dance", "x") == display.apply_state(BUSY, "idle", "x")


def test_apply_state_does_not_change_the_view_it_was_given() -> None:
    before = display.View("reply", "h", "r")

    display.apply_state(before, "listening", "")

    assert before == display.View("reply", "h", "r")


def test_the_text_shown_is_cut_to_fit_the_window() -> None:
    out = display.apply_state(IDLE, "heard", "h" * 1000)
    assert len(out.heard) <= display.HEARD_LIMIT
    assert out.heard.endswith("…")

    out = display.apply_state(IDLE, "reply", "r" * 1000)
    assert len(out.reply) <= display.REPLY_LIMIT
    assert out.reply.endswith("…")


def test_the_view_shown_never_holds_control_characters() -> None:
    out = display.apply_state(IDLE, "reply", "\x1b[2Jhi\x07")

    assert "\x1b" not in out.reply and "\x07" not in out.reply


def test_only_listening_and_thinking_pulse() -> None:
    assert set(display.PULSING) == {"listening", "thinking"}


def test_pulse_radius_is_constant_when_not_pulsing() -> None:
    radii = {display.pulse_radius(tick, False) for tick in range(200)}

    assert len(radii) == 1


def test_pulse_radius_swells_and_shrinks_within_bounds_when_pulsing() -> None:
    still = display.pulse_radius(0, False)
    radii = [display.pulse_radius(tick, True) for tick in range(200)]

    assert all(isinstance(r, int) for r in radii)
    assert min(radii) < still < max(radii)
    assert max(radii) - min(radii) <= 2 * display.PULSE_AMPLITUDE


# --- pump (the child's stdin reader) --------------------------------------------------------


def _drain(q: queue.Queue) -> list:
    out = []
    while not q.empty():
        out.append(q.get_nowait())
    return out


def test_pump_queues_each_valid_line_in_order_and_then_a_quit_marker() -> None:
    q: queue.Queue = queue.Queue()
    lines = display.encode("listening") + display.encode("heard", "hi")

    display.pump(io.StringIO(lines), q)

    assert _drain(q) == [("listening", ""), ("heard", "hi"), None]


def test_pump_skips_junk_and_keeps_going() -> None:
    q: queue.Queue = queue.Queue()
    lines = "junk\n" + display.encode("reply", "ok") + "[1]\n"

    display.pump(io.StringIO(lines), q)

    assert _drain(q) == [("reply", "ok"), None]


def test_pump_posts_the_quit_marker_on_an_empty_stream() -> None:
    q: queue.Queue = queue.Queue()

    display.pump(io.StringIO(""), q)

    assert _drain(q) == [None]


@pytest.mark.parametrize("error", [OSError("gone"), ValueError("closed"), BrokenPipeError()])
def test_pump_posts_the_quit_marker_even_if_the_stream_breaks(error: Exception) -> None:
    def broken() -> Any:
        yield display.encode("heard", "hi")
        raise error

    q: queue.Queue = queue.Queue()

    display.pump(broken(), q)

    assert _drain(q) == [("heard", "hi"), None]


# --- Display (the terminal's end) -------------------------------------------------------------


class FakeStdin:
    def __init__(self, log: list[str], **errors: Exception) -> None:
        self.log = log
        self.errors = errors
        self.writes: list[str] = []
        self.write_attempts = 0
        self.flushes = 0
        self.closes = 0

    def write(self, text: str) -> int:
        self.write_attempts += 1
        if "write" in self.errors:
            raise self.errors["write"]
        self.log.append("stdin.write")
        self.writes.append(text)
        return len(text)

    def flush(self) -> None:
        if "flush" in self.errors:
            raise self.errors["flush"]
        self.log.append("stdin.flush")
        self.flushes += 1

    def close(self) -> None:
        self.closes += 1
        self.log.append("stdin.close")
        if "close" in self.errors:
            raise self.errors["close"]


class FakeProc:
    def __init__(
        self,
        args: Any,
        kwargs: dict[str, Any],
        *,
        stdin_errors: dict[str, Exception],
        exited: bool,
        wait_times_out: bool,
        terminate_error: Exception | None,
    ) -> None:
        self.args = args
        self.kwargs = kwargs
        self.log: list[str] = []
        self.stdin = FakeStdin(self.log, **stdin_errors)
        self.returncode: int | None = 1 if exited else None
        self.wait_times_out = wait_times_out
        self.terminate_error = terminate_error
        self.wait_timeouts: list[Any] = []
        self.terminates = 0

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        self.log.append("wait")
        self.wait_timeouts.append(timeout)
        if self.wait_times_out:
            raise subprocess.TimeoutExpired(self.args, timeout or 0)
        self.returncode = 0
        return 0

    def terminate(self) -> None:
        self.log.append("terminate")
        self.terminates += 1
        if self.terminate_error is not None:
            raise self.terminate_error


class Spawner:
    """Stands in for `subprocess.Popen`: records the call and hands back a `FakeProc`."""

    def __init__(
        self,
        *,
        error: Exception | None = None,
        stdin_errors: dict[str, Exception] | None = None,
        exited: bool = False,
        wait_times_out: bool = False,
        terminate_error: Exception | None = None,
    ) -> None:
        self.error = error
        self.stdin_errors = stdin_errors or {}
        self.exited = exited
        self.wait_times_out = wait_times_out
        self.terminate_error = terminate_error
        self.procs: list[FakeProc] = []

    def __call__(self, args: Any, **kwargs: Any) -> FakeProc:
        if self.error is not None:
            raise self.error
        proc = FakeProc(
            args,
            kwargs,
            stdin_errors=self.stdin_errors,
            exited=self.exited,
            wait_times_out=self.wait_times_out,
            terminate_error=self.terminate_error,
        )
        self.procs.append(proc)
        return proc


def started(**kwargs: Any) -> tuple[display.Display, Spawner]:
    spawner = Spawner(**kwargs)
    shown = display.Display(popen=spawner)
    assert shown.start() is True
    return shown, spawner


def test_start_spawns_this_pythons_display_module_with_a_text_pipe() -> None:
    shown, spawner = started()

    assert len(spawner.procs) == 1
    proc = spawner.procs[0]
    assert proc.args == [sys.executable, "-P", "-m", "pli.display"]
    assert proc.kwargs == {
        "stdin": subprocess.PIPE,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "text": True,
        "bufsize": 1,
    }
    assert shown.alive is True


def test_start_twice_spawns_one_window() -> None:
    shown, spawner = started()

    assert shown.start() is True
    assert len(spawner.procs) == 1


def test_send_writes_one_json_line_and_flushes() -> None:
    shown, spawner = started()

    shown.send("heard", "read my mail")

    stdin = spawner.procs[0].stdin
    assert stdin.writes == [display.encode("heard", "read my mail")]
    assert json.loads(stdin.writes[0]) == {"state": "heard", "text": "read my mail"}
    assert stdin.flushes == 1
    assert spawner.procs[0].log == ["stdin.write", "stdin.flush"]


def test_send_defaults_to_empty_text() -> None:
    shown, spawner = started()

    shown.send("listening")

    assert json.loads(spawner.procs[0].stdin.writes[0]) == {"state": "listening", "text": ""}


def test_send_cleans_untrusted_text_before_it_leaves_the_terminal() -> None:
    shown, spawner = started()

    shown.send("reply", "\x1b[2Jhi\x07")

    written = spawner.procs[0].stdin.writes[0]
    assert "\x1b" not in written and "\x07" not in written


def test_send_sends_an_unknown_state_as_idle() -> None:
    shown, spawner = started()

    shown.send("dance", "x")

    assert json.loads(spawner.procs[0].stdin.writes[0])["state"] == "idle"


@pytest.mark.parametrize(
    "stdin_errors",
    [
        {"write": BrokenPipeError()},
        {"flush": BrokenPipeError()},
        {"write": ValueError("I/O operation on closed file")},
        {"flush": ValueError("I/O operation on closed file")},
        {"write": OSError("pipe")},
        {"flush": OSError("pipe")},
    ],
)
def test_a_broken_pipe_turns_the_display_off_silently(stdin_errors: dict[str, Exception]) -> None:
    shown, spawner = started(stdin_errors=stdin_errors)
    stdin = spawner.procs[0].stdin

    shown.send("heard", "hi")  # must not raise

    assert shown.alive is False
    attempts = stdin.write_attempts
    shown.send("reply", "again")
    shown.send("idle")
    assert stdin.write_attempts == attempts  # later sends do not even try


def test_a_child_that_has_already_exited_disables_the_display() -> None:
    shown, spawner = started(exited=True)  # e.g. no DISPLAY: the child said so and left

    shown.send("heard", "hi")

    assert shown.alive is False
    assert spawner.procs[0].stdin.write_attempts == 0


def test_a_child_that_exits_later_disables_the_display() -> None:
    shown, spawner = started()
    shown.send("listening")
    assert spawner.procs[0].stdin.writes != []

    spawner.procs[0].returncode = 0  # the user closed the window
    shown.send("heard", "hi")

    assert shown.alive is False
    assert len(spawner.procs[0].stdin.writes) == 1


@pytest.mark.parametrize(
    "error", [FileNotFoundError("no python"), PermissionError("denied"), OSError("fork failed")]
)
def test_a_failed_spawn_leaves_the_display_off_and_never_raises(error: OSError) -> None:
    spawner = Spawner(error=error)
    shown = display.Display(popen=spawner)

    assert shown.start() is False
    assert shown.alive is False
    shown.send("heard", "hi")  # no-op
    spawner.error = None  # even if spawning would work now, the display stays off
    assert shown.start() is False
    assert spawner.procs == []
    shown.close()  # no-op


def test_send_before_start_is_a_no_op() -> None:
    shown = display.Display(popen=Spawner())

    shown.send("heard", "hi")

    assert shown.alive is False


def test_close_closes_stdin_then_waits_and_does_not_kill_a_child_that_left() -> None:
    shown, spawner = started()

    shown.close()

    proc = spawner.procs[0]
    assert proc.log == ["stdin.close", "wait"]
    assert proc.wait_timeouts == [2]
    assert proc.terminates == 0
    assert shown.alive is False


def test_close_falls_back_to_terminate_when_the_child_will_not_leave() -> None:
    shown, spawner = started(wait_times_out=True)

    shown.close()  # must not raise

    assert spawner.procs[0].log == ["stdin.close", "wait", "terminate"]


def test_close_survives_a_terminate_that_fails() -> None:
    shown, _ = started(wait_times_out=True, terminate_error=ProcessLookupError())

    shown.close()


@pytest.mark.parametrize("error", [BrokenPipeError(), ValueError("closed"), OSError("x")])
def test_close_still_waits_when_closing_stdin_fails(error: Exception) -> None:
    shown, spawner = started(stdin_errors={"close": error})

    shown.close()

    assert spawner.procs[0].log == ["stdin.close", "wait"]


def test_close_is_idempotent() -> None:
    shown, spawner = started()

    shown.close()
    shown.close()

    proc = spawner.procs[0]
    assert proc.stdin.closes == 1
    assert proc.wait_timeouts == [2]


def test_close_cleans_up_a_display_that_was_switched_off() -> None:
    shown, spawner = started(stdin_errors={"write": BrokenPipeError()})
    shown.send("heard", "hi")
    assert shown.alive is False

    shown.close()

    assert "wait" in spawner.procs[0].log


def test_close_before_start_is_a_no_op() -> None:
    display.Display(popen=Spawner()).close()


def test_send_after_close_is_a_no_op() -> None:
    shown, spawner = started()
    shown.close()

    shown.send("heard", "hi")

    assert spawner.procs[0].stdin.write_attempts == 0


def test_a_closed_display_does_not_restart() -> None:
    shown, spawner = started()
    shown.close()

    assert shown.start() is False
    assert len(spawner.procs) == 1


# --- main() wiring, against a fake Tk (the real window is not opened here) --------------------


class FakeWidget:
    created: list[FakeWidget] = []

    def __init__(self, *args: Any, **options: Any) -> None:
        self.options = dict(options)
        self.items: dict[int, dict[str, Any]] = {}
        FakeWidget.created.append(self)

    def pack(self, **options: Any) -> None:
        pass

    def configure(self, **options: Any) -> None:
        self.options.update(options)

    def create_oval(self, *coords: float, **options: Any) -> int:
        self.items[1] = {"coords": list(coords), **options}
        return 1

    def itemconfigure(self, item: int, **options: Any) -> None:
        self.items[item].update(options)

    def coords(self, item: int, *coords: float) -> None:
        self.items[item]["coords"] = list(coords)


class FakeRoot:
    """Runs scheduled callbacks in order until `destroy`, as Tk's mainloop would."""

    def __init__(self) -> None:
        self.pending: list[Any] = []
        self.destroyed = False
        self.calls: dict[str, Any] = {}
        #: What the widgets would ask for; the window must grow to this, never below its minimum.
        self.req_height = 100

    def update_idletasks(self) -> None:
        pass

    def winfo_reqheight(self) -> int:
        return self.req_height

    def title(self, text: str) -> None:
        self.calls["title"] = text

    def geometry(self, text: str) -> None:
        self.calls["geometry"] = text

    def resizable(self, width: bool, height: bool) -> None:
        self.calls["resizable"] = (width, height)

    def configure(self, **options: Any) -> None:
        self.calls["configure"] = options

    def after(self, ms: int, fn: Any) -> None:
        self.pending.append(fn)

    def destroy(self) -> None:
        self.destroyed = True

    def mainloop(self) -> None:
        deadline = time.monotonic() + 10
        while not self.destroyed and time.monotonic() < deadline:
            batch, self.pending = self.pending, []
            for fn in batch:
                if not self.destroyed:  # real Tk drops pending callbacks once destroyed
                    fn()
            time.sleep(0.005)


@pytest.fixture
def fake_tk(monkeypatch: pytest.MonkeyPatch) -> FakeRoot:
    root = FakeRoot()
    FakeWidget.created = []
    module = types.SimpleNamespace(Tk=lambda: root, Canvas=FakeWidget, Label=FakeWidget)
    monkeypatch.setitem(sys.modules, "tkinter", module)
    return root


def test_main_shows_each_message_and_closes_the_window_when_stdin_ends(
    fake_tk: FakeRoot, monkeypatch: pytest.MonkeyPatch
) -> None:
    signals: list[tuple[Any, Any]] = []
    monkeypatch.setattr(display.signal, "signal", lambda *args: signals.append(args))
    monkeypatch.setattr(
        sys,
        "stdin",
        io.StringIO(
            display.encode("listening")
            + "garbage\n"
            + display.encode("heard", "show deadlines")
            + display.encode("thinking")
            + display.encode("reply", "\x1b[2Jtwo due today")
        ),
    )

    display.main()

    assert fake_tk.destroyed is True
    assert fake_tk.calls["title"] == "pli"
    assert fake_tk.calls["geometry"] == "300x340"
    assert fake_tk.calls["resizable"] == (False, False)
    assert signals == [(display.signal.SIGINT, display.signal.SIG_IGN)]
    canvas, word, heard, reply = (FakeWidget.created[i] for i in (0, 1, 2, 3))
    colour, label = display.style_for("reply")
    assert word.options["text"] == label and word.options["fg"] == colour
    assert canvas.items[1]["fill"] == colour
    assert heard.options["text"] == "show deadlines"
    assert reply.options["text"] == "[2Jtwo due today"
    x0, y0, x1, y1 = canvas.items[1]["coords"]
    assert (x0 + x1) / 2 == 150 and (y0 + y1) / 2 == 50 and x1 - x0 == y1 - y0


def _run_main_with(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(display.signal, "signal", lambda *args: None)
    monkeypatch.setattr(sys, "stdin", io.StringIO(display.encode("reply", "an answer")))
    display.main()


def test_the_window_grows_to_fit_text_that_needs_more_than_the_minimum_height(
    fake_tk: FakeRoot, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Measured with real Tk: long words needed 338 of 340 px and wide text 446, so a
    fixed height would clip the end of a reply."""
    fake_tk.req_height = 446

    _run_main_with(monkeypatch)

    assert fake_tk.calls["geometry"] == "300x446"


def test_the_window_never_shrinks_below_its_minimum_height(
    fake_tk: FakeRoot, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake_tk.req_height = 212

    _run_main_with(monkeypatch)

    assert fake_tk.calls["geometry"] == "300x340"


def test_main_exits_1_with_one_line_when_tk_cannot_open_a_display(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def no_display() -> None:
        raise RuntimeError("no display name and\nno $DISPLAY environment variable")

    monkeypatch.setattr(display.signal, "signal", lambda *args: None)
    monkeypatch.setitem(sys.modules, "tkinter", types.SimpleNamespace(Tk=no_display))

    with pytest.raises(SystemExit) as stop:
        display.main()

    assert stop.value.code == 1
    err = capsys.readouterr().err
    assert len(err.splitlines()) == 1 and "no $DISPLAY" in err


def test_main_exits_1_with_one_line_when_tkinter_is_missing(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(display.signal, "signal", lambda *args: None)
    monkeypatch.setitem(sys.modules, "tkinter", None)  # makes `import tkinter` raise

    with pytest.raises(SystemExit) as stop:
        display.main()

    assert stop.value.code == 1
    assert len(capsys.readouterr().err.splitlines()) == 1


# --- the real module, in a real child (no window: display variables removed) ---


def _no_display_env() -> dict[str, str]:
    drop = {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY"}
    return {k: v for k, v in os.environ.items() if k not in drop}


def test_importing_the_module_does_not_import_tkinter() -> None:
    code = "import sys, pli.display; print('tkinter' in sys.modules)"

    out = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=60, check=True
    )

    assert out.stdout.strip() == "False"


def test_the_child_without_a_display_says_so_in_one_line_and_exits_1() -> None:
    out = subprocess.run(
        [sys.executable, "-m", "pli.display"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
        env=_no_display_env(),
    )

    assert out.returncode == 1
    assert out.stdout == ""
    assert len(out.stderr.strip().splitlines()) == 1
    assert "Traceback" not in out.stderr


def test_the_child_runs_nothing_from_the_folder_it_is_started_in(tmp_path: Path) -> None:
    """`python -m` puts the current folder first on the import path, so a file there named
    like a standard module (`queue.py`) would run inside the window process."""
    marker = tmp_path / "ran"
    (tmp_path / "queue.py").write_text(f"open({str(marker)!r}, 'w').close()\nraise ImportError\n")

    def spawn(args: Any, **kwargs: Any) -> subprocess.Popen:
        return subprocess.Popen(args, env=_no_display_env(), cwd=tmp_path, **kwargs)

    shown = display.Display(popen=spawn)
    assert shown.start() is True
    try:
        deadline = time.monotonic() + 30
        while shown.alive and time.monotonic() < deadline:
            time.sleep(0.05)
        assert shown.alive is False
    finally:
        shown.close()
    assert not marker.exists(), "the child imported a file from its working folder"


def test_a_real_child_without_a_display_switches_the_display_off() -> None:
    def spawn(args: Any, **kwargs: Any) -> subprocess.Popen:
        return subprocess.Popen(args, env=_no_display_env(), **kwargs)

    shown = display.Display(popen=spawn)
    assert shown.start() is True
    try:
        deadline = time.monotonic() + 30
        while shown.alive and time.monotonic() < deadline:
            time.sleep(0.05)
        assert shown.alive is False
        shown.send("heard", "hi")  # no-op, no raise
    finally:
        shown.close()
