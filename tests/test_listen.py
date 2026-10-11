import io
import queue
import tarfile
import time

import numpy as np
import pytest

from robo import listen
from robo.listen import FRAME, Endpointer, Listener, ensure_kws_model, speech_gate, strip_wake

SPEECH = 0.3


def frame(i: int, level: float = 0.0) -> np.ndarray:
    """A mic frame at `level` whose first sample tags it with its stream index `i`."""
    f = np.full(FRAME, level, np.float32)
    f[0] = i * 1e-4
    return f


def tags(audio) -> list[int]:
    """The stream indexes of the frames in `audio` (inverse of `frame`)."""
    return [round(float(x) * 1e4) for x in audio[::FRAME]]


def frames(a: int, b: int, level: float = 0.0) -> list[np.ndarray]:
    return [frame(i, level) for i in range(a, b)]


# --- strip_wake --------------------------------------------------------------------------------


@pytest.mark.parametrize(("text", "command"), [
    ("Hey Robo, what's on my calendar today?", "what's on my calendar today?"),
    ("Hi, robots.", ""),
    ("ok Robo.", ""),
    ("Okay robo", ""),
    (" Robot, open Moodle.", "open Moodle."),
    ("Yo robbo. What time is it?", "What time is it?"),
    ("I'm studying linear algebra tonight.", "I'm studying linear algebra tonight."),
    ("Robert called", "Robert called"),
    ("", ""),
])
def test_strip_wake(text, command):
    assert strip_wake(text) == command


# --- Endpointer / speech_gate -----------------------------------------------------------------


def ends_at(levels, frame_s=0.25, gate=0.1) -> int | None:
    """1-based frame at which the Endpointer says the utterance ended (frames of 0.25 s)."""
    ep = Endpointer(gate, frame_s)
    return next((n for n, rms in enumerate(levels, 1) if ep.feed(rms)), None)


def test_ends_after_one_second_of_silence_after_speech():
    assert ends_at([SPEECH] * 2 + [0.0] * 10) == 2 + 4


def test_short_pause_does_not_end():
    assert ends_at([SPEECH, 0, 0, 0, SPEECH] + [0.0] * 10) == 5 + 4


def test_no_speech_gives_up_after_six_seconds():
    assert ends_at([0.0] * 100) == 24


def test_endless_speech_stops_at_fifteen_seconds():
    assert ends_at([SPEECH] * 100) == 60


def test_gate_tracks_noise_floor_with_minimum():
    assert speech_gate([0.03] * 50 + [SPEECH] * 12) == pytest.approx(0.075)  # wake speech ignored
    assert speech_gate([0.001] * 60) == listen.MIN_GATE
    assert speech_gate([]) == listen.MIN_GATE


# --- Listener ---------------------------------------------------------------------------------


class FakeMic:
    def __init__(self, fs=()):
        self.q, self.closed = queue.Queue(), False
        for f in fs:
            self.q.put(f)

    def read(self, timeout):
        try:
            return self.q.get(timeout=0.005)
        except queue.Empty:
            return None

    def close(self):
        self.closed = True


class FakeSpotter:
    """Fires on the frame tagged `at`; records what it was fed."""

    def __init__(self, at=None):
        self.at, self.fed, self.resets = at, [], 0

    def hit(self, f):
        self.fed.append(tags(f)[0])
        return self.fed[-1] == self.at

    def reset(self):
        self.resets += 1


class FakeStt:
    def __init__(self, *texts):
        self.texts, self.heard = list(texts), []

    def __call__(self, audio):
        self.heard.append(audio)
        return self.texts.pop(0)


def start(mic, spot, stt):
    events = queue.Queue()
    lis = Listener(lambda: events.put("wake"), lambda t: events.put(("text", t)),
                   lambda m: events.put(("error", m)),
                   mic=lambda: mic, spotter=lambda: spot, transcriber=lambda: stt)
    assert lis.start()
    return lis, events


def until_text(events) -> list:
    got = [events.get(timeout=5)]
    while got[-1][0] != "text":
        got.append(events.get(timeout=5))
    return got


def test_wake_then_command_includes_pre_roll():
    # idle 0-39 (wake fires on 39), speech 40-49, silence 50-69
    mic = FakeMic(frames(0, 40) + frames(40, 50, SPEECH) + frames(50, 70))
    spot, stt = FakeSpotter(at=39), FakeStt("Hey Robo, what's on my calendar today?")
    lis, events = start(mic, spot, stt)
    assert until_text(events) == ["wake", ("text", "what's on my calendar today?")]
    lis.stop()
    heard = tags(stt.heard[0])
    assert heard == list(range(40 - listen.PRE_ROLL_FRAMES, heard[-1] + 1))  # contiguous
    assert 50 < heard[-1] < 69  # ended on the silence, before the mic ran dry
    assert not set(spot.fed) & set(heard[listen.PRE_ROLL_FRAMES:])  # KWS not fed while recording
    assert spot.resets == 1 and mic.closed


def test_wake_word_alone_then_follow_up_utterance():
    # wake on 9, "hi robots" 10-12, pause, then the command 33-37
    mic = FakeMic(frames(0, 10) + frames(10, 13, SPEECH) + frames(13, 33)
                  + frames(33, 38, SPEECH) + frames(38, 70))
    spot, stt = FakeSpotter(at=9), FakeStt("Hi, robots.", "open Moodle")
    lis, events = start(mic, spot, stt)
    assert until_text(events) == ["wake", ("text", "open Moodle")]
    lis.stop()
    first, second = tags(stt.heard[0]), tags(stt.heard[1])
    assert second[0] == first[-1] + 1 and 33 in second  # no pre-roll, no gap


def test_wake_word_alone_then_silence_gives_empty_text():
    mic = FakeMic(frames(0, 10) + frames(10, 12, SPEECH) + frames(12, 120))
    spot, stt = FakeSpotter(at=9), FakeStt("Hey Robo.")
    lis, events = start(mic, spot, stt)
    assert until_text(events) == ["wake", ("text", "")]
    lis.stop()
    assert len(stt.heard) == 1  # the silent follow-up is not transcribed


def test_listen_now_records_without_wake_or_pre_roll():
    mic = FakeMic(frames(0, 30))
    spot, stt = FakeSpotter(), FakeStt("What's due this week?")
    lis, events = start(mic, spot, stt)
    for _ in range(400):  # let the idle frames drain first
        if mic.q.empty():
            break
        time.sleep(0.005)
    lis.listen_now()
    for f in frames(100, 105, SPEECH) + frames(105, 125):
        mic.q.put(f)
    assert until_text(events) == [("text", "What's due this week?")]
    lis.stop()
    assert min(tags(stt.heard[0])) >= 100


def test_stop_ends_thread_and_closes_mic():
    mic = FakeMic()
    lis, _ = start(mic, FakeSpotter(), FakeStt())
    lis.stop()
    assert not lis._thread.is_alive() and mic.closed


def test_start_fails_without_mic_or_model():
    errors, mic = [], FakeMic()

    def no_mic():
        raise OSError("no input device")

    def no_model():
        raise RuntimeError("model missing")

    assert not Listener(lambda: None, lambda t: None, errors.append, mic=no_mic).start()
    assert not Listener(lambda: None, lambda t: None, errors.append,
                        mic=lambda: mic, spotter=no_model).start()
    assert len(errors) == 2 and "no input device" in errors[0] and mic.closed


# --- ensure_kws_model -------------------------------------------------------------------------


def test_kws_model_downloaded_once(tmp_path):
    calls = []

    def fetch(url, dest):
        calls.append(url)
        with tarfile.open(dest, "w:bz2") as tar:
            info = tarfile.TarInfo(f"{listen.KWS_NAME}/tokens.txt")
            info.size = 3
            tar.addfile(info, io.BytesIO(b"abc"))

    model = ensure_kws_model(tmp_path, fetch=fetch)
    assert (model / "tokens.txt").read_text() == "abc"
    assert ensure_kws_model(tmp_path, fetch=fetch) == model
    assert calls == [listen.KWS_URL]
    assert [p.name for p in tmp_path.iterdir()] == [listen.KWS_NAME]  # no .part / temp left
