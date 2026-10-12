"""Does robo take the sentences that call it and ignore the rest? Real speech model, real matcher.

  uv run python scripts/voice_eval.py OUT_DIR       macOS `say` voices (model must be cached)
  uv run python scripts/voice_eval.py --record DIR  YOU read 10 prompted phrases, saved as DIR/*.wav
  uv run python scripts/voice_eval.py --wavs DIR    score DIR/robo_*.wav and DIR/other_*.wav

Prints a line per phrase, then the misses (a sentence for robo that was not taken) and the false
positives (other speech that was taken). For your own clips it also says whether each one clears
the speech gate (`listen.MIN_GATE`): a clip that does not would never reach the model. Synthetic
voices are not yours: use their score to compare a change with the one before it, not to tune to
a number.
"""

from __future__ import annotations

import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

from robo import listen

VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Alex", "Tessa", "Aman", "Fred", "Rishi", "Reed"]
FOR_ROBO = [
    "Robo, what time is it?",
    "Hey robo, what's due this week?",
    "What's due this week, robo?",
    "Robo.",
    "Hey Robo",
    "Okay robo, plan my day.",
    "Can you help me with my homework, robo?",
    "Robo, I got eight out of ten on the quiz.",
    "Yo robo, open my calendar.",
    "Robo draw me a diagram of the water cycle.",
]
NOT_FOR_ROBO = [
    "I bought a robot yesterday.",
    "Robots are interesting.",
    "The weather is nice today.",
    "Let's watch the game tonight.",
    # a known false positive on purpose: Parakeet often writes the user's "Robo" as "Rubble"
    "Rubble was everywhere after the storm.",
    "Turn the volume up a little bit.",
    "Welcome back to the show everybody.",
    "The robbery happened on Tuesday.",
    "Throw the ball over the fence.",
    "Rob, can you pass me the salt?",
]


def speak(voice: str, text: str, path: Path) -> np.ndarray | None:
    """16 kHz mono audio of `voice` saying `text` with a little silence around it."""
    done = subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE",
                           "--data-format=LEI16@16000", text], capture_output=True)
    if done.returncode:
        return None
    with wave.open(str(path)) as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    pad = np.zeros(8000, np.float32)
    return np.concatenate([pad, audio / 32768, pad])


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    start = time.time()
    stt = listen.Parakeet()
    print(f"model loaded in {time.time() - start:.1f}s")
    wrong = []
    total = 0
    for voice in VOICES:
        for wanted, phrases in ((True, FOR_ROBO), (False, NOT_FOR_ROBO)):
            for i, text in enumerate(phrases):
                audio = speak(voice, text, out / f"{voice}_{int(wanted)}{i}.wav")
                if audio is None:
                    print(f"skipping {voice}: not installed")
                    break
                heard = stt(audio)
                request = listen.addressed(heard)
                total += 1
                ok = (request is not None) == wanted
                print(f"{'ok ' if ok else 'BAD'} {voice:9} {'for robo' if wanted else 'other  '}"
                      f" | {text!r} -> {heard!r} -> {request!r}")
                if not ok:
                    wrong.append(("MISS" if wanted else "FALSE-POSITIVE", voice, text, heard))
    print(f"\n{total - len(wrong)}/{total} correct")
    for kind, voice, text, heard in wrong:
        print(f"{kind:14} {voice:9} {text!r} => {heard!r}")


PROMPTS = [("robo", "Robo, what time is it?"), ("robo", "Hey robo, what's due this week?"),
           ("robo", "Okay robo, plan my day."), ("robo", "What's due tomorrow, robo?"),
           ("robo", "Robo, I got eight out of ten on the quiz."), ("robo", "Robo."),
           ("other", "I bought a robot yesterday."), ("other", "The weather is nice today."),
           ("other", "Let's watch the game tonight."),
           ("other", "Turn the volume up a little bit.")]


def record(out: Path, seconds: float = 4.0) -> None:
    """You read each prompt, as you would to robo, from where you normally sit."""
    import sounddevice as sd

    out.mkdir(parents=True, exist_ok=True)
    for i, (kind, text) in enumerate(PROMPTS, 1):
        input(f"[{i}/{len(PROMPTS)}] Press Enter, then say: {text!r}  ")
        audio = sd.rec(int(seconds * listen.SAMPLE_RATE), samplerate=listen.SAMPLE_RATE,
                       channels=1, dtype="int16")
        sd.wait()
        with wave.open(str(out / f"{kind}_{i:02d}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(listen.SAMPLE_RATE)
            w.writeframes(audio.tobytes())
    print(f"saved {len(PROMPTS)} clips in {out}; now: --wavs {out}")


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (listen.SAMPLE_RATE, 1, 2):
            raise SystemExit(f"{path.name}: need 16 kHz mono 16-bit (use --record)")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        return pcm.astype(np.float32) / 32768


def evaluate(folder: Path) -> None:
    """Score your clips: `robo_*` must be taken, `other_*` ignored; does each reach the model?"""
    stt = listen.Parakeet()
    wrong, silent, total = [], [], 0
    for path in sorted(folder.glob("*.wav")):
        wanted = path.name.startswith("robo")
        audio = read_wav(path)
        frames = audio[: len(audio) // listen.FRAME * listen.FRAME].reshape(-1, listen.FRAME)
        level = np.sqrt((frames ** 2).mean(1))
        loud = int((level > listen.MIN_GATE).sum())
        heard = stt(audio)
        request = listen.addressed(heard)
        total += 1
        ok = (request is not None) == wanted
        gate = "" if loud >= listen.MIN_SPEECH_FRAMES else "  BELOW THE GATE: robo would not listen"
        print(f"{'ok ' if ok else 'BAD'} {path.name:12} loud frames {loud:2d} "
              f"peak {level.max():.3f} | {heard!r} -> {request!r}{gate}")
        if not ok:
            wrong.append(path.name)
        if gate:
            silent.append(path.name)
    print(f"\n{total - len(wrong)}/{total} correct; gate = {listen.MIN_GATE} RMS, "
          f"{len(silent)} clip(s) below it" + (f": {', '.join(silent)}" if silent else ""))
    if silent:
        print("Your voice is quieter than the gate: lower MIN_GATE in listen.py (try 0.012).")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--record"]:
        record(Path(args[1]))
    elif args[:1] == ["--wavs"]:
        evaluate(Path(args[1]))
    else:
        main(Path(args[0] if args else "voice_eval"))
