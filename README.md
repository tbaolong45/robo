# Robo

A desktop study buddy with an animated robot face. Its brain is
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research); robo is the face and the chat window.

- **Ask anything.** Type in the window. Replies stream into the bubble while the mouth "talks".
- **The face shows what Hermes is doing.** It goes through thinking → browsing/searching → talking → idle, then sleepy after 5 min and asleep after 15 min.
- **It also shows how Hermes feels about its reply.** Hermes starts every reply with a hidden tag such as `[[feel:proud]]`. The app strips the tag and changes expression before the first word appears, so no extra model call is needed.
- **School digest.** It covers today's classes (Outlook calendar), important new mail, Teams messages, and what's due on Moodle. It runs once a day: when robo starts, or on the first wake from sleep. If it fails, it tries again on the next wake. Press 📚 to run it any time.

Hermes reads those sites in **robo's own Brave**. It is a separate profile in `~/.hermes/profiles/robo/brave` (mode 0700), signed in to your school accounts only. It runs headless on `127.0.0.1:9333` next to your everyday Brave. (Your everyday Brave profile can't be used: Brave locks its login databases while it is open.)

Hermes only **reads** these sites. The persona and the skills forbid sending, replying, submitting, deleting and marking anything. The `robo-guard` plugin enforces it as an allowlist:
- Robo's browser opens only Outlook, Teams, Microsoft sign-in and *your* Moodle. Sign-out, compose and prefilled-message links are refused.
- It can click only elements from the latest page snapshot whose label has no write word.
- It can't type, press Enter, accept dialogs, use the credential vault or edit skills.
- Once a conversation has read school pages, it can't fetch other URLs, so injected instructions can't post your mail anywhere.

## Setup

```bash
uv sync --extra dev
uv run robo setup --moodle https://moodle.your-school.edu   # once; safe to re-run
uv run robo signin    # once: sign in to Outlook, Teams and Moodle (passkey), then close that window
uv run robo           # the window
uv run robo chat      # text-only debug REPL (prints [emotion] before each reply)
```

`robo setup` does the following:
1. Turns on the Hermes API server in your default profile (Hermes' default bind is `127.0.0.1:8642`), with a key. Only `API_SERVER_ENABLED` and `API_SERVER_KEY` are added to `~/.hermes/.env`.
2. Creates a separate `robo` Hermes profile with its **own** key, served by the host gateway at `/p/robo/`.
3. Saves your Moodle address in the robo profile, then installs `hermes/SOUL.md`, `hermes/skills/school/*` and `hermes/plugins/robo-guard`. It also sets robo's model and its toolsets (browser, web, memory, skills; no terminal or file writes), and points robo's browser at robo's Brave (`browser.cdp_url`).
4. Restarts the gateway, but only if something changed.

It never changes your default profile beyond step 1.

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

- **The guard judges labels.** A button whose label has no write word, such as an icon-only button, can still be clicked. The skills say never to click anything but navigation.
- **Any local program can drive robo's Brave** through its debug port while it runs. The port listens on 127.0.0.1 only.
- **Opening a mail or a Teams chat marks it read.** The skills read the list views. Teams opens your most recent chat by itself when its Chat tab is shown, so that one chat may be marked read.
- **Long or virtual lists.** Robo reports what the page shows (the first part of a long inbox), plus Moodle's upcoming and timeline pages only.
- **Public pages:** `web_search` works with Hermes' Brave Search backend. That backend can't fetch whole pages, so `web_extract` needs another Hermes web backend (e.g. Firecrawl, via `hermes -p robo tools`).
