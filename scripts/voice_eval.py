"""Does robo take the sentences that call it and ignore the rest? macOS `say` voices -> the real
Parakeet model -> robo.listen.addressed.

Usage: uv run python scripts/voice_eval.py OUT_DIR   (macOS; needs the speech model in the cache)

Prints a line per phrase, then the misses (a sentence for robo that was not taken) and the false
positives (other speech that was taken). Synthetic voices are not yours: use the score to compare a
change with the one before it, not to tune the matcher to a number.
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


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "voice_eval"))
