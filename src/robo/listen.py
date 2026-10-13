"""Hands-free voice input: robo hears every sentence (Parakeet TDT v2, on this laptop) and takes
the ones that call it by name ("robo, what time is it?", "what's due, robo?"), plus anything said
in the few seconds after it answers, or after a click on its face. Nothing leaves the laptop."""

from __future__ import annotations

import logging
import os
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
END_SILENCE_S = 0.7  # other speech (TV, people): short, so little is transcribed
NO_SPEECH_S = 6.0
MAX_UTTERANCE_S = 15.0
PATIENT_SILENCE_S = 3.0  # talking to robo: a pause to think does not end the request (no end word)
PATIENT_MAX_S = 120.0
MIN_SPEECH_FRAMES = 4  # ~0.3 s above the gate, or it was a knock, not a sentence
READ_TIMEOUT = 0.5
STT_MODEL = "nemo-parakeet-tdt-0.6b-v2"  # int8 ONNX: ~0.4 s for 3 s of speech on this CPU
EARLY_FRAMES = 15  # ~1.2 s into a sentence, check whether it starts with robo's name
MIC_STALL_S = 5.0  # no frame for this long: the mic is gone (unplugged, or stuck after a sleep)
MIC_RETRY_S = 5.0  # ...then it is reopened this often
SILENT_FRAMES = 38  # ~3 s of exact zeros: that is what a microphone without permission delivers

# How Parakeet writes the user's "robo" (measured on two recordings of their voice): Robo, Rubo,
# Robbo, Roombo; at the start of a sentence also Robot and Rubble. "Robot"/"rubble" at the end, and
# "robots", are just words ("bought a robot.", "Robots are interesting").
_SOUND = r"r(?:o|u|oo|ou)m?bb?"
_START_NAME = rf"{_SOUND}(?:o|oh|ow|ot|le)"
_END_NAME = rf"{_SOUND}(?:o|oh|ow)"
# \W* after the greeting: Parakeet sometimes glues it to the name ("Yorobo"); the name must still
# fit whole, so "Hirobumi" and "Hiring" do not match
_LEAD = re.compile(rf"^\W*(?:(?:hey|hi|high|hay|ok|okay|yo)\W*)?{_START_NAME}\b\W*", re.I)
_TAIL = re.compile(rf"\W*\b{_END_NAME}\W*$", re.I)
_ANYWHERE = re.compile(rf"\b{_END_NAME}\b", re.I)  # "robo"-like words are rare anywhere


def addressed(text: str) -> str | None:
    """The request in `text` if it calls robo by name, else None ("" = just the name)."""
    if not (_LEAD.match(text) or _TAIL.search(text) or _ANYWHERE.search(text)):
        return None
    return without_name(text)


def without_name(text: str) -> str:
    """`text` without a leading or trailing "(hey) robo"."""
    command = _TAIL.sub("", _LEAD.sub("", text, count=1)).strip()
    return command if re.search(r"\w", command) else ""


def rms(frame: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(frame))))


LEVEL_PEAK = 0.5  # Parakeet reads soft speech worse (TTS at 0.15x: 44 -> 48 of 50 names caught)
LEVEL_MAX_GAIN = 20.0  # ...but near-silence must not become loud noise


def leveled(audio: np.ndarray) -> np.ndarray:
    """`audio` scaled so its peak (99.5th percentile, so one click doesn't count) is LEVEL_PEAK."""
    peak = float(np.percentile(np.abs(audio), 99.5))
    if not peak:
        return audio
    return (audio * min(LEVEL_MAX_GAIN, LEVEL_PEAK / peak)).astype(np.float32, copy=False)


def speech_gate(idle_rms: Iterable[float]) -> float:
    """RMS above which a frame counts as speech, from recent quiet RMS (the room's noise)."""
    levels = list(idle_rms)
    floor = float(np.percentile(levels, NOISE_PERCENTILE)) if levels else 0.0
    return max(GATE_FACTOR * floor, MIN_GATE)


class Endpointer:
    """Decides, frame by frame, when one spoken utterance is over."""

    def __init__(self, gate: float, frame_s: float = FRAME_S):
        self.gate, self.frame_s = gate, frame_s
        self.end_silence, self.max_s = END_SILENCE_S, MAX_UTTERANCE_S
        self.frames = self.silent = 0
        self.heard = False

    def feed(self, level: float) -> bool:
        """Add one frame's RMS; True once the utterance ended (or never started)."""
        self.frames += 1
        if level > self.gate:
            self.heard, self.silent = True, 0
        else:
            self.silent += 1
        if self.frames * self.frame_s >= self.max_s:
            return True
        if self.heard:
            return self.silent * self.frame_s >= self.end_silence
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


class Parakeet:
    """NVIDIA Parakeet TDT 0.6B v2 (English) via onnx-asr, int8 on CPU; loads in a few seconds
    (downloaded once, ~650 MB, into the Hugging Face cache)."""

    def __init__(self):
        # onnxruntime 1.30+ opens a connection to a Microsoft server to report usage unless this is
        # set before it starts (checked 2026-10-13 on 1.31); robo is an offline assistant.
        os.environ.setdefault("ORT_DISABLE_TELEMETRY", "1")
        import onnx_asr

        # CPU only: CoreML (macOS default) loads 3x slower, runs 2x slower, hears differently
        self._model = onnx_asr.load_model(STT_MODEL, quantization="int8",
                                          providers=["CPUExecutionProvider"])

    def __call__(self, audio: np.ndarray) -> str:
        return str(self._model.recognize(leveled(audio), sample_rate=SAMPLE_RATE)).strip()


class Listener:
    """Hears every sentence on a daemon thread; callbacks run on that thread.

    `on_wake()` when robo is called by name, then `on_text(request)`. A request ends after
    PATIENT_SILENCE_S of quiet. A sentence also counts without the name while robo expects
    one: after `listen_now()` (a click; `on_text("")` if nothing is said within NO_SPEECH_S),
    after `follow_up(seconds)` (it just answered), or right after a bare "robo". A mic that
    stops delivering is reopened; one that only gives silence is reported.
    """

    def __init__(self, on_wake: Callable[[], None], on_text: Callable[[str], None],
                 on_error: Callable[[str], None], mic: Callable[[], Mic] = SoundDeviceMic,
                 transcriber: Callable[[], Callable[[np.ndarray], str]] = Parakeet,
                 quick: Callable[[], Callable[[np.ndarray], str]] | None = None,
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
        self._last_audio = 0.0  # when the mic last delivered a frame
        self._zeros = 0  # consecutive all-zero frames

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    @property
    def ready(self) -> bool:
        """Running and the speech model is loaded: what you say is understood from now on."""
        return self.running and self._stt is not None

    def start(self) -> bool:
        """Open the mic (False and on_error if that fails); the thread loads speech recognition,
        so the window need not wait for it, and the audio spoken meanwhile is kept."""
        try:
            mic = self._mic()
        except Exception as e:
            self.on_error(f"I can't open the microphone: {e}")
            return False
        self._stop.clear()
        self._thread = threading.Thread(target=self._load_and_run, args=(mic,), daemon=True,
                                        name="robo-listen")
        self._thread.start()
        return True

    def _load_and_run(self, mic: Mic) -> None:
        try:
            self._stt = self._transcriber()
            self._quick = self._quick_factory() if self._quick_factory else self._stt
        except Exception as e:
            log.exception("speech recognition failed to load")
            mic.close()
            self.on_error(f"I can't load speech recognition: {e}")
            return
        self._last_audio = self._clock()
        self._run(mic)

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

    def _run(self, mic: Mic | None) -> None:
        pre_roll: deque[np.ndarray] = deque(maxlen=PRE_ROLL_FRAMES)
        quiet: deque[float] = deque(maxlen=NOISE_FRAMES)
        try:
            while not self._stop.is_set():
                if self._asked and self._clock() >= self._open_until:
                    self._asked = False  # clicked (or said "robo"), then nothing: give up
                    self.on_text("")
                frame = self._read(mic)
                if frame is None:
                    if self._clock() - self._last_audio >= MIC_STALL_S:
                        mic = self._reopen(mic)
                        if mic is None:  # stop() came first
                            return
                    continue
                gate = speech_gate(quiet)
                if rms(frame) <= gate:
                    pre_roll.append(frame)
                    quiet.append(rms(frame))
                    continue
                woke = self._clock() < self._open_until  # robo expects this sentence: show it now
                if woke:
                    self.on_wake()
                frames, loud, woke = self._record(mic, [*pre_roll, frame], gate, woke)
                pre_roll.clear()
                if loud >= MIN_SPEECH_FRAMES:
                    text = self._stt(np.concatenate(frames)) if self._stt else ""
                    self._heard(text, woke)
        except Exception as e:  # the mic or the recogniser failed: say so, stop listening
            log.exception("listener stopped")
            self.on_error(f"Voice input stopped: {e}")
        finally:
            if mic:
                mic.close()

    def _read(self, mic: Mic) -> np.ndarray | None:
        """One frame (None on timeout), noting when audio last came and if it is only silence."""
        frame = mic.read(READ_TIMEOUT)
        if frame is None:
            return None
        self._last_audio = self._clock()
        self._zeros = 0 if frame.any() else self._zeros + 1
        if self._zeros == SILENT_FRAMES:  # once per run of zeros
            self.on_error("The microphone only gives me silence. Check that it isn't muted and "
                          "that robo may use it (on a Mac: System Settings -> Privacy & Security "
                          "-> Microphone).")
        return frame

    def _reopen(self, dead: Mic) -> Mic | None:
        """The mic delivered nothing for MIC_STALL_S: say so, close it, reopen it every
        MIC_RETRY_S. None if stop() came first."""
        self.on_error("I lost the microphone, reconnecting...")
        try:
            dead.close()
        except Exception:
            log.warning("closing the lost microphone failed", exc_info=True)
        while True:
            try:
                mic = self._mic()
            except Exception as e:
                log.warning("microphone still unavailable: %s", e)
            else:
                self._last_audio = self._clock()
                return mic
            if self._stop.wait(MIC_RETRY_S):
                return None

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
                ) -> tuple[list[np.ndarray], int, bool]:
        """Frames until the sentence ends (or stop()), how many were above the gate, and whether
        robo woke up (a quick early check found its name at the start)."""
        ep, loud, start = Endpointer(gate), 1, len(frames)
        ep.feed(rms(frames[-1]))  # the frame that crossed the gate
        if woke:
            ep.end_silence, ep.max_s = PATIENT_SILENCE_S, PATIENT_MAX_S
        while not self._stop.is_set():
            frame = self._read(mic)
            if frame is None:  # the mic went quiet: that time counts as silence
                if any(ep.feed(0.0) for _ in range(round(READ_TIMEOUT / FRAME_S))):
                    break
                continue
            frames.append(frame)
            level = rms(frame)
            loud += level > gate
            if ep.feed(level):
                break
            if self._quick and not woke and len(frames) - start == EARLY_FRAMES:
                woke = addressed(self._quick(np.concatenate(frames))) is not None
                if woke:
                    self.on_wake()
                    ep.end_silence, ep.max_s = PATIENT_SILENCE_S, PATIENT_MAX_S
        return frames, loud, woke
