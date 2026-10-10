"""Push-to-talk speech input for the agent prompt, transcribed on this machine.

The agent reads its requests from an `input_fn(prompt) -> str`. `voice_input` is a
drop-in for `input`: type a line and it is used as typed; press Enter on an empty
line and the microphone listens until you press Enter again, and the words come back
as if you had typed them.

**Audio stays on this machine.** The speech model runs locally (faster-whisper) and
the recording is never written to disk or sent anywhere; only the final text goes on
to the agent, exactly like a typed line.

Rules:

1. **Typing always works, and never starts the microphone.** A line with anything in
   it is returned untouched. Only an empty or space-only line means "listen".
2. **Silence never reaches the speech model.** Whisper answers an empty room with
   fluent nonsense ("Thank you."), which the agent would then act on. A clip that is
   too short or too quiet is dropped before transcription.
3. **The transcript is normalised.** The REPL matches `quit` and `help` exactly, and
   Whisper writes "Quit." - so the text is lowercased and stripped of punctuation.
4. **Nothing the recogniser or a library says reaches the terminal as markup.**
5. **Leaving while listening still leaves.** Ctrl-D / Ctrl-C during a recording stops
   the microphone first and then propagates, so the REPL's own exit path runs.
6. **A forgotten microphone cannot grow without bound.** At most `MAX_SECONDS` of
   audio is kept.

Importing this module, and constructing the recorder or the transcriber, must never
require `sounddevice`, `faster_whisper` or numpy. A box without the `voice` extra still
runs everything else, so those imports happen inside the calls that need them and a
failure becomes a `VoiceError` that names the fix.
"""

from __future__ import annotations

import contextlib
import importlib
import math
import re
import threading
from array import array
from collections.abc import Callable
from typing import TYPE_CHECKING, Any, Protocol

from rich.console import Console
from rich.markup import escape

if TYPE_CHECKING:  # pragma: no cover - only needed for the annotation
    from pli.config import Settings

__all__ = [
    "MAX_SECONDS",
    "MIN_SAMPLES",
    "PROMPT_HINT",
    "SAMPLE_RATE",
    "SILENCE_RMS",
    "Recorder",
    "SoundDeviceRecorder",
    "VoiceError",
    "WhisperTranscriber",
    "build_voice_input",
    "normalise",
    "overdriven",
    "rms",
    "voice_input",
]

#: What Whisper expects: 16 kHz, mono.
SAMPLE_RATE = 16_000
#: Longest recording kept. A request is a sentence; this only bounds a forgotten mic.
MAX_SECONDS = 15
MAX_SAMPLES = MAX_SECONDS * SAMPLE_RATE
#: Longest `start()` waits for real audio. A cold PipeWire input delivered ~0.7 s of
#: digital zeros before the first real sample (measured on this machine; a warm one,
#: none), so without the wait a speaker who starts the moment "Listening" appears loses
#: the front of the first word. It returns as soon as audio is live, so the ceiling only
#: costs time when the microphone is genuinely dead.
WARMUP_SECONDS = 1.5
#: Anything shorter than this (0.3 s) is a bump on the desk, not a request.
MIN_SAMPLES = int(0.3 * SAMPLE_RATE)
#: Below this RMS (fraction of full scale) the clip is treated as silence. Starting
#: value, to be calibrated live on this microphone in this room.
SILENCE_RMS = 0.01
#: Given to Whisper as `initial_prompt`: the words this agent is likely to be told,
#: so "unsure" is not heard as "on sure".
PROMPT_HINT = (
    "read my mail, show the deadlines, show the important ones, security alerts, "
    "show what you are unsure about, quit"
)

_NOT_WORD = re.compile(r"[^\w\s']")


class VoiceError(RuntimeError):
    """Voice input cannot work right now. The message is one sentence a person can act on."""


class Recorder(Protocol):
    def start(self) -> None: ...

    def stop(self) -> array[int]: ...


#: Curly and look-alike apostrophes, mapped to the plain one.
_APOSTROPHES = str.maketrans(dict.fromkeys("\u2018\u2019\u02bc`\u00b4", "'"))


def normalise(text: str) -> str:
    """Lowercase, punctuation to spaces (apostrophes kept, curly ones made straight so
    "haven't" stays one word), whitespace collapsed."""
    return " ".join(_NOT_WORD.sub(" ", text.lower().translate(_APOSTROPHES)).split())


#: A sample this close to full scale (of 32768) counts as clipped.
CLIP_LEVEL = 32_000
#: An input is "overdriven" when this share of it is clipped, or when its RMS is above
#: LOUD_RMS. Measured here: a real speech clip is RMS 0.14 with 0% clipped; the same
#: microphone with its gain at maximum read RMS 0.44-0.65 with 1.4-19% clipped in a quiet room.
CLIP_FRACTION = 0.01
LOUD_RMS = 0.4


def overdriven(samples: array[int]) -> bool:
    """True when the input is clipping or far louder than speech: gain set too high."""
    if not samples:
        return False
    clipped = sum(1 for s in samples if abs(s) >= CLIP_LEVEL)
    return clipped / len(samples) >= CLIP_FRACTION or rms(samples) >= LOUD_RMS


def rms(samples: array[int]) -> float:
    """Root-mean-square level on a -1..1 scale. Silence, and an empty clip, are 0.0."""
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768


def _say(console: Console, style: str, message: str) -> None:
    console.print(f"[{style}]{escape(message)}[/{style}]")


def voice_input(
    read_line: Callable[[str], str],
    recorder: Recorder,
    transcriber: Callable[[array[int]], str],
    console: Console,
    on_listen: Callable[[], None] | None = None,
) -> Callable[[str], str]:
    """An `input_fn`: typed lines pass through, an empty line listens.

    `on_listen` is called once each time the microphone actually opens, so a status
    window can show it; it is not called for typed lines or when the microphone fails.
    """

    def input_fn(prompt: str) -> str:
        line = read_line(prompt)
        if line.strip():
            return line
        console.print("[dim]Opening the microphone...[/dim]")
        try:
            recorder.start()
        except VoiceError as exc:
            _say(console, "red", str(exc))
            return ""
        if on_listen is not None:
            on_listen()
        console.print("[dim]Listening - press Enter to stop.[/dim]")
        try:
            read_line("")
        except (EOFError, KeyboardInterrupt):
            recorder.stop()
            raise
        samples = recorder.stop()
        if len(samples) < MIN_SAMPLES or rms(samples) < SILENCE_RMS:
            console.print("[dim]Heard nothing.[/dim]")
            return ""
        if overdriven(samples):
            _say(
                console,
                "yellow",
                "Your microphone input is overdriven, so speech may be misheard and silence "
                "cannot be told from talking. Lower the input volume - see 'Check your input "
                "gain' in the README.",
            )
        try:
            text = normalise(transcriber(samples))
        except VoiceError as exc:
            _say(console, "red", str(exc))
            return ""
        if not text:
            console.print("[dim]Heard nothing.[/dim]")
            return ""
        console.print(f'Heard: "{escape(text)}"')
        return text

    return input_fn


class SoundDeviceRecorder:
    """Records the default microphone into memory while between `start` and `stop`."""

    def __init__(self) -> None:
        self._samples: array[int] = array("h")
        self._stream: Any = None
        #: Set when the first non-silent audio arrives: the stream is really running.
        self._live = threading.Event()

    def start(self) -> None:
        sounddevice = _import_sounddevice()
        self._samples = array("h")
        self._live.clear()
        try:
            self._stream = sounddevice.InputStream(
                samplerate=SAMPLE_RATE, channels=1, dtype="int16", callback=self._on_audio
            )
            self._stream.start()
        except Exception as exc:
            self._release()
            raise VoiceError(f"Could not open the microphone: {exc}") from exc
        # Opened is not listening: wait for real audio so "Listening" means it, or give up.
        try:
            self._live.wait(WARMUP_SECONDS)
        except BaseException:  # Ctrl-C while warming up must not leave the microphone open
            self._release()
            raise

    def stop(self) -> array[int]:
        self._release()
        return self._samples

    def _on_audio(self, indata: Any, frames: int, time: Any, status: Any) -> None:
        self._append(indata.tobytes())

    def _append(self, chunk: bytes) -> None:
        if not self._live.is_set() and any(chunk):
            self._live.set()
        room = MAX_SAMPLES - len(self._samples)
        if room > 0:
            self._samples.frombytes(chunk[: room * self._samples.itemsize])

    def _release(self) -> None:
        """Stop and close the stream if there is one. Cleanup never raises."""
        stream, self._stream = self._stream, None
        if stream is None:
            return
        with contextlib.suppress(Exception):
            stream.stop()
        with contextlib.suppress(Exception):
            stream.close()


def _import_sounddevice() -> Any:
    try:
        return importlib.import_module("sounddevice")
    except ImportError as exc:
        raise VoiceError("Microphone support is not installed. Run: uv sync --extra voice") from exc
    except OSError as exc:  # sounddevice raises this when PortAudio itself is missing
        raise VoiceError(
            "The PortAudio system library is missing, so the microphone cannot be used. "
            "Run: sudo apt install libportaudio2"
        ) from exc


class WhisperTranscriber:
    """Speech to text with a local faster-whisper model, loaded on first use."""

    def __init__(self, model_name: str, *, console: Console) -> None:
        self._model_name = model_name
        self._console = console
        self._model: Any = None

    def __call__(self, samples: array[int]) -> str:
        try:
            faster_whisper, numpy = _import_speech_packages()
            if self._model is None:
                self._console.print(
                    f"[dim]Loading speech model {escape(self._model_name)} "
                    "(the first run downloads it)...[/dim]"
                )
                self._model = faster_whisper.WhisperModel(
                    self._model_name, device="cpu", compute_type="int8"
                )
            audio = numpy.frombuffer(samples, dtype=numpy.int16).astype(numpy.float32) / 32768.0
            # `transcribe` is lazy: the audio is only decoded while the segments are read.
            segments, _info = self._model.transcribe(
                audio,
                language="en",
                beam_size=1,
                vad_filter=True,
                condition_on_previous_text=False,
                initial_prompt=PROMPT_HINT,
            )
            return " ".join(segment.text.strip() for segment in segments).strip()
        except VoiceError:
            raise
        except Exception as exc:
            raise VoiceError(f"Speech-to-text failed: {exc}") from exc


def _import_speech_packages() -> tuple[Any, Any]:
    try:
        return importlib.import_module("faster_whisper"), importlib.import_module("numpy")
    except ImportError as exc:
        raise VoiceError("Speech-to-text is not installed. Run: uv sync --extra voice") from exc


def build_voice_input(
    settings: Settings, console: Console, on_listen: Callable[[], None] | None = None
) -> Callable[[str], str]:
    """The `input_fn` for `pli agent --voice`. Constructing it imports nothing heavy."""
    return voice_input(
        input,
        SoundDeviceRecorder(),
        WhisperTranscriber(settings.stt_model, console=console),
        console,
        on_listen,
    )
