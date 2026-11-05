# Speech and motion: measurements and what to try next

For the owner. Measured on 2026-11-04, on the full agent; only what still holds for the plain chatbot is kept here. Files are
under `native/Sources/`. Nothing here was tried with your voice or the live app.

**How to read the claims**
- **[M]** measured for this document. Rig: M5 Pro, 24 GB, with other builds running (load about 9), so timings are
  pessimistic. All audio is macOS synthetic voices, which is good for comparing two options and not for tuning.
- **[C]** read from the code, or shown by a test with fakes, not seen in the running app.
- **[E]** an estimate.

**Terms**
- **ASR** (automatic speech recognition): audio in, text out. Robo uses NVIDIA Parakeet TDT 0.6B v2, English only, on the
  CPU through ONNX Runtime.
- **WER** (word error rate): wrong, missing and extra words divided by the words of the reference text. Lower is better.
- **RTF** (real-time factor): seconds of compute per second of audio. 0.05 means a 4 s clip takes 0.2 s.
- **Frame**: 80 ms of audio. **Gate**: the loudness above which a frame counts as speech.
- **VAD** (voice activity detection): a small model that says "speech / not speech", better than loudness alone.
- **Follow-up window**: the 15 s after a reply when you can talk without Ctrl+Q.

## The short version

1. **Keep Parakeet.** Apple's built-in recogniser ran at the same speed with about 3× the errors on the test requests.
2. **Don't add streaming ASR, a wake word or a VAD model now.** With push to talk they fix problems Robo doesn't have.
3. **Decided (2026-11-05):** you speak English to Robo, so Parakeet v2 stays and no second engine is needed.

## Where the time goes: key release to the request

| Step | Time | Mark |
|---|---|---|
| Audio recorded after the key comes up (`RoboVoice/Listen.swift`) | 0.32 s | constant |
| Parakeet transcribes (mean clip 2.6 s) | about 0.09 s | [M] |
| The app starts the run over HTTP | under 0.01 s | [M] |

**About 0.4 s of local time, then the model.** What you see meanwhile: the face says "listening" from key-down, and nothing
changes between key-up and the transcript.

## Speech engines

46 English requests (`tests/evals/requests.jsonl`, on the `revamp` branch), 4 voices, 184 clips, 1,396 words [M]:

| Engine | WER | Clips with an error | Worst voice | Time per clip |
|---|---|---|---|---|
| Parakeet TDT v2 (release build) | **2.29%** | 22 | 4.87% | 87 ms mean, about 6.7 cores busy |
| Apple SpeechTranscriber (`.transcription`) | 6.73% | 52 | 18.62% | 85 ms median, RTF 0.035 |

`robo voice-eval` (the name matcher, not the words of a request): **178/200** [M]: 12 misses, and 10 false positives that are
all the deliberate "Rubble" sentence. Model load 0.8 s; footprint 806 MB, peak 951 MB [M]. SpeechTranscriber on this Mac: 30
locales, en_US already installed [M].

A direction check from elsewhere, vendor-run: Argmax's table has SpeechTranscriber at 14.0 error rate and parakeet-v2 at 11.7 on an
M4 Mac mini.

## What I'd do next, in order

Most of these need your voice to tune or a decision from you.

### 1. Cap a key-less follow-up recording (S: under a day)
A follow-up recording uses the patient settings, up to 120 s (`patientMaxS` in `RoboVoice/Listen.swift`), so a TV that never pauses
can keep one open long after the MIC light went off, and its last sentence then goes to the model [C]. Cap it at the window's
remaining time plus a small margin (about 20 s in total), keeping the 3 s pause rule, and let one side own the window instead of
both the app and the listener computing `now + 15`.
- **Risk:** a very long key-less request is cut; the key is unaffected.
- **Measure:** `ListenTests` with constant loud frames in an open window.

### 2. Show "transcribing" at key-up, and end the tail early (S)
Key-up only calls `ear.release()` (`RoboUI/Window.swift`), so the face still says "listening" while robo is busy. Change the look
at key-up. Also stop the 0.32 s tail as soon as its frames are quiet, rather than always waiting.
- **Gain:** up to 0.3 s, and it feels more responsive. **Risk:** a clipped last word.
- **Measure:** WER on your own clips, released "early". **Needs your voice.**

### 3. Don't clip or discard speech on the key path (S)
A press has no pre-roll: the audio just before it is thrown away (`RoboVoice/Listen.swift`), so a word started with the press can
lose its first sound. And "the key decides" isn't quite true: under 4 loud frames, the speech is never transcribed, so soft speech
in a louder room gets "Sorry". Prepend 2-3 frames, and stop gating a held key on loudness.
- **Risk:** noise gets transcribed more often. **Measure:** WER on clips with clipped starts, and on soft speech.
- **Needs your voice.**

### 4. Make `robo voice-eval` score requests, not just the name (S; replay is M)
Today it scores whether the name was caught, while the live app wakes by key. The numbers above came from a throwaway script over
`--wavs`. Add WER and per-clip timing. Later, a replay mode that pushes WAVs through a real `Listener`, with noise-only clips and
a "pause to think" clip.
- **Gain:** every voice change gets a number. **Risk:** none, it is a tool.

### 5. Live words while the key is held (M)
Re-run Parakeet on the growing recording about once a second and show the text on the card. For display only: the final pass
on key-up stays as it is, and nothing ever acts on a partial, so no transcript changes and "don't end a request on a ?" holds.
At 87 ms per clip this looks feasible [E]. It is the most visible interactivity gain here: you can see "Robert" before you
release.
- **Risk:** CPU and heat; a run uses about 6.7 cores in batch [M]. Cap the rate.
- **Measure:** CPU while held, and final transcripts unchanged.

### 6. Let the noise floor follow a louder room (S)
With the key on, loud frames outside a window aren't learned, so a lasting jump can freeze the gate below the room, and click and
follow-up windows then record to the cap [C]. This is rarer than it sounds: in a quiet room `minGate` sets the gate, so the level
must rise about 6.7× from the measured 0.0012 floor to cross 0.008, not 2.5×. Learning from those frames too is about one line, and
`minGate` doesn't change.
- **Measure:** replay a step **above** 0.008; a smaller step doesn't reproduce it.

### 7. Smaller items
- **ONNX Runtime threads and spinning (S):** try fewer threads. Benefit is battery, not latency [E]. Transcripts must match
  exactly, since the name matcher was tuned on this output.
- **Unload the model on memory pressure (M):** reload is 0.8 s from a warm disk [M], and starting it at key-down would hide most
  of that. But only on pressure, not on a timer, at 806 MB of 24 GB. The listener keeps its transcriber for the whole run, so this
  needs restructuring.

## Ideas I'd reject for now

| Idea | Why not |
|---|---|
| Switch to Apple SpeechAnalyzer | Same speed, about 3× the WER on these clips [M]. Its one real win is about 0.9 GB back. Recheck on your own voice before closing this for good. |
| Streaming ASR (Nemotron 3.5, Parakeet EOU) | With push to talk the whole clip is ready at key-up, in about 90 ms. Item 5 gives the visible part without a new engine. Moves every tuned number. |
| FluidAudio or CoreML Parakeet on the Neural Engine | Saves at most about 60 ms [E]; adds a dependency and model downloads. Revisit if battery becomes a measured problem. The `CLAUDE.md` CPU-only rule measured ONNX Runtime's CoreML provider, not these conversions, so it doesn't rule them out. |
| WhisperKit for English | whisper-small.en is behind parakeet-v2 in Argmax's own table. |
| A wake word (openWakeWord, Porcupine) | You chose Ctrl+Q on 2026-10-16. Another always-on listener would bring back the false wakes that decision removed. |
| A VAD model (Silero v6, Apple `SpeechDetector`) | With the key on it only helps the click and follow-up windows, and the follow-up window already needs two words. If it comes back: Silero's maintainers now recommend v6, and one forum report describes a compile error passing `SpeechDetector` to `SpeechAnalyzer`. |
| Listener state as one enum | A refactor of thread-sensitive code needs a reason it doesn't yet have. |
| One display-synced clock for animation; arrays instead of dictionaries in `Animator` | No CPU number exists for the Swift app. Measure idle, typing and roaming first. |
| "Skip redraws when the face didn't change" | Nearly a no-op: the breathing changes `bob` every frame (`RoboCore/Animator.swift`, drawn in `RoboUI/FaceRender.swift`). A lower idle frame rate between blinks is the idea to test instead, once a CPU number exists. |
| A spring for the pet's walk | Keeping the speed on a new aim fixed the hitch in a few lines. |

## Not measured

- Anything on your own voice, the real Ctrl+Q, or the live app.
- CPU of the Swift app. It wasn't running; the only number on record, about 5% of a core idle, is from the retired Python build.
- The model's real first-token time.

## Sources

- Argmax, vendor-run benchmark: https://www.argmaxinc.com/blog/apple-and-argmax
- FluidAudio (Apache-2.0; about 190× on M4 Pro, by its own figures): https://github.com/FluidInference/FluidAudio
- Apple SpeechDetector: https://developer.apple.com/documentation/speech/speechdetector, and the forum report:
  https://developer.apple.com/forums/thread/797544
- Silero VAD models: https://docs.vad.ricky0123.com/user-guide/models/
- Nemotron 3.5 ASR: https://letsdatascience.com/news/nvidia-releases-open-nemotron-35-audio-transcription-and-tra-e4112b2f
