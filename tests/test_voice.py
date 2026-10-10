"""Push-to-talk input for the agent prompt: what it hears, and what it refuses to pass on.

The agent reads a line from `input_fn(prompt)`. Voice is a different `input_fn`: an
empty line starts the microphone, a second Enter stops it, and the transcript is what
comes back as if it had been typed. Rules pinned here:

**Typing always works, and never starts the microphone.** A line with anything in it
comes back untouched. Only an empty (or space-only) line means "listen".

**Silence never reaches the speech model.** Whisper answers an empty room with fluent
nonsense ("Thank you."), which the agent would then act on. A clip that is too short
or too quiet is dropped before transcription and the user is told "Heard nothing".

**The transcript is normalised before it is returned.** The REPL matches `quit` and
`help` exactly, and Whisper writes "Quit." - lowercase, no punctuation, one space.

**Nothing the recogniser returns, and no error text, reaches the terminal as markup.**

**Leaving while listening still leaves.** Ctrl-D or Ctrl-C during a recording stops the
microphone first and then propagates, so the REPL's own exit path runs.

**A forgotten microphone cannot grow without bound.** The recorder keeps at most
`MAX_SECONDS` of audio; the rest is dropped.

**Nothing heavy is imported until it is used**, and a missing package, a missing system
library or a missing device is one sentence a person can act on, never a traceback.

Nothing here opens a microphone, loads a model, imports numpy or touches the network:
every device, model and module is a fake.
"""

from __future__ import annotations

import importlib
import io
import math
import sys
import threading
import time
from array import array
from typing import Any

import pytest
from rich.console import Console

from pli import voice
from pli.config import Settings

_REAL_IMPORT = importlib.import_module
LOUD = 3000  # about 0.09 of full scale, well above the silence floor
QUIET = 3  # about 0.0001 of full scale


def _clip(value: int = LOUD, *, seconds: float = 1.0, samples: int | None = None) -> array[int]:
    count = samples if samples is not None else int(seconds * voice.SAMPLE_RATE)
    return array("h", [value]) * count


def _console() -> tuple[Console, io.StringIO]:
    buffer = io.StringIO()
    return Console(file=buffer, width=200, force_terminal=False, color_system=None), buffer


class Reader:
    """A scripted `read_line`: returns each reply in turn, raises it if it is an exception.

    A callable reply is called and its result returned, so a test can look at what had
    been printed at the moment the program blocked waiting for Enter.
    """

    def __init__(self, *replies: Any) -> None:
        self.replies = list(replies)
        self.prompts: list[str] = []

    def __call__(self, prompt: str) -> str:
        self.prompts.append(prompt)
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        return reply() if callable(reply) else reply


class FakeRecorder:
    def __init__(self, audio: array[int] | None = None, start_error: Exception | None = None):
        self.audio = _clip() if audio is None else audio
        self.start_error = start_error
        self.started = 0
        self.stopped = 0

    def start(self) -> None:
        self.started += 1
        if self.start_error is not None:
            raise self.start_error

    def stop(self) -> array[int]:
        self.stopped += 1
        return self.audio


class FakeTranscriber:
    def __init__(self, text: str = "", error: Exception | None = None) -> None:
        self.text = text
        self.error = error
        self.calls: list[array[int]] = []

    def __call__(self, samples: array[int]) -> str:
        self.calls.append(samples)
        if self.error is not None:
            raise self.error
        return self.text


class Rig:
    """One `voice_input` wired to fakes, and the console it prints to."""

    def __init__(
        self,
        *,
        audio: array[int] | None = None,
        text: str = "",
        start_error: Exception | None = None,
        transcribe_error: Exception | None = None,
    ) -> None:
        self.console, self.buffer = _console()
        self.recorder = FakeRecorder(audio, start_error)
        self.transcriber = FakeTranscriber(text, transcribe_error)
        self.reader = Reader()

    def ask(self, *replies: Any) -> str:
        self.reader = Reader(*replies)
        read = voice.voice_input(self.reader, self.recorder, self.transcriber, self.console)
        return read("pli> ")

    @property
    def output(self) -> str:
        return self.buffer.getvalue()


# --- typing is untouched ---------------------------------------------------------


@pytest.mark.parametrize("line", ["read my mail", "  show the deadlines  ", "Quit.", "?"])
def test_a_typed_line_comes_back_untouched_and_the_microphone_never_starts(line: str) -> None:
    rig = Rig(text="Thank you.")

    assert rig.ask(line) == line

    assert rig.recorder.started == 0
    assert rig.recorder.stopped == 0
    assert rig.transcriber.calls == []
    assert rig.reader.prompts == ["pli> "]


def test_end_of_input_at_the_prompt_propagates_without_touching_the_microphone() -> None:
    rig = Rig()

    with pytest.raises(EOFError):
        rig.ask(EOFError())

    assert rig.recorder.started == 0


# --- push to talk ----------------------------------------------------------------


def test_enter_then_enter_records_and_returns_the_normalised_transcript() -> None:
    rig = Rig(text="Quit.")

    assert rig.ask("", "") == "quit"

    assert rig.recorder.started == 1
    assert rig.recorder.stopped == 1
    assert rig.transcriber.calls == [rig.recorder.audio]
    assert rig.reader.prompts == ["pli> ", ""]
    assert 'Heard: "quit"' in rig.output


@pytest.mark.parametrize("line", [" ", "   ", "\t", " \t "])
def test_a_space_only_line_counts_as_an_empty_one(line: str) -> None:
    rig = Rig(text="Read my mail.")

    assert rig.ask(line, "") == "read my mail"

    assert rig.recorder.started == 1


def test_the_listening_hint_says_how_to_stop_and_appears_before_the_wait() -> None:
    rig = Rig(text="Quit.")
    seen: list[str] = []

    rig.ask("", lambda: seen.append(rig.output) or "")

    assert len(seen) == 1
    assert "Listening" in seen[0]
    assert "Enter" in seen[0]
    assert "stop" in seen[0]


def test_the_user_is_told_the_microphone_is_opening_before_the_slow_part_begins() -> None:
    """Opening can take a couple of seconds the first time. Silence there invites a second
    Enter, which would then end the recording the moment it began."""
    rig = Rig(text="Quit.")
    at_start: list[str] = []
    opened = rig.recorder.start

    def spy() -> None:
        at_start.append(rig.output)
        opened()

    rig.recorder.start = spy  # type: ignore[method-assign]

    rig.ask("", "")

    assert "Opening the microphone" in at_start[0]
    assert "Listening" not in at_start[0]


def test_a_recorder_that_will_not_start_is_reported_and_returns_nothing() -> None:
    rig = Rig(start_error=voice.VoiceError("Could not open the microphone: no device."))

    assert rig.ask("") == ""

    assert "Could not open the microphone: no device." in rig.output
    assert "Listening" not in rig.output
    assert rig.reader.prompts == ["pli> "]
    assert rig.transcriber.calls == []


def test_an_error_message_is_printed_literally_not_as_markup() -> None:
    rig = Rig(start_error=voice.VoiceError("device [bold red]gone[/] away"))

    rig.ask("")

    assert "device [bold red]gone[/] away" in rig.output


def test_a_transcriber_error_is_reported_and_returns_nothing() -> None:
    rig = Rig(transcribe_error=voice.VoiceError("Speech-to-text failed: [boom]"))

    assert rig.ask("", "") == ""

    assert "Speech-to-text failed: [boom]" in rig.output
    assert "Heard:" not in rig.output


@pytest.mark.parametrize("interrupt", [EOFError(), KeyboardInterrupt()])
def test_leaving_while_listening_stops_the_microphone_and_still_propagates(
    interrupt: BaseException,
) -> None:
    rig = Rig(text="Quit.")

    with pytest.raises(type(interrupt)):
        rig.ask("", interrupt)

    assert rig.recorder.started == 1
    assert rig.recorder.stopped == 1
    assert rig.transcriber.calls == []


# --- silence never reaches the model ---------------------------------------------


def test_a_quiet_clip_never_reaches_the_transcriber() -> None:
    rig = Rig(audio=_clip(QUIET, seconds=2), text="Thank you.")

    assert rig.ask("", "") == ""

    assert rig.transcriber.calls == []
    assert "Heard nothing." in rig.output
    assert rig.recorder.stopped == 1


def test_a_clip_shorter_than_the_minimum_never_reaches_the_transcriber() -> None:
    rig = Rig(audio=_clip(samples=voice.MIN_SAMPLES - 1), text="Thank you.")

    assert rig.ask("", "") == ""

    assert rig.transcriber.calls == []
    assert "Heard nothing." in rig.output


def test_a_clip_of_exactly_the_minimum_length_is_transcribed() -> None:
    rig = Rig(audio=_clip(samples=voice.MIN_SAMPLES), text="Quit.")

    assert rig.ask("", "") == "quit"

    assert len(rig.transcriber.calls) == 1


def test_an_empty_recording_does_not_crash() -> None:
    rig = Rig(audio=array("h"), text="Thank you.")

    assert rig.ask("", "") == ""

    assert rig.transcriber.calls == []
    assert "Heard nothing." in rig.output


def test_the_silence_floor_separates_a_clip_just_below_from_one_just_above() -> None:
    edge = math.ceil(voice.SILENCE_RMS * 32768)  # the first int16 level at or over the floor
    quiet = Rig(audio=_clip(edge - 1), text="Quit.")
    audible = Rig(audio=_clip(edge), text="Quit.")

    assert quiet.ask("", "") == ""
    assert audible.ask("", "") == "quit"

    assert quiet.transcriber.calls == []
    assert len(audible.transcriber.calls) == 1


@pytest.mark.parametrize("text", ["", "   ", "...", "?!", " - . - "])
def test_a_transcript_with_no_words_returns_nothing(text: str) -> None:
    rig = Rig(text=text)

    assert rig.ask("", "") == ""

    assert "Heard nothing." in rig.output
    assert "Heard:" not in rig.output


def test_a_transcript_containing_markup_is_printed_without_being_interpreted() -> None:
    rig = Rig(text="[bold red]Quit[/]")

    assert rig.ask("", "") == "bold red quit"

    assert 'Heard: "bold red quit"' in rig.output


# --- normalise and rms -----------------------------------------------------------


@pytest.mark.parametrize(
    ("heard", "expected"),
    [
        ("Quit.", "quit"),
        ("Bye!", "bye"),
        ("Help?", "help"),
        ("Read my mail.", "read my mail"),
        ("  Show   the deadlines?? ", "show the deadlines"),
        ("What's due?", "what's due"),
        ("I haven\u2019t finished 3", "i haven't finished 3"),  # curly apostrophe kept as one
        ("show the important ones, please.", "show the important ones please"),
        ("Security-alerts", "security alerts"),
        ("Show\tthe\nevents", "show the events"),
        ("...", ""),
        ("", ""),
    ],
)
def test_normalise_lowercases_strips_punctuation_and_collapses_spaces(
    heard: str, expected: str
) -> None:
    assert voice.normalise(heard) == expected


def test_rms_of_nothing_is_zero_rather_than_an_error() -> None:
    assert voice.rms(array("h")) == 0.0


def test_rms_is_on_a_scale_where_full_scale_is_one() -> None:
    assert voice.rms(array("h", [-32768, -32768])) == pytest.approx(1.0)
    assert voice.rms(array("h", [16384, -16384, 16384])) == pytest.approx(0.5)
    assert voice.rms(array("h", [0, 0, 0])) == 0.0


# --- the recorder ----------------------------------------------------------------


def test_the_recorder_keeps_at_most_the_maximum_and_keeps_the_start() -> None:
    cap = voice.MAX_SECONDS * voice.SAMPLE_RATE
    recorder = voice.SoundDeviceRecorder()

    for second in range(1, 26):  # 25 s of audio, one distinct value per second
        recorder._append(_clip(second).tobytes())

    kept = recorder.stop()
    assert len(kept) == cap
    assert set(kept) == set(range(1, voice.MAX_SECONDS + 1))


def test_one_oversized_chunk_is_truncated_not_dropped() -> None:
    cap = voice.MAX_SECONDS * voice.SAMPLE_RATE
    recorder = voice.SoundDeviceRecorder()

    recorder._append(_clip(7, seconds=25).tobytes())

    kept = recorder.stop()
    assert len(kept) == cap
    assert set(kept) == {7}


def test_stopping_a_recorder_that_never_started_returns_empty_audio() -> None:
    assert len(voice.SoundDeviceRecorder().stop()) == 0


class FakeStream:
    def __init__(self, owner: FakeSoundDevice, **kwargs: Any) -> None:
        self.owner = owner
        self.kwargs = kwargs

    def start(self) -> None:
        self.owner.events.append("start")
        if self.owner.start_error:
            raise self.owner.start_error

    def stop(self) -> None:
        self.owner.events.append("stop")
        if self.owner.stop_error:
            raise self.owner.stop_error

    def close(self) -> None:
        self.owner.events.append("close")
        if self.owner.close_error:
            raise self.owner.close_error


class FakeSoundDevice:
    """The slice of `sounddevice` the recorder uses."""

    def __init__(
        self,
        *,
        open_error: Exception | None = None,
        start_error: Exception | None = None,
        stop_error: Exception | None = None,
        close_error: Exception | None = None,
    ) -> None:
        self.open_error = open_error
        self.start_error = start_error
        self.stop_error = stop_error
        self.close_error = close_error
        self.events: list[str] = []
        self.streams: list[FakeStream] = []

    def InputStream(self, **kwargs: Any) -> FakeStream:  # noqa: N802 - mirrors sounddevice
        if self.open_error:
            raise self.open_error
        stream = FakeStream(self, **kwargs)
        self.streams.append(stream)
        return stream


class Block:
    """What sounddevice hands the callback: an array-like with `tobytes`."""

    def __init__(self, data: bytes) -> None:
        self.data = data

    def tobytes(self) -> bytes:
        return self.data


def _patch_imports(monkeypatch: pytest.MonkeyPatch, **modules: Any) -> None:
    """Make `voice` see these modules (or raise these errors) for these names only."""

    def fake(name: str, package: str | None = None) -> Any:
        if name not in modules:
            return _REAL_IMPORT(name, package)
        found = modules[name]
        if isinstance(found, BaseException):
            raise found
        return found

    monkeypatch.setattr(voice.importlib, "import_module", fake)


def test_start_opens_a_mono_16khz_int16_stream_and_stop_releases_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sd = FakeSoundDevice()
    _patch_imports(monkeypatch, sounddevice=sd)
    recorder = voice.SoundDeviceRecorder()

    recorder.start()
    stream = sd.streams[0]
    callback = stream.kwargs.pop("callback")
    assert stream.kwargs == {"samplerate": 16_000, "channels": 1, "dtype": "int16"}
    callback(Block(array("h", [1, 2, 3]).tobytes()), 3, None, None)
    callback(Block(array("h", [4]).tobytes()), 1, None, None)
    heard = recorder.stop()

    assert list(heard) == [1, 2, 3, 4]
    assert sd.events == ["start", "stop", "close"]


def test_each_recording_starts_from_an_empty_buffer(monkeypatch: pytest.MonkeyPatch) -> None:
    sd = FakeSoundDevice()
    _patch_imports(monkeypatch, sounddevice=sd)
    recorder = voice.SoundDeviceRecorder()

    recorder.start()
    recorder._append(array("h", [1, 1, 1]).tobytes())
    first = recorder.stop()
    recorder.start()
    recorder._append(array("h", [2]).tobytes())
    second = recorder.stop()

    assert list(first) == [1, 1, 1]
    assert list(second) == [2]


def test_ctrl_c_while_the_microphone_warms_up_still_closes_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sd = FakeSoundDevice()
    _patch_imports(monkeypatch, sounddevice=sd)
    recorder = voice.SoundDeviceRecorder()

    class Interrupted:
        def clear(self) -> None: ...
        def is_set(self) -> bool:
            return False

        def wait(self, timeout: float | None = None) -> bool:
            raise KeyboardInterrupt

    recorder._live = Interrupted()  # type: ignore[assignment]

    with pytest.raises(KeyboardInterrupt):
        recorder.start()

    assert sd.events == ["start", "stop", "close"]  # the microphone light goes off


@pytest.mark.parametrize("failing", ["stop", "close"])
def test_stop_never_raises_even_when_the_stream_will_not_stop_or_close(
    monkeypatch: pytest.MonkeyPatch, failing: str
) -> None:
    sd = FakeSoundDevice(**{f"{failing}_error": RuntimeError("device vanished")})
    _patch_imports(monkeypatch, sounddevice=sd)
    recorder = voice.SoundDeviceRecorder()
    recorder.start()
    recorder._append(array("h", [5]).tobytes())

    assert list(recorder.stop()) == [5]
    assert sd.events == ["start", "stop", "close"]  # a failed stop still closes


@pytest.mark.parametrize(
    "fake",
    [
        FakeSoundDevice(open_error=OSError("Error querying device -1")),
        FakeSoundDevice(start_error=RuntimeError("Error querying device -1")),
    ],
)
def test_a_missing_input_device_is_one_sentence(
    monkeypatch: pytest.MonkeyPatch, fake: FakeSoundDevice
) -> None:
    _patch_imports(monkeypatch, sounddevice=fake)

    with pytest.raises(voice.VoiceError, match=r"Could not open the microphone: Error querying"):
        voice.SoundDeviceRecorder().start()

    if fake.streams:  # a stream that opened but would not start is not left open
        assert fake.events[-1] == "close"


def test_a_missing_sounddevice_package_names_the_extra_to_install(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(sys.modules, "sounddevice", None)

    with pytest.raises(voice.VoiceError, match="uv sync --extra voice"):
        voice.SoundDeviceRecorder().start()


def test_a_missing_portaudio_library_names_the_system_package(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, sounddevice=OSError("PortAudio library not found"))

    with pytest.raises(voice.VoiceError, match="libportaudio2"):
        voice.SoundDeviceRecorder().start()


# --- the transcriber -------------------------------------------------------------


class Vector(list):
    """The slice of a numpy array the transcriber uses: astype and division."""

    def astype(self, dtype: str) -> Vector:
        assert dtype == "float32"
        return Vector(float(x) for x in self)

    def __truediv__(self, divisor: float) -> Vector:
        return Vector(x / divisor for x in self)


class FakeNumpy:
    int16 = "int16"
    float32 = "float32"

    def frombuffer(self, buffer: Any, dtype: str) -> Vector:
        assert dtype == "int16"
        return Vector(buffer)


class Segment:
    def __init__(self, text: str) -> None:
        self.text = text


class FakeWhisperModel:
    def __init__(self, owner: FakeFasterWhisper) -> None:
        self.owner = owner

    def transcribe(self, audio: Any, **kwargs: Any) -> tuple[Any, object]:
        self.owner.transcribed.append((audio, kwargs))
        error = self.owner.transcribe_error

        def segments() -> Any:
            for text in self.owner.texts:
                yield Segment(text)
            if error:  # raised while the generator is consumed, as the real one does
                raise error

        return segments(), object()


class FakeFasterWhisper:
    def __init__(
        self,
        texts: tuple[str, ...] = (" Show the", " deadlines. "),
        *,
        load_error: Exception | None = None,
        transcribe_error: Exception | None = None,
    ) -> None:
        self.texts = texts
        self.load_error = load_error
        self.transcribe_error = transcribe_error
        self.loaded: list[tuple[tuple[Any, ...], dict[str, Any]]] = []
        self.transcribed: list[tuple[Any, dict[str, Any]]] = []

    def WhisperModel(self, *args: Any, **kwargs: Any) -> FakeWhisperModel:  # noqa: N802
        if self.load_error:
            raise self.load_error
        self.loaded.append((args, kwargs))
        return FakeWhisperModel(self)


def _transcriber(
    monkeypatch: pytest.MonkeyPatch, fake: FakeFasterWhisper | None = None
) -> tuple[voice.WhisperTranscriber, FakeFasterWhisper, io.StringIO]:
    fake = fake or FakeFasterWhisper()
    _patch_imports(monkeypatch, faster_whisper=fake, numpy=FakeNumpy())
    console, buffer = _console()
    return voice.WhisperTranscriber("tiny.en", console=console), fake, buffer


def test_the_model_is_loaded_once_on_cpu_in_int8_and_the_text_is_joined(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transcriber, fake, buffer = _transcriber(monkeypatch)

    first = transcriber(_clip(LOUD, seconds=1))
    second = transcriber(_clip(LOUD, seconds=1))

    assert first == second == "Show the deadlines."
    assert fake.loaded == [(("tiny.en",), {"device": "cpu", "compute_type": "int8"})]
    assert buffer.getvalue().count("Loading speech model tiny.en") == 1


def test_the_model_is_asked_for_english_with_the_command_vocabulary_as_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transcriber, fake, _ = _transcriber(monkeypatch)

    transcriber(_clip(LOUD, seconds=1))

    _, kwargs = fake.transcribed[0]
    assert kwargs == {
        "language": "en",
        "beam_size": 1,
        "vad_filter": True,
        "condition_on_previous_text": False,
        "initial_prompt": voice.PROMPT_HINT,
    }
    for phrase in ("read my mail", "deadlines", "important", "security", "unsure", "quit"):
        assert phrase in voice.PROMPT_HINT


def test_the_audio_is_handed_over_as_floats_on_a_minus_one_to_one_scale(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transcriber, fake, _ = _transcriber(monkeypatch)

    transcriber(array("h", [0, 16384, -32768]))

    audio, _ = fake.transcribed[0]
    assert audio == [0.0, 0.5, -1.0]


@pytest.mark.parametrize("failing", ["load", "transcribe"])
def test_any_failure_in_the_model_becomes_one_voice_error(
    monkeypatch: pytest.MonkeyPatch, failing: str
) -> None:
    boom = RuntimeError("out of memory")
    fake = FakeFasterWhisper(
        load_error=boom if failing == "load" else None,
        transcribe_error=boom if failing == "transcribe" else None,
    )
    transcriber, _, _ = _transcriber(monkeypatch, fake)

    with pytest.raises(voice.VoiceError, match="Speech-to-text failed: out of memory"):
        transcriber(_clip())


def test_a_library_that_breaks_on_import_is_a_voice_error_not_a_traceback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, faster_whisper=OSError("libcudnn.so not found"))
    console, _ = _console()

    with pytest.raises(voice.VoiceError, match="Speech-to-text failed: libcudnn.so not found"):
        voice.WhisperTranscriber("tiny.en", console=console)(_clip())


def test_a_missing_faster_whisper_names_the_extra_to_install(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(sys.modules, "faster_whisper", None)
    console, _ = _console()

    with pytest.raises(voice.VoiceError, match="uv sync --extra voice") as caught:
        voice.WhisperTranscriber("tiny.en", console=console)(_clip())

    assert not str(caught.value).startswith("Speech-to-text failed")  # not re-wrapped


def test_a_missing_numpy_names_the_extra_to_install(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_imports(monkeypatch, faster_whisper=FakeFasterWhisper(), numpy=ImportError("no numpy"))
    console, _ = _console()

    with pytest.raises(voice.VoiceError, match="uv sync --extra voice") as caught:
        voice.WhisperTranscriber("tiny.en", console=console)(_clip())

    assert not str(caught.value).startswith("Speech-to-text failed")  # not re-wrapped


# --- laziness --------------------------------------------------------------------


def _forbid_heavy_imports(monkeypatch: pytest.MonkeyPatch) -> None:
    ban = AssertionError("a heavy package was imported before it was needed")
    _patch_imports(monkeypatch, sounddevice=ban, faster_whisper=ban, numpy=ban)


def test_constructing_the_recorder_and_transcriber_imports_nothing_heavy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _forbid_heavy_imports(monkeypatch)
    console, _ = _console()

    voice.SoundDeviceRecorder()
    voice.WhisperTranscriber("tiny.en", console=console)


def test_building_the_voice_input_imports_nothing_heavy_and_wires_typing_and_the_model(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _forbid_heavy_imports(monkeypatch)
    monkeypatch.setattr("builtins.input", lambda prompt="": "read my mail")
    console, _ = _console()

    read = voice.build_voice_input(Settings(_env_file=None, stt_model="tiny.en"), console)

    assert callable(read)
    assert read("pli> ") == "read my mail"  # typing goes through the real `input`


def test_the_configured_speech_model_name_is_the_one_the_transcriber_gets(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    made: list[tuple[str, Console]] = []

    class Spy:
        def __init__(self, model_name: str, *, console: Console) -> None:
            made.append((model_name, console))

    monkeypatch.setattr(voice, "WhisperTranscriber", Spy)
    console, _ = _console()

    voice.build_voice_input(Settings(_env_file=None, stt_model="small.en"), console)

    assert made == [("small.en", console)]


# --- the first word is not lost to stream start-up ---------------------------------------------


@pytest.fixture(autouse=True)
def _no_warmup_unless_a_test_asks(monkeypatch: pytest.MonkeyPatch) -> None:
    """Fake streams never deliver audio, so without this every `start()` would wait."""
    monkeypatch.setattr(voice, "WARMUP_SECONDS", 0)


class StreamingSoundDevice(FakeSoundDevice):
    """Feeds the callback from a thread once started: silence first, like a real microphone.

    A real PipeWire input delivers about 0.4 s of digital zeros before the first real
    sample; anyone who starts speaking at the moment "Listening" appears loses that long.
    """

    def __init__(self, chunks: list[bytes], gap: float = 0.02) -> None:
        super().__init__()
        self.chunks, self.gap = chunks, gap

    def InputStream(self, **kwargs: Any) -> FakeStream:  # noqa: N802 - mirrors sounddevice
        stream = super().InputStream(**kwargs)
        started = stream.start

        def start() -> None:
            started()

            def feed() -> None:
                for chunk in self.chunks:
                    time.sleep(self.gap)
                    kwargs["callback"](Block(chunk), 0, None, None)

            threading.Thread(target=feed, daemon=True).start()

        stream.start = start  # type: ignore[method-assign]
        return stream


SILENCE = bytes(2000)
SPEECH = array("h", [900, -900] * 250).tobytes()
HISS = array("h", [1, -1] * 250).tobytes()  # quiet but alive: not digital silence


def _timed_start(recorder: voice.SoundDeviceRecorder) -> float:
    began = time.perf_counter()
    recorder.start()
    return time.perf_counter() - began


def test_start_waits_for_real_audio_before_returning_so_the_first_word_is_not_lost(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, sounddevice=StreamingSoundDevice([SILENCE, SILENCE, SPEECH]))
    monkeypatch.setattr(voice, "WARMUP_SECONDS", 5)
    recorder = voice.SoundDeviceRecorder()

    took = _timed_start(recorder)

    assert 0.03 < took < 2  # past the silence (~0.06 s), nowhere near the 5 s ceiling
    assert any(recorder.stop())  # the real audio was already in the buffer


def test_start_gives_up_waiting_after_the_warmup_ceiling_when_only_silence_arrives(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, sounddevice=StreamingSoundDevice([SILENCE] * 3, gap=0.01))
    monkeypatch.setattr(voice, "WARMUP_SECONDS", 0.15)
    recorder = voice.SoundDeviceRecorder()

    took = _timed_start(recorder)

    assert 0.1 < took < 2  # waited the ceiling, then carried on instead of hanging
    assert not any(recorder.stop())


def test_quiet_background_hiss_counts_as_a_live_microphone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, sounddevice=StreamingSoundDevice([HISS]))
    monkeypatch.setattr(voice, "WARMUP_SECONDS", 5)

    assert _timed_start(voice.SoundDeviceRecorder()) < 2


def test_every_recording_waits_for_its_own_stream_to_come_alive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_imports(monkeypatch, sounddevice=StreamingSoundDevice([SILENCE, SILENCE, SPEECH]))
    monkeypatch.setattr(voice, "WARMUP_SECONDS", 5)
    recorder = voice.SoundDeviceRecorder()
    _timed_start(recorder)
    recorder.stop()

    second = _timed_start(recorder)

    assert second > 0.03  # the second stream started with silence too: it waited again
    recorder.stop()


# --- an overdriven microphone is named, not left to look like noise ----------------------------
#
# Measured on the machine this was built on: a real speech clip sits at RMS 0.14 with 0%
# of its samples clipped; the microphone with its gain at maximum read RMS 0.44-0.65 with
# 1.4-19% clipped in a quiet room, and 3 s of that came back as fluent text.


def _with_clipped(clipped: int, total: int = 10_000) -> array[int]:
    """`clipped` full-scale samples among `total`, the rest silent (so RMS stays low)."""
    return array("h", [32767] * clipped + [0] * (total - clipped))


@pytest.mark.parametrize(
    ("samples", "expected"),
    [
        (_with_clipped(100), True),  # exactly 1% clipped
        (_with_clipped(99), False),  # just under
        (_clip(13_200, samples=10_000), True),  # RMS 0.403, nothing clipped
        (_clip(13_000, samples=10_000), False),  # RMS 0.397
        (_clip(LOUD, seconds=1), False),  # ordinary speech level
        (array("h"), False),  # an empty clip is the silence gate's business
    ],
)
def test_overdriven_means_one_percent_clipped_or_a_level_above_point_four(
    samples: array[int], expected: bool
) -> None:
    assert voice.overdriven(samples) is expected


def test_an_overdriven_recording_is_named_but_still_transcribed() -> None:
    rig = Rig(audio=_with_clipped(2_000, 16_000), text="Read my mail.")

    assert rig.ask("", "") == "read my mail"

    assert "overdriven" in rig.output
    assert "README" in rig.output
    assert len(rig.transcriber.calls) == 1


def test_a_normal_level_recording_gets_no_warning() -> None:
    rig = Rig(audio=_clip(LOUD, seconds=1), text="Read my mail.")

    rig.ask("", "")

    assert "overdriven" not in rig.output
