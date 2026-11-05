# Backend recommendations: voice, interaction, motion

For the owner. Checked against the code on 2026-11-04, after the revamp (robo-agent, macOS 26 minimum). Paths are under
`native/Sources/` unless they say otherwise. Nothing here was tried with your voice, the real key or the live app.

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
- **MCP server**: a helper process that gives the agent tools (here, Playwright for the browser).

## The short version

1. **Speech recognition is not the bottleneck.** It is about 6% of the local wait. The largest local cost is starting
   the agent's command-line process and its tool servers for every single request: about 1 s, every time. The earlier
   version of this document never measured this.
2. **Keep Parakeet.** Apple's built-in recogniser ran at the same speed with about 3× the errors on Robo's own requests.
3. **Don't add streaming ASR, a wake word or a VAD model now.** With push to talk they fix problems Robo doesn't have.
4. **Decided (2026-11-05):** you speak English to Robo, so Parakeet v2 stays and no second engine is needed.

## Where the time goes: key release to first letter

| Step | Time | Mark |
|---|---|---|
| Audio recorded after the key comes up (`RoboVoice/Listen.swift:29`) | 0.32 s | constant |
| Parakeet transcribes (mean clip 2.6 s) | about 0.09 s | [M] |
| The app starts the run over HTTP | under 0.01 s | [M] |
| Agent process and MCP servers start, up to the first text, with a fake API that answers at once | 0.93-1.41 s warm, 5.5 s on a fresh install | [M] |
| The model's own time to first token | about 1-2 s | [E], needs the network |
| Text reaches the screen (tag filter, 33 ms typing tick) | under 0.1 s | [E] |

**Total: about 1.4 s of local time, plus the model.** What you see meanwhile: the face says "listening" from key-down, and
nothing changes between key-up and the transcript, about 0.4 s.

Also measured, one new session with empty memory [M]: each request to the API is about 49 KB, and 34.7 KB of that is the tool
list, including 25 Playwright tools sent even for "what's due". Prompt caching is already on: the requests carry 3
`cache_control` markers, and the system prompt and tools were byte-identical across runs.

## Speech engines on Robo's real requests

46 English requests from `tests/evals/requests.jsonl`, 4 voices, 184 clips, 1,396 words [M]:

| Engine | WER | Clips with an error | Worst voice | Time per clip |
|---|---|---|---|---|
| Parakeet TDT v2 (release build) | **2.29%** | 22 | 4.87% | 87 ms mean, about 6.7 cores busy |
| Apple SpeechTranscriber (`.transcription`) | 6.73% | 52 | 18.62% | 85 ms median, RTF 0.035 |

`robo voice-eval` (the name matcher, not the words of a request): **178/200** [M]: 12 misses, and 10 false positives that are
all the deliberate "Rubble" sentence. Model load 0.8 s; footprint 806 MB, peak 951 MB [M]. SpeechTranscriber on this Mac: 30
locales, en_US already installed [M].

A direction check from elsewhere, vendor-run: Argmax's table has SpeechTranscriber at 14.0 error rate and parakeet-v2 at 11.7 on an
M4 Mac mini.

## Already done

Each of these was first reproduced by a test that failed on the old code. They are uncommitted, and not yet seen on the live app.

- **A held key could be refused as hands-free.** If a sound had started a recording in the follow-up window, the recording
  ignored the key. Your sentence then came back as "Hold Ctrl+Q and say that again" while you were holding it, and your reply
  was already gone. A click had the same problem. Now the key or the click ends that recording and drops what it held, since
  that may be the room and must not get the key's authority. After a click or the name, the sentence continues under the key
  instead, and ends at the release (`RoboVoice/Listen.swift:508`,
  `aKeyPressedDuringAFollowUpRecordingIsNotHandsFree`, `aClickDuringAFollowUpRecordingIsNotHandsFree`,
  `aKeyPressedDuringAClickRecordingKeepsTheWordsAndEndsAtTheRelease`).
- **A race in the safety filter.** "Was this said hands-free" was a property the app read after a hop to the main thread, by
  which time a later delivery could have changed it, so a sentence from the TV could pass unfiltered. The flag now travels
  with the text (`aLaterDeliveryDoesNotChangeWhetherATextWasHandsFree`).
- **"Listening" and the blur could stick.** A long press that ended while the model loaded or a transcription ran got no
  answer, and nothing times that state out. Now it gets "Sorry, I didn't catch that." That speech is lost; a press still held
  when the model is ready records as usual (`aLongPressWhileTheModelLoadsStillGetsAnAnswer`,
  `aPressThatCameAndWentDuringATranscriptionStillGetsAnAnswer`).
- **The pet no longer stops dead when its walk gets a new aim.** The usual trigger: the card grows a line, which moves the
  corner it is walking to. `come` and `sleep` walks keep their speed; drift paths are unchanged (`RoboCore/Roam.swift`,
  `aReAimedWalkKeepsItsSpeed`).
- **A call moves the pet at once**, instead of at the next resting tick up to 0.5 s later
  (`aCallMovesThePetAtOnceNotAtTheNextRestingTick`).
- **A refused hands-free sentence no longer wipes the reply** (done in the revamp).

Being fixed in a separate piece of work, not finished as this was written: memory hits go into the system prompt
(`agent/robo_agent/harness.py:247`, `:339`), and they change per question. So once memory has content, each request misses the
cached conversation behind them [C]. The fix moves memory into the user turn.

## What I'd do next, in order

The rest are recommendations. Most need your voice to tune or a decision from you.

### 1. Cap a key-less follow-up recording (S: under a day)
A follow-up recording uses the patient settings, up to 120 s (`RoboVoice/Listen.swift:24`, `:514`), so a TV that never pauses can
keep one open long after the MIC light went off, and its last sentence is then taken as hands-free [C]. The overrun can reach the
full 120 s. Cap it at the window's remaining time plus a small margin (about 20 s in total), keeping the 3 s pause rule, and let
one side own the window instead of both the app and the listener computing `now + 15`.
- **Gain:** a real safety gap closes. **Risk:** a very long key-less request is cut; the key is unaffected.
- **Measure:** `ListenTests` with constant loud frames in an open window. **Touches:** the follow-up window constraint.

### 2. Stop paying about 1 s to start the agent on every request (M: a few days)
Measure Playwright's share first. If it is large, start it only when a browser tool is needed, which also shrinks every
request. Then consider one warm agent process per session.
- **Gain:** up to about 1 s on every request [E]. **Risk: high.** The guard and hooks are bound to each run and must keep
  failing closed; don't trade safety for this. A warm process also needs the memory fix above, since its system prompt can't
  change per question.
- **Measure:** the fake-API timing above, then real first-token time. **Touches:** the robo-guard notes in `CLAUDE.md`.

### 3. Show "transcribing" at key-up, and end the tail early (S)
Key-up only calls `ear.release()` (`RoboUI/Window.swift:176`), so the face still says "listening" while robo is busy. Change
the look at key-up. Also stop the 0.32 s tail as soon as its frames are quiet, rather than always waiting.
- **Gain:** up to 0.3 s, and it feels more responsive. **Risk:** a clipped last word.
- **Measure:** WER on your own clips, released "early". **Needs your voice.**

### 4. Don't clip or discard speech on the key path (S)
A press has no pre-roll: the audio just before it is thrown away (`RoboVoice/Listen.swift:381`), so a word started with the press can
lose its first sound. And "the key decides" isn't quite true: under 4 loud frames, the speech is never transcribed
(`RoboVoice/Listen.swift:496`), so soft speech in a louder room gets "Sorry". Prepend 2-3 frames, and stop gating a held key on loudness.
- **Risk:** noise gets transcribed more often. **Measure:** WER on clips with clipped starts, and on soft speech.
- **Touches:** the speech gate floor. **Needs your voice.**

### 5. Make `robo voice-eval` score requests, not just the name (S; replay is M)
Today it scores whether the name was caught, while the live app wakes by key (`RoboUI/Launch.swift:132`). The numbers above came
from a throwaway script over `--wavs`. Add WER against `tests/evals/requests.jsonl` and per-clip timing. Later, a replay mode
that pushes WAVs through a real `Listener`, with noise-only clips and a "pause to think" clip.
- **Gain:** every voice change gets a number. **Risk:** none, it is a tool.

### 6. Live words while the key is held (M)
Re-run Parakeet on the growing recording about once a second and show the text on the card. For display only: the final pass
on key-up stays as it is, and nothing ever acts on a partial, so no transcript changes and "don't end a request on a ?" holds.
At 87 ms per clip this looks feasible [E]. It is the most visible interactivity gain here: you can see "Robert" before you
release.
- **Risk:** CPU and heat; a run uses about 6.7 cores in batch [M]. Cap the rate.
- **Measure:** CPU while held, and final transcripts unchanged.

### 7. Let the noise floor follow a louder room (S)
With the key on, loud frames outside a window aren't learned (`RoboVoice/Listen.swift:402`), so a lasting jump can freeze the gate
below the room, and click and follow-up windows then record to the cap [C]. This is rarer than it sounds: in a quiet room `minGate`
sets the gate (`RoboVoice/Listen.swift:126`), so the level must rise about 6.7× from the measured 0.0012 floor to cross 0.008, not
2.5×. Learning from those frames too is about one line, and `minGate` doesn't change.
- **Measure:** replay a step **above** 0.008; a smaller step doesn't reproduce it. **Touches:** the speech gate floor.

### 8. Smaller items
- **ONNX Runtime threads and spinning (S):** try fewer threads. Benefit is battery, not latency [E]. Transcripts must match
  exactly, since the name matcher was tuned on this output.
- **Unload the model on memory pressure (M):** reload is 0.8 s from a warm disk [M], and starting it at key-down would hide most
  of that. But only on pressure, not on a timer, at 806 MB of 24 GB. The listener keeps its transcriber for the whole run
  (`RoboVoice/Listen.swift:312`), so this needs restructuring, and the existing "audio kept during a load" covers startup only.
- **Agent evals and cost (M):** `tests/evals/` and `scripts/eval_live.py` exist. Add write requests that must ask or be blocked,
  gate learned skills on the offline suite, add model and price to `usage.jsonl`, and try the cheap model for the LMS scan.
- **Nudge counters (S):** `sentToday` and `slotsUsed` only change together (`RoboCore/NudgeBudget.swift:200-207`). Drop one, unless
  `normalPerDay` may later be lower than the slot count. Cleanup only.

## Ideas I'd reject for now

| Idea | Why not |
|---|---|
| Switch to Apple SpeechAnalyzer | Same speed, about 3× the WER on these clips [M]. Its one real win is about 0.9 GB back. Recheck on your own voice before closing this for good. |
| Streaming ASR (Nemotron 3.5, Parakeet EOU) | With push to talk the whole clip is ready at key-up, in about 90 ms. Item 6 gives the visible part without a new engine. Moves every tuned number. |
| FluidAudio or CoreML Parakeet on the Neural Engine | Saves at most about 60 ms of 1.4 s [E]; adds a dependency and model downloads. Revisit if battery becomes a measured problem. The `CLAUDE.md` CPU-only rule measured ONNX Runtime's CoreML provider, not these conversions, so it doesn't rule them out. |
| WhisperKit for English | whisper-small.en is behind parakeet-v2 in Argmax's own table. |
| A wake word (openWakeWord, Porcupine) | You chose Ctrl+Q on 2026-10-16. Another always-on listener would bring back the false wakes that decision removed. |
| A VAD model (Silero v6, Apple `SpeechDetector`) | With the key on it only helps the click and follow-up windows, which are already filtered by two words and `Intent`. If it comes back: Silero's maintainers now recommend v6, and one forum report describes a compile error passing `SpeechDetector` to `SpeechAnalyzer`. |
| Listener state as one enum | The three bugs above were fixed in place. A refactor of thread-sensitive code needs a reason it doesn't yet have. |
| One display-synced clock for animation; arrays instead of dictionaries in `Animator` | No CPU number exists for the Swift app. Measure idle, typing and roaming first. |
| "Skip redraws when the face didn't change" | Nearly a no-op: the breathing changes `bob` every frame (`RoboCore/Animator.swift:161`, drawn at `RoboUI/FaceRender.swift:293`). A lower idle frame rate between blinks is the idea to test instead, once a CPU number exists. |
| A spring for the pet's walk | Keeping the speed on a new aim fixed the hitch in a few lines. |

## Not measured

- Anything on your own voice, the real Ctrl+Q, or the live app.
- CPU of the Swift app. It wasn't running; the only number on record, about 5% of a core idle, is from the retired Python build.
- The model's real first-token time, and how much of the 1 s startup is Playwright.
- Memory's effect on the cache: the request bodies above were captured with empty memory.

## Sources

- Argmax, vendor-run benchmark: https://www.argmaxinc.com/blog/apple-and-argmax
- FluidAudio (Apache-2.0; about 190× on M4 Pro, by its own figures): https://github.com/FluidInference/FluidAudio
- Apple SpeechDetector: https://developer.apple.com/documentation/speech/speechdetector, and the forum report:
  https://developer.apple.com/forums/thread/797544
- Silero VAD models: https://docs.vad.ricky0123.com/user-guide/models/
- Nemotron 3.5 ASR: https://letsdatascience.com/news/nvidia-releases-open-nemotron-35-audio-transcription-and-tra-e4112b2f
