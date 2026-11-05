# Robo: notes for agents

Read `README.md` first (setup, layout table, `dev` → PR → `master` workflow). This file
holds only what the code and the README don't say. Product intent: a Desktop Goose-style pet that
lives on the screen but helps. Keep it alive (it reacts, roams, looks around) and out of the way.
Voice is input only: the user talks to it through the mic (local speech recognition) and it answers
in text. It never speaks, so don't add speech output.

Two programs: the Swift app (`native/`, the running app since 2026-10-13; the Python/Qt build and
its tests were deleted in the 2026-11-04 revamp) and its chat service `robo-agent` (`agent/`, Python). macOS 26 is the minimum
(`Package.swift` `.macOS(.v26)`, `bundle.sh` `LSMinimumSystemVersion` 26.0): there is no pre-26 code path.

**The agent was removed on purpose (owner, 2026-11-05).** Robo is a plain chatbot with no tools. The full agent (tools, skills,
guard, sandbox, approvals, memory, learning, school features, nudges, radar, source check) is on branch `revamp`, commit `da7f196`.
The owner designs the harness and the self-improvement loop themself: don't add tools, memory or learning without being asked.
`chat.execute` is the seam: anything that emits `message.delta` and ends a run the same way works with the app.

## Verify
- Swift: `native/test.sh` (not `swift test`), and `native/test.sh -c release -Xswiftc -enable-testing` for
  concurrency code. Service: `uv run pytest -q && uv run ruff check agent tests`. CI runs the Swift suite on
  `macos-26` and pytest + `ruff check agent tests` on Ubuntu, on pushes to and PRs into `master`.
- UI: capture only Robo's window (`screencapture -l<id>`, id from Quartz `kCGWindowName == "Robo"`); a full-screen
  capture shows whatever else the user has open. The face: `ROBO_FACE_SHEET=<dir> native/test.sh --filter FaceSheet`
  writes `face_sheet.png` (every expression and effect, over white and dark grey). For glass over a backdrop: an
  `SCContentFilter` naming exact windows (your own opaque window plus Robo's), never a region capture: it caught a private
  notification on 2026-11-04.
- Voice: `robo voice-eval` (macOS voices → real Parakeet → name matcher). Compare a change with the score before it.
  The "Rubble was…" false positive is deliberate (`startName` in `Listen.swift`). `--record DIR` / `--wavs DIR` score
  the user's own voice (the only way to calibrate `Listen.minGate`); don't record while a call is live, the mic would
  capture other people.
- A test copy of the app, away from the live service:
  `open -n --env ROBO_AGENT_URL=http://127.0.0.1:9 --env ROBO_NO_VOICE=1 X.app`. With
  `ROBO_AGENT_URL` set the app does not start its service.
- **The service without the live setup or the network** (checked 2026-11-05): a throwaway `HOME=<dir>` holding
  `<dir>/.local/share/robo/agent/` (0700) with a `config.json` (e.g. `{"port": 8799}`), a `server_key` and a dummy `api_key`
  (0600 each), and `ANTHROPIC_BASE_URL=http://127.0.0.1:9` in the environment, so no request reaches DeepSeek. Start
  `HOME=<dir> ANTHROPIC_BASE_URL=http://127.0.0.1:9 uv run --project <checkout> robo-agent serve` and talk to it with curl
  (`/health` needs no key; everything else `Authorization: Bearer <server_key>`). With that dead address a run fails in about
  a second with `DeepSeek failed: Connection error.`
- `tests/test_chat.py` runs the real service and the real `anthropic` client against a fake DeepSeek on loopback: no key, no
  network. Use it for anything about what the client really sends.
- The tests needing a key window (`EditKeyTests`, `KeyboardHandoffTests`, `theTextBoxTakesFocusAcceptsTypingAndSendsIt`) fail
  while the screen is locked; unlock the Mac before trusting them.
- **Test trap: the pointer.** A card stays open while the pointer is over it, and a synthetic click leaves the pointer where it
  clicked, so tests and live checks of a card closing fail on a clean checkout until the pointer is warped to a corner
  (`CGWarpMouseCursorPosition`).

- **CI's compiler can reject what this Mac compiles (2026-11-05)**: `macos-26` failed with "unable to type-check this expression
  in reasonable time" on test lines unchanged since a green run on 2026-10-27; the runner's compiler probably changed (not proved).
  The whole Swift job stops at compiling, so no test runs. Check before pushing: `swift build --build-tests --scratch-path <dir>
  -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=100` (plus test.sh's plugin path), and spell out the types of what it names.

## The live setup
- `~/Applications/Robo.app` runs at login through the `ai.robo` LaunchAgent. At launch the app starts
  `uv run --project <checkout> robo-agent serve` (`AgentHome.service`), where `<checkout>` is the source
  tree the app was BUILT from (`Setup.checkout` = `#filePath`). So the live service's code and `agent/SOUL.md` are that
  checkout's files, and SOUL.md is re-read on every request, with no install step. Build the installed app
  from the checkout you mean it to run. The chat's session id is `robo-<day>-<personaStamp>`, a hash of SOUL.md
  taken once at app launch (`Launch.swift`): after editing it, a restarted app starts a new session, with an empty history.
- `R` = `~/.local/share/robo/agent` holds `config.json`, `api_key` and `server_key`. The service logs to
  `~/Library/Logs/Robo/agent.log`. History lives only in the service's memory (`make_app`'s `histories`): per session id, the last
  100 messages (`chat.MAX_MESSAGES`), lost on restart. A turn joins it only when it completes, so a failed or stopped turn is not
  remembered. The app's `Transcript` is memory only too.
- `config.json` is read ONCE when the service starts (`cli.main`), and only `port` and `model` mean anything to it; other settings,
  such as those `revamp` wrote, are ignored. The keys are read again on every request (an env var `DEEPSEEK_API_KEY` /
  `ROBO_SERVER_KEY` wins over the file). After editing the config, restart the service: the app stops the one it started when it
  quits (`applicationWillTerminate`) and `AgentKeeper` starts a new one before the next request; a service the app did not start
  is left alone. **`launchctl bootout` does not run that (2026-11-05): the service survived it, the new app found it healthy and
  used the old code.** After changing Python code, stop `robo-agent serve` too and check its start time.
- **Keys are 0600 files, not the Keychain (tried 2026-10-20, live)**: its partition list pins an item to the cdhash of the build
  that saved it, so each rebuild asked for the login password and a background read hung on that dialog.
- Don't run `robo setup` while testing (it rewrites `config.json`'s `uv_path` and the LaunchAgent to point at the build it runs
  from, and refuses a bare binary), and send the live service nothing but a harmless prompt if a live check is needed: it goes to
  DeepSeek.

## The chat service (`agent/robo_agent`)
- **Provider: DeepSeek (owner, 2026-11-05)**, through its Anthropic-format API: `https://api.deepseek.com/anthropic`
  (`config.API_BASE`), `deepseek-flash`, with the `anthropic` client. `chat.client` sets BOTH `api_key` and `auth_token`: DeepSeek
  prefers Bearer, and the client otherwise fills the missing one from a real Anthropic key in the environment.
  `ANTHROPIC_BASE_URL` overrides the address, which is the test seam. Thinking is disabled. Checked live on 2026-11-05 with
  `robo chat`: replies stream, the session remembers, and DeepSeek sends the stop reason that `chat.execute` needs to tell a
  whole reply from a dropped stream (a stream can end quietly with no error; without a stop reason the run fails).
- `Activity.working` and `.waiting` stay in the face tables though nothing reaches them now.

## Constraints (checked 2026-10-12; recheck if ONNX Runtime or Parakeet change)
- **Speech model on the CPU only** (`Parakeet`, `CPUExecutionProvider`). On a Mac the CoreML provider loaded 3× slower,
  ran 2× slower and transcribed differently (fp16) from the CPU output the name matcher was tuned on.
- **The app does not download the speech model**: it reads the Hugging Face cache
  (`~/.cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v2-onnx`, `refs/main` → snapshot with
  `encoder-model.int8.onnx`, `decoder_joint-model.int8.onnx`, `vocab.txt`).
  `Parakeet.cachedModel`'s error gives the `uvx` command that fetches it.
- **Audio is levelled before Parakeet** (`leveled`, peak 0.5, boost capped at 20×): the model reads soft speech worse
  (synthetic voice at 0.15× volume: 44 → 48 of 50 names caught).
- **English only (owner, 2026-11-05)**: Parakeet v2 hears only English.
- **Don't end a request on a "?".** Parakeet punctuates a clause cut off mid-question as a question (36 of 40 probes,
  4 TTS voices), so an early send would pass half a request on. A pause to think must not end the request.
- **No spoken end word** (removed 2026-10-13 at the user's request). A request ends only after
  `Listen.patientSilenceS` = 3 s of quiet. The old "over" check ran every ~0.8 s on the last 2 s of audio, so a natural
  "over" mid-sentence sent a half request; the 1.6 s pause also cut off thinking. Cost: a room that never goes quiet
  (TV) keeps the request open up to `patientMaxS`. Don't add a word that can occur in speech.
- **Push to talk = Ctrl+Q (2026-10-16)**, at the user's request, instead of the name. `RoboUI/Hotkey.swift` uses Carbon
  `RegisterEventHotKey` (no Accessibility or Input Monitoring permission; one down and one up event, no auto-repeat; a
  system hotkey should keep Ctrl+Q from the app in front, not checked). `Listener.hold()/release()` record from down to
  up regardless of the gate, +4 frames of tail; a press under `Listen.tapS` = 0.4 s is a click (`listenNow`).
  `Listener(nameWake:)` is `!byKey`: with the key, loud sound outside a window is not even transcribed; if the
  system refuses the key, the name wake is back. Registration is exclusive only inside a process: a second process
  registering the same combo was accepted in a probe, so a clash with another app is not detected (and which app gets
  the key then is untested). Test the real key with the user's own press (checked live 2026-10-16: hold and tap both
  work); a synthetic Ctrl+Q posted with `CGEvent` goes to the system, whichever app is in front.
- **Key-less follow-up window (reworked 2026-10-19)**: `RoboWindow.followUpS` = 15 s, armed in
  `finishedTyping()` (not at run end: typing at 55 cps and reading used to eat the old 10 s; `followDue` is set in
  `ended()` and cleared by `clearReply()`/`closeBubble()`, which also send `ear.followUp(0)`, so errors, `say()` lines,
  mic notes and a new question never arm or keep it). The MIC light pulses LISTENING while it is open. In `Listener` a
  window with `asked == false` delivers only a transcript of two words or more (`heard`): the first version woke robo
  after `minSpeechFrames` loud frames, and a noise in the room cleared the reply being read within seconds of a live
  reply (found 2026-10-19 on the live app). The listener never wakes robo for such text; `handsFree` travels with it
  (`onText(text, handsFree)`) and `onHeard` does the wake (which stops a run and clears the last reply). A held key or a click is
  never filtered. **Hands-free text is simply accepted (2026-11-05)**: nothing can act on the world, so
  the refusal went with the tools, and `Intent` only has `closesChat`. A harness that can act needs that gate back
  (`Intent.changesThings` on `revamp`, an allow-list of read-only sentences). TV or another voice can still fill the window, and
  that text goes to DeepSeek.
- **Speech gate floor** (`Listen.minGate` = 0.008, lowered from 0.02 on 2026-10-15). The user's "Robo" on the MacBook
  Pro mic has p99 0.020 and peak 0.032 per 80 ms frame (room floor 0.0012, room peaks ~0.005), so at 0.02 none of five
  calls reached the model; at 0.008 all five did, at 0.012 two. Calibrate on the user's own voice through the real mic
  (`robo voice-eval --record`, or replay a clip through `Endpointer`), not a TTS voice. Recording from the Bluetooth
  headset (WH-CH720N) while Robo ran was followed by "I lost the microphone, reconnecting..." (not isolated: probably the
  headset's profile switch); it recovered by itself within ~20 s. **The live app died of that class of event on
  2026-10-20 11:30 (SIGABRT on the `robo-listen` thread)**: `Microphone.init` read the input format, then
  `installTap(format:)` with it, and when the device changed in between AVAudioEngine raised an NSException ("Failed to
  create tap due to format mismatch", 2 ch 44100 Hz) that Swift cannot catch. Now the tap gets `format: nil` and
  `AdaptiveResampler` builds the converter from each buffer's own format. Reproduced with a scratch program (a wrong
  explicit format aborts with that message, exit 134; nil installs cleanly), the device change itself is not testable
  here. Other uncatchable AVAudioEngine exceptions could remain (a catch needs an Objective-C shim).
- **Listener startup is asynchronous**: `Listener.start()` opens the mic and returns; the model loads on its thread.
  Use `Listener.running`/`ready` to know voice input is alive. Listener callbacks reach the UI
  only through the window's `bridge` (main-queue hops).
- **The reply is typed, not printed** (`RoboCore/Typewriter.swift`, no clock of its own: the window calls `advance(dt)`
  every `RoboWindow.typeS` = 0.033 s while letters are pending). Each tick re-renders the Markdown *prefix* with its open
  marks closed and the last word hidden, so a half-typed `**` or `-` never flashes. The pace follows the service (it never
  lags more than ~2-6 s), so don't slow it down for looks. `cps: 0` in `~/.config/robo/theme.json` shows replies at once.
- **Face (2026-11-04)**: a white disc of 112 pt (`FaceRender.disc` = 112/128) inside a 128×128 `FaceView`, lit from the
  top left, the rest of the view is room for its shadow; the features are soft graphite (`FaceParams` hue 215, sat 0.08; luminance
  `FaceRender.graphiteL` = 0.045) and take a colour only for a strong mood: proud 44, concerned 34, playful 318, sad 258
  (dusk, it was royal blue), error 356; `inkL` = 0.13 is the ceiling for those, ≥ 4.5:1 on the disc. The disc is `#ffffff`
  to `#f6f7f9`; on a white backdrop its shadow (alpha 0.3) and rim (alpha 0.16) show where it ends. hue and sat left the
  Python goldens (`colourFields` in ExpressionsTests). The dark screen and neon glow of the
  Python design are gone. A face-only window is 136×136 (the face + `RoboWindow.margin` 4 on each side); the roamer is
  given that size. Accessibility: a button labelled "Robo". The repaint interval follows the activity
  (`FaceView.frameMS`: 33 ms busy, 40 idle, 66 sleepy, 100 asleep); 66 ms is the slowest that still shows a blink (2 shut
  frames). Look at the contact sheet after any face change.
- **Liquid Glass card (2026-10-16, at the user's request)**: `GlassSurface` (`CardChrome.swift`) is `NSGlassEffectView`. It
  is a plain sibling *behind* the card's views at `Chrome.glow` in, `Chrome.gap` (9) short of the bottom, and there is no
  tail (a rounded rect is all glass can be). Spike results (scratch app, same panel flags, 2026-10-16): glass renders
  properly in the never-key panel of an accessory app, in light and dark; `.clear` has weak contrast on bright
  backdrops, so `.regular`; the panel's transparent margin passes clicks through (WindowServer hit test); a 30 Hz resize
  costs ~0.5 ms per tick. Text, lights and buttons are the system colours (`Chrome.text/textDim/hairline/wash`), fonts
  the system font (mono only for code), so look at it over a bright and a dark backdrop (put your own striped window
  under a test copy and capture only that region, never a region of the user's desktop). No accent and no tint:
  everything is neutral ink. Only a warning (orange, the amber light) or a failure (red) has a
  colour. Links are the text's ink, underlined. Increase Contrast raises the veil and the text alpha
  (`Chrome.increaseContrast`). Only `Themes.glass` exists; `theme.json` keeps `face_bg, cps, text_px, line_h, caret,
  caret_ms, bot_name` and ignores the rest. The card fades in over 0.18 s
  (`RoboWindow.fadeIn`, not with Reduce Motion); closing is instant on purpose. The typing tick (`CardView.setReply`, 1000
  characters) is 0.7 ms on average; caching fonts or the Markdown look was tried and dropped. Typing is ~2 % of a core at
  30 Hz; don't optimise it further without a new measurement. The header lights show only when something is wrong
  (`Led.shows`: warn, bad) or while listening in the follow-up window: "Agent …", "Agent problem", "Mic problem", "Listening"
  (`Health.swift` polls `<agent>/health`, no key: one miss amber, two red; the mic is `Listener.ready`). There is no model chip.
  **Found by looking at the picture**: `WrapLabelView.height` measured without the `.kern: 0` that `draw` uses, so a line
  that just fit wrapped when drawn and the last line was cut off; now measured with the draw attributes. A test of the text
  cannot see this: capture the window.
- **Backdrop-adaptive card (2026-10-19, user request: "black area -> white chat, white area -> dark chat, smooth", and "the
  colour of the words has to contrast with the area it is in")**: `Backdrop` (ScreenCaptureKit `SCScreenshotManager`,
  display minus Robo's own app, 16 px picture of the glass rectangle, `Shade.meanLuma`) is asked about every 0.25 s while
  the card shows; `Shade` (pure, RoboCore) decides: luma < 0.42 -> light card, > 0.58 -> dark, between keeps the last
  (hysteresis), eases with tau 0.12 s, `ink` = smoothstep(0.35, 0.65, level) so the text flips fast instead of fading
  through a grey. `Chrome.text/textDim/hairline/wash` read `Chrome.ink` (nil = the system colours, used until a look
  succeeded and after 3 failed ones). **Spike: an NSGlassEffectView's `appearance` decides light or dark; `tintColor`
  hardly matters; two stacked glasses (`.aqua` below, `.darkAqua` above at alpha 1 - level) crossfade smoothly**
  (`GlassSurface`; only one renders at rest). `GlassSurface.lightVeil` 0.70, `darkVeil` 0.72 (Increase Contrast 0.85
  each). `Chrome.textDim` is our own 0.68 alpha, not `secondaryLabelColor` (3.5:1 on the light glass). Measured from pixels
  2026-11-04 over black and white: lowest 4.66:1, light look; 4.99:1, dark look. **Known, cause not found (2026-11-04):**
  while the card listens or works the glass renders nearly clear: a light pane 184 instead of 230 over black, dark 69
  instead of 28 over white, with the same view tree and shade level. A forced redraw, a resize and a layer-coloured veil
  did not change it. The veils are set so the text holds 4.5:1 either way. Needs **Screen Recording for Robo** (the user's one click;
  `CGRequestScreenCaptureAccess` once per launch); without it the look is the system one. A copy built *before* the grant
  did not see it until rebuilt, so after a grant check with a fresh build.
  **Bug found on the live app 2026-10-19 (the user's "black words on a black card")**: over a black backdrop the card
  stayed dark although the shade said light, 4 of 4 trials, while fresh test copies passed. Cause: changing an
  `NSGlassEffectView`'s `appearance` after it has rendered can leave it showing the old one. Both glasses now get `.aqua`
  / `.darkAqua` once at creation and only which one shows (hidden/alpha) changes. Test any glass change on the INSTALLED
  app, not only on a fresh copy, and look at the picture, not only at the numbers. To test: launch a copy with `open -n`
  (so the permission is Robo's, not your shell's), put an opaque window of your own at level `.floating - 1` under it,
  pin the pet with Stay (it roams otherwise), capture only that region.
- **Chat window (2026-10-23, user request: a bigger, detached, bubble-style, adaptive Liquid Glass chat; polished 2026-11-04)**.
  `ChatPanel`/`ChatView` (`ChatPanel.swift`),
  `BubbleView`/`BubbleText` (`Bubbles.swift`), the window side in `Chat.swift`, the conversation in RoboCore `Transcript`
  (memory only, one per service session id: `reset(for:)` on a new day or persona; 200 turns). Decisions (the user's): a
  window of its own, **fixed 520x640 (`ChatPanel.contentSize`), centred on the main display** each time it opens, opens
  on `ask()` (typed or spoken). It closes by its close
  button (`ChatView.close`, answers the first click), `Intent.closesChat` ("close the chat", whole sentence, spoken or
  typed; "close the browser tab" goes to the service), or Esc while its text box has the keyboard (`ChatPanel.onEscape`;
  the panel is non-activating, so Esc in another app never reaches it). No timer; a face click does not close it; English only. **All typing goes to the chat** (the separate Type panel
  was removed 2026-11-04): the menu's Type, or a face click while voice input is off, calls `typeText()` =
  `openChat(focusInput: true)`. The text box grows to `ChatPanel.inputLines` = 5 lines, Return sends, Shift+Return is a
  new line, Send is disabled while the box is empty; there is an empty state, a "jump to latest" button while scrolled
  up, Copy on robo's bubbles (the Markdown as written), no bubble tails, a bubble as wide as its text (`BubbleText.spansBox`: code, rules, tables and centred formulas keep the
  column), and `setLive` is throttled like the card's
  reply. A finished reply is announced to VoiceOver (`Chat.swift`, `.announcementRequested`). The pet's card keeps what
  is quick (menu, "Listening"); `say()` notices become robo bubbles while the chat is open
  (`Transcript.note` goes BEFORE the turn being written, which must stay last). Flow: `ask` -> `chatBegin` (your turn +
  an open empty robo turn, `clearReply()` only resets the typewriter), `render()` pushes `tw.view()` to
  `ChatView.setLive`, `finishedTyping` -> `chatSealed` (final text, footer, failed), `.listening(true)` or a new ask ->
  `chatInterrupted` (partial kept, footer "stopped", an empty turn is dropped). **Close mid-run falls back to the pet's
  card** (`render()` routes by `chatOpen`), so nothing is lost. `Machine.chatOn` is true in the app and **false in the
  `Rig` by default** (`Rig(chat: true)` in `ChatTests.swift`), so every card test is unchanged; `showChat`/`focusChat`
  are the seams (the rig records, never orders front). **Adaptive glass**: its own `Shade` (`chatShade`), looks every
  0.5 s while open, `GlassSurface(radius:)` crossfades and the PANEL's `appearance` flips at level 0.5, so text (system
  dynamic colours: `Markdown.attributed(..., ink: nil)`, `Chrome.text(_ ink:)`) follows with no rebuild and `Chrome.ink`
  stays the card's. The card's look and the chat's share the one `sampling` flag: `Backdrop` is single-flight and
  silently drops a second caller (its `done` never runs), so two flags would stick forever. The panel is non-activating,
  `becomesKeyOnlyIfNeeded`; a click on its text box takes the keyboard (`EditKeys`, handback through `Focus`).
  A test copy launched from a scratch path made macOS ask "bypass the system private
  window picker" for Screen Recording: do not click it for the user; test through the INSTALLED app
  (`open -n ~/Applications/Robo.app --env HOME=<throwaway> ...`, `ROBO_CHAT_DEMO=1` opens it with a made-up
  conversation), which has the grant. **Not verified**: Spaces/full-screen, dragging, the capture cost over time.
- **Chat polish, called-to-side, blur, LaTeX (2026-10-23)**. **Called = middle of the nearest side**: `Roamer.callToSide`
  (vertically centred; `nearestSide()` measures from the window's top-left like `Roamer.step`), `RoboWindow.roam()`
  counts `chatOpen` as called, so the pet parks at the left or right edge while the chat is up. **Blur**: only while Robo
  listens or the chat's text box has the keyboard (`machine.chatTyping`), no longer while the chat is merely up. `BlurVeil`
  (panel at `.floating - 1`, ignores the mouse) shows a blurred half-size capture of the screen WITHOUT Robo's windows
  (`Backdrop.blurredPicture`, `blurSigma` = 1.3, dim 0.10, refreshed every 1 s); none under Reduce Transparency or
  without Screen Recording. The system `NSVisualEffectView` blur was rejected: at partial alpha it only ghosts the sharp
  screen over itself; sigma 2.5 was too strong ("a little"). **LaTeX** (SwiftMath 1.7.3, exact pin in
  `native/Package.swift`): `Latex.extract` (RoboCore, pure) takes `$..$`, `$$..$$`, `\(..\)`, `\[..\]` out BEFORE the
  Markdown parse (Apple's parser eats the backslashes of `\frac`, `\_`, `\{`) and leaves a private-use placeholder;
  `Math.restore` (`Math.swift`, called inside `Markdown.attributed` before the typewriter's hidden tail) swaps each for a
  `MathCell` (an `NSTextAttachmentCell`, baseline = the typeset list's descent). Rules: code (fenced, inline) is never
  read, `\$` is a dollar, an inline `$` opens only with no space after it and closes only with no space before it and no
  digit after it ("costs $5 and $10" is text), no formula crosses a blank line, 600 characters and 60 per reply, invalid
  LaTeX goes back as the author's source with its dollars, a formula wider than the column is set smaller (down to
  60 %). **Each formula is typeset twice** (dark and light ink) and the cell picks at DRAW time by the view's
  `effectiveAppearance` (the chat) or the card's ink level, so the glass flipping needs no rebuild. **SwiftMath's fonts
  live in a resource bundle that SwiftPM's accessor looks for in `Contents/Resources`: `bundle.sh` copies every
  `*.bundle` of the build there; without it the first formula is a `fatalError`.** SOUL.md tells the model to write
  `$..$`/`$$..$$` and to fence code (an unfenced Python example once rendered `*` as emphasis). **Verified live
  under Hermes (2026-10-23)**: a long math answer typeset in the chat, a typed follow-up through the real text box, the
  typed "close the chat". **Not verified**: a formula in a table cell; any of it with this chat service.
- **Tables, scroller, VoiceOver menu, links**. `Markdown.tableLayouts`: a column is never narrower than its longest word, the prose
  columns give up the room, and if the longest words alone do not fit, cells go down to `tableMinPx` = 11; the grid is
  `Chrome.hairline`. `TextBox` uses the system's scroller at `.small`, and the text is `TextBox.scrollerRoom` narrower while
  it shows: an overlay scroller's track otherwise hides the end of each line (overlay knobs were still visible in captures
  6 s after opening, in this non-activating panel). The face answers VoiceOver's "show menu"
  (`accessibilityPerformShowMenu` = right click). Chips and buttons have plain labels; the chips use SF Symbols, not emoji.
  There is deliberately no global key for the menu: it would take a shortcut from every other app. Links in a reply ask first
  (`confirmLink`, an `NSAlert` with the full URL) and images are never fetched.
- **Called = corner** (`Roamer.step`, 2026-10-13, reordered 2026-10-19): priority is `engaged` (mouse pressed: freeze) >
  Stay (the menu's pin, `Roamer.stays(now:)`: it stays, even through a call) > `called` (request or card up: walks to the
  nearest corner, or the nearest side while the chat is open, at `Roam.callSpeed` = 240 px/s, and stays; it clears a
  *drop's* hold) > `held` (a drop: 600 s) > `asleep` (walks to the *nearest* corner) > wander. Until 2026-10-19 a drop
  outranked a call and a nap always went to the bottom-right bed, so a dragged robo "went to the same corner, not the
  nearest" (the user's report); `bed()` is now only the initial placement. The right-click menu opens the card but does
  not call (`card.chips.isHidden`), or dragging then right-clicking for Stay would send it away. The branch draws no
  random numbers, so seeded wander paths did not change. Nearest is measured by the window's top-left; with a tall card
  the face parks a card-height under a *top* corner. The resting tick is 500 ms: a call with no event, such as opening the chat box, can lag 0.5 s.
- **The main display only (2026-10-21, user request: "just work in the main screen and bounce (slightly) when it hits the
  edge")**. `ScreenSpace.roamArea` hands the `Roamer` the usable area of `displays.first` (the one with the menu bar) and
  no other, so a drift never leaves it and a drag onto a second monitor stops at the main display's edge (`roamer.hold`
  -> `fit`; the pure `Roamer`/`fit` still take a list of screens). A drift ends ON a wall (`pickTarget`), and then
  `Roam.bounce` plays: two shrinking hops (`bounceHeight` 16 px, 0.6 s) inward, applied as the *change* of the curve each
  frame so a resize or a move of the window during it is kept, and cut short by a press/drop/call (`startRest`). It is
  quicker than the 40 px/s drift on purpose (`neverFasterThanTheSpeedLimit` skips its steps); `Roamer.bouncing` keeps the
  window's 30 Hz timer for it. Calls and naps stop `Roam.edge` = 24 px in from a corner (no hop).

## Swift app (`native/`)
- **Test with `native/test.sh`**, not `swift test` (the Command Line Tools ship the Testing macros but the default build
  system does not pass their folder). **Install a new build with
  `ROBO_SIGN_IDENTITY="Robo Local Signing" native/bundle.sh ~/Applications/Robo.app` (the path must end in `.app`), then
  `launchctl kickstart -k gui/$(id -u)/ai.robo`.** (2026-10-19, macOS 26.7: after replacing the binary `kickstart` can
  fail with `last exit reason = OS_REASON_CODESIGNING`, `job state = spawn failed` and `needs LWCR update` in
  `launchctl print gui/$(id -u)/ai.robo`; the binary itself runs. Re-register the same plist:
  `launchctl bootout gui/$(id -u)/ai.robo; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.robo.plist`. That
  is not `robo setup`: it rewrites nothing.) That identity is a self-signed certificate in
  `~/Library/Keychains/robo-signing.keychain-db` (empty password, in the search list, trusted for code signing); the
  designated requirement is the bundle id plus the certificate hash, so the microphone permission survives rebuilds. A
  build without `ROBO_SIGN_IDENTITY` is ad hoc and macOS asks again each time.
- **Start the app with `open -n --env ROBO_AGENT_URL=http://127.0.0.1:9 X.app`** for a real microphone: launched from a
  shell, the shell is the microphone client and robo says it lost it. Dev switches: `ROBO_NO_VOICE=1`,
  `ROBO_CHAT_DEMO=1` (`DevSwitches` in `Launch.swift`).
- **ONNX Runtime**: `native/Vendor/onnxruntime-swift-package-manager` is Microsoft's bindings trimmed and pointed at the
  1.30.0 pod. Upstream's 1.24.2 changed 6 of 200 transcripts against the old Python app's 1.31; any ORT version change
  moves the encoder output ~4 %, enough to flip a transcript. 1.30 keeps the encoder weights twice (~1.4 GB footprint
  instead of ~0.8 GB), so `Parakeet.init` sets `session.disable_prepacking=1` (+15-20 ms per clip, same transcripts;
  measured with `footprint`, not `ps`, which is unreliable on a loaded Mac): drop it once a 1.31 pod exists (none was
  published on 2026-10-13).
- **ORT 1.30+ sends usage telemetry to Microsoft by default** (sockets to MSFT addresses 9-13 s after a session is
  created; none with `ORT_DISABLE_TELEMETRY=1`). `Parakeet.init` sets it before ORT starts.
- Swift traps to remember: `String ==` treats `e`+U+0301 and U+00E9 as equal and indexes grapheme clusters, so
  code-point logic uses `unicodeScalars`; many golden values came from Python, whose `round()` is half-to-even;
  `@MainActor` tests only run main-queue hops they `await`. **`JSONSerialization.data` raises an NSException no Swift can
  catch on what its own parser accepts (`-1e999` reads as -infinity on macOS 26.7): check `isValidJSONObject` first.**
  Foundation's JSON parsers also accept a trailing comma. **A release-only crash the tests missed (2026-10-20)**: a `for await`
  over a task group collecting into a captured var with a tuple holding a `Result` passed the debug build and all tests, but the
  release build lost every answer and died in `TaskGroup::offer` (SIGSEGV). Use `withTaskGroup(of:returning:)`, a plain struct and
  no nested function capturing the group.
- **First launch of a new signing identity** shows the microphone permission dialog; until it is answered the UI must
  not wait on it (`Listener.start()` must not block the main thread). `AgentService.ensure` blocks up to 30 s: it runs
  off the main thread.
