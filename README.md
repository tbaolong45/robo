# Robo

Robo is a small animated robot face that lives on your macOS desktop and acts as a voice front end for a local AI agent. You talk to it, it hands the request to the agent, and the agent's answer streams back as text that is typed out in a Liquid Glass chat window. While it waits, Robo walks along the screen edges, looks around and reacts.

Two ideas shape the project:

- **The pet is only the interface.** Speech recognition, the face, windows and reminders run inside Robo. All reasoning and tool use (browser, terminal, files, desktop apps) happens in a separate agent process, which Robo reaches over loopback HTTP.
- **Voice is input only.** Robo listens through the microphone and answers in text. It never speaks.

## Architecture

```
┌──────────────────────── Robo (macOS app) ────────────────────────┐
│  mic ─▶ endpointing ─▶ Parakeet (ONNX, CPU) ─▶ text               │
│                                                │                  │
│  face · roaming · card · chat ◀── SSE stream ◀─┤                  │
│  calendar nudges · daily radar · source checks │                  │
└────────────────────────────────────────────────┼──────────────────┘
                                                 │ HTTP on 127.0.0.1
┌────────────────────────── Agent server ────────▼──────────────────┐
│  persona (SOUL.md) · skills · robo-guard plugin · LLM · tools     │
└───────────────────────────────────────────────────────────────────┘
```

- **Agent protocol.** A request is `POST /v1/runs` with a Bearer key. Robo then follows the run's Server-Sent Events: text deltas, tool calls, approval requests and the end of the run. `/approval` answers an ask and `/stop` cancels a run.
- **Pure core, thin shell.** Every decision is a plain function that is given the current time and returns what to do. That covers the face's mood, where the pet walks, which reminder fires and whether a card may interrupt you. Windows, audio and the network sit in a thin layer around these functions, so almost all behaviour can be tested without a screen, a clock or a microphone.

## How it works

### Voice
- Audio is captured at 16 kHz in 80 ms frames.
- A loudness gate decides which frames count as speech. It sits at 2.5× the room's noise floor, never below a fixed minimum. A short pre-roll keeps the start of a word.
- Push to talk is a global hotkey (Ctrl+Q, registered through Carbon `RegisterEventHotKey`, which needs no Accessibility permission). Hold it to talk. A tap starts listening for one sentence, ended by 3 s of silence. If the key can't be registered, Robo wakes when you say its name instead.
- Each clip is levelled before it is transcribed.
- Speech is turned into text on the device, with NVIDIA Parakeet TDT 0.6B (int8) on ONNX Runtime:
  - a 128-band mel spectrogram is computed first;
  - TDT decoding is greedy;
  - it runs on the CPU only, because other execution providers changed the transcripts;
  - the runtime's telemetry is turned off.
- No audio leaves the machine.
- For 15 s after a reply has finished typing, you can answer without the key. A reply in that window must be two words or more, and it can't ask for anything that changes the world (send, delete, pay, a bare "yes").

### Text on screen
- **Typing.** Replies are typed out at about 55 characters a second and never fall more than a few seconds behind the stream.
- **Markdown.** On each tick the shown prefix is rendered with its open marks closed, so a half-typed `**` never flashes.
- **Mood tags.** A hidden `[[feel:x]]` tag at the start of a reply sets the face's expression before the first word appears. A filter strips it from the stream, even when the tag is split across chunks.
- **LaTeX.** Formulas are taken out of the text before the Markdown parse, then typeset with SwiftMath. Each formula is drawn in two inks, so it stays legible when the glass flips between light and dark.
- **Adaptive glass.**
  - Robo captures a 16 px picture of the screen behind its glass (ScreenCaptureKit, with Robo's own windows left out) and measures its brightness.
  - Over a dark area the glass turns light, and over a light area it turns dark.
  - The switch uses hysteresis and easing, so the glass doesn't flicker at the boundary.
  - Contrast is checked against WCAG.

### The pet
- **Animation.** The face's features move on springs. Blinks and glances come from a seeded random number generator, so the motion is reproducible in tests.
- **Roaming.** The pet rests, drifts to a wall of the main display and bounces a little when it gets there.
- **Calls.** When called, it walks to the nearest corner or side and waits there.
- **Priorities.** A mouse press beats Stay, Stay beats a call, a call beats a drop, a drop beats sleep, and sleep beats wandering.
- **Window.** The panel never takes the keyboard. Its transparent margin lets clicks pass through to whatever is behind it.

### Active mode
- **Deadline nudges.**
  - Robo reads calendar links (ICS, RFC 5545) and the user's study ledger.
  - A reminder ladder sets when each item is announced, for example 5 days, 1 day and 3 hours before a deadline.
  - A nudge budget allows three cards a day at fixed slots, with quiet hours at night. A card never interrupts a reply, a run or an idle Mac.
  - Deadlines are timed by the wall clock, the rest by a monotonic one.
- **Daily radar.** Once a morning Robo fetches papers, lab announcements, news, repositories, internships and contests. Then it:
  - fetches only from an exact host allowlist over HTTPS, with ETag/304 caching under SHA-256 file names;
  - ranks the items against a short interest profile, with TF-IDF and MMR to keep the list diverse;
  - writes them to a Markdown note.

  No AI runs in this step, and nothing it fetches reaches the agent.
- **Source checks.** Before a link or a radar item is shown, Robo runs an offline heuristic over it. It looks for look-alike hosts, brand names in the wrong place, hidden destinations and scam wording. A scam is dropped, a doubtful item is marked ⚠, and a primary source is marked ✓.
- **LMS scan.** A read-only agent skill reads new course posts and reports their dates as JSON. Robo's strict decoder trusts none of it:
  - the reply must be exactly one fenced list;
  - links are pinned to the right host and path;
  - dates must be real and plausible;
  - text must be one clean line, and every item must quote its source.

### Safety model
- **Persona.** `hermes/SOUL.md` sets the rules: do exactly what was asked, treat page text as data, never do graded work.
- **robo-guard plugin.** It checks every tool call before it runs. It can block a call (graded-work pages, the agent's own setup, remote content in notes) or ask the user about it (send, delete, desktop-app clicks). After each step it writes a receipt, so the UI can show "✓ sent" or "⚠ unverified" under a claim.
- **Secrets.** Calendar links and API keys are kept in files readable only by the user (mode 0600) and are never logged.
- **Approval mode.** With `approvals.mode: off`, the guard's blocks are the only hard stop. Set `approvals.mode` to `manual` to get an Allow/Deny card before irreversible steps.

## Repository layout

| Path | What |
|---|---|
| `native/Sources/RoboCore` | Pure logic: the agent's event stream, the feeling filter, the mind, the roamer, the typewriter, Markdown and LaTeX extraction, ICS, reminders, the nudge budget, radar ranking, source checks, the LMS decoder |
| `native/Sources/RoboVoice` | Microphone, resampling, endpointing, mel features, Parakeet on ONNX Runtime |
| `native/Sources/RoboSystem` | Files and secrets, setup, calendar and radar fetchers, the browser profile, login item |
| `native/Sources/RoboUI` | The panel, face, card, chat, glass, backdrop sampling, hotkey |
| `native/Sources/robo` | Entry point and command line (`setup`, `calendar`, `plan`, `activity`) |
| `src/robo/` | The Python/Qt reference build. The Swift tests carry golden values generated from it |
| `hermes/` | The agent side: persona, skills and the `robo-guard` plugin |
| `docs/` | Architecture, a newcomer's guide and a technical deep dive |

## Build and test

You need Apple silicon, macOS 14 or newer (macOS 26 for Liquid Glass), the Swift toolchain, [uv](https://docs.astral.sh/uv/) and an agent server that speaks the runs API ([Hermes Agent](https://hermes-agent.nousresearch.com)).

```bash
# Swift app
cd native
./test.sh                                    # Swift Testing suite (use this, not `swift test`)
./test.sh -c release -Xswiftc -enable-testing  # also in release: concurrency bugs can show only there
ROBO_SIGN_IDENTITY="<your identity>" ./bundle.sh ~/Applications/Robo.app
~/Applications/Robo.app/Contents/MacOS/robo setup   # agent profile, skills, login item
open -n ~/Applications/Robo.app

# Python reference build and the agent templates
uv sync --extra dev
uv run pytest -q && uv run ruff check src tests scripts hermes
```

- **Signing.** Sign with a stable identity. macOS ties the microphone and Screen Recording permissions to the code signature, so an ad hoc build asks again after every rebuild.
- **Running without the agent.** To run the app with no live agent, start it with `ROBO_HERMES_URL=http://127.0.0.1:9`. Add `ROBO_NO_VOICE=1` and `ROBO_NO_WATCH=1` to turn off the microphone and the activity watcher.

## Further reading

- [docs/architecture.md](docs/architecture.md): diagrams of what runs where, one request from start to finish, and where files live.
- [docs/newcomer-guide.md](docs/newcomer-guide.md): the project explained for someone new to Swift and app development.
- [docs/technical-deep-dive.md](docs/technical-deep-dive.md): every technique used, why it was chosen and what it costs.

## Known limits

- **Prompt injection.** Robo reads untrusted text (mail, chats, web pages) and acts on your accounts. The persona and the guard reduce the risk but do not remove it.
- **Offline source checks.** They catch impersonation and offer scams, not phishing in general: about three quarters of live phishing URLs were flagged.
- **Spaces and full screen.** The app stays on the Space where it started and doesn't follow you into full-screen apps.
- **Hotkey clashes.** A clash with another app over the same hotkey is not detected.
