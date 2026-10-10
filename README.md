# Robo

A desktop study buddy with an animated robot face. Its brain is
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research); robo is the face and the chat window.

- **Ask anything.** Type in the window. Replies stream into the bubble while the mouth "talks".
- **The face shows what Hermes is doing.** It goes through thinking → browsing/searching → talking → idle, then sleepy after 5 min and asleep after 15 min.
- **It also shows how Hermes feels about its reply.** Hermes starts every reply with a hidden tag such as `[[feel:proud]]`. The app strips the tag and changes expression before the first word appears, so no extra model call is needed.
- **School digest.** It covers today's classes (Outlook calendar), important new mail, Teams messages, and what's due on Moodle. It runs on the first wake from sleep each day, or when you press 📚.

Hermes reads those sites in **robo's own Brave**. It is a separate profile in `~/.hermes/profiles/robo/brave` (mode 0700), signed in to your school accounts only. It runs headless on `127.0.0.1:9333` next to your everyday Brave. (Your everyday Brave profile can't be used: Brave locks its login databases while it is open.)

Hermes only **reads** these sites:
- The persona and the skills forbid sending, replying, submitting, deleting and marking anything.
- The `robo-guard` plugin blocks clicks and typing on write-like buttons.
- Inbox and Teams are read from their list views, because opening a message or chat marks it read.

## Setup

```bash
uv sync --extra dev
uv run robo setup     # once; safe to re-run
uv run robo signin    # once: sign in to Outlook, Teams and Moodle (passkey), then close that window
uv run robo           # the window
uv run robo chat      # text-only debug REPL (prints [emotion] before each reply)
```

`robo setup` does the following:
1. Turns on the Hermes API server in your default profile. It listens on `127.0.0.1:8642` only and needs a key. Only two keys are added to `~/.hermes/.env`; every other line is left as it is.
2. Creates a separate `robo` Hermes profile with its **own** key, served by the host gateway at `/p/robo/`.
3. Installs `hermes/SOUL.md`, `hermes/skills/school/*` and `hermes/plugins/robo-guard`. It also sets robo's model and its toolsets (browser, web, memory, skills; no terminal or file writes), and points robo's browser at robo's Brave (`browser.cdp_url`).
4. Restarts the gateway, but only if something changed.

It never changes your default profile beyond step 1.

Set your Moodle address once by telling robo: "my Moodle is https://…". Hermes remembers it.
When your school logins expire, run `robo signin` again. Robo can't do passkey sign-ins itself, so it says "not signed in" instead of guessing.

## Layout

| Path | What |
|---|---|
| `src/robo/brain.py` | `HermesClient`: `POST /v1/runs`, SSE `/v1/runs/{id}/events` → typed events |
| `src/robo/feelings.py` | Strips `[[feel:x]]` tags from the streamed text and turns them into `Feeling` events |
| `src/robo/mind.py` | Pure reducer: events + clock → activity, emotion, talking, status label |
| `src/robo/face/` | Expression table, spring/blink/glance animator, QPainter widget |
| `src/robo/app.py` | The window: face, bubble, input, 📚, Esc to stop, approval bar |
| `src/robo/wake.py` | logind `PrepareForSleep` watcher + once-a-day digest clock (`data/robo_state.json`) |
| `src/robo/browser.py` | Robo's own headless Brave (CDP on 127.0.0.1:9333) and `robo signin` |
| `src/robo/setup.py` | `robo setup` |
| `hermes/` | Persona, school skills, guard plugin and config installed into the robo profile |

The old `pli` terminal agent is preserved at git tag `pli-final`.

## Tests

```bash
uv run pytest -q && uv run ruff check src tests scripts
QT_QPA_PLATFORM=offscreen uv run python scripts/face_snapshots.py /tmp/faces   # every expression as PNG
```

## Limits (known)

- **The guard only judges what it can see.** It blocks clicks and typing on controls whose label contains a write word (send, reply, submit, delete, post, accept, …), and it blocks JavaScript evaluation and raw CDP. It can't judge controls with no text, such as icon-only buttons, or links passed straight to `browser_navigate`. Read-only is also written into the persona and skills.
- **Any local program can drive robo's Brave** through its debug port while it runs. The port listens on 127.0.0.1 only.
- **Opening a mail or a Teams chat marks it read.** The skills read the list views.
