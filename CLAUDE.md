# Robo: notes for agents

Read `README.md` first (features, setup, layout table, `dev` → PR → `master` workflow). This file
holds only what the code and the README don't say. Product intent: a Desktop Goose-style pet that
lives on the screen but helps. Keep it alive (it reacts, roams, looks around) and out of the way.
Voice is input only: the user talks to it through the mic (local speech recognition) and it answers
in text in the bubble. It never speaks, so don't add speech output.

## Verify
- `uv run pytest -q && uv run ruff check src tests scripts hermes`. CI runs both on Ubuntu and
  macOS with `QT_QPA_PLATFORM=offscreen`.
- UI: render with `QWidget.grab()` and look at the PNG. For the real window, capture only that
  window (`screencapture -l<id>`, id from Quartz `kCGWindowName == "Robo"`); a full-screen capture
  shows whatever else the user has open.
- Voice: `scripts/voice_eval.py` (macOS voices → real Parakeet → name matcher). Compare a change with
  the score before it. The "Rubble was…" false positive is deliberate (see `listen._START_NAME`).
  Its `--record` / `--wavs` modes score the user's own voice (the only way to calibrate `MIN_GATE`);
  don't record while a call is live, the mic would capture other people.
- Run the real app without reaching the live agent: `ROBO_HERMES_URL=http://127.0.0.1:9 uv run robo`.
- Hermes-backed features (digest, study plan, `robo-make`) can only be checked against the live
  gateway: `printf '<prompt>\n' | uv run robo chat` prints the tools it used. The digest takes
  about 2 min, reads mail, Teams, Moodle and the calendar, and writes nothing until a "yes";
  `robo-make` writes into `~/Robo/`. Activity, plan and autostart can be run for real in a throwaway
  `HOME` (`HOME=<dir> .venv/bin/robo activity`, `setup.desktop(platform="darwin")` + `plutil -lint`).
- To look at a page `robo-make` wrote, serve a copy over loopback (browser tools block `file:`) and
  delete the `.playwright-mcp/` folder they leave in the repo.

## The machine is a live deployment
Hermes runs robo with approvals off. `robo setup` rewrites the `ai.robo` LaunchAgent to point at
the checkout it is run from, which may not be the one that runs at login. Don't run `setup` or
`signin` while testing, and send Hermes nothing but a harmless prompt if a live check is needed.

## Constraints (checked 2026-10-12; recheck if Qt, onnx-asr or Parakeet change)
- **Speech model on the CPU only** (`listen.Parakeet`, `providers=["CPUExecutionProvider"]`). On a
  Mac the default CoreML provider loaded 3× slower, ran 2× slower and transcribed differently
  (fp16) from the CPU output the name matcher was tuned on.
- **Audio is levelled before Parakeet** (`listen.leveled`, peak 0.5, boost capped at 20×): the model
  reads soft speech worse (synthetic voice at 0.15× volume: 44 → 48 of 50 names caught).
- **Don't end a request on a "?".** Parakeet punctuates a clause cut off mid-question as a question
  (36 of 40 probes, 4 TTS voices), so an early send would pass half a request to an agent that has
  every permission. The README promises that a pause to think does not end the request.
- **Listener startup is asynchronous**: `Listener.start()` opens the mic and returns; the model
  loads on its thread. Use `Listener.running`, not the return value, to know voice input is alive.
  Listener callbacks reach the UI only through `app._Bridge` signals.
- **Qt text**: `QTextDocument.setDefaultStyleSheet` does not apply to `setMarkdown`, so
  `widgets.style_markdown` post-processes the document. Block backgrounds cannot pad. macOS has no
  `monospace` family (`widgets.MONO` names Menlo first). A hidden `QTextBrowser` has no real width,
  so `RoboWindow._size_text` measures again once a box becomes visible (otherwise the first message
  is clipped to one line).
- **Right-click menu**: one `QGridLayout`. Nested per-row layouts gave an intermittent
  "QObject: shared QObject was deleted directly" message at exit.
- **Face cost**: the repaint interval follows the activity (`FRAME_MS` in `face/widget.py`), and
  the glow strokes are drawn without antialiasing on purpose (mean pixel difference 0.1/255).
  Idle robo costs about 5 % of one core. 66 ms is the slowest interval that still shows a blink.
- **Tests that send `RunEnded` straight to `RoboWindow`** must patch `OUTPUT_DIR` and `open_file`;
  otherwise `_made_since(0.0)` opens real files from `~/Robo`.
