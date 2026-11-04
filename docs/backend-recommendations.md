# Backend recommendations: voice, interaction, motion, agent

Written 2026-11-04 for the revamp. Every claim below was checked against the code in this checkout and cites
`file:line` (paths under `native/Sources/` unless they say otherwise). Nothing here is built yet; each item says how
to measure it, so a change can be compared with the code before it (the rule in `CLAUDE.md` "Verify").

**Terms used once and then freely**
- **ASR** (automatic speech recognition): audio in, text out. Robo's is NVIDIA Parakeet TDT 0.6B v2, English only,
  run on the CPU through ONNX Runtime (`RoboVoice/Parakeet.swift:1`, `:247`).
- **Frame**: 80 ms of audio (1280 samples at 16 kHz, `RoboVoice/Listen.swift:12-14`). **RMS** is its loudness.
- **Gate**: the loudness above which a frame counts as speech (`speechGate`, `Listen.swift:126-128`).
- **Noise floor**: what the gate is computed from, the room's quiet level.
- **Endpointer**: the code that decides an utterance is over (`Listen.swift:143-158`).
- **VAD** (voice activity detection): a small model that says "speech / not speech" per frame, better than loudness.
- **RTF** (real-time factor): seconds of compute per second of audio. 0.05 = a 4 s clip takes 0.2 s.
- **WER** (word error rate): wrong, missing and extra words divided by the words of a reference text.
- **Follow-up window**: the 15 s after a reply when you can talk without Ctrl+Q (`RoboUI/Window.swift:20`).
- **Main thread**: the one thread AppKit draws on; work there competes with every animation.

## Ranked summary

Rank = value for the user divided by effort and risk. S = under a day, M = a few days, L = a week or more.

| # | Item | Area | Effort | Why first |
|---|------|------|--------|-----------|
| 1 | A refused hands-free sentence wipes the reply being read | interaction | S | made more frequent by the new `Intent` rule |
| 2 | A follow-up utterance can run 120 s past a 15 s window | interaction / safety | S | TV speech delivered "hands-free" after the MIC light is off |
| 3 | Voice eval measures name matching only: add timing, WER, a replay-through-`Listener` mode | voice | M | everything below needs a number first |
| 4 | Push-to-talk feel: a "transcribing" state, a second press = "send now", shorter tail | voice / interaction | S | perceived latency, cheap |
| 5 | Noise floor can freeze in a steadily louder room | voice | M | needs recalibration on the user's voice |
| 6 | Speech model resident forever (~0.8-1.4 GB): unload after idle | voice | M | memory on a laptop |
| 7 | A VAD model as a second stage after the gate | voice | M | fewer noise transcriptions |
| 8 | ASR engine choice: measure Parakeet, then try SpeechAnalyzer / WhisperKit | voice | L | only if 3 shows a problem |
| 9 | Agent service: evals on every prompt/skill change, caching, cost per run, cheap model for background | agent | M | the team is building it now |
| 10 | Listener's 11 lock-guarded fields into one explicit state | interaction | M | makes 1, 2 and 4 safe to change |
| 11 | One frame clock instead of 7 repeating timers; skip redraws that change nothing | motion | M | CPU, smoother frames |
| 12 | Roam: a retarget restarts from zero speed | motion | S | a visible hitch |
| 13 | Animator builds dictionaries every frame | motion | S | small; measure first |
| 14 | Nudges: one budget counted twice; prefer natural breaks | interaction | S | cleanup |

---

## 1. A refused hands-free sentence wipes the reply being read (S)

**Problem.** In a follow-up window the listener calls `onWake()` as soon as it has two words (`Listen.swift:456-461`),
then delivers the text. `onWake` becomes `.listening(true)` in the app, which stops the run and clears the reply
(`RoboUI/App.swift:202-208`). Only after that does `onHeard` check `Intent.changesThings` and refuse
(`App.swift:159-161`), replacing the reply with "That would change something...". Since the `Intent` rule was
inverted (only clearly read-only requests pass hands-free), many more sentences are refused, so a stray "okay so..."
from the room now costs the user the answer they were reading.

**Recommendation.** Decide before waking. `RoboVoice` does not depend on `RoboCore` (`native/Package.swift:16-21`), so
give `Listener` a filter closure (for example `acceptsHandsFree: (String) -> Bool`, passed by the app as
`{ !Intent.changesThings($0) }`), checked in the `handsFree` branch of `heard` before `onWake()`. A refused text then
gets a short note through `onNote` (or a new callback) that does not clear the reply; the window can stay open.

**Tradeoff.** One more seam between voice and UI. **Measure.** A `RoboUITests` case: a reply is shown, the window is
open, a refused sentence arrives; the reply text must survive. **Note for the lead:** the message in `App.swift:161`
says "That would change something"; with the new rule "I only take questions without the key, so hold Ctrl+Q" would be
more accurate (outside my files).

## 2. A follow-up utterance can outlive its window by 105 s (S)

**Problem.** Two clocks own the window. The app sets `followUntil = typedAt + 15 s` (`App.swift:451-456`) and drives
the MIC light and `nudgeHeld` from it (`App.swift:337`, `Nudges.swift:229`); the listener keeps its own `openUntil`
(`Listen.swift:216`, `:342-345`). When sound crosses the gate inside the window, `woke` is true (`Listen.swift:396-398`),
so `record` switches to the patient settings: 3 s of silence or up to `patientMaxS` = 120 s (`Listen.swift:24`, `:504`).
`inWindow` was captured at the start, so whatever is said during those 120 s is delivered with `handsFree: true`
(`Listen.swift:412`). A TV that never pauses keeps one recording going long after the light went off, and the sentence
it ends with is then taken. CLAUDE.md already names the cost "a room that never goes quiet keeps the request open up to
`PATIENT_MAX_S`"; for a key-less window it is worse than a cost.

**Recommendation.** For an utterance that started in a follow-up window (not a click, not the key), cap its length at
the time the window had left plus a small margin (say 20 s total), keeping the 3 s patient silence (the README's "a
pause to think does not end the request"). Then make one side own the window: the listener reports "window opened /
closed" and the app only displays it, instead of both computing `now + 15`.

**Tradeoff.** A very long hands-free request is cut; the key has no cap change. **Measure.** A `ListenTests` case with
`FakeMic` (`native/Tests/RoboVoiceTests/ListenTests.swift:162`) feeding constant loud frames into an open window:
today it records 120 s; after, it ends by the cap and `handsFree` text never arrives after the window.

## 3. Measure first: the voice eval checks only the name matcher (M)

**Problem.** `robo voice-eval` transcribes clips and scores `addressed(heard)` (`RoboVoice/VoiceEval.swift:118-120`,
`:147-150`): did a sentence with "robo" get taken. The live app wakes by Ctrl+Q, and with the key registered name wake is
off (`RoboUI/Launch.swift:82`, `nameWake: !byKey`). So the eval tests the fallback mode, not the words of the request,
and it times nothing except the model load (`VoiceEval.swift:103-106`). The gate, the endpointer, the windows and
the pre-roll are never exercised on real audio.

**Recommendation.**
1. Per clip: wall time and RTF of `stt(audio)`, and WER against the prompt text (the prompts are known in all three
   modes). Print median and worst.
2. A `--replay DIR` mode that pushes each WAV through a real `Listener` frame by frame. The listener already takes an
   injected mic, transcriber and clock (`Listen.swift:230-236`); a WAV-backed `AudioSource` (`AudioInput.swift:6-10`) is
   ~20 lines. Score: did the request arrive whole, how long after the speech ended, was anything delivered for
   noise-only clips.
3. Mix room noise (fan, TV, keyboard) at a few levels into the clips, and add a "pause to think" clip (2.5 s of
   silence mid-sentence) that must arrive as one request.

**Tradeoff.** None for the app; it is a tool. **Measure.** It is the measurement. Keep CLAUDE.md's rule: calibrate on
the user's own voice (`robo voice-eval --record`), TTS only compares a change with the one before it.

## 4. Push-to-talk feel (S)

**Problem a: no "transcribing" state.** Key down shows "listening" (`Window.swift:333-337`); key up only calls
`ear.release()` (`Window.swift:178`). The transcription runs on the inference queue (`Listen.swift:486-491`) and the UI
hears nothing until `onHeard` (`App.swift:156`). The face keeps "listening" while robo is in fact busy.
**Fix:** a callback at release (and at the end of a windowed utterance, before `infer.async`) that switches the face to
a "thinking/transcribing" look. **Measure:** the time from key-up to `ask()` in a log line; the look should change
within one frame of key-up.

**Problem b: a press during a click window is ignored.** In a click window `record` runs the endpointer and never reads
`held` (`Listen.swift:498-524`); the run loop checks `held` only between utterances (`Listen.swift:382`). Pressing
Ctrl+Q mid-sentence does nothing until 3 s of silence. **Fix:** in `record`, a key press ends the endpointer wait and
hands over to `recordHeld` with the frames so far (the request continues under the key). **Measure:** a `ListenTests`
case: click window, speech, `hold()`, `release()`; one request containing both parts.

**Problem c: the tail.** `releaseTailFrames` = 4 frames, 0.32 s recorded after key-up (`Listen.swift:29`, `:476-481`).
Try 2 (0.16 s saved on every request). **Measure:** with item 3's WER on the user's own clips released "early"; keep 4
if the last word gets lost.

## 5. The noise floor can freeze (M)

**Problem.** The floor learns only from frames at or under the gate (`Listen.swift:388-392`): `quiet.append(level)`
runs for quiet frames only. Frames above the gate either start a recording or, with name wake off and no window, are
dropped without being learned (`Listen.swift:400-402`). If the room gets steadily louder (a fan, air conditioning, TV)
to above 2.5 times the old floor (`gateFactor`, `Listen.swift:18`), the gate never rises: every frame is "speech", every
click or follow-up window records until the 120 s cap, and the minimum-speech check (`Listen.swift:407`) passes on noise.

**Recommendation.** Learn the floor from all frames not inside a recording: the 20th percentile of the last ~5 s
(`noiseFrames` = 62, `noisePercentile` = 20 already exist, `Listen.swift:16-17`). A percentile of everything still
ignores short speech, and a sustained level becomes the new floor. Optional: a 100 Hz high-pass before the RMS (Accelerate
`vDSP` biquad) so hum and desk thumps weigh less.

**Tradeoff.** Someone talking without pause for 5 s raises the floor under their own voice; with Ctrl+Q that does not
matter (`recordHeld` ignores the gate except for its loud-frame count, `Listen.swift:476-487`). `minGate` = 0.008 was set
on the user's voice (CLAUDE.md "Speech gate floor"): recalibrate with `robo voice-eval --record` and item 3's replay mode,
never on TTS. **Measure:** replay mode with a fan clip whose level steps up 4x after 10 s: today the gate stays; after,
it follows within ~5 s, and noise-only windows deliver nothing.

## 6. The speech model stays loaded forever (M)

**Problem.** The model loads once at start (`Listen.swift:305-318`) and stays. CLAUDE.md measured ~1.4 GB footprint with
ONNX Runtime 1.30 and ~0.8 GB with `session.disable_prepacking` (set at `Parakeet.swift:275-278`). Robo is idle most of
the day.

**Recommendation.** Unload after N minutes without a press, click or window (say 30), and reload on key-down while
recording (the listener already keeps audio spoken during a load, `Listen.swift:257-261`). Optionally prewarm on
key-down only, never at a timer.

**Tradeoff.** The first request after idle waits for the load; how long is unknown (the eval prints it,
`VoiceEval.swift:103-106`). If it is over ~1 s, unload only on memory pressure (`DispatchSource.makeMemoryPressureSource`)
instead. **Measure:** `footprint <pid>` (not `ps`, per CLAUDE.md) idle before/after; load time from the eval line.

## 7. A VAD model after the gate (M)

**Problem.** Speech is loudness only: `rms(frame) > gate` (`Listen.swift:381`, `:388`, `Endpointer.feed` at `:153`). A
door, music or a cough above the gate starts a recording and a transcription.

**Recommendation.** Silero VAD v5 (an ~2 MB ONNX model) run through the ONNX Runtime already linked for Parakeet, as a
second stage: the gate stays the cheap first test, the VAD confirms speech before a recording starts and before the
endpointer counts a frame as "still talking". Silero reads 512-sample windows, so an 80 ms frame is 2.5 windows (keep the
remainder). Keep it on the CPU provider like Parakeet (CLAUDE.md "Speech model on the CPU only").

**Tradeoff.** ~1 ms of CPU per frame, a second model to ship, one more threshold to calibrate. With Ctrl+Q as the main
path the gain is mostly in click and follow-up windows. **Measure:** replay mode with noise-only clips (count of
transcriptions) and the user's speech clips (misses must not go up).

## 8. ASR engine choice (L, only if item 3 shows a need)

**Facts.** Parakeet TDT 0.6B v2 is English only (`Parakeet.swift:1`), so Vietnamese speech is not recognised at all
(the Vietnamese words in `Intent` matter for typed or future input). The bit-exact numpy-matching mel code
(`Parakeet.swift:7-19`) and the CPU-only rule were tuned for the name matcher, which the Ctrl+Q mode does not use
(`Launch.swift:82`). The package targets macOS 14 (`native/Package.swift:7`).

**Candidates, after measuring Parakeet's RTF and WER on the user's clips:**
- **Apple SpeechAnalyzer / SpeechTranscriber** (macOS 26, on device, streaming partial results, many languages). Needs
  `if #available(macOS 26, *)` while the package says macOS 14. Partial results are for display only: never end a
  request on a "?" and no spoken end word (CLAUDE.md constraints); the request still ends on the key or 3 s of silence.
- **WhisperKit** (Swift package, CoreML, multilingual): a new dependency; CoreML transcribes differently from the CPU
  (CLAUDE.md), which now matters only for the fallback name wake.
- **Parakeet on chunks while the key is held**: lower latency on long requests, but chunking changes transcripts.

**Tradeoff.** Switching moves every tuned number. **Measure:** the same clips through each candidate: WER, RTF,
key-up-to-text time, memory. Change only for a clear win.

## 9. The agent service (summary; D1-D3 own the design) (M)

The plan replaces Hermes with a local Python service on the Claude Agent SDK behind the same HTTP contract the app
already speaks: `POST /v1/runs`, `GET /v1/runs/{id}/events` (server-sent events), `/stop`, `/approval`
(`RoboCore/Brain.swift:85-103`, `:151-160`) and `/health` (`RoboCore/Health.swift:29`). Keeping the contract means the app
does not change. The harness is the SDK's tool loop plus a guard hook (today's `robo-guard` blocks and asks), approvals
and receipts; memory is local facts with BM25 (a classic keyword-ranking formula) plus the profile, Supermemory
optional; self-improvement is a review after each run that may write a vetted "learned skill".

**Recommendations.**
- **Evals on every prompt or skill change.** They exist: `tests/evals/requests.jsonl` (49 read-only student requests),
  `tests/evals/canaries.jsonl` (30 hostile texts replayed through the guard offline by `tests/test_canaries.py`) and the
  opt-in live runner `scripts/eval_live.py`. Extend them rather than start over: add write requests that must ask or be
  blocked, and gate every learned skill on the offline suite passing.
- **Prompt caching** for the fixed persona and skill text, so each run pays for it once. `Usage` already records
  `cacheRead`/`cacheWrite` per run (`RoboCore/Usage.swift:9-12`, `:41`): the hit rate can be watched from day one.
- **Cost per run.** Tokens per run are logged to `usage.jsonl`; add the model and price so a day's spend is visible.
  CLAUDE.md's numbers (a chat turn ~95k tokens, one course scan ~340k) are the baseline to beat.
- **A cheap model for background passes** (LMS scan, post-run review), the strong one for the user's own requests.

**Tradeoff.** A learned skill is code-like text the agent will obey: it must pass the same guard and evals as a
hand-written one. **Measure:** eval pass rate, tokens and cost per request kind, cache hit rate.

## 10. The listener's state as one explicit mode (M)

**Problem.** `Listener` holds 11 fields under one lock: `loaded`, `alive`, `opening`, `generation`, `openUntil`, `asked`,
`handsFreeText`, `held`, `heldAt`, `tapped`, `failure` (`Listen.swift:211-223`). Which combinations are legal is spread
over `hold`, `release`, `followUp`, `open`, `heard` and the run loop (`Listen.swift:325-350`, `:365-372`, `:453-471`).
Items 1, 2 and 4 all change these transitions.

**Recommendation.** One enum for the listening mode (idle, click window, follow-up window, held, transcribing), with
`openUntil`/`heldAt` as associated values, and one `transition` function. Keep the lifecycle fields (`loaded`, `alive`,
`opening`, `generation`, `failure`) as they are.

**Tradeoff.** A refactor of thread-sensitive code; do it behind the existing `ListenTests` (which use fakes and pass
today) and add cases for 1, 2 and 4 first. **Measure:** the suite stays green; no behaviour change.

## 11. One frame clock for motion (M)

**Problem.** Seven repeating main-thread timers animate the app: the face (25-30 Hz, `RoboUI/FaceView.swift:16-23`,
`:63-67`), roaming (30 Hz moving, 2 Hz resting, `Window.swift:25`, `:262-270`), the window tick (10 Hz,
`Window.swift:161`), typing (30 Hz while letters are due, `App.swift:409`), the card's shade ease (`App.swift:557`), the
chat's shade ease (`RoboUI/Chat.swift:203`) and the typing dots (`RoboUI/CardChrome.swift:475`). Most run only while
needed, which is good, but during a reply four or five tick at slightly different rates and phases, not in step with
the display. The face also repaints on every tick whether or not anything changed (`FaceView.swift:104-110`).

**Recommendation.** First the cheap part: skip `needsDisplay` when the face parameters are unchanged (an idle face
between blinks and glances). Then, if the measurement says it is worth it, one display-synchronised clock
(`NSView.displayLink(target:selector:)`, available from macOS 14) that calls each active animation with the same `dt`
and stops when none is active, with `preferredFrameRateRange` capped at 30 so a 120 Hz screen does not quadruple the cost.

**Tradeoff.** A display link that is left running costs more than the timers it replaces; the on-demand behaviour
must survive. **Measure:** CPU of the running app idle, while typing, while roaming (`top -pid` over a minute, or
Instruments' Time Profiler), before and after. CLAUDE.md's Python figure was ~5 % of a core idle; the Swift build has no
recorded number yet.

## 12. Roaming: a retarget starts again from zero speed (S)

**Problem.** `go()` resets `origin`, `elapsed` and the trip time (`RoboCore/Roam.swift:247-252`), and `travel` eases with
smoothstep from that origin (`Roam.swift:255-262`), which starts at speed zero. When the target changes mid-walk (asleep
then called, a call target that moves, `Roam.swift:165-172`) the pet stops dead and accelerates again.

**Recommendation.** Keep the walk's velocity across a retarget: follow the goal with a critically damped spring (a
spring tuned to arrive as fast as possible without overshooting; `Animator` already uses one, `Animator.swift:134-140`),
capped at the walk speed. The wall bounce (`Roam.swift:24-30`) can stay as it is.

**Tradeoff.** The pure `Roamer` tests pin exact paths, and the Python tree is the spec with golden values; new golden
values are needed. **Measure:** the speed limit test (`neverFasterThanTheSpeedLimit`) and a new test that speed is
continuous across a retarget.

## 13. Animator dictionaries every frame (S, measure first)

**Problem.** `Animator.step` builds two to three `[KeyPath: Double]` dictionaries per frame (`RoboCore/Animator.swift:86-87`,
`:105-108`), hashing key paths for every parameter on every tick.

**Recommendation.** An array indexed by a small enum of face parameters. Only worth it if item 11's profile shows
`Animator.step` near the top; it is a few hundred lookups per frame.

## 14. Nudges (S)

**Problem.** The normal budget is counted twice: `sentToday < normalPerDay` and "this slot is unused"
(`RoboCore/NudgeBudget.swift:200`), with `normalPerDay` = 3 and three slots (`NudgeBudget.swift:131-133`), so one implies
the other. Slots already wait for a free moment (a slot stays open until the next, `NudgeBudget.swift:7`; `nudgeHeld` waits
for idle, `Nudges.swift:228-230`).

**Recommendation.** Drop one counter (or document that `normalPerDay` may later be lower than the slot count). If nudges
should feel less like alarms, prefer the moment right after a run ends or the Mac is unlocked within an open slot,
instead of the first free tick.

**Measure.** The existing NudgeBudget tests stay green.

---

## Checked and dropped or corrected

- "macOS 26 is the new minimum": the package says macOS 14 (`native/Package.swift:7`); macOS 26 APIs need `#available`.
- "Add an eval set of real requests": one exists (`tests/evals/`, `scripts/eval_live.py`); item 9 extends it.
- "About 6 timers": there are 7 repeating ones plus a one-shot in `Card.swift:362` and the 1 Hz blur refresh
  (`BlurVeil.swift:55`), and most are already on demand, so the gain is smaller than "6 always-on timers" suggests.
- "Nudges at natural breaks instead of fixed slots": partly true already (item 14).
