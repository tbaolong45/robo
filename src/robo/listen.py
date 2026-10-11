"""Hands-free voice input: robo hears every sentence (faster-whisper, on this laptop) and takes
the ones that call it by name ("robo, what time is it?", "what's due, robo?"), plus anything said
in the few seconds after it answers, or after a click on its face. Nothing leaves the laptop."""

from __future__ import annotations

import logging
import queue
import re
import threading
import time
from collections import deque
from collections.abc import Callable, Iterable
from typing import Protocol

import numpy as np

log = logging.getLogger(__name__)

SAMPLE_RATE = 16000
FRAME = 1280  # 80 ms
FRAME_S = FRAME / SAMPLE_RATE
PRE_ROLL_FRAMES = 6  # ~0.5 s kept from before the voice crossed the gate (soft first syllables)
NOISE_FRAMES = 62  # ~5 s of quiet RMS for the noise floor
NOISE_PERCENTILE = 20
GATE_FACTOR = 2.5  # speech = RMS above 2.5x the room's noise floor...
MIN_GATE = 0.02  # ...and above this (float RMS, -1..1)
END_SILENCE_S = 0.7
NO_SPEECH_S = 6.0
MAX_UTTERANCE_S = 15.0
MIN_SPEECH_FRAMES = 4  # ~0.3 s above the gate, or it was a knock, not a sentence
READ_TIMEOUT = 0.5
WHISPER_MODEL = "base.en"  # ~0.8 s per sentence on this CPU
QUICK_MODEL = "tiny.en"  # ~0.4 s: only to notice "robo, ..." while the sentence is still going
EARLY_FRAMES = 15  # ~1.2 s into a sentence, check whether it starts with robo's name
OVER_EVERY = 10  # ~0.8 s: while you talk to robo, check whether you just said "over"
OVER_WINDOW = 25  # ~2 s of the latest audio for that check

_NAME = r"rob(?:ots?|o|oh|ow|bo)"
_LEAD = re.compile(rf"^\W*(?:(?:hey|hi|ok|okay|yo)\W+)?{_NAME}\b\W*", re.I)
_TAIL = re.compile(rf"\W*\b{_NAME}\W*$", re.I)
_ANYWHERE = re.compile(r"\brob(?:o|oh|ow|bo)\b", re.I)  # "robo" is rare; "robot" only at an edge


def addressed(text: str) -> str | None:
    """The request in `text` if it calls robo by name, else None ("" = just the name)."""
    if not (_LEAD.match(text) or _TAIL.search(text) or _ANYWHERE.search(text)):
        return None
    return without_name(text)


_OVER = re.compile(r"[\W_]*\bover(?:\s+and\s+out)?\W*$", re.I)


def without_over(text: str) -> str:
    """`text` without the closing "over" that ended it."""
    return _OVER.sub("", text)


def without_name(text: str) -> str:
    """`text` without a leading or trailing "(hey) robo"."""
    command = _TAIL.sub("", _LEAD.sub("", text, count=1)).strip()
    return command if re.search(r"\w", command) else ""


def rms(frame: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(frame))))


def speech_gate(idle_rms: Iterable[float]) -> float:
    """RMS above which a frame counts as speech, from recent quiet RMS (the room's noise)."""
    levels = list(idle_rms)
    floor = float(np.percentile(levels, NOISE_PERCENTILE)) if levels else 0.0
    return max(GATE_FACTOR * floor, MIN_GATE)


class Endpointer:
    """Decides, frame by frame, when one spoken utterance is over."""

    def __init__(self, gate: float, frame_s: float = FRAME_S):
        self.gate, self.frame_s = gate, frame_s
        self.frames = self.silent = 0
        self.heard = False

    def feed(self, level: float) -> bool:
        """Add one frame's RMS; True once the utterance ended (or never started)."""
        self.frames += 1
        if level > self.gate:
            self.heard, self.silent = True, 0
        else:
            self.silent += 1
        if self.frames * self.frame_s >= MAX_UTTERANCE_S:
            return True
        if self.heard:
            return self.silent * self.frame_s >= END_SILENCE_S
        return self.frames * self.frame_s >= NO_SPEECH_S


class Mic(Protocol):
    def read(self, timeout: float) -> np.ndarray | None: ...  # one float32 FRAME, None on timeout
    def close(self) -> None: ...


class SoundDeviceMic:
    """16 kHz mono int16 microphone; a PortAudio callback queues frames so none are dropped."""

    def __init__(self):
        import sounddevice as sd

        self._q: queue.Queue[np.ndarray] = queue.Queue()
        self._stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="int16",
                                      blocksize=FRAME, callback=self._push)
        self._stream.start()

    def _push(self, indata, frames, time, status) -> None:
        self._q.put(indata[:, 0].astype(np.float32) / 32768)

    def read(self, timeout: float) -> np.ndarray | None:
        try:
            return self._q.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        self._stream.close()


class Whisper:
    """faster-whisper on CPU (int8); construct it where it should load (~1 s)."""

    def __init__(self, model: str = WHISPER_MODEL):
        from faster_whisper import WhisperModel

        self._model = WhisperModel(model, device="cpu", compute_type="int8")

    def __call__(self, audio: np.ndarray) -> str:
        segments, _ = self._model.transcribe(audio, language="en", beam_size=1, vad_filter=True,
                                             initial_prompt="Robo,")
        return " ".join(s.text.strip() for s in segments).strip()


class Listener:
    """Hears every sentence on a daemon thread; callbacks run on that thread.

    `on_wake()` when robo is called by name, then `on_text(request)`. Saying "over" ends a
    request at once, even when the room never goes quiet (TV). A sentence also counts
    without the name while robo expects one: after `listen_now()` (a click; `on_text("")` if
    nothing is said within NO_SPEECH_S), after `follow_up(seconds)` (it just answered), or right
    after a bare "robo".
    """

    def __init__(self, on_wake: Callable[[], None], on_text: Callable[[str], None],
                 on_error: Callable[[str], None], mic: Callable[[], Mic] = SoundDeviceMic,
                 transcriber: Callable[[], Callable[[np.ndarray], str]] = Whisper,
                 quick: Callable[[], Callable[[np.ndarray], str]] = lambda: Whisper(QUICK_MODEL),
                 clock: Callable[[], float] = time.monotonic):
        self.on_wake, self.on_text, self.on_error = on_wake, on_text, on_error
        self._mic, self._transcriber, self._quick_factory = mic, transcriber, quick
        self._clock = clock
        self._stt: Callable[[np.ndarray], str] | None = None
        self._quick: Callable[[np.ndarray], str] | None = None
        self._stop = threading.Event()
        self._open_until = 0.0  # a sentence without the name counts until then
        self._asked = False  # the open window came from a click or a bare "robo": end it with ""
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        """Open the mic and load Whisper; False (and on_error) if either fails."""
        try:
            mic = self._mic()
        except Exception as e:
            self.on_error(f"I can't open the microphone: {e}")
            return False
        try:
            self._stt, self._quick = self._transcriber(), self._quick_factory()
        except Exception as e:
            mic.close()
            self.on_error(f"I can't load speech recognition: {e}")
            return False
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, args=(mic,), daemon=True,
                                        name="robo-listen")
        self._thread.start()
        return True

    def listen_now(self) -> None:
        """The next sentence is for robo (the face was clicked)."""
        self._open(NO_SPEECH_S, asked=True)

    def follow_up(self, seconds: float) -> None:
        """Robo just answered: a reply in the next `seconds` needs no name."""
        self._open(seconds, asked=False)

    def _open(self, seconds: float, asked: bool) -> None:
        self._open_until, self._asked = self._clock() + seconds, asked

    def stop(self, wait: float = READ_TIMEOUT + 5) -> None:
        """End the thread; waits up to `wait` s (a transcription in flight finishes on its own)."""
        self._stop.set()
        if self._thread:
            self._thread.join(wait)

    def _run(self, mic: Mic) -> None:
        pre_roll: deque[np.ndarray] = deque(maxlen=PRE_ROLL_FRAMES)
        quiet: deque[float] = deque(maxlen=NOISE_FRAMES)
        try:
            while not self._stop.is_set():
                if self._asked and self._clock() >= self._open_until:
                    self._asked = False  # clicked (or said "robo"), then nothing: give up
                    self.on_text("")
                frame = mic.read(READ_TIMEOUT)
                if frame is None:
                    continue
                gate = speech_gate(quiet)
                if rms(frame) <= gate:
                    pre_roll.append(frame)
                    quiet.append(rms(frame))
                    continue
                woke = self._clock() < self._open_until  # robo expects this sentence: show it now
                if woke:
                    self.on_wake()
                frames, loud, woke, over = self._record(mic, [*pre_roll, frame], gate, woke)
                pre_roll.clear()
                if loud >= MIN_SPEECH_FRAMES:
                    text = self._stt(np.concatenate(frames)) if self._stt else ""
                    self._heard(without_over(text) if over else text, woke)
        except Exception as e:  # the mic or Whisper failed: say so, stop listening
            log.exception("listener stopped")
            self.on_error(f"Voice input stopped: {e}")
        finally:
            mic.close()

    def _heard(self, text: str, woke: bool) -> None:
        """Decide whether a transcribed sentence was for robo (`woke`: robo already showed it)."""
        if self._stop.is_set():
            return
        request = without_name(text) if woke else addressed(text)
        if request is None:
            return  # not for robo (TV, other people)
        if not woke:
            self.on_wake()
        self._open_until, self._asked = 0.0, False
        if request:
            self.on_text(request)
        else:  # just "robo" (or nothing intelligible): the request follows
            self._open(NO_SPEECH_S, asked=True)

    def _record(self, mic: Mic, frames: list[np.ndarray], gate: float, woke: bool
                ) -> tuple[list[np.ndarray], int, bool, bool]:
        """Frames until the sentence ends (or stop()), how many were above the gate, whether
        robo woke up (a quick early check found its name at the start), and whether "over"
        ended it."""
        ep, loud, start = Endpointer(gate), 1, len(frames)
        ep.feed(rms(frames[-1]))  # the frame that crossed the gate
        while not self._stop.is_set():
            frame = mic.read(READ_TIMEOUT)
            if frame is None:  # the mic went quiet: that time counts as silence
                if any(ep.feed(0.0) for _ in range(round(READ_TIMEOUT / FRAME_S))):
                    break
                continue
            frames.append(frame)
            level = rms(frame)
            loud += level > gate
            if ep.feed(level):
                break
            n = len(frames) - start
            if not self._quick or n < min(EARLY_FRAMES, OVER_EVERY):
                continue
            if not woke and n == EARLY_FRAMES:
                woke = addressed(self._quick(np.concatenate(frames))) is not None
                if woke:
                    self.on_wake()
            elif woke and n % OVER_EVERY == 0:
                if _OVER.search(self._quick(np.concatenate(frames[-OVER_WINDOW:]))):
                    return frames, loud, woke, True
        return frames, loud, woke, False
