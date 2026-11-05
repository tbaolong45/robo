# Robo, explained for a newcomer

This guide is for someone new to Swift and to building apps. It explains what Robo is, how its
pieces fit together and how to read its code. `README.md` lists the features and
`docs/technical-deep-dive.md` explains each technology in depth. This page is the gentle way in.

> **An honest note first.** Most of Robo was built by prompting AI agents, and many features were
> never checked by a person on the real machine. The tests are real and thorough, but "the tests
> pass" is not the same as "it works the way I want". Section 9 says what was verified and what
> wasn't.

---

## 1. What Robo is, in one minute

Robo is a small animated robot face that floats on your Mac's screen, like the "Desktop Goose"
toy, except you can talk to it.

- You **hold Ctrl+Q and talk**. Your Mac turns your voice into text locally, and no audio leaves
  the laptop. You can type too.
- That text goes to `robo-agent`, a small Python service in this repo, which asks an **AI model**
  (DeepSeek) for a reply. It is a plain chatbot: it has no tools and can't do anything on your Mac.
- The answer comes back as **text** in a glass-looking card or chat window. Robo never speaks.

## 2. The big picture: two programs that talk to each other

```
 ┌──────────────────────────── your Mac ─────────────────────────────┐
 │                                                                    │
 │   ROBO APP (native/, Swift)             ROBO-AGENT (agent/, Python)│
 │   the "face"                            the chat service           │
 │   ─────────────                         ────────────               │
 │   • draws the face, card, chat          • the persona (SOUL.md)    │
 │   • listens to the mic        HTTP      • the conversation so far  │
 │   • speech → text (Parakeet) ───────▶   • asks DeepSeek for a reply│
 │   • shows the reply         ◀───────                               │
 │   • starts the service        stream     runs at 127.0.0.1:8765    │
 │                               (SSE)                                │
 └────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
                                   the AI model (DeepSeek), on the internet
```

The key idea: **the app itself never talks to an AI model.** It is a user interface. It sends
your sentence to `robo-agent` over HTTP on your own machine (`127.0.0.1` means "this computer")
and shows what comes back. The app starts the service itself
(`uv run --project <this repo> robo-agent serve`) and starts it again if it has died.

The `agent/` folder holds the service:
- `robo_agent/`: `server.py` answers the app's HTTP calls, `chat.py` gets one reply from DeepSeek,
  `config.py` reads the settings and keys, and `cli.py` is the `robo-agent` command.
- `SOUL.md`: the **persona**, the instructions that tell the model how to behave ("start every
  reply with a feeling tag", "never do graded work", "you have no tools").

There is no install step: the service reads `SOUL.md` from this folder on every request. Its settings
and keys live in `~/.local/share/robo/agent/` (`robo setup` writes `config.json` there, and
`robo key set deepseek` stores your API key). There are no tools and no memory on purpose: the owner
will design that layer, and the earlier full agent is kept on the `revamp` branch.

## 3. Glossary: the words you will meet

| Word | What it means here |
|---|---|
| **Swift** | Apple's programming language for Mac and iPhone apps. Robo's app is written in it. |
| **SwiftPM** (Swift Package Manager) | Swift's built-in build tool. `native/Package.swift` tells it what to build. Similar to `pyproject.toml` + `pip` in Python. |
| **Package / target / module** | A *package* is the whole project (`native/`). It has *targets*, each a folder of code under `Sources/` that compiles into a *module* you can `import`. |
| **AppKit** | Apple's older toolkit for Mac windows, buttons and drawing (`NSWindow`, `NSView`). Robo uses it, not SwiftUI. |
| **`.app` bundle** | A Mac app is really a folder ending in `.app`, holding the program, its libraries and an `Info.plist` (the app's ID card). `bundle.sh` builds it. |
| **Code signing** | A cryptographic stamp on the app. macOS ties permissions (microphone, screen recording) to it, so Robo uses a stable self-made certificate ("Robo Local Signing") to keep them across rebuilds. |
| **LaunchAgent** | A macOS file (`~/Library/LaunchAgents/ai.robo.plist`) that starts a program when you log in. `launchctl` is the command that controls it. |
| **robo-agent** | Robo's chat service: a small local Python service (`agent/`) that sends your text to DeepSeek and streams the answer back. The app starts it in the background. |
| **Persona** | The standing instructions the model reads (`agent/SOUL.md`). |
| **HTTP / SSE** | Robo starts a "run" with `POST /v1/runs`, then listens to a *Server-Sent Events* stream: a connection that stays open while the service pushes events (text pieces, "the run ended"). |
| **Parakeet / ONNX Runtime** | Parakeet is NVIDIA's speech-to-text model. ONNX Runtime is the library that runs it on the CPU. Both live on the Mac. |
| **Pure code** | Code that only computes: no screen, no files, no clock of its own (time is passed in as an argument). It is easy to test, and Robo keeps as much as it can this way. |
| **CI** | Continuous Integration: GitHub runs the Swift tests on macOS and the service's Python tests on Ubuntu for every pull request into `master` (`.github/workflows/`). |
| **`dev` / `master` / PR** | Work goes on the `dev` branch. A *pull request* (PR) proposes merging it into `master`, the branch the laptops run. It's merged when CI is green. |

## 4. A map of the repository

```
robo/
├── README.md              what it does, setup, workflow
├── CLAUDE.md              hard-won facts for AI agents working here (dense, but true)
├── docs/
│   ├── newcomer-guide.md  this file
│   ├── technical-deep-dive.md  each technology, explained
│   └── backend-recommendations.md  speech and motion measurements, what to try next
├── agent/                 ★ the chat service: robo-agent (Python)
│   ├── robo_agent/        server, chat, config, CLI
│   └── SOUL.md            the persona
├── tests/                 the service's tests (pytest)
└── native/                ★ the Swift app
    ├── Package.swift      the build recipe
    ├── test.sh            run the tests (use this, not plain `swift test`)
    ├── bundle.sh          build a signed Robo.app
    ├── Vendor/            Microsoft's ONNX Runtime bindings, pinned to one version
    ├── Sources/
    │   ├── robo/          main.swift: the entry point, reads the command
    │   ├── RoboCore/      pure logic (no windows, no files)
    │   ├── RoboVoice/     microphone + speech recognition
    │   ├── RoboSystem/    talks to macOS: files, setup, the service
    │   └── RoboUI/        everything on screen
    └── Tests/             one test folder per module
```

### Why four modules?

It's a layered design. Each layer may only use the layers below it:

```
            robo  (main.swift: "which command did you type?")
             │
           RoboUI       windows, face drawing, card, chat, hotkey      ← hardest to test
          ╱   │   ╲
  RoboVoice RoboSystem │   mic & speech │ files, setup, network
          ╲   │   ╱
           RoboCore     pure rules: moods, typing pace, roaming,     ← easiest to test
                        glass shade, LaTeX extraction
```

This pays off in tests. `RoboCore` has no screen and no real clock, so a test can state the time
and the pet's position, ask where it walks next, and get an exact answer in microseconds. The UI
layer is kept thin so that most of the logic lives where it can be tested.

## 5. A Swift crash course, using Robo's own code

You can read most of this repo knowing about ten things.

### 5.1 Constants, variables, functions

```swift
let cap = 80                 // `let` = constant (can't change)
var buf = [Unicode.Scalar]() // `var` = variable; this is an empty array
func stripTags(_ reply: String) -> String { ... }   // takes a String, returns a String
```

The `_` means "no label when calling": you write `stripTags("hi")`, not `stripTags(reply: "hi")`.

### 5.2 Optionals: "maybe a value"

Swift makes you handle "nothing" explicitly. `String?` means "a String or `nil`".

```swift
private var mood: String?    // nil until the first feeling arrives

if let t = tag(s, at: i) { ... }        // runs only if tag(...) returned something
guard let key = readKey(file) else { throw ... }   // bail out early if missing
```

`guard ... else` is everywhere in this repo: "make sure this is true, or leave now".

### 5.3 `struct`, `enum`, `class`

- **`struct`**: a value, copied when you pass it. Most of RoboCore is structs
  (`FeelingFilter`, `Typewriter`, `Roamer`).
- **`enum`**: one of a fixed set of cases, optionally carrying data. The service's events are an
  enum: something like `.delta("Hi")`, `.feeling("happy")`, `.runEnded(...)`. A `switch` over an
  enum must handle every case, so the compiler tells you when you forgot one.
- **`class`**: a shared object, passed by reference. UI things are classes (`RoboWindow`,
  `NSView` subclasses), because a window is one thing that many parts point to.

`public enum Intent { static func ... }` is a trick for a "namespace": an enum with no cases
can't be created, so it's just a box of functions.

### 5.4 Access control

`private` = only this file. `public` = other modules can use it. RoboCore marks what RoboUI may
call as `public`; everything else stays hidden.

### 5.5 Closures

A closure is a function you pass around, written in `{ }`:

```swift
tokens.first(where: { $0.isEmpty })   // $0 is "the current element"
```

### 5.6 Concurrency: `async`, `await`, `@MainActor`

- Only the **main thread** may touch the screen. `@MainActor` on a class or function means "this
  runs on the main thread", and the compiler enforces it.
- `async` functions can pause without freezing the app (the service's stream).
  `await` marks the spot where they may pause.
- The microphone and speech model run on their own thread (`robo-listen`) and hand results to
  the UI.

A real lesson from this repo: a concurrency bug passed every debug-build test and then crashed
only in the **release** build. That's why CLAUDE.md says to also run the tests in release mode
for concurrency code.

### 5.7 Tests

Robo uses Apple's newer **Swift Testing** library. A test is a function marked `@Test`, and
`#expect` checks a condition. From `Tests/RoboCoreTests/FeelingsTests.swift`:

```swift
@Test func tagSplitAcrossDeltas() {
    var f = FeelingFilter()
    #expect(f.feed("[[fe") == [])            // not a whole tag yet: show nothing
    #expect(f.feed("el:hap") == [])
    #expect(f.feed("py]] Hi") == [.feeling("happy"), .delta("Hi")])
}
```

This tests a real problem. The service streams text in random-sized pieces, so the hidden mood tag
`[[feel:happy]]` can arrive split across three pieces, and Robo must never flash
`[[fe` on screen. `FeelingFilter` (`Sources/RoboCore/Feelings.swift`) holds text back until it
knows whether it's a tag.

The service's tests are ordinary **pytest** functions in `tests/`. They run the real service
against a fake DeepSeek on your own machine, so they take seconds and never call the real one.

**Suggested first exercise:** open `Feelings.swift` next to `FeelingsTests.swift` and match each
test to the code that makes it pass.

## 6. One request, start to finish

"Hold Ctrl+Q, *what's a derivative?*, let go":

1. **Hotkey** (`RoboUI/Hotkey.swift`): macOS reports Ctrl+Q down. `Listener.hold()` starts
   keeping the audio.
2. **Microphone** (`RoboVoice/AudioInput.swift`): sound arrives in small chunks (80 ms frames).
3. **Release** → `Listener.release()`. The audio is levelled (soft voices get louder) and
   **Parakeet** (`RoboVoice/Parakeet.swift`) turns it into text. On the CPU only: the GPU path was
   slower and gave different text.
4. **The window** (`RoboUI/Window.swift`, `App.swift`) shows your words and calls `ask(text)`.
   The face turns to "thinking".
5. **The client** (`RoboCore/Brain.swift`, `AgentClient`) sends `POST /v1/runs` to `127.0.0.1:8765` with the server key and opens
   the event stream. If the service has died, the app starts it again first (`AgentKeeper` in
   `RoboUI/Launch.swift`).
6. **robo-agent** (`agent/robo_agent/chat.py`) sends the persona, the session's history and your
   text to DeepSeek. Text pieces arrive in the app. **`FeelingFilter`** removes the `[[feel:x]]` tag
   and the face changes expression.
7. **The typewriter** (`RoboCore/Typewriter.swift`) shows the answer letter by letter, about
   55 characters a second, re-rendering the Markdown each tick so half-typed `**bold` never
   flashes.
8. **Display**: in the chat window (`ChatPanel.swift`, `Bubbles.swift`) or the pet's card
   (`Card.swift`). LaTeX formulas are typeset by `Math.swift` (the SwiftMath library).
9. **Mind** (`RoboCore/Mind.swift`) is a small *state machine* (idle → listening → thinking →
   talking → idle) that decides the face's mood from the events and the clock.
10. After the reply finishes typing there is a **15-second follow-up window**: you can answer
    without pressing the key, with a sentence of two words or more.

## 7. Features, and where they live

| Feature | Main files |
|---|---|
| Face (a white disc with coloured features), expressions, blinking, eyes following the mouse | `RoboCore/Expressions.swift`, `Animator.swift`, `RoboUI/FaceView.swift`, `FaceRender.swift` |
| Roaming along the screen edges, corners, the bounce | `RoboCore/Roam.swift`, `RoboUI/Screens.swift` |
| Voice: hotkey, mic, speech-to-text | `RoboUI/Hotkey.swift`, `RoboVoice/*` |
| Talking to the service | `RoboCore/Brain.swift`, `Events.swift`, `Health.swift`; starting it: `RoboSystem/Agent.swift`, `RoboUI/Launch.swift` |
| The chat service | `agent/robo_agent/server.py`, `chat.py`, `config.py`, `cli.py`, `agent/SOUL.md` |
| Glass card that turns light or dark to match the screen behind it | `RoboUI/CardChrome.swift`, `Backdrop.swift`, `RoboCore/Shade.swift` |
| Chat window with bubbles and LaTeX | `RoboUI/Chat.swift`, `ChatPanel.swift`, `Bubbles.swift`, `Math.swift`, `RoboCore/Transcript.swift` |
| Blur while listening or typing | `RoboUI/BlurVeil.swift` |
| `robo setup` (the service's settings and server key, the login item), `robo key` | `RoboSystem/Setup.swift`, `RoboSystem/Agent.swift` |

## 8. Building, testing and running

The app needs macOS 26 or newer (`native/Package.swift` says `.macOS(.v26)`). All Swift commands
are run from `native/`.

```bash
./test.sh                        # all Swift tests. Use this, not `swift test`:
                                 # the script passes a folder the Testing library needs.
./test.sh -c release -Xswiftc -enable-testing     # the same tests in release mode

swift build                      # just compile (debug)

# Build a signed app and install it where the login item looks for it:
ROBO_SIGN_IDENTITY="Robo Local Signing" ./bundle.sh ~/Applications/Robo.app

# Run a harmless test copy: no voice, service address pointed at nothing
# (with ROBO_AGENT_URL set, the app does not start its own service)
open -n --env ROBO_NO_VOICE=1 --env ROBO_AGENT_URL=http://127.0.0.1:9 ~/Applications/Robo.app
```

The chat service (Python), from the repo root:

```bash
uv sync                                                       # install dependencies
uv run pytest -q && uv run ruff check agent tests            # tests + linter
```

What `bundle.sh` does, step by step (a good way to learn what a Mac app *is*):
1. `swift build -c release` compiles an optimised program.
2. It makes the folder `Robo.app/Contents/{MacOS,Frameworks,Resources}`.
3. It copies in the program, the ONNX Runtime library and the math fonts.
4. It writes `Info.plist`, which holds the app's ID (`ai.robo.app`), "no Dock icon"
   (`LSUIElement`), the minimum macOS (26.0) and the sentence macOS shows when asking for the
   microphone.
5. It code-signs the result.

## 9. What was verified, and what wasn't
**Checked on the real Mac at some point:** push-to-talk, the glass card flipping light/dark, the
chat window's look, the microphone crash fix (a scratch program, not the real device change).

**Not verified for real** (from CLAUDE.md's own "Not verified" lists):
- whether the model follows the whole persona (a short live chat on 2026-11-05 did stream, remember and use the feeling tag);
- many UI states over light and dark backgrounds.

**One thing to know about.** Speech becomes text on the Mac, but that text, and what you type, goes
to DeepSeek. [Its privacy policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
says data is stored in the People's Republic of China.

## 10. How to read the code: a suggested order

1. `README.md` (features), then section 2 of this guide again.
2. `native/Package.swift` (about 30 lines: the module map).
3. `native/Sources/robo/main.swift` (the entry point: a `switch` over the command).
4. `RoboCore/Feelings.swift` + its test: small, pure, a real problem.
5. `RoboCore/Mind.swift` + `MindTests.swift`: the face's state machine.
6. `RoboCore/Typewriter.swift`: pacing, time passed in as an argument.
7. `RoboCore/Roam.swift`: how the pet decides where to walk.
8. `agent/robo_agent/server.py`, then `chat.py`: how one request is answered.
9. `RoboUI/Window.swift` and `App.swift`: where everything is wired together. This is the
   hardest part, so leave it for last.
10. `docs/technical-deep-dive.md` for each technology in depth.

Tip: the comments in this repo explain *why* (often with a date and a measurement), and CLAUDE.md
records the traps that were found the hard way. When something looks odd, search CLAUDE.md for
the name first: there's usually a story.

## 11. What this project shows about "vibe-coding"

Things that went well, worth copying next time:
- **A pure core with many tests.** It let AI agents change a lot of code without breaking it.
- **Small, well-named commits** on `dev`, with CI before `master`.
- **Writing down measurements**, not opinions ("3× slower", "36 of 40 probes").

Things to do differently:
- **Push often.** Nine commits nearly disappeared with a folder moved to the Trash.
- **Check features yourself**, not only through tests. Several bugs here were only found by
  looking at the real screen (black text on a black card, a cut-off line).
- **Keep scope small.** One app grew a speech engine, its own agent, a calendar system, a job
  radar, a scam detector and a chat window, which is a lot to maintain alone. On 2026-11-05 most of
  that was removed (it is on the `revamp` branch).
- **Be careful with permissions.** An agent with full access to your accounts and no approvals
  is a real risk, whoever wrote the code.
