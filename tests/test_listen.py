import itertools
import queue
import sys
import threading
import time
import types

import numpy as np
import pytest

from robo import listen
from robo.listen import FRAME, Endpointer, Listener, addressed, speech_gate

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


# --- addressed -----------------------------------------------------------------------------------


@pytest.mark.parametrize(("text", "said"), [
    ("Robo, what time is it?", "what time is it?"),
    ("Hey Robo, what's on my calendar today?", "what's on my calendar today?"),
    ("What's due this week, robo?", "What's due this week"),
    ("Can robo open Moodle for me", "Can robo open Moodle for me"),
    ("Robot, open Moodle.", "open Moodle."),
    ("ok Robo.", ""),
    ("Yo robbo. What time is it?", "What time is it?"),
    # what Parakeet TDT v2 wrote for the user's own "robo" (recorded 2026-10-11)
    ("Rubo opened mail.", "opened mail."),
    ("High robot check models.", "check models."),
    ("Ok Rubo Blameday.", "Blameday."),
    ("Rubo, tell me a joke.", "tell me a joke."),
    ("Rubo.", ""),
    ("Robot draft an email my professor.", "draft an email my professor."),
    ("Rubo, what's weather? Thanks, Rubo.", "what's weather? Thanks"),
    # second, held-out recording
    ("Roombo search timer for 10 minutes.", "search timer for 10 minutes."),
    ("Hi Robo read my latest.", "read my latest."),
    ("Can you help me, Robo?", "Can you help me"),
    ("Rubble play mode.", "play mode."),
    ("Robbo play mode.", "play mode."),
    # Parakeet glues a greeting to the name: "Yo robo, ..." came out as "Yorobo, ..."
    ("Yorobo, open my calendar.", "open my calendar."),
    ("Heyrobo what's due this week?", "what's due this week?"),
    ("Okayrobo.", ""),
])
def test_sentences_that_call_robo(text, said):
    assert addressed(text) == said


@pytest.mark.parametrize("text", [
    "I'm studying linear algebra tonight.", "Robert called", "the robot vacuum is broken",
    "I'm going to show you how to do this.", "", "you",
    # the user's own sentences without the name (Parakeet transcripts)
    "Robots are interesting.", "Let's go over notes.", "I need study calculus tonight.",
    "The letter was long today.", "Can you pass me water?", "Ruby on rails is fun",
    "My friend bought a ro robot.", "Rob is coming over tonight. The robot.",
    "Ralph is coming over tonight, the robots.", "The house was rubble", "Robert called.",
    # words that start like "greeting + name" once the space between them may be missing
    "Hirobumi Ito was a statesman.", "Hiring robots is hard.", "Hiroshima is a city.",
    "Okay so the robot vacuum is loud.", "Yoruba is a language.",
])
def test_sentences_not_for_robo(text):
    assert addressed(text) is None


# --- Endpointer / speech_gate -----------------------------------------------------------------


def ends_at(levels, frame_s=0.25, gate=0.1) -> int | None:
    """1-based frame at which the Endpointer says the utterance ended (frames of 0.25 s)."""
    ep = Endpointer(gate, frame_s)
    return next((n for n, rms in enumerate(levels, 1) if ep.feed(rms)), None)


def test_ends_after_most_of_a_second_of_silence_after_speech():
    assert ends_at([SPEECH] * 2 + [0.0] * 10) == 2 + 3  # 0.75 s >= END_SILENCE_S


def test_short_pause_does_not_end():
    assert ends_at([SPEECH, 0, 0, SPEECH] + [0.0] * 10) == 4 + 3  # a 0.5 s pause goes on


def test_no_speech_gives_up_after_six_seconds():
    assert ends_at([0.0] * 100) == 24


def test_endless_speech_stops_at_fifteen_seconds():
    assert ends_at([SPEECH] * 100) == 60


def test_gate_tracks_noise_floor_with_minimum():
    assert speech_gate([0.03] * 50 + [SPEECH] * 12) == pytest.approx(0.075)  # wake speech ignored
    assert speech_gate([0.001] * 60) == listen.MIN_GATE
    assert speech_gate([]) == listen.MIN_GATE


# --- Parakeet ------------------------------------------------------------------------------------


def test_parakeet_loads_on_the_cpu_only(monkeypatch):
    loaded = {}

    def load_model(name, **kwargs):
        loaded.update(name=name, **kwargs)
        return object()

    monkeypatch.setitem(sys.modules, "onnx_asr", types.SimpleNamespace(load_model=load_model))
    listen.Parakeet()
    assert loaded == {"name": listen.STT_MODEL, "quantization": "int8",
                      "providers": ["CPUExecutionProvider"]}


def test_parakeet_hears_every_utterance_at_the_same_level(monkeypatch):
    heard = []

    class Model:
        def recognize(self, audio, sample_rate):
            heard.append(audio)
            return " ok "

    fake = types.SimpleNamespace(load_model=lambda *a, **k: Model())
    monkeypatch.setitem(sys.modules, "onnx_asr", fake)
    stt = listen.Parakeet()
    soft = (np.sin(np.linspace(0, 400, 16000)) * 0.05).astype(np.float32)
    assert stt(soft) == "ok"
    assert np.abs(heard[0]).max() == pytest.approx(listen.LEVEL_PEAK, rel=0.05)
    assert heard[0].dtype == np.float32


@pytest.mark.parametrize(("peak", "want"), [
    (0.05, listen.LEVEL_PEAK),  # soft speech is brought up
    (0.9, listen.LEVEL_PEAK),  # loud speech is brought down to the level the model was checked at
    (0.0001, 0.0001 * listen.LEVEL_MAX_GAIN),  # near-silence is not turned into loud noise
])
def test_leveled_scales_to_the_peak_but_caps_the_boost(peak, want):
    audio = (np.sin(np.linspace(0, 400, 16000)) * peak).astype(np.float32)
    assert np.abs(listen.leveled(audio)).max() == pytest.approx(want, rel=0.05)


def test_leveled_leaves_silence_and_one_click_alone():
    assert not listen.leveled(np.zeros(1600, np.float32)).any()
    click = np.zeros(16000, np.float32)
    click[100] = 1.0  # one sample is not the level of the utterance (99.5th percentile)
    assert np.abs(listen.leveled(click)).max() <= 1.0 * listen.LEVEL_MAX_GAIN


# --- Listener ------------------------------------------------------------------------------------


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


class FakeStt:
    def __init__(self, *texts):
        self.texts, self.heard = list(texts), []

    def __call__(self, audio):
        self.heard.append(audio)
        return self.texts.pop(0) if self.texts else ""


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


@pytest.fixture
def no_stall(monkeypatch):
    """For tests that jump a hand-driven clock while no frames arrive (looks like a dead mic)."""
    monkeypatch.setattr(listen, "MIC_STALL_S", 1e9)


def start(mic, stt, clock=None, quick=None):
    events = queue.Queue()
    lis = Listener(lambda: events.put("wake"), lambda t: events.put(("text", t)),
                   lambda m: events.put(("error", m)), mic=lambda: mic,
                   transcriber=lambda: stt, quick=lambda: quick or FakeStt(),
                   clock=clock or time.monotonic)
    assert lis.start()
    return lis, events


def sentence(a: int, n: int = 5) -> list[np.ndarray]:
    """Quiet, n frames of speech, then a second of quiet."""
    return frames(a, a + 8) + frames(a + 8, a + 8 + n, SPEECH) + frames(a + 8 + n, a + 30)


def drained(mic, timeout=3.0):
    end = time.monotonic() + timeout
    while not mic.q.empty() and time.monotonic() < end:
        time.sleep(0.005)
    time.sleep(0.05)


def test_a_sentence_with_the_name_is_a_request():
    mic = FakeMic(sentence(0))
    stt = FakeStt("Robo, what time is it?")
    lis, events = start(mic, stt)
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "what time is it?")]
    lis.stop()
    heard = tags(stt.heard[0])
    assert heard[0] == 8 - listen.PRE_ROLL_FRAMES and heard == list(range(heard[0], heard[-1] + 1))


def test_other_speech_is_ignored():
    mic = FakeMic(sentence(0) + sentence(30))
    stt = FakeStt("I'm studying linear algebra tonight.", "the robot vacuum is broken")
    lis, events = start(mic, stt)
    drained(mic)
    lis.stop()
    assert events.empty() and len(stt.heard) == 2


def test_a_knock_is_not_transcribed():
    mic = FakeMic(frames(0, 8) + frames(8, 10, SPEECH) + frames(10, 30))
    stt = FakeStt()
    lis, events = start(mic, stt)
    drained(mic)
    lis.stop()
    assert stt.heard == [] and events.empty()


def test_after_an_answer_a_reply_needs_no_name(no_stall):
    clock = Clock()
    mic = FakeMic()
    stt = FakeStt("and tomorrow?", "and next week?")
    lis, events = start(mic, stt, clock)
    lis.follow_up(10)
    for f in sentence(0):
        mic.q.put(f)
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "and tomorrow?")]
    clock.t = 30  # the window closed (and it was used once anyway)
    for f in sentence(100):
        mic.q.put(f)
    drained(mic)
    lis.stop()
    assert events.empty()


def test_click_takes_the_next_sentence_or_gives_up(no_stall):
    clock = Clock()
    mic = FakeMic()
    lis, events = start(mic, FakeStt("what's due"), clock)
    lis.listen_now()
    for f in sentence(0):
        mic.q.put(f)
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "what's due")]
    lis.listen_now()
    clock.t = listen.NO_SPEECH_S + 1
    assert events.get(timeout=5) == ("text", "")
    lis.stop()


def test_bare_name_then_the_request():
    mic = FakeMic(sentence(0) + sentence(30))
    lis, events = start(mic, FakeStt("Hey robo.", "open Moodle"))
    assert [events.get(timeout=5), events.get(timeout=5), events.get(timeout=5)] == [
        "wake", "wake", ("text", "open Moodle")]
    lis.stop()


def test_a_mic_that_goes_quiet_still_ends_the_sentence():
    mic = FakeMic(frames(0, 8) + frames(8, 14, SPEECH))  # then no frames at all
    lis, events = start(mic, FakeStt("Robo, open Moodle"))
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "open Moodle")]
    lis.stop()


def test_an_error_is_reported_not_silent():
    class Broken(FakeMic):
        def read(self, timeout):
            raise OSError("device unplugged")

    lis, events = start(Broken(), FakeStt())
    kind, message = events.get(timeout=5)
    assert kind == "error" and "unplugged" in message
    lis._thread.join(2)
    assert not lis._thread.is_alive()


def test_stop_returns_quickly_while_transcribing():
    class Slow(FakeStt):
        def __call__(self, audio):
            time.sleep(3)
            return "x"

    mic = FakeMic(sentence(0))
    lis, _ = start(mic, Slow())
    drained(mic)
    t = time.monotonic()
    lis.stop(wait=0.2)
    assert time.monotonic() - t < 1.0


def test_start_fails_without_the_mic():
    errors = []

    def no_mic():
        raise OSError("no input device")

    lis = Listener(lambda: None, lambda t: None, errors.append, mic=no_mic)
    assert not lis.start() and not lis.running
    assert errors == ["I can't open the microphone: no input device"]


def test_a_speech_model_that_will_not_load_is_reported_later_and_frees_the_mic():
    errors, mic = queue.Queue(), FakeMic()

    def no_model():
        raise RuntimeError("model missing")

    lis = Listener(lambda: None, lambda t: None, errors.put, mic=lambda: mic, transcriber=no_model)
    assert lis.start()  # the model loads on the listener thread, so start() cannot know yet
    assert errors.get(timeout=5) == "I can't load speech recognition: model missing"
    lis._thread.join(2)
    assert not lis.running and mic.closed


def test_start_returns_before_the_model_has_loaded_and_the_audio_is_kept():
    release, events = threading.Event(), queue.Queue()
    stt, mic = FakeStt("Robo, what time is it?"), FakeMic(sentence(0))  # spoken while loading

    def slow_model():
        release.wait(5)
        return stt

    lis = Listener(lambda: events.put("wake"), lambda t: events.put(("text", t)),
                   lambda m: events.put(("error", m)), mic=lambda: mic, transcriber=slow_model,
                   quick=lambda: FakeStt())
    assert not lis.running
    t = time.monotonic()
    assert lis.start() and lis.running
    assert time.monotonic() - t < 1.0 and events.empty() and not mic.q.empty()
    assert not lis.ready  # alive, but the model has not loaded
    release.set()
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "what time is it?")]
    assert lis.ready
    lis.stop()
    assert not lis.running and not lis.ready


def test_robo_perks_up_while_you_are_still_talking():
    order = []

    class Quick(FakeStt):
        def __call__(self, audio):
            order.append(("quick", len(audio) // FRAME))
            return "Robo, what is"

    class Final(FakeStt):
        def __call__(self, audio):
            order.append(("final", len(audio) // FRAME))
            return "Robo, what is the time in Tokyo right now?"

    long = frames(0, 8) + frames(8, 48, SPEECH) + frames(48, 70)  # 3.2 s of speech
    lis, events = start(FakeMic(long), Final(), quick=Quick())
    assert events.get(timeout=5) == "wake"
    assert order[0][0] == "quick" and order[0][1] < 30  # early, mid-sentence
    assert events.get(timeout=5) == ("text", "what is the time in Tokyo right now?")
    lis.stop()
    assert order[-1][0] == "final" and order.count(("final", order[-1][1])) == 1
    assert events.empty()  # one wake per sentence


def test_an_expected_sentence_wakes_robo_at_once():
    order, mic, done = [], FakeMic(), queue.Queue()

    def final(audio):
        order.append("final")
        return "and tomorrow?"

    lis = Listener(lambda: order.append("wake"), done.put, lambda m: None, mic=lambda: mic,
                   transcriber=lambda: final, quick=lambda: FakeStt())
    assert lis.start()
    lis.follow_up(10)
    for f in sentence(0):
        mic.q.put(f)
    assert done.get(timeout=5) == "and tomorrow?"
    lis.stop()
    assert order == ["wake", "final"]  # robo showed it was listening before transcribing


def test_other_speech_gets_only_the_quick_check():
    calls = []

    class Quick(FakeStt):
        def __call__(self, audio):
            calls.append("quick")
            return "I'm going to show you"

    long = frames(0, 8) + frames(8, 48, SPEECH) + frames(48, 70)
    mic = FakeMic(long)
    lis, events = start(mic, FakeStt("I'm going to show you how to do this."), quick=Quick())
    drained(mic)
    time.sleep(0.2)
    lis.stop()
    assert events.empty() and calls == ["quick"]


def test_saying_over_ends_the_command_even_while_the_tv_keeps_talking():
    seen = []

    class Quick(FakeStt):
        def __call__(self, audio):
            seen.append(len(audio) // FRAME)
            return "Robo, what's the date" if len(seen) == 1 else "what's the date, over."

    noisy = frames(0, 8) + frames(8, 208, SPEECH)  # 16 s of sound: the room never goes quiet
    stt = FakeStt("Robo, what's the date, over.")
    lis, events = start(FakeMic(noisy), stt, quick=Quick())
    assert events.get(timeout=5) == "wake"
    assert events.get(timeout=5) == ("text", "what's the date")
    lis.stop()
    assert len(stt.heard[0]) // FRAME < 60  # ended at "over", not at the 15 s limit


@pytest.mark.parametrize(("text", "command"), [
    ("Robo, what's the date, over.", "what's the date"),
    ("what's the date over", "what's the date"),
    ("Robo, flip the page over", "flip the page over"),  # not ended by the word: kept
])
def test_over_is_dropped_only_when_it_ended_the_command(text, command):
    ended = text != "Robo, flip the page over"
    assert listen.without_name(listen.without_over(text) if ended else text) == command


def test_one_model_serves_the_quick_checks_by_default():
    loads = []

    def model():
        loads.append(1)
        return FakeStt()

    lis = Listener(lambda: None, lambda t: None, lambda m: None, mic=FakeMic, transcriber=model)
    assert lis.start()
    lis.stop()
    assert len(loads) == 1 and lis._quick is lis._stt  # Parakeet is fast enough for both


def test_once_robo_is_listening_a_thinking_pause_does_not_end_the_request():
    # woke by name, then 1.2 s of silence mid-request, then more words
    clip = (frames(0, 8) + frames(8, 20, SPEECH) + frames(20, 35) + frames(35, 45, SPEECH)
            + frames(45, 80))
    stt = FakeStt("Robo, plan my day and also check my mail")
    lis, events = start(FakeMic(clip), stt, quick=FakeStt("Robo, plan my"))
    assert events.get(timeout=5) == "wake"
    assert events.get(timeout=5) == ("text", "plan my day and also check my mail")
    lis.stop()
    assert len(stt.heard) == 1 and 44 in tags(stt.heard[0])  # one request, both halves


def test_a_long_request_is_not_cut_at_fifteen_seconds():
    clip = frames(0, 8) + frames(8, 8 + 375, SPEECH) + frames(383, 420)  # 30 s of speech
    stt = FakeStt("Robo, a long question")
    lis, events = start(FakeMic(clip), stt, quick=FakeStt("Robo, a"))
    assert events.get(timeout=5) == "wake"
    assert events.get(timeout=10) == ("text", "a long question")
    lis.stop()
    assert len(stt.heard[0]) // FRAME > 375


# --- a microphone that dies or only gives silence ----------------------------------------------


class Ticking(FakeMic):
    """A mic on a hand-driven clock: every empty read is a READ_TIMEOUT that passes."""

    def __init__(self, clock, fs=()):
        super().__init__(fs)
        self.clock = clock

    def read(self, timeout):
        f = super().read(timeout)
        if f is None:
            self.clock.t += timeout
        return f


def test_a_mic_that_stops_delivering_is_reopened_and_the_next_outage_reported_again(monkeypatch):
    monkeypatch.setattr(listen, "MIC_RETRY_S", 0.01)
    clock, events = Clock(), queue.Queue()
    dead, fresh, gone = Ticking(clock), Ticking(clock, sentence(0)), OSError("no device")
    mics = itertools.chain([dead, gone, fresh], itertools.repeat(gone))  # reopening fails once

    def factory():
        mic = next(mics)
        if isinstance(mic, Exception):
            raise mic
        return mic

    lis = Listener(lambda: events.put("wake"), lambda t: events.put(("text", t)),
                   lambda m: events.put(("error", m)), mic=factory,
                   transcriber=lambda: FakeStt("Robo, what time is it?"), quick=lambda: FakeStt(),
                   clock=clock)
    assert lis.start()
    assert events.get(timeout=5) == ("error", "I lost the microphone, reconnecting...")
    assert [events.get(timeout=5), events.get(timeout=5)] == ["wake", ("text", "what time is it?")]
    assert events.get(timeout=5)[0] == "error"  # the fresh mic died too: reported again
    lis.stop()  # ...and stop() ends the retrying
    assert dead.closed and fresh.closed and events.empty() and not lis.running


class Scripted(FakeMic):
    """Plays `script`: a frame, or None for a READ_TIMEOUT that passes on the hand-driven clock;
    once it runs out, the mic just waits."""

    def __init__(self, clock, script):
        super().__init__()
        self.clock, self.script = clock, list(script)

    def read(self, timeout):
        if not self.script:
            time.sleep(0.005)
            return None
        item = self.script.pop(0)
        if item is None:
            self.clock.t += timeout
        return item


@pytest.mark.parametrize(("timeouts", "reported"), [(9, False), (10, True)])  # 4.5 s, 5 s
def test_only_a_gap_of_mic_stall_seconds_is_an_outage(timeouts, reported):
    clock, errors = Clock(), []
    mic = Scripted(clock, frames(0, 4) + [None] * timeouts + frames(4, 6))
    lis = Listener(lambda: None, lambda t: None, errors.append, mic=lambda: mic,
                   transcriber=lambda: FakeStt(), clock=clock)
    assert lis.start()
    end = time.monotonic() + 5
    while mic.script and time.monotonic() < end:
        time.sleep(0.005)
    time.sleep(0.05)
    lis.stop()
    assert bool(errors) == reported


def test_a_mic_that_only_gives_silence_is_reported_once_until_sound_returns():
    def zeros(n):
        return [np.zeros(FRAME, np.float32) for _ in range(n)]

    n = listen.SILENT_FRAMES
    mic = FakeMic(zeros(n + 20) + frames(1, 4) + zeros(n + 5) + frames(5, 8) + zeros(n - 1)
                  + frames(8, 10))
    lis, events = start(mic, FakeStt())
    drained(mic)
    assert lis.running  # not fatal
    lis.stop()
    errors = [events.get_nowait() for _ in range(events.qsize())]
    assert len(errors) == 2 and all(
        kind == "error" and "only gives me silence" in m and "Microphone" in m
        for kind, m in errors)
