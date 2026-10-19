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
  about 2 min, reads mail, Teams, Moodle and the calendar, and changes nothing there until a "yes",
  but a live digest now writes a Plans note into the Obsidian vault (`~/Documents/Robo`) and opens
  Obsidian in the background; `robo-make` writes into `~/Robo/`. Activity, plan and autostart can be run for real in a throwaway
  `HOME` (`HOME=<dir> .venv/bin/robo activity`, `setup.desktop(platform="darwin")` + `plutil -lint`).
- To look at a page `robo-make` wrote, serve a copy over loopback (browser tools block `file:`) and
  delete the `.playwright-mcp/` folder they leave in the repo.

## The machine is a live deployment
The config templates say `approvals.mode: manual` (timeout 120 s; it was `off` until 2026-10-19), but the
live Hermes profile only changes when the user runs `robo setup`, so assume the old `off` until told
otherwise. `robo setup` rewrites the `ai.robo` LaunchAgent (and the
skills' command) to point at the build it is run from: the Python checkout, or the Swift app
(`~/Applications/Robo.app` is the one that runs at login since 2026-10-13). Don't run `setup` or
`signin` while testing, and send Hermes nothing but a harmless prompt if a live check is needed.
Start a test copy of the app with `ROBO_NO_VOICE=1 ROBO_NO_WATCH=1` and a dead `ROBO_HERMES_URL`.

## Constraints (checked 2026-10-12; recheck if Qt, onnx-asr or Parakeet change)
- **Speech model on the CPU only** (`listen.Parakeet`, `providers=["CPUExecutionProvider"]`). On a
  Mac the default CoreML provider loaded 3× slower, ran 2× slower and transcribed differently
  (fp16) from the CPU output the name matcher was tuned on.
- **Audio is levelled before Parakeet** (`listen.leveled`, peak 0.5, boost capped at 20×): the model
  reads soft speech worse (synthetic voice at 0.15× volume: 44 → 48 of 50 names caught).
- **Don't end a request on a "?".** Parakeet punctuates a clause cut off mid-question as a question
  (36 of 40 probes, 4 TTS voices), so an early send would pass half a request to an agent that has
  every permission. The README promises that a pause to think does not end the request.
- **No spoken end word** (removed 2026-10-13 at the user's request). A request ends only after
  `PATIENT_SILENCE_S` = 3 s of quiet (Swift `Listen.patientSilenceS`). The old "over" check ran every
  ~0.8 s on the last 2 s of audio, so a natural "over" mid-sentence sent a half request; the 1.6 s
  pause also cut off thinking. Cost: a room that never goes quiet (TV) keeps the request open up to
  `PATIENT_MAX_S`. Don't add a word that can occur in speech.
- **Push to talk = Ctrl+Q (Swift app only, 2026-10-16)**, at the user's request, instead of the name.
  `RoboUI/Hotkey.swift` uses Carbon `RegisterEventHotKey` (no Accessibility or Input Monitoring
  permission; one down and one up event, no auto-repeat; a system hotkey should keep Ctrl+Q from the app in front, not checked).
  `Listener.hold()/release()` record from down to up regardless of the gate, +4 frames of tail; a press
  under `Listen.tapS` = 0.4 s is a click (`listenNow`). `Listener(nameWake:)` is `!hotkeyRegistered`:
  with the key, loud sound outside a window is not even transcribed; if the system refuses the key, the
  name wake is back. Registration is exclusive only inside a process: a second process registering the
  same combo was accepted in a probe, so a clash with another app is not detected (and which app gets
  the key then is untested). The Python build still wakes by name (spec and fallback). Test the real key
  with the user's own press (checked live 2026-10-16: hold and tap both work); a synthetic Ctrl+Q posted
  with `CGEvent` goes to the system, whichever app is in front.
- **Key-less follow-up window (Swift app, reworked 2026-10-19)**: `RoboWindow.followUpS` = 15 s, armed in
  `finishedTyping()` (not at run end: typing at 55 cps and reading used to eat the old 10 s; `followDue` is set
  in `ended()` and cleared by `clearReply()`/`closeBubble()`, which also send `ear.followUp(0)`, so errors, `say()`
  lines, mic notes and a new question never arm or keep it). The MIC light pulses LISTENING while it is open
  (`CardView.micState(..., following:)`). In `Listener` a window with `asked == false` wakes robo only after
  `minSpeechFrames` loud frames (a knock used to clear the reply and leave "listening" on). `Listener.handsFree`
  marks text spoken inside such a window; `onHeard` refuses it when `Intent.changesThings` (send, reply, delete,
  book, pay..., Vietnamese gửi/trả lời/xóa, or a sentence that is only "yes"/"ok"/"go ahead": the digest proposes
  and waits for a yes) and says to hold Ctrl+Q; a held key or a click is never filtered. Spoken text is never an
  approval (it stops the run, which denies). TV or another voice can still fill the window with a read-only
  request. The Python build keeps its 10 s from the end of the run.
- **Speech gate floor** (`MIN_GATE` / `Listen.minGate` = 0.008, lowered from 0.02 on 2026-10-15). The
  user's "Robo" on the MacBook Pro mic has p99 0.020 and peak 0.032 per 80 ms frame (room floor 0.0012,
  room peaks ~0.005), so at 0.02 none of five calls reached the model; at 0.008 all five did, at 0.012
  two. Calibrate on the user's own voice through the real mic (`scripts/voice_eval.py --record`, or
  replay a clip through `Endpointer`), not a TTS voice. Recording from the Bluetooth headset
  (WH-CH720N) while Robo ran was followed by "I lost the microphone, reconnecting..." in Robo (not
  isolated: probably the headset's profile switch); it recovered by itself within ~20 s.
- **Listener startup is asynchronous**: `Listener.start()` opens the mic and returns; the model
  loads on its thread. Use `Listener.running`, not the return value, to know voice input is alive.
  Listener callbacks reach the UI only through `app._Bridge` signals.
- **Qt text**: `QTextDocument.setDefaultStyleSheet` does not apply to `setMarkdown`, so
  `widgets.style_markdown` post-processes the document. Block backgrounds cannot pad. macOS has no
  `monospace` family (`widgets.MONO` names Menlo first). A hidden `QTextBrowser` has no real width,
  so `RoboWindow._size_text` measures again once a box becomes visible (otherwise the first message
  is clipped to one line). A heading's size only takes effect if the importer's
  `FontSizeAdjustment` is *cleared* (a merge cannot remove it, and while it exists it overrides any
  pixel size): `style_markdown` replaces the fragment's format. Fixed 2026-10-13; before that every
  heading rendered at body size, and the test only looked at the property, so check what renders.
- **Right-click menu**: one `QGridLayout`. Nested per-row layouts gave an intermittent
  "QObject: shared QObject was deleted directly" message at exit.
- **Face cost**: the repaint interval follows the activity (`FRAME_MS` in `face/widget.py`), and
  the glow strokes are drawn without antialiasing on purpose (mean pixel difference 0.1/255).
  Idle robo costs about 5 % of one core. 66 ms is the slowest interval that still shows a blink.
- **Tests can't open real files, notes or the gateway**: `tests/conftest.py` guards `OUTPUT_DIR`,
  `VAULT`, `open_file`, `open_note`, the vault spawner and `app.HealthPoller` for every test, so a
  test must patch them itself to open anything (otherwise `_made_since(0.0)` would open real files
  from `~/Robo` or the vault). It also points `theme.CONFIG` at a temp `theme.json` with `cps: 0`
  (instant typing, the old bubble); a test of the typing writes its own speed there. Other code
  must say `theme.CONFIG`, never `from robo.theme import CONFIG`, or the patch misses it.
- **The reply is typed, not printed** (`typewriter.py`, Qt-free, no clock of its own: `app` calls
  `advance(dt)` at 30 Hz, `TYPE_S`, only while letters are pending). Each tick re-renders the
  Markdown *prefix* with its open marks closed and the last word painted transparent, because
  `setMarkdown` resets the scroll bar (`_render` puts it back) and a half-typed `**` or `-` would
  flash. A tick costs about 3 ms (`setMarkdown`), so typing is ~10 % of a core for a few seconds;
  raise `TYPE_S` before anything else if a machine struggles. `cps: 0` shows replies at once.
  The pace follows Hermes (it never lags more than ~2-6 s), so don't slow it down for looks.
- **Liquid Glass card (Swift app, 2026-10-16, at the user's request; replaces the holo card and the five
  themes there)**: `GlassSurface` (`CardChrome.swift`) is `NSGlassEffectView` on macOS 26, a frosted
  `NSVisualEffectView(.hudWindow, state .active)` before. It is a plain sibling *behind* the card's views at
  `Chrome.glow` in, `Chrome.gap` (9) short of the bottom: the layout numbers (margins 42/19/19/19, column 302,
  window 348 wide, face x 110) did not change, and there is no tail (a rounded rect is all glass can be).
  Spike results (scratch app, same panel flags, 2026-10-16): glass renders properly in the never-key panel of an
  accessory app, in light and dark; `.clear` has weak contrast on bright backdrops, so `.regular`; the panel's
  transparent margin passes clicks through (WindowServer hit test); a 30 Hz resize costs ~0.5 ms per tick, no
  measurable window-server difference from a plain view. Text, lights and buttons are the system colours
  (`Chrome.text/textDim/hairline/wash`), fonts the system font (mono only for code), so no contrast table is
  possible any more: look at it over a bright and a dark backdrop (put your own striped window under a test copy
  and capture only that region, never a region of the user's desktop). The hue (accent) tints the glass at
  `CardView.tint` = 0.10, per 2-degree step. Only `Themes.glass` exists; `theme.json` keeps `hue, acc_s, acc_v,
  face_bg, cps, text_px, line_h, caret, caret_ms, follow_emotion, bot_name, model_chip` and ignores the rest. The
  card fades in over 0.18 s (`RoboWindow.fadeIn`, not with Reduce Motion); closing is instant on purpose.
  Measured with a throwaway probe against a clean checkout of the previous commit (2026-10-16, this Mac): a
  hue step costs 2.09 ms on the holo card (the card-sized frame bitmap rebuilt at 2x) and 0.04 ms now (one
  `tintColor`), about 50x less, and the face's mood sweep makes these steps all the time. The typing tick
  (`CardView.setReply`, 1000 characters) is 0.7 ms on average in both (median 0.8), so caching fonts or the
  Markdown look was tried and dropped: no gain. Typing is ~2 % of a core at 30 Hz; don't optimise it further
  without a new measurement.
  The Themes, Header lights and Face cost notes below describe the Python tree.
- **Backdrop-adaptive card (Swift, 2026-10-19, user request: "black area -> white chat, white area -> dark chat,
  smooth", and "the colour of the words has to contrast with the area it is in")**: `Backdrop` (ScreenCaptureKit
  `SCScreenshotManager`, display minus Robo's own app, 16 px picture of the glass rectangle, `Shade.meanLuma`) is asked
  about every 0.25 s while the card shows; `Shade` (pure, RoboCore) decides: luma < 0.42 -> light card, > 0.58 -> dark,
  between keeps the last (hysteresis), eases with tau 0.12 s, `ink` = smoothstep(0.35, 0.65, level) so the text flips fast
  instead of fading through a grey. `Chrome.text/textDim/faint/hairline/wash` read `Chrome.ink` (nil = the old system colours,
  used until a look succeeded and after 3 failed ones). **Spike (scratch app, same panel flags): an NSGlassEffectView's
  `appearance` decides light or dark; `tintColor` hardly matters; two stacked glasses (`.aqua` below, `.darkAqua` above at
  alpha 1 - level) crossfade smoothly** (`GlassSurface`; only one renders at rest). `veilStrength` 0.22 (a white/black wash
  over the glass) was set after measuring text contrast on real captures (WCAG, region of the body text): 8.8:1 light card
  over black, 4.48:1 dark card over white at 0 veil (hence the veil). Needs **Screen Recording for Robo** (the user's one
  click; `CGRequestScreenCaptureAccess` once per launch); without it the look is the system one. Verified with a test copy
  launched via `open -n` over my own black/white backdrop window; a copy built *before* the grant did not see it until
  rebuilt, so after a grant check with a fresh build. macOS may re-confirm capture access monthly (not seen yet). Pre-macOS-26
  fallback (blur flips appearance at 0.5) never ran here. Final measurement (final build, robo pinned with the menu's
  Stay over my own backdrop; WCAG contrast of the body text against the glass behind it): black 10.7:1, grey 0.25 12.2:1,
  grey 0.5 13.5:1 (inside the hysteresis band the card keeps the last look), grey 0.75 8.0:1, white 6.3:1; every one above 4.5:1.
  One early run showed a dark card over black that did not come back in 7 later trials (same code); if it shows up, suspect a
  stale `NSGlassEffectView` render after an appearance change or a capture that never returned (`Backdrop` has no timeout).
  To test: launch a copy with `open -n` (so the permission is Robo's, not your shell's), put an opaque window of your own at
  level `.floating - 1` under it, pin the pet with Stay (it roams otherwise), capture only that region.
- **Approvals, receipts, usage (Swift app, 2026-10-19)**: `approval.request` carries `request_id`; the app sends it with the
  answer and queues parallel asks (oldest shown, "+N more"), the automatic digest denies every ask at once, links in a reply
  ask first (`confirmLink`, an `NSAlert` with the full URL) and images are never fetched. The guard (`robo-guard`) now hard-blocks
  graded-work actions (Moodle quiz attempt URLs/labels, assignment submit, raw JS on school hosts, `/mod/quiz/` in a command)
  and remote images/scripts in written notes, and asks for send/move/junk/invites/Outlook-Teams `computer_use`; the asks only
  bite in `approvals.mode: manual`. It appends receipts to `~/.local/share/robo/receipts.jsonl`; the app shows "✓ sent · host"
  or "⚠ unverified" under a reply from them (`Receipt`) and logs tokens to `usage.jsonl` (`ROBO_DAILY_TOKENS` = optional cap;
  Hermes reports no usage for failed/cancelled runs). **The cua-driver capability manifest was researched and not shipped**:
  v3 manifests expire within 24 h (Hermes has no handling), need a per-profile file, and the terminal/browser tools bypass it.
- **Learning engine (2026-10-19)**: `study-quiz` skill (confidence 1-5 before the answer, citation, <= 5 questions), review state in a
  `## Reviews` section of `study.md` (boxes 1/3/7/14/30 d), one combined `Review:` task for `robo plan`, readiness in the digest;
  SOUL.md "Learning first" (hints before answers, graded work is never done for the student).
- **Themes (Python tree)**: every colour comes from a `theme.Theme` token, never a literal in a widget. The card
  follows the face's live hue in all five themes (the user chose this over one fixed colour);
  `hud.chrome` is cached on `Theme.rev` plus the quantised hue. Label contrast is tested at all
  360 hues (`tests/test_theme.py`), because the face's hue sweeps through every colour.
- **Header lights**: HERMES polls `<gateway>/health` (no key needed, `health.HealthPoller`, amber
  on the first miss, red on the second); MIC is `listen.Listener.ready` (thread alive *and* model
  loaded; `running` alone is true while it still loads).
- **Notes**: drafts, plans and text are Obsidian-flavoured Markdown in
  `~/Documents/Robo/{Drafts,Plans,Notes}`, written by the agent through the `robo-notes` skill
  (`{{VAULT}}` is filled by `robo setup`) and opened by the app with `obsidian://open?path=...`.
  `obsidian.json` (Obsidian's vault list) is only edited while Obsidian is closed.
- **Called = corner** (`Roamer.step`, 2026-10-13, reordered 2026-10-19): priority is `engaged` (mouse
  pressed: freeze) > Stay (the menu's pin, `Roamer.stays(now:)`: it stays, even through a call) >
  `called` (request or card up: walks to the nearest corner of its screen at `CALL_SPEED` = 240 px/s,
  since a drift's 40 px/s takes a minute across 2560 px, and stays; it clears a *drop's* hold) > `held`
  (a drop: 600 s) > `asleep` (walks to the *nearest* corner) > wander. Until 2026-10-19 a drop outranked
  a call and a nap always went to the bottom-right bed, so a dragged robo "went to the same corner, not
  the nearest" (the user's report); `bed()` is now only the initial placement. The right-click menu opens
  the card but does not call (`card.chips.isHidden`; Python: `menu.isHidden()`), or dragging then
  right-clicking for Stay would send it away. After the call it rests in the corner, then drifts. The
  branch draws no random numbers, so seeded wander paths did not change. Nearest is measured by the
  window's top-left, which is the face's up to a constant offset; with a tall card the face parks a
  card-height under a *top* corner (the card needs room above it). Swift's resting tick is 500 ms: a
  call can lag 0.5 s.
- **Several monitors** (`roam.fit`): the window must lie inside the *union* of the screens and may
  straddle two that touch; a spot half over a dead corner between unequal monitors goes to the nearest
  single-screen clamp. Both drag paths must call `roamer.hold` on every move, or the 33 ms roam tick
  pulls the window back (`tests/test_app.py` pins it). Screens are re-read after
  `screenAdded/Removed/primaryScreenChanged` (`QTimer.singleShot(0)`: a removed screen is still
  listed while its signal runs); an empty list keeps the last layout. Dragged live across a 2560×1440
  main and a built-in display at x = -1800 (2026-10-13), both ways, no snap-back.

## Native Swift port (`native/`, checked 2026-10-13)
A SwiftPM package that ports everything above (RoboCore, RoboVoice, RoboSystem, RoboUI) and **has
been the running app since 2026-10-13**: the `ai.robo` LaunchAgent starts `~/Applications/Robo.app`.
The Python tree stays as the spec (the ported tests carry golden values generated from it) and as
the fallback: `~/robo-cutover-backup-20261013/ROLLBACK.md` restores the old login item and profile.
- **Test with `native/test.sh`**, not `swift test` (the Command Line Tools ship the Testing macros
  but the default build system does not pass their folder). **Install a new build with
  `ROBO_SIGN_IDENTITY="Robo Local Signing" native/bundle.sh ~/Applications/Robo.app` (the path must
  end in `.app`), then `launchctl kickstart -k gui/$(id -u)/ai.robo`.** That identity is a
  self-signed certificate in `~/Library/Keychains/robo-signing.keychain-db` (empty password, in the
  search list, trusted for code signing); the designated requirement is the bundle id plus the
  certificate hash, so the microphone permission survives rebuilds. A build without
  `ROBO_SIGN_IDENTITY` is ad hoc and macOS asks again each time.
- **Start the app with `open -n --env ROBO_HERMES_URL=http://127.0.0.1:9 X.app`** for a real
  microphone: launched from a shell, the shell is the microphone client and robo says it lost it.
  Dev switches: `ROBO_NO_VOICE=1`, `ROBO_NO_WATCH=1` (`ROBO_HERMES_URL` also skips robo's Brave).
- **ONNX Runtime**: `native/Vendor/onnxruntime-swift-package-manager` is Microsoft's bindings trimmed
  and pointed at the 1.30.0 pod. Upstream's 1.24.2 changes 6 of 200 transcripts against the Python
  app's 1.31; any ORT version change moves the encoder output ~4 %, enough to flip a transcript.
  No 1.31 pod was published on 2026-10-13 (`curl -sI https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.31.0.zip`);
  the Swift encoder is ~13 ms per clip slower than Python's until it is. 1.30 also keeps the encoder
  weights twice (~1.4 GB footprint instead of ~0.8 GB), so `Parakeet.init` sets
  `session.disable_prepacking=1` (+15-20 ms per clip, same transcripts; measured with `footprint`,
  not `ps`, which is unreliable on a loaded Mac): drop it once a 1.31 pod exists.
- **ORT 1.30+ sends usage telemetry to Microsoft by default** (sockets to MSFT addresses 9-13 s after
  a session is created, in Python's 1.31 wheel too; none with `ORT_DISABLE_TELEMETRY=1`). Both
  builds set it before ORT starts (`listen.Parakeet.__init__`, Swift `Parakeet.init`).
- Swift traps to remember: `String ==` treats `e`+U+0301 and U+00E9 as equal (Python does not) and
  indexes grapheme clusters, so code-point logic uses `unicodeScalars`; `round()` is half-to-even in
  Python; `@MainActor` tests only run main-queue hops they `await`.
- **Skills call `{{ROBO}} plan|activity`** (`hermes/skills/school/study-plan/SKILL.md`): each
  `robo setup` fills the command of its own build (Python: `uv run --project <checkout> robo`; Swift:
  the app executable). `Setup.checkout` and `RoboApp.dataDir` come from `#filePath` of the build, so
  build from this checkout; Swift `robo setup` refuses a bare binary (it needs the `.app`).
- **First launch of a new signing identity** shows the microphone permission dialog; until it is
  answered the UI must not wait on it (`Listener.start()` must not block the main thread).
