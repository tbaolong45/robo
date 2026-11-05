# Robo: every technical piece, explained

The companion to `newcomer-guide.md`. That guide gives the overview; this one goes through
**each technology and technique** in the project, one at a time. Each part says:

- **The idea**: what the concept is, in plain words, as if you'd never met it.
- **In Robo**: how this project uses it, with the file to look at.
- **Why it matters**: the problem it solves, or the bug that happened without it.

You don't need to read it in order. Every numbered part stands on its own.

---

## Contents

1. [Architecture: how the program is shaped](#1-architecture-how-the-program-is-shaped)
2. [Voice: from sound waves to text](#2-voice-from-sound-waves-to-text)
3. [Talking to the service: HTTP and streaming](#3-talking-to-the-service-http-and-streaming)
4. [The chat service: LLM, persona, history](#4-the-chat-service-llm-persona-history)
5. [Text on screen: streams, typing, Markdown, LaTeX](#5-text-on-screen-streams-typing-markdown-latex)
6. [The face and its movement](#6-the-face-and-its-movement)
7. [Mac windows, glass and the screen](#7-mac-windows-glass-and-the-screen)
8. [Permissions, signing, installing, starting at login](#8-permissions-signing-installing-starting-at-login)
9. [Concurrency: doing several things at once](#9-concurrency-doing-several-things-at-once)
10. [Files, data and secrets](#10-files-data-and-secrets)
11. [Testing and quality](#11-testing-and-quality)
12. [Build tools and dependencies](#12-build-tools-and-dependencies)
13. [Trade-offs at a glance](#13-trade-offs-at-a-glance)

---

## 1. Architecture: how the program is shaped

### 1.1 Two processes, one boundary
**The idea.** A *process* is a running program with its own memory. Two processes can't see
each other's variables; they talk through a channel such as a network socket.

**In Robo.** The app (the face, Swift) and `robo-agent` (the chat service, Python, `agent/`) are
separate processes. They talk over HTTP on `127.0.0.1:8765` (*loopback*: a network address that
never leaves the machine). The app starts the service (`RoboSystem/Agent.swift`, `AgentService`)
and starts it again before a request if it has died; its output goes to
`~/Library/Logs/Robo/agent.log`.

**Why it matters.** Each side can crash, restart or be replaced on its own. The app needs no AI
code, and `robo chat` is a text-only client for the same API. The other side was in fact replaced
twice: Hermes Agent until 2026-11-04, then a full agent on the Claude Agent SDK (kept on the `revamp`
branch), then this chat service on 2026-11-05, all behind the same run API. The price: everything that
crosses the boundary must be turned into text (JSON), and either side can be "not answering" at any
moment. That's why there's an AGENT status light (`RoboCore/Health.swift`: one miss turns it amber,
two in a row red).

### 1.2 Layers and modules
**The idea.** Code is split into *modules* (units that compile separately). A rule says which
module may use which, so dependencies point one way.

**In Robo.** `native/Package.swift` declares five targets: `RoboCore` → `RoboVoice`,
`RoboSystem` → `RoboUI` → `robo` (main). `RoboCore` imports no AppKit at all, and the compiler
would refuse if it tried.

**Why it matters.** The rules can't be broken by accident: the compiler enforces them.

### 1.3 "Functional core, imperative shell"
**The idea.** Put decisions in *pure functions* (input → output, no side effects, no hidden
clock) and keep the code that *does* things (draws, writes files, talks to the network) thin,
around the outside.

**In Robo.** Nearly every rule is pure and takes time as a parameter:
- `Mind.react(event, now:)` and `Mind.tick(now:)` decide the face's activity;
- `Roamer.step(now:asleep:engaged:called:)` decides where the pet walks;
- `Typewriter.advance(dt)` decides how much of the reply shows.

The UI calls them on a timer and shows the result.

**Why it matters.** A test can state the time and check the answer exactly, with no waiting and no
real clock. That's how the Swift tests run in seconds.

### 1.4 Dependency injection with protocols ("seams")
**The idea.** A *protocol* (Swift's word for an *interface*) lists what something must be able
to do, without saying how. Code that depends on the protocol can be handed the real thing or a
fake.

**In Robo.** `RoboUI/Machine.swift` defines what the window needs from the outside world: the
agent (`AgentAPI`), the microphone, the health poll, and a `Machine` (displays, pointer,
clock, files). The app passes the real ones; the tests pass fakes through a "rig" (`Rig(...)` in
the UI tests).

**Why it matters.** The *whole window*, from a spoken request through a typed reply, can be tested
without a microphone, a network or a screen.

### 1.5 A port with golden values
**The idea.** *Porting* means rewriting a program in another language. *Golden values* are
outputs saved from the old version that the new version must reproduce exactly.

**In Robo.** The Swift app began as a port of an earlier Python/Qt app (deleted from the repo in
the 2026-11-04 revamp; many golden values stay in the Swift tests as regression pins). Python's
quirks are no longer copied since 2026-11-05. Two choices from that time stay because the pins depend on them:
- The face animator's random numbers come from a Mersenne Twister, so a seed gives identical blinks.
- Text is handled as *Unicode scalars* (see 5.5) in the typewriter and the emotion filter.

**Why it matters.** The behaviour was already tuned. Equality with a saved run turns "did this
change break anything?" into a yes/no test.

---

## 2. Voice: from sound waves to text

### 2.1 Digital audio
**The idea.** A microphone measures air pressure. A computer stores it as numbers called
*samples*, taken many times a second (the *sample rate*). Values run from −1 to 1.

**In Robo.** Robo uses **16,000 samples a second (16 kHz), mono**, the rate speech models are
trained on, handled in **frames of 1,280 samples = 80 ms**. Mac microphones deliver other rates
(44.1 or 48 kHz, sometimes stereo), so an `AdaptiveResampler` converts each buffer.

**Why it matters.** The resampler builds its converter from *each buffer's own format*. When a
Bluetooth headset switched profiles, the format changed between "read the format" and "install
the tap", and Apple's audio engine threw an exception that Swift can't catch. The live app
crashed (2026-10-20). Asking for no fixed format (`format: nil`) fixed it.

### 2.2 Loudness, noise floor and the speech gate
**The idea.** *RMS* (root mean square) is a frame's average loudness. The *noise floor* is how
loud the room is when nobody talks. A *gate* says "this frame is speech" when it's clearly above
the floor.

**In Robo.** The constants are at the top of `Listen.swift`:
- the noise floor is the 20th percentile of about 5 s of quiet frames;
- speech = RMS above **2.5 × the floor** *and* above `minGate` = **0.008**;
- at least 4 loud frames (~0.3 s) are needed, otherwise it was a knock, not a sentence.

**Why it matters.** The first floor (0.02) came from synthetic voices. The user's real "Robo" on
a MacBook mic peaked at 0.03 and averaged 0.02, so it **never** reached the model. The lesson,
recorded in CLAUDE.md: calibrate on the real voice through the real mic.

### 2.3 Endpointing, pre-roll and push-to-talk
**The idea.** *Endpointing* decides where an utterance starts and ends. A *ring buffer* keeps
the last N items and overwrites the oldest.

**In Robo.**
- **Pre-roll:** the last ~0.5 s (6 frames) before the gate opened is kept in a ring buffer, so
  the soft first syllable isn't cut off.
- **End:** for other people's speech, 0.7 s of quiet ends it (cheap to ignore). For a request to
  Robo, it takes **3 s** of quiet (`patientSilenceS`), up to 2 minutes, so a pause to think
  doesn't send half a sentence.
- **Push-to-talk:** while Ctrl+Q is held, the gate is ignored and everything is recorded, plus
  ~0.3 s after release (`releaseTailFrames`). A press shorter than 0.4 s counts as a "tap": listen
  to the next sentence.

**Why it matters.** Two failed designs are recorded:
- An end word ("over") fired in the middle of normal sentences.
- Ending on a "?" sent half-questions, because the model punctuates a cut-off clause as a
  question (36 of 40 probes).

Both were removed: a request is ended by silence, or by releasing the key.

### 2.4 Levelling
**The idea.** *Normalisation* scales audio so its loudest point reaches a target.

**In Robo.** `leveled()` scales each utterance to a peak of 0.5, with the boost capped at 20×
(so near-silence doesn't become loud noise).

**Why it matters.** The model reads soft speech worse: in a test at 0.15× volume, 44 of 50 names
were caught without levelling and 48 with it.

### 2.5 The speech model: Parakeet TDT
**The idea.** *Automatic speech recognition* (ASR) turns audio into text with a neural network.

**In Robo.** NVIDIA's **Parakeet TDT 0.6B v2** (0.6 billion parameters, English) runs locally.
The pipeline is in `Parakeet.swift`:

1. **Mel spectrogram (features).** The audio is cut into 25 ms windows (400 samples) every 10 ms
   (hop 160). Each is turned into frequencies with an FFT (512 points), and the frequencies are
   grouped into **128 mel bands** (a scale that matches how human hearing spaces pitch). The
   result is a picture of the sound: time × pitch × energy.
2. **Encoder.** A large network (a FastConformer) turns the picture into a sequence of vectors
   that summarise the sounds.
3. **Decoder + joint (TDT, Token-and-Duration Transducer).** At each step the model predicts
   **a token** (a word piece from a 1,024-entry vocabulary, or "blank" = nothing new) **and a
   duration** (how many encoder steps to skip; one of 5 values). Robo decodes *greedily* (takes
   the best guess each time, at most 10 tokens per step). The duration lets the model skip
   silence quickly, which is part of why TDT is fast.
4. **Text.** The word pieces are joined; `▁` marks a space.

**Why it matters, and the traps.**
- *int8 quantisation:* the weights are stored as 8-bit integers instead of 32-bit floats. The
  file is ~4× smaller and faster on a CPU, with a small loss of accuracy.
- *Precision is fragile.* The model can flip a word on feature differences of 1e-5, so the
  Swift FFT is computed in double precision, as the tuned transcripts were. The bundled
  float32 version changed 8 of 200 test transcripts.
- *CPU only.* Apple's CoreML backend loaded 3× slower, ran 2× slower and transcribed
  differently.

### 2.6 ONNX Runtime
**The idea.** *ONNX* is a standard file format for neural networks. *ONNX Runtime* (ORT,
Microsoft) is a library that runs them on many platforms.

**In Robo.** The model ships as two ONNX files (`encoder-model.int8.onnx`,
`decoder_joint-model.int8.onnx`). The Swift bindings are *vendored* (copied into
`native/Vendor/`) and pinned to ORT **1.30.0**.

**Why it matters.**
- Any ORT version change moved the encoder's output by ~4 %, enough to change transcripts, so the
  version is pinned.
- ORT 1.30 kept the weights twice in memory (~1.4 GB), so `disable_prepacking` is set (+15–20 ms
  per clip, same text).
- **ORT sends usage telemetry to Microsoft by default.** Robo sets
  `ORT_DISABLE_TELEMETRY=1`, which matters for a "no audio leaves the laptop" promise.

### 2.7 Name matching and closing the chat
**The idea.** A *regular expression* (regex) is a pattern for matching text.

**In Robo.** In the fallback mode (wake by name), a regex accepts what Parakeet actually writes
for "Robo": `robo`, `roboh`, `robot`, "hey robo", "ok robo"... (`startName` and `lead` in
`Listen.swift`). `RoboCore/Intent.swift` has one question left: is this whole sentence a request to
close the chat (`closesChat`)?

**Why it matters.** For 15 s after an answer you may reply without the key. That window can also
be filled by a TV or a roommate; nothing can act on the world, so such a sentence just goes to the
model. A sentence of only one word ("yeah") doesn't wake Robo: the first version woke on any noise
and wiped the reply being read.

---

## 3. Talking to the service: HTTP and streaming

Code: the app's client is `RoboCore/Brain.swift` (`AgentClient`);
the server is `agent/robo_agent/server.py` (aiohttp).

### 3.1 HTTP and REST
**The idea.** *HTTP* is the web's request/response protocol: a *method* (GET = read,
POST = act), a *path*, *headers* and a *body*. A *REST API* is a set of such paths.

**In Robo.** Three calls, plus a health check:
| Call | What it does |
|---|---|
| `POST /v1/runs` with `{"input": text, "session_id": ...}` | start a "run" (one reply); returns its id |
| `GET /v1/runs/{id}/events` | the stream of what happens (see 3.3) |
| `POST /v1/runs/{id}/stop` | cancel the run |
| `GET /health` | "are you up?" (no key needed; the AGENT light polls it) |

### 3.2 Authentication with a bearer token
**The idea.** An *API key* is a long random secret. Sent as `Authorization: Bearer <key>`, it
proves the caller is allowed.

**In Robo.** `robo setup` makes a server key (32 random bytes from the system's secure generator,
base64url) and stores it in `~/.local/share/robo/agent/server_key` (0600). The app sends it with
every call, and the server compares it in constant time (`hmac.compare_digest`).

**Why it matters.** Even on loopback, any program on the Mac could otherwise spend your DeepSeek key
through the service.

### 3.3 Server-Sent Events (SSE)
**The idea.** SSE is a long-lived HTTP response that the server keeps writing to. Each event is a
few lines (`id: 17`, `data: {...json...}`) followed by a blank line.

**In Robo.** The service sends `message.delta` for each piece of the reply, then one of
`run.completed`, `run.failed` or `run.cancelled`. `SSEParser` splits the bytes into events, and each
JSON payload becomes a Swift `Event` (`RoboCore/Events.swift`), such as `.delta(text)` and
`.runEnded(status:...)`.

**Why it matters.** Text appears while the AI is still writing; nobody waits for the whole
answer.

### 3.4 Resuming, and failing safe
**In Robo.** If the stream drops, the client reconnects once, asking for events after the last
id it saw (`Last-Event-ID`; the server keeps every event of a run and replays the rest). If that
fails too, it **stops the run**. The server also writes a `: ping` comment every 15 s on a quiet
stream, because the client gives up on a stream that is silent for 120 s.

**Why it matters.** A reply nobody can see shouldn't keep using the model.

### 3.5 Sessions
**The idea.** A *session* is a conversation the service remembers.

**In Robo.** The app uses one session id a day (`robo-<day>-<stamp>`; the stamp is a short hash of
`SOUL.md`, taken when the app starts). The service keeps each session's history (4.4).

---

## 4. The chat service: LLM, persona, history

All of it lives in `agent/`. There is no install step: the service reads `SOUL.md` from the checkout
on every request.

### 4.1 One call to an LLM
**The idea.** A *large language model* (LLM) predicts text. It is shown a conversation and writes
the next message.

**In Robo.** `agent/robo_agent/chat.py`, `execute`: the persona, the session's history and your new
text go to DeepSeek, model `deepseek-flash`, with thinking disabled and at most 8,192 tokens per
reply. The text comes back as `message.delta` events. There are no tools: the model can't do
anything but answer.

**Why it matters.** `chat.execute` is where a harness plugs in later: anything that emits
`message.delta` and ends a run the same way works with the app.

### 4.2 The persona (system prompt)
**The idea.** A *system prompt* is the standing instruction text the model reads before every
conversation.

**In Robo.** `agent/SOUL.md`. Some of its rules:
- start every reply with `[[feel:emotion]]`;
- say so when a request needs a tool it doesn't have, and never pretend it did something;
- write maths in LaTeX and code in fenced blocks;
- give hints before answers and never do graded work.

**Why it matters.** It's only a *request* to the model, which usually follows it but may not.

### 4.3 The provider
**In Robo.** DeepSeek offers an API in Anthropic's format, so the service uses the `anthropic`
Python client pointed at `https://api.deepseek.com/anthropic`. `ANTHROPIC_BASE_URL` reroutes it, which
is how the tests reach their fake. Both credentials are set to your DeepSeek key.

**Why it matters.** DeepSeek prefers Bearer, and the client would otherwise fill the missing
credential from a real Anthropic key in the environment, and send it to DeepSeek.

### 4.4 History
**In Robo.** `server.py` keeps a dictionary from session id to messages, in memory, and `chat.py`
cuts each one to the last 100. A turn joins it only when it completes, so a failed or stopped turn
is not remembered. A restart of the service forgets everything.

**Why it matters.** Real memory is left to the harness on purpose (see the top of `CLAUDE.md`).

---

## 5. Text on screen: streams, typing, Markdown, LaTeX

### 5.1 Parsing a stream: the feeling tag
**The idea.** A *streaming parser* handles input that arrives in arbitrary pieces.

**In Robo.** `RoboCore/Feelings.swift`, `FeelingFilter`: the tag `[[feel:happy]]` can arrive as
`[[fe` + `el:hap` + `py]] Hi`. The filter holds back anything that *could still become* a tag (up
to 80 characters), then emits `.feeling("happy")` and the clean text.

### 5.2 The typewriter: a schedule, not a timer per letter
**In Robo.** `RoboCore/Typewriter.swift` gives every character a *reveal time*:
- visible characters cost `1/cps` (about 55 a second);
- Markdown syntax costs nothing: an opening `**` appears *with* the next letter and a closing one
  with the previous letter, so a half mark never shows;
- sentence ends pause a little.

The app calls `advance(dt)` at 30 Hz. If the typing falls ~2 s or more behind what the service
has sent, it speeds up (up to 6×; 8× once the run has ended).

**Why it matters.** It looks alive, yet it never makes you wait longer than the AI itself. Each
tick re-renders the *prefix* as Markdown, which costs about 0.7 ms (measured), so typing uses
~2 % of a core.

### 5.3 Markdown to rich text
**The idea.** *Markdown* is plain text with light marks (`**bold**`, `- item`). An
*attributed string* is text with styles attached to ranges.

**In Robo.** `RoboUI/Markdown.swift` uses Foundation's Markdown parser
(`AttributedString(markdown:)`) and converts the blocks into an `NSAttributedString` with this
app's spacing, code boxes, task boxes, quotes and tables.

### 5.4 LaTeX with placeholders
**The idea.** *LaTeX* is the standard notation for maths (`\frac{a}{b}`, `x^2`).

**In Robo.**
1. `RoboCore/Latex.swift` finds formulas (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`) **before**
   the Markdown parser, which would eat the backslashes, and replaces each one with a
   private-use Unicode character plus a number.
2. `RoboUI/Math.swift` typesets each formula with **SwiftMath** (a library that draws maths with
   Core Text and the Latin Modern Math font) into an image, which goes into the text in place of
   the placeholder.
3. Each formula is drawn twice (dark ink and light ink), and the right one is picked at draw
   time, so a glass that flips from light to dark needs no rebuild.

Rules that avoid false formulas follow pandoc: `$5 and $10` is money, `\$` is a dollar sign, and
code is never read as maths.

### 5.5 Unicode: scalars versus characters
**The idea.** Text is stored as *Unicode code points* (scalars). What a person sees as one
"character" (a *grapheme cluster*) can be several scalars: `é` can be one scalar or `e` plus an
accent mark.

**In Robo.** Swift's `String` counts grapheme clusters and treats both kinds of `é` as equal.
Python counts scalars and doesn't. Code that must match Python works on `unicodeScalars`.

**Why it matters.** A `]` followed by a combining mark fuses into one Swift character, and a
`[[feel:x]]` tag would silently stop matching.

---

## 6. The face and its movement

### 6.1 Parametric expressions
**In Robo.** `RoboCore/Expressions.swift` maps (activity, emotion) to a set of numbers: eye
width and height, gaze, lids, lid angle, mouth width, skew and hue. "Thinking + curious" is just
a different set of numbers.

### 6.2 Springs
**The idea.** Animating with a *spring* means each value is pulled toward its target as if by an
elastic band. *Critically damped* means it arrives as fast as possible without wobbling past the
target.

**In Robo.** `RoboCore/Animator.swift`: every face number springs toward its target with
stiffness ω = 14 rad/s, critically damped. On top of that come blinks (0.15 s; a big change of
expression swaps the shape in the middle of a blink, like toy robots do), glances, breathing and
mouth movement while letters are typed.

### 6.3 Seeded randomness
**The idea.** A *pseudo-random number generator* (PRNG) produces numbers that look random but
are fixed by a starting *seed*.

**In Robo.** Blinks and glances use a Mersenne Twister, so a seed gives the same blinks every
time and tests can compare whole animation traces.

### 6.4 Drawing and its cost
**In Robo.** `RoboUI/FaceRender.swift` paints with **Core Graphics** (Apple's 2D drawing API): a
white disc of 112 points inside a 128×128 view (the rest is room for its shadow), lit from the top
left, with the eyes and mouth as ellipses and arcs in soft graphite "ink". Only a strong mood gives
the ink a colour, kept dark enough (relative luminance at most 0.13) to reach at least 4.5:1 against
the disc's edge. The repaint interval follows the activity (`FaceView.frameMS`: 33 ms when busy,
40 idle, 66 sleepy, 100 asleep). VoiceOver sees the face as a button named "Robo".

**Why it matters.** A pet that's always on screen must be cheap, so it repaints slowly when
nothing happens; 66 ms is the slowest interval that still shows a blink. To see every expression
at once, `ROBO_FACE_SHEET=<folder> native/test.sh --filter FaceSheet` writes a contact sheet.

### 6.5 Coordinate systems
**The idea.** Screens have an *origin* and an axis direction.

**In Robo.** AppKit puts (0, 0) at the **bottom-left** of the primary display with y going **up**.
Quartz and Robo's own maths use **top-left, y down**. `RoboUI/Screens.swift` converts between
them using the primary display's height. Views set `isFlipped` to get y-down.

### 6.6 The roaming state machine
**In Robo.** `RoboCore/Roam.swift`, `Roamer.step(now:asleep:engaged:called:)`, with a fixed priority:

1. **engaged**: the mouse is pressed on it, so it freezes;
2. **Stay**: pinned from the menu;
3. **called**: walks to the nearest side or corner at 240 px/s and waits there;
4. **held**: you dropped it somewhere, so it stays 10 min;
5. **asleep**: walks to the nearest corner;
6. **wander**: rests 20–60 s, then drifts (40 px/s on average, ease-in-out) to a wall of the
   main screen and bounces off it twice (16 px, 0.6 s).

`maxDT` = 0.25 s: after a laptop sleep, the time gap counts as one short frame, not a giant jump.

---

## 7. Mac windows, glass and the screen

### 7.1 An accessory app with a floating panel
**The idea.** A Mac app normally has a Dock icon and a menu bar, and takes the keyboard when
clicked.

**In Robo.**
- `Info.plist` sets `LSUIElement = true`, an **accessory app**: no Dock icon and no menu bar.
- The pet lives in an `NSPanel` (`RoboUI/Panel.swift`): borderless, see-through, at the
  *floating* window level (above normal windows), on every Space, and **non-activating**, so
  clicking it never takes the keyboard from the app you're typing in.
- Typing goes to the chat window (`RoboUI/ChatPanel.swift`), also a non-activating panel, whose
  text box takes the keyboard only when you click into it (and hands it back afterwards).

**Why it matters.** A pet that stole your keyboard focus would be unbearable. One cost: with no
menu bar, AppKit doesn't turn Cmd-C/V into copy/paste, so `RoboUI/Keys.swift` adds that back.

### 7.2 A global hotkey without extra permissions
**In Robo.** `RoboUI/Hotkey.swift` uses Carbon's old `RegisterEventHotKey`, not an event
monitor.

**Why it matters.**
- It needs **no Accessibility or Input Monitoring permission**.
- It delivers exactly one key-down and one key-up (no auto-repeat), which push-to-talk needs.
- The limit: if another app registers Ctrl+Q too, macOS doesn't report the clash.

### 7.3 Liquid Glass
**In Robo.** The card and the chat use `NSGlassEffectView` (Apple's *Liquid Glass* material,
new in macOS 26, which is why the app needs macOS 26). Text uses system colours. With Increase
Contrast on, the wash over the glass is stronger and secondary text is more opaque.

**Why it matters, and a bug.** Changing a glass view's light/dark appearance *after* it has drawn
could leave it showing the old one: black text on a black card, on the live app only. The fix:
make two glasses (light and dark) once, then only crossfade between them.

### 7.4 Adapting to what's behind the card
**The idea.** *Luma* is perceived brightness. *Hysteresis* means two thresholds (switch at 0.42
one way, 0.58 the other) so a value near the middle doesn't flicker. *Easing* moves gradually
toward a target. *Smoothstep* is an S-shaped curve.

**In Robo.**
1. `RoboUI/Backdrop.swift` uses **ScreenCaptureKit** to take a tiny 16-pixel picture of the
   screen under the card, *excluding Robo's own windows* (or it would measure itself and flip
   forever), about every 0.25 s.
2. `RoboCore/Shade.swift` decides light or dark with hysteresis and eases the change (time
   constant 0.12 s).
3. The text colour flips quickly through `smoothstep(0.35, 0.65)` instead of fading through an
   unreadable grey.

**Why it matters.** Text contrast was *measured* with the **WCAG** formula (the web's
accessibility standard; 4.5:1 is the minimum for body text) on real captures over black and white:
the lowest was 4.66:1 on the light look and 4.99:1 on the dark one.

### 7.5 The blur veil
**In Robo.** `RoboUI/BlurVeil.swift`: while Robo listens or the chat's text box has the keyboard, a
click-through panel just *below* Robo's level shows a slightly blurred picture of the screen
(σ = 1.3), refreshed every second. It's off under Reduce Transparency, or without Screen Recording
permission.

**Why it matters.** The system blur was too strong and "ghosted" at low opacity, so a custom
one was made.

---

## 8. Permissions, signing, installing, starting at login

### 8.1 TCC: macOS privacy permissions
**The idea.** macOS asks before an app may use the microphone, record the screen and so on. The
grants are stored by a system called *TCC* and tied to the app's identity.

**In Robo.** It needs the **Microphone**. **Screen Recording** is optional: it gives the adaptive
glass and the blur.

**A trap.** An app started *from a terminal* counts as the terminal, so test copies are started
with `open -n`.

### 8.2 Code signing
**The idea.** *Signing* attaches a cryptographic signature that proves who built an app and that
it hasn't changed since. A *designated requirement* is the rule macOS uses to decide whether a
new build is "the same app".

**In Robo.** `bundle.sh` signs with **"Robo Local Signing"**, a self-made certificate in its own
keychain. The designated requirement is the bundle id plus the certificate's hash.

**Why it matters.** Without a stable identity (*ad hoc* signing), every rebuild looks like a new
app, and macOS asks for the microphone again each time.

### 8.3 The app bundle
**In Robo.** `bundle.sh` assembles `Robo.app/Contents/`:
- `MacOS/robo`: the program;
- `Frameworks/onnxruntime.framework`: the speech model's runtime;
- `Resources/`: the math fonts;
- `Info.plist`: the app's id `ai.robo.app`, `LSUIElement`, and the text shown when it asks for
  the microphone.

It also adds an *rpath* (where to look for libraries) so the program finds its framework, then
signs the whole bundle.

### 8.4 Starting at login: launchd
**The idea.** *launchd* is the macOS service manager. A *LaunchAgent* plist file tells it to
start a program when you log in; `launchctl` controls it.

**In Robo.** `robo setup` writes `~/Library/LaunchAgents/ai.robo.plist` pointing at the build
that ran setup.

**A trap.** After replacing the binary, launchd sometimes refused it (`OS_REASON_CODESIGNING`).
The fix was `bootout` followed by `bootstrap` (re-register), not editing anything.

### 8.5 What `robo setup` changes
`RoboSystem/Setup.swift`:
1. checks it runs from the `.app` and that `uv` is installed;
2. writes `~/.local/share/robo/agent/config.json`, keeping what is already there;
3. creates the server key if there is none;
4. writes the LaunchAgent;
5. reminds you to run `robo key set deepseek` if the key is missing.

It's built to be re-runnable: running it twice gives the same result (*idempotent*). The API key
goes through `robo key set deepseek`, which reads it from a hidden prompt or from stdin, never from
the command line (where it would stay in the shell's history).

---

## 9. Concurrency: doing several things at once

### 9.1 The main thread
**The idea.** A *thread* is a line of execution. UI frameworks allow screen changes from only
one, the *main thread*. Anything slow on it freezes the app.

**In Robo.** These run off the main thread:
- the microphone and the speech model (a dedicated thread, `robo-listen`);
- the service's stream, and starting the service (`AgentService.ensure` can wait up to 30 s).

Results hop to the main thread before touching the UI.

### 9.2 Swift concurrency
**The idea.**
- `async` marks a function that can pause, and `await` marks where it may pause.
- `@MainActor` marks code that must run on the main thread, and the compiler checks it.
- `Sendable` marks data that's safe to pass between threads.
- An `AsyncThrowingStream` is a sequence whose items arrive over time (`for try await event in
  stream`).
- A `TaskGroup` runs several tasks in parallel and collects their results.

**In Robo.** `AgentClient.events(...)` is an `AsyncThrowingStream<Event, Error>`. The service is
Python `asyncio`, the same idea in another language: each run is a task.

### 9.3 Two real concurrency lessons
- **A crash that only happened in release.** A task group collected results into a captured
  variable. Every debug-build test passed; the optimised release build lost every answer and
  crashed in `TaskGroup::offer` 14 s after launch. The fix: return the results from the group
  (`withTaskGroup(of:returning:)`). The rule since then: **run concurrency tests in release mode
  too** (`./test.sh -c release -Xswiftc -enable-testing`).
- **Uncatchable exceptions.** Apple's audio engine reports some errors as Objective-C
  `NSException`s, which Swift's `do/catch` can't catch: the app just aborts. The only defences
  are avoiding the condition (2.1) or a small Objective-C wrapper.

---

## 10. Files, data and secrets

### 10.1 Where things live
| Path | What |
|---|---|
| `~/.local/share/robo/agent/` (folder 0700) | the service: `config.json` and the keys (`api_key`, `server_key`) |
| `~/.config/robo/theme.json` | settings you may edit by hand |
| `~/Library/Logs/Robo/agent.log` | the service's output |

The split between *config* (`~/.config`) and *data* (`~/.local/share`) follows the XDG Base
Directory convention.

### 10.2 File permissions
**The idea.** Unix permissions in octal: `0600` = only the owner can read and write; `0700` = only
the owner can enter the folder.

**In Robo.** The keys are `0600`, inside a `0700` folder.

### 10.3 Atomic writes
**The idea.** Write the new content to a temporary file in the same folder, then *rename* it over
the old one. A rename is atomic: other readers see the old file or the new one, never half.

**In Robo.** `config.json` and the key files (`Host.atomicWrite` in `RoboSystem/Host.swift`).

### 10.4 Secrets
**In Robo.** No key is ever printed, logged or put in an error. `robo key status` says only "set" or
"not set".

**Why not the Keychain?** That was tried. The Keychain pins an item to the exact build that saved
it, so each rebuild asked for the login password, and a background read hung waiting on that
dialog.

---

## 11. Testing and quality

### 11.1 The test frameworks
- **Swift Testing** (`@Test`, `#expect`): the tests in `native/Tests/`, one folder per module.
- **pytest** for the service: `tests/test_chat.py` runs the real service and the real `anthropic`
  client against a fake DeepSeek on loopback, each test in a throwaway `HOME`. No key, no network.
- **ruff**: a Python *linter* (checks style and common mistakes).

### 11.2 Kinds of checks used
| Check | What it gives |
|---|---|
| Unit tests on pure code | exact answers, fast |
| Whole-window tests with fakes | the real flow without hardware |
| Golden values from Python | proof the port matches |
| `robo voice-eval` (TTS voices, or your own recordings) | a score to compare a change with the one before |
| Release-mode test run | catches optimiser-only concurrency bugs |
| Looking at captured screenshots | bugs no test sees (a cut-off line, black on black) |

### 11.3 CI and flaky tests
**The idea.** CI runs the tests on fresh machines for every PR. A *flaky* test passes or fails
depending on timing or machine speed, not on the code.

**In Robo.** `.github/workflows/tests.yml` runs the Swift tests on a `macos-26` runner and pytest
and ruff on Ubuntu. PR #7 was merged over one red macOS run: a typing test that needs to catch a reply
mid-typing failed twice on GitHub's runner, but passed 3/3 locally, and the PR didn't touch that code. Making such a test
not depend on machine speed (a fake clock instead of real waiting) is the real fix.

### 11.4 "Verified" means seen
CLAUDE.md separates **verified with fakes**, **verified live** and **not verified** for every
feature. Some bugs (the black-on-black card, the last line of a card cut off) were only found by
looking at the real app.

---

## 12. Build tools and dependencies

| Tool | Role |
|---|---|
| **SwiftPM** (`Package.swift`) | builds the Swift modules, fetches SwiftMath (exact pin `1.7.3`), uses the vendored ONNX Runtime |
| **`native/test.sh`** | runs `swift test` with the path to the Testing macros, which the Command Line Tools ship but don't pass by themselves |
| **`native/bundle.sh`** | release build → `.app` folder → `Info.plist` → sign (8.3) |
| **uv** | the Python package manager (fast; `uv.lock` pins every version, all at least two weeks old) |
| **`pyproject.toml`** | the service's dependencies (`anthropic`, `aiohttp`, exact pins), its `robo-agent` command and tool settings |
| **Git + GitHub** | `dev` for work, `master` for what runs, PRs with CI between them |

**Pinning** (exact versions) matters here more than usual: one ONNX Runtime version change
changes transcripts (2.6).

---

## 13. Trade-offs at a glance

| Decision | Gained | Paid |
|---|---|---|
| Local speech model on the CPU | privacy, works offline, stable transcripts | ~1.2–1.4 GB of RAM, a second to load, CPU use while transcribing |
| Push-to-talk instead of always matching the name | TV and other people are never transcribed | you press a key |
| Silence ends a request (3 s) | thinking pauses are fine | a noisy room keeps it open longer |
| A plain chatbot with no tools | nothing can act on the world, little to go wrong | it can only talk, and remembers little |
| Pure core + fakes | huge, fast test suite | more code: protocols, rigs, passing time around |
| Self-signed certificate | permissions survive rebuilds | a keychain to keep, launchd quirks |
| Files instead of the Keychain for secrets | no password dialogs on rebuild | protected only by file permissions |

---

*Written 2026-10-26, updated 2026-11-04 for the revamp (the new face, macOS 26) and 2026-11-05 for
the plain chatbot. Numbers come from CLAUDE.md and the code's comments, which record when and how
each was measured.*
