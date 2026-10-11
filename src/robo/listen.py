"""Hands-free voice input: a wake word (sherpa-onnx KWS), then one utterance (faster-whisper)."""

from __future__ import annotations

import logging
import os
import queue
import re
import shutil
import tarfile
import tempfile
import threading
import urllib.request
from collections import deque
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Protocol

import numpy as np

log = logging.getLogger(__name__)

SAMPLE_RATE = 16000
FRAME = 1280  # 80 ms
FRAME_S = FRAME / SAMPLE_RATE
PRE_ROLL_FRAMES = 25  # ~2 s kept before the wake fires: people say the command without a pause
NOISE_FRAMES = 62  # ~5 s of idle RMS for the noise floor
NOISE_PERCENTILE = 20
GATE_FACTOR = 2.5  # speech = RMS above 2.5x the room's noise floor...
MIN_GATE = 0.02  # ...and above this (float RMS, -1..1)
END_SILENCE_S = 1.0
NO_SPEECH_S = 6.0
MAX_UTTERANCE_S = 15.0
READ_TIMEOUT = 0.5

WAKE_PHRASES = ("robo", "robot", "hey robo", "hey robot", "okay robo")
KWS_THRESHOLD = 0.15  # measured: 4/7 wakes, 0 false wakes on room/TV speech; no ":boost"
KWS_NAME = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
KWS_URL = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/{KWS_NAME}.tar.bz2"
CACHE = Path.home() / ".cache" / "robo"
WHISPER_MODEL = "base.en"

_WAKE = re.compile(r"^\W*(?:(?:hey|hi|ok|okay|yo)\W+)?rob(?:ots|ot|oh|ow|bo|o)\b\W*", re.I)


def strip_wake(text: str) -> str:
    """The command after a leading wake phrase ("Hey Robo, what's up?" -> "what's up?")."""
    command = _WAKE.sub("", text, count=1).strip()
    return command if re.search(r"\w", command) else ""


def rms(frame: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(frame))))


def speech_gate(idle_rms: Iterable[float]) -> float:
    """RMS above which a frame counts as speech, from recent idle RMS (the room's noise)."""
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


class Spotter(Protocol):
    def hit(self, frame: np.ndarray) -> bool: ...  # True when a wake phrase just ended
    def reset(self) -> None: ...  # forget audio fed so far


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


class WakeSpotter:
    """sherpa-onnx open-vocabulary keyword spotter for WAKE_PHRASES."""

    def __init__(self, model: Path):
        import sentencepiece
        import sherpa_onnx

        bpe = sentencepiece.SentencePieceProcessor(model_file=str(model / "bpe.model"))
        keywords = model / "robo-keywords.txt"
        keywords.write_text("".join(
            f"{' '.join(bpe.encode(p.upper(), out_type=str))} @{p.upper().replace(' ', '_')}\n"
            for p in WAKE_PHRASES))
        onnx = {p: str(next(model.glob(f"{p}-*[!8].onnx"))) for p in ("encoder", "decoder",
                                                                      "joiner")}  # not .int8
        self._kws = sherpa_onnx.KeywordSpotter(
            tokens=str(model / "tokens.txt"), **onnx, keywords_file=str(keywords),
            num_threads=1, keywords_threshold=KWS_THRESHOLD)
        self.reset()

    def hit(self, frame: np.ndarray) -> bool:
        self._stream.accept_waveform(SAMPLE_RATE, frame)
        while self._kws.is_ready(self._stream):
            self._kws.decode_stream(self._stream)
        if not self._kws.get_result(self._stream):
            return False
        self._kws.reset_stream(self._stream)
        return True

    def reset(self) -> None:
        self._stream = self._kws.create_stream()


class Whisper:
    """faster-whisper base.en on CPU (int8); construct it where it should load (~1 s)."""

    def __init__(self):
        from faster_whisper import WhisperModel

        self._model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")

    def __call__(self, audio: np.ndarray) -> str:
        segments, _ = self._model.transcribe(audio, language="en", beam_size=1, vad_filter=True,
                                             initial_prompt="Hey Robo,")
        return " ".join(s.text.strip() for s in segments).strip()


def ensure_kws_model(root: Path = CACHE,
                     fetch: Callable[[str, Path], object] = urllib.request.urlretrieve) -> Path:
    """The KWS model dir under `root`, downloaded (~13 MB) and unpacked on first use."""
    model = root / KWS_NAME
    if model.is_dir():
        return model
    root.mkdir(parents=True, exist_ok=True)
    part = root / f"{KWS_NAME}.tar.bz2.part"
    tmp = Path(tempfile.mkdtemp(dir=root, prefix=".kws-"))
    try:
        fetch(KWS_URL, part)
        with tarfile.open(part) as tar:
            tar.extractall(tmp, filter="data")
        os.replace(tmp / KWS_NAME, model)  # appears complete or not at all
    finally:
        part.unlink(missing_ok=True)
        shutil.rmtree(tmp, ignore_errors=True)
    return model


class Listener:
    """Wake word -> one spoken command, on a daemon thread; callbacks run on that thread.

    `on_wake()` when the wake word is heard, then `on_text(command)` ("" when nothing
    intelligible was said). `listen_now()` skips the wake word for the next utterance.
    """

    def __init__(self, on_wake: Callable[[], None], on_text: Callable[[str], None],
                 on_error: Callable[[str], None], mic: Callable[[], Mic] = SoundDeviceMic,
                 spotter: Callable[[], Spotter] = lambda: WakeSpotter(ensure_kws_model()),
                 transcriber: Callable[[], Callable[[np.ndarray], str]] = Whisper):
        self.on_wake, self.on_text, self.on_error = on_wake, on_text, on_error
        self._mic, self._spotter, self._transcriber = mic, spotter, transcriber
        self._stt: Callable[[np.ndarray], str] | None = None  # loaded on first use
        self._now, self._stop = threading.Event(), threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        """Open the mic and load the wake word model (downloaded the first time); False if not."""
        try:
            mic = self._mic()
        except Exception as e:
            self.on_error(f"I can't open the microphone: {e}")
            return False
        try:
            spotter = self._spotter()
        except Exception as e:
            mic.close()
            self.on_error(f"I can't load the wake word model: {e}")
            return False
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, args=(mic, spotter), daemon=True,
                                        name="robo-listen")
        self._thread.start()
        return True

    def listen_now(self) -> None:
        self._now.set()

    def stop(self, wait: float = READ_TIMEOUT + 5) -> None:
        """End the thread; waits up to `wait` s (a transcription in flight finishes on its own)."""
        self._stop.set()
        if self._thread:
            self._thread.join(wait)

    def _run(self, mic: Mic, spotter: Spotter) -> None:
        pre_roll: deque[np.ndarray] = deque(maxlen=PRE_ROLL_FRAMES)
        idle_rms: deque[float] = deque(maxlen=NOISE_FRAMES)
        try:
            while not self._stop.is_set():
                woke = False
                if not self._now.is_set():
                    frame = mic.read(READ_TIMEOUT)
                    if frame is None:
                        continue
                    pre_roll.append(frame)
                    idle_rms.append(rms(frame))
                    if not spotter.hit(frame):
                        continue
                    woke = True
                try:
                    if woke:
                        self.on_wake()
                    self._command(mic, list(pre_roll) if woke else [], speech_gate(idle_rms))
                except Exception as e:
                    log.exception("voice command failed")
                    self.on_error(f"I couldn't hear that: {e}")
                self._now.clear()  # a click while already listening is not a second request
                pre_roll.clear()
                spotter.reset()
        except Exception as e:  # the mic or the wake word model failed: say so, stop listening
            log.exception("listener stopped")
            self.on_error(f"Voice input stopped: {e}")
        finally:
            mic.close()

    def _command(self, mic: Mic, pre_roll: list[np.ndarray], gate: float) -> None:
        frames, heard = self._record(mic, gate)
        text = self._transcribe(pre_roll + frames) if heard or pre_roll else ""
        command = strip_wake(text)
        if not command and heard and _WAKE.match(text):  # just the wake word, then a pause
            frames, heard = self._record(mic, gate)
            command = strip_wake(self._transcribe(frames)) if heard else ""
        if not self._stop.is_set():
            self.on_text(command)

    def _record(self, mic: Mic, gate: float) -> tuple[list[np.ndarray], bool]:
        """Frames until the utterance ends (or stop()); and whether any speech was heard."""
        ep, frames = Endpointer(gate), []
        while not self._stop.is_set():
            frame = mic.read(READ_TIMEOUT)
            if frame is None:  # the mic went quiet: that time counts as silence
                if any(ep.feed(0.0) for _ in range(round(READ_TIMEOUT / FRAME_S))):
                    break
                continue
            frames.append(frame)
            if ep.feed(rms(frame)):
                break
        return frames, ep.heard

    def _transcribe(self, frames: list[np.ndarray]) -> str:
        if not frames or self._stop.is_set():
            return ""
        self._stt = self._stt or self._transcriber()
        return self._stt(np.concatenate(frames))
