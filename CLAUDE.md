# Robo: notes for agents

Read `README.md` first (features, setup, layout table, `dev` → PR → `master` workflow). This file
holds only what the code and the README don't say. Product intent: a Desktop Goose-style pet that
lives on the screen but helps. Keep it alive (it reacts, roams, looks around) and out of the way.
Voice is input only: the user talks to it through the mic (local speech recognition) and it answers
in text. It never speaks, so don't add speech output.

Two programs: the Swift app (`native/`, the running app since 2026-10-13; the Python/Qt build and
its tests were deleted in the 2026-11-04 revamp) and its brain `robo-agent` (`agent/`, Python on the
Claude Agent SDK, which replaced Hermes Agent in the same revamp). macOS 26 is the minimum
(`Package.swift` `.macOS(.v26)`, `bundle.sh` `LSMinimumSystemVersion` 26.0): there is no pre-26 code path.

## Verify
- Swift: `native/test.sh` (not `swift test`), and `native/test.sh -c release -Xswiftc -enable-testing` for
  concurrency code. Agent: `uv run pytest -q && uv run ruff check agent tests scripts`. CI runs the Swift suite on
  `macos-26` and pytest + `ruff check agent tests scripts` on Ubuntu, on pushes to and PRs into `master`.
- UI: capture only Robo's window (`screencapture -l<id>`, id from Quartz `kCGWindowName == "Robo"`); a full-screen
  capture shows whatever else the user has open. The face: `ROBO_FACE_SHEET=<dir> native/test.sh --filter FaceSheet`
  writes `face_sheet.png` (every expression and effect, over white and dark grey). For glass over a backdrop: an
  `SCContentFilter` naming exact windows (your own opaque window plus Robo's), never a region capture: it caught a private
  notification on 2026-11-04.
- Voice: `robo voice-eval` (macOS voices → real Parakeet → name matcher). Compare a change with the score before it.
  The "Rubble was…" false positive is deliberate (`startName` in `Listen.swift`). `--record DIR` / `--wavs DIR` score
  the user's own voice (the only way to calibrate `Listen.minGate`); don't record while a call is live, the mic would
  capture other people.
- A test copy of the app, away from the live agent:
  `open -n --env ROBO_AGENT_URL=http://127.0.0.1:9 --env ROBO_NO_VOICE=1 --env ROBO_NO_WATCH=1 X.app`. With
  `ROBO_AGENT_URL` set the app starts neither its agent nor its Brave.
- **The agent service without the live setup or the network** (the pytest suite does this with fakes; this is for a
  real `robo-agent serve`): a throwaway `HOME=<dir>` holding `<dir>/.local/share/robo/agent/` (0700) with a
  `config.json` (e.g. `{"port": 8799, "approvals": "manual", "learn": false, "vault": "<dir>/vault"}`), a
  `server_key` and a dummy `api_key` (0600 each), and `ANTHROPIC_BASE_URL=http://127.0.0.1:9` in the environment
  (the SDK passes the inherited environment to its CLI), so no request reaches Anthropic. Start
  `HOME=<dir> ANTHROPIC_BASE_URL=http://127.0.0.1:9 uv run robo-agent serve` and talk to it with curl
  (`/health` needs no key; everything else `Authorization: Bearer <server_key>`), or point the app's client at it.
  `robo chat` (with `HOME=<dir>`) starts the service AND Robo's Brave with the throwaway profile
  `<dir>/.hermes/profiles/robo/brave`: kill that Brave afterwards (it listens on 9333, where the live one would).
  The first run also fetches `@playwright/mcp` with `npx`. **Slow failure, known**: with Anthropic unreachable the
  SDK's CLI retries for several minutes before the run fails with a clear "Connection refused"; the app shows only
  "thinking" until then. Don't mistake that for a hang.
- `tests/test_e2e.py` runs the real SDK and bundled CLI against a fake API with a fake `npx`: no key, no network (it skips
  if the CLI is absent; the sandbox tests are macOS only). Use it for anything about what the CLI really does with the
  options; `test_server.py` fakes the client and cannot see that. The CLI adds `system`-role and reminder messages of its
  own around the user's text.
- Agent features (digest, study plan, `robo-make`, the LMS scan) can only be checked against the live agent:
  `printf '<prompt>\n' | ~/Applications/Robo.app/Contents/MacOS/robo chat` prints the tools it used. The digest takes
  about 2 min, reads mail, Teams, Moodle and the calendar, and changes nothing there until a "yes"; `robo-make` writes
  into `~/Robo/`. Activity and plan can be run for real in a throwaway `HOME`.
- To look at a page `robo-make` wrote, serve a copy over loopback (browser tools block `file:`) and delete the
  `.playwright-mcp/` folder they leave in the repo.

## The live setup
- `~/Applications/Robo.app` runs at login through the `ai.robo` LaunchAgent. At launch the app starts robo's Brave
  (`Browser.ensure`, profile `~/.hermes/profiles/robo/brave`, kept where the Hermes build had it so the school logins
  survive) and `uv run --project <checkout> robo-agent serve` (`AgentHome.service`), where `<checkout>` is the source
  tree the app was BUILT from (`Setup.checkout` = `#filePath`). So the live agent's code, `agent/SOUL.md` and
  `agent/skills/` are that checkout's files: the persona and skills are re-read and filled from `config.json` on every
  run (`config.render_skills` into `R/runs/<run id>`, deleted after), with no install step. Build the installed app
  from the checkout you mean it to run. The chat's session id is `robo-<day>-<personaStamp>`, a hash of SOUL.md and the
  skills taken once at app launch (`Launch.swift`): after editing them, a restarted app starts a new session. **On
  `resume` the CLI keeps the session's first system prompt and ignores a new one** (seen in the requests, 2026-11-04), so
  anything that must reach every turn goes in the query text (`execute`: the memory block); the skill listing does update.
- `R` = `~/.local/share/robo/agent` holds `config.json`, the keys, `sessions.json` (robo session → SDK session,
  resumed; a lost transcript drops the mapping and the run retries once as a new session), `activity.jsonl`, `memory/`, `skills-learned/`, `learning.jsonl`, `consolidated` (the day of the last profile rewrite) and
  `claude/` (the SDK CLI's `CLAUDE_CONFIG_DIR`). The service logs to `~/Library/Logs/Robo/agent.log`.
- `config.json` is read ONCE when the service starts (`cli.main`); the keys are read again on every run or request
  (an env var `ANTHROPIC_API_KEY` / `SUPERMEMORY_API_KEY` / `ROBO_SERVER_KEY` wins over the file). After editing the
  config, restart the service: the app stops the one it started when it quits (`applicationWillTerminate`) and
  `AgentKeeper` starts a new one before the next request; a service the app did not start is left alone.
- **Approvals**: `Setup.defaultApprovals` = `"off"` (the user asked for "all permission" on 2026-10-23); only a NEW
  `config.json` gets it, `robo setup` keeps a value already there, and an unknown value is read as `"manual"`. Under
  `"off"` the harness allows every guard ask itself and no `approval.request` is sent; the blocks hold in every mode.
  Under `"manual"` an ask reaches the card as Allow/Deny with its `request_id`; no answer in 120 s (`APPROVAL_S`) is
  deny, and a denied call returns "BLOCKED: the user denied this. Do NOT retry it...". `"session"` approves only that
  exact rule key (tool + action) for the rest of the run.
- Don't run `robo setup` or `robo signin` while testing (setup rewrites `config.json`'s `robo_cmd`/`uv_path` and the
  LaunchAgent to point at the build it runs from, and refuses a bare binary), and send the live agent nothing but a
  harmless prompt if a live check is needed.

## The agent (`agent/robo_agent`)
- **Tools** (a new tool is a CLI plus a skill unless it needs what Bash's sandbox refuses: loopback, as the browser does, or R,
  as memory does; Playwright's 25 tools are about 5.3k tokens of schema per turn, measured 2026-11-05) (`harness.TOOLS`): Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch, Skill, plus the MCP servers
  `playwright` (`npx -y @playwright/mcp@0.0.83 --cdp-endpoint http://127.0.0.1:9333`, snapshots in
  `~/.local/share/robo/browser`) and `robo` (in-process: `memory_add`, `memory_search`, `memory_forget`). There is no
  `computer_use`: SOUL.md's `{{DESKTOP_APPS}}` tells it to open GUI apps with `open -a`. Every approval shows the card
  (Hermes' auto-approved "Allow computer_use" branch was removed 2026-11-04). `setting_sources=[]` and
  `strict_mcp_config`: the user's own Claude settings, CLAUDE.md files and MCP servers never reach the agent.
  `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` keeps the API key out of Bash's environment, which is why no permission mode is
  set: the tools are allowed by name and the guard's explicit "allow" answers the rest. The skills are an explicit
  `robo:<name>` list: `skills="all"` also offered the CLI's bundled ones (update-config, plugin-authoring...).
- **The boundary** (`harness.boundary`; tried against the real CLI 2026-11-04, kept in `tests/test_e2e.py`). The deny rules
  (`Read(//abs/**)`) hold even against the hook's "allow" and hide R from Grep and Glob. Alone they do not stop Bash:
  `python3 -c open(...)` and `cat ~/.he*/...` read the key; the macOS sandbox (Linux: none) stops those, `ps eww` (which
  shows the key in the CLI's environment) and writes to `AGENT`. `allowUnsandboxedCommands: false` also refuses
  `dangerouslyDisableSandbox`. No `allowLocalBinding`, so Bash reaches nothing on loopback, not through the sandbox's proxy
  either (Playwright, which needs port 9333, runs outside it). `allowedDomains: ["*"]` keeps the internet. The owner chose to keep the sandbox with its costs (2026-11-05). **Costs**: `ps`,
  `top`, dev servers, AppleScript to other apps, and `git init`/`git clone` (`.git/config` and `.git/hooks` are protected;
  `allowGitConfig` did not help; commits in an existing repository work). SOUL's `{{DESKTOP_APPS}}` tells the agent.
  `open` needs Launch Services, hence `excludedCommands: ["open:*"]` (`open:*` or `open *`, bare `open` does not match; a
  chain such as `open x; cat y` stays sandboxed). **Known hole**: what `open` starts runs outside the sandbox: an app
  written to disk read the key in a test. The guard refuses `open` of a path to code, a speed bump only (`open -a Name`
  of an app robo built still works). `disableSkillShellExecution` is real: a skill's ``!`cmd` `` never reaches the
  PreToolUse hook, so it had run with no guard. An `apiKeyHelper` also worked against the fake API but sends the key as
  both `x-api-key` and Bearer; not tried on the real API, not used.
- **robo-guard** (`guard.py`, the PreToolUse decision of every call; its docstring is the full rule list; `guard.cwd`
  follows the hook's `cwd`, since a Bash `cd` moves the CLI). A Grep or Glob with no `path` from the home folder is blocked
  on purpose (it would cover R); the message tells the agent to give one. A hook that
  raises would let the call through, so `harness.hooks.pre` turns any exception into a deny (fails closed). Blocks:
  anything in `R` or `~/.hermes` (read or write: keys, memory, Brave's school cookies), writes to the agent's own code
  and skills and to `receipts.jsonl`/`usage.jsonl`; graded work (quiz attempt URLs and labels, assignment submit,
  forum post, any click/type/key on a quiz-attempt page, raw JS on a school host, `/mod/quiz/` or `/mod/assign/` in
  Bash or browser code); remote images or active HTML in a `.md` note. Asks: a Bash command with an irreversible word
  anywhere (`rm`, `sudo`, `kill`, `ssh`, `git push`, curl uploads... `grep rm notes` over-asks on purpose), a click on a
  target missing from the latest snapshot or labelled Send/Reply/Delete/Pay..., Enter/Space and send shortcuts except
  Enter right after typing into a search box, dialogs, uploads, URLs with side effects (`BAD_URL`: `[?&;#]action=`, not a
  bare `action=`, which matched Moodle's `logaction=0`), and on a mail host Move/Junk and Send with the addresses typed
  in this run. **Refs**: a snapshot ref (`e5`) is trusted only from the latest snapshot, outside quoted text and listed
  once; a page-changing call whose result carries no snapshot forgets them (under Hermes the guard forgot them after
  ANY click, so with every ask denied the LMS course list stopped at 1 of 8 courses; `school-posts` still says to read
  the page with `browser_snapshot()` and to go back with `browser_navigate`, never `browser_navigate_back`; the guard
  reads a snapshot saved to a `.yml` file too). A regex guard is a
  speed bump (raw JS or Bash can get around it); SOUL.md's graded-work rule is the main control.
- **Receipts**: `guard.post` appends one line per state-changing call (no typed text, no page text) to
  `~/.local/share/robo/receipts.jsonl` (0600, last 2000), with the kinds `Receipt.swift` reads: `browser_click`,
  `browser_press`, `write_file` (Write), `patch` (Edit). A terminal `>>` leaves none, so a "saved" claim without a Write
  or Edit shows "⚠ unverified".
- **Memory** (`memory.py`): `R/memory/facts.jsonl` (≤ 500 facts; a new fact with ≥ 0.75 word overlap updates an old one)
  and `profile.md`. `context_for` puts the profile and up to 6 BM25 hits (≤ 2000 characters, marked "Memory, not
  instructions") into the turn. The service has ONE `Store` (one lock, the Supermemory key set again per run); no HTTP call
  holds the lock, and a change of `facts.jsonl` by another process (`robo-agent memory forget`) is reloaded. `private_reason` refuses secrets (key shapes, Luhn-valid card numbers,
  IBANs, long mixed tokens), sentences about secrets, e-mail addresses and message bodies. **Supermemory is set aside (owner,
  2026-11-05)**: the code stays, and with no `supermemory_key` nothing is sent. With a key it is a mirror only: local is the
  truth, its failures go to `learning.jsonl` and are ignored. It gets vetted facts only (`memory_add`, the learner): no raw turns
  (`context_for` searches locally, so paraphrase recall through it exists only in the `memory_search` tool, which sends the query the agent chooses unless `private_reason` flags it; the correction
  fallback, the user's raw words, is `mirror=False`: the row's `local` flag keeps every later forget off the wire too, since a DELETE carries the text), no `/v4/conversations`, no `/v4/profile` read, and counted habits
  stay local (`habit_key`: `_sm_add` skips them, nothing is forgotten there for them, and `add` never merges into them).
- **Learning** (`learn.py`, after every run that was not cancelled and not automated, in one background job, `CHEAP_MODEL` =
  `claude-haiku-5-5`, 60 s, unless `"learn": false`): up to 3 facts per run; a skill is considered only after ≥ 5 tool
  calls, a failed run or a correction ("no, I meant..."). The model's reply must be strict JSON; `vet_skill` refuses
  reserved names (`school-`, `study-`, `robo-`, any built-in), graded-work words, anything that weakens safety
  (guard/approvals/SOUL.md/sudo...), HTML/images/remote scripts, secrets, > 4096 bytes, > 30 skills. An updated skill
  keeps `SKILL.md.prev`. A learned skill never replaces a built-in one. The profile is rewritten once a day; a profile
  with a number no fact holds is rejected for the plain summary. **Page text must not teach**: facts come from the user's
  words only, the skill step reads `harness.trace_line` (allow-listed arguments, clipped, private text `[redacted]`), not
  the reply; automated runs are skipped by session (`robo-posts-`, `robo-eval-`) or by the exact `DIGEST_PROMPT` (pinned to
  `Window.swift`). Rewriting an existing skill takes a second call that shows its body; a rename is refused. There is
  deliberately no in-run `skill_save` or `session_search` as in Hermes: with approvals off, a tool that writes
  skills during a run is an injection path. **Habits**: `R/activity.jsonl` (0600, last 2000, no text; the facts call also
  names a coarse `type`), and `learn.daily` turns 28 days of it into counted `habit` facts (`habit_key`, source
  `activity`): a time of day on ≥ 5 distinct days, a weekday and time on ≥ 3, each ≥ half of the active days. A pattern
  that stops loses its fact; one the user forgets is muted (`memory/habits-muted.json`).

## Constraints (checked 2026-10-12; recheck if ONNX Runtime or Parakeet change)
- **Speech model on the CPU only** (`Parakeet`, `CPUExecutionProvider`). On a Mac the CoreML provider loaded 3× slower,
  ran 2× slower and transcribed differently (fp16) from the CPU output the name matcher was tuned on.
- **The app does not download the speech model**: it reads the Hugging Face cache
  (`~/.cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v2-onnx`, `refs/main` → snapshot with
  `encoder-model.int8.onnx`, `decoder_joint-model.int8.onnx`, `vocab.txt`), fetched once by the retired Python app.
  `Parakeet.cachedModel`'s error gives the `uvx` command that fetches it.
- **Audio is levelled before Parakeet** (`leveled`, peak 0.5, boost capped at 20×): the model reads soft speech worse
  (synthetic voice at 0.15× volume: 44 → 48 of 50 names caught).
- **English only (owner, 2026-11-05)**: Parakeet v2 hears only English, and `Intent` reads only English, so spoken text in another
  language is refused without the key. The guard's and the learner's Vietnamese words stay: they read pages and typed text.
- **Don't end a request on a "?".** Parakeet punctuates a clause cut off mid-question as a question (36 of 40 probes,
  4 TTS voices), so an early send would pass half a request to an agent that has every permission. The README promises
  that a pause to think does not end the request.
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
- **Key-less follow-up window (reworked 2026-10-19, refusal reworked 2026-11-04)**: `RoboWindow.followUpS` = 15 s, armed in
  `finishedTyping()` (not at run end: typing at 55 cps and reading used to eat the old 10 s; `followDue` is set in
  `ended()` and cleared by `clearReply()`/`closeBubble()`, which also send `ear.followUp(0)`, so errors, `say()` lines,
  mic notes and a new question never arm or keep it). The MIC light pulses LISTENING while it is open. In `Listener` a
  window with `asked == false` delivers only a transcript of two words or more (`heard`): the first version woke robo
  after `minSpeechFrames` loud frames, and a noise in the room cleared the reply being read within seconds of a live
  reply (found 2026-10-19 on the live app). The listener never wakes robo for such text; `handsFree` travels with it (`onText(text, handsFree)`) and `onHeard`
  decides. **`Intent.changesThings` is an allow-list**: only a clearly read-only sentence (a question, "show/read/
  find/explain...", thanks, "close the chat") is false; any write verb, any other order, a bare "yes"/"ok"/"go ahead"
  (the digest proposes and waits for a yes) and whatever it cannot read are true. A true one is refused WITHOUT waking:
  the reply stays, the note "Hold Ctrl+Q and say that again: without the key I only answer questions." goes beside it
  (a chat line, or the card's "heard" line), and the window reopens for the time it had left. Only an accepted sentence
  wakes robo (which stops a run and clears the last reply). A held key or a click is never filtered. Spoken text is
  never an approval (it stops the run, which denies). TV or another voice can still fill the window with a read-only
  request.
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
  marks closed and the last word hidden, so a half-typed `**` or `-` never flashes. The pace follows the agent (it never
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
  everything is neutral ink. Only a warning (orange, the approval's well and the amber light) or a failure (red) has a
  colour. Links are the text's ink, underlined. Increase Contrast raises the veil and the text alpha
  (`Chrome.increaseContrast`). Only `Themes.glass` exists; `theme.json` keeps `face_bg, cps, text_px, line_h, caret,
  caret_ms, bot_name` and ignores the rest. The card fades in over 0.18 s
  (`RoboWindow.fadeIn`, not with Reduce Motion); closing is instant on purpose. The typing tick (`CardView.setReply`, 1000
  characters) is 0.7 ms on average; caching fonts or the Markdown look was tried and dropped. Typing is ~2 % of a core at
  30 Hz; don't optimise it further without a new measurement. The header lights show only when something is wrong
  (`Led.shows`: warn, bad) or while listening in the follow-up window: "Agent …", "Agent problem", "Mic problem", "Listening"
  (`Health.swift` polls `<agent>/health`, no key: one miss amber, two red; the mic is `Listener.ready`). There is no model chip.
- **Backdrop-adaptive card (2026-10-19, user request: "black area -> white chat, white area -> dark chat, smooth", and "the
  colour of the words has to contrast with the area it is in")**: `Backdrop` (ScreenCaptureKit `SCScreenshotManager`,
  display minus Robo's own app, 16 px picture of the glass rectangle, `Shade.meanLuma`) is asked about every 0.25 s while
  the card shows; `Shade` (pure, RoboCore) decides: luma < 0.42 -> light card, > 0.58 -> dark, between keeps the last
  (hysteresis), eases with tau 0.12 s, `ink` = smoothstep(0.35, 0.65, level) so the text flips fast instead of fading
  through a grey. `Chrome.text/textDim/faint/hairline/wash` read `Chrome.ink` (nil = the system colours, used until a look
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
- **Chat window (2026-10-23, user request: a bigger, detached, bubble-style, adaptive Liquid Glass chat so the agent need
  not write a note for long answers; polished 2026-11-04)**. `ChatPanel`/`ChatView` (`ChatPanel.swift`),
  `BubbleView`/`BubbleText` (`Bubbles.swift`), the window side in `Chat.swift`, the conversation in RoboCore `Transcript`
  (memory only, one per agent session id: `reset(for:)` on a new day or persona; 200 turns). Decisions (the user's): a
  window of its own, **fixed 520x640 (`ChatPanel.contentSize`), centred on the main display** each time it opens, opens
  on `ask()` (typed, spoken, the menu's digest). The automatic digest goes on the pet's card and into the conversation
  (`chatBegin(show:)`), with no Screen Recording dialog; if the chat is already open it stays there. It closes by its close
  button (`ChatView.close`, answers the first click), `Intent.closesChat` ("close the chat", whole sentence, spoken or
  typed; "close the Moodle tab" still goes to the agent), or Esc while its text box has the keyboard (`ChatPanel.onEscape`;
  the panel is non-activating, so Esc in another app never reaches it). No timer; a face click does not close it; English only. **All typing goes to the chat** (the separate Type panel
  was removed 2026-11-04): the menu's Type, or a face click while voice input is off, calls `typeText()` =
  `openChat(focusInput: true)`. The text box grows to `ChatPanel.inputLines` = 5 lines, Return sends, Shift+Return is a
  new line, Send is disabled while the box is empty; there is an empty state, a "jump to latest" button while scrolled
  up, Copy on robo's bubbles (the Markdown as written), no bubble tails, a bubble as wide as its text (`BubbleText.spansBox`: code, rules, tables and centred formulas keep the
  column), and `setLive` is throttled like the card's
  reply. A finished reply is announced to VoiceOver (`Chat.swift`, `.announcementRequested`). The pet's card keeps what
  is quick (menu, "Listening", Allow/Deny, nudges, the automatic digest); `say()` notices become robo bubbles while the chat is open
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
  `becomesKeyOnlyIfNeeded`; a click on its text box takes the keyboard (`EditKeys`, handback through `Focus`),
  `nudgeHeld` waits while that is so. A test copy launched from a scratch path made macOS ask "bypass the system private
  window picker" for Screen Recording: do not click it for the user; test through the INSTALLED app
  (`open -n ~/Applications/Robo.app --env HOME=<throwaway> ...`, `ROBO_CHAT_DEMO=1` opens it with a made-up
  conversation), which has the grant. **Not verified**: Spaces/full-screen, dragging, the capture cost over time.
  Agent side: SOUL.md "Drafts, plans and text" and the skills say answer in the chat, write a file only on request;
  pinned in both template suites (`answersStayInTheChatAndAFileIsWrittenOnlyOnRequest`).
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
  `*.bundle` of the build there; without it the first formula is a `fatalError`.** SOUL.md tells the agent to write
  `$..$`/`$$..$$` and to fence code (an unfenced Python example once rendered `*` as emphasis). **Test trap**: the
  pointer. A card stays open while the pointer is over it, and synthetic clicks leave it over the chat's place, so
  `theCardKeepsAnUnansweredNudgeForAMinuteThenClosesIt` and `everyOtherWayTheCardEndsIsDismissedNeverMuted(.timeout)`
  failed on a clean checkout until the pointer was warped to a corner (`CGWarpMouseCursorPosition`). **Verified live
  under Hermes (2026-10-23)**: a long math answer typeset in the chat, a typed follow-up through the real text box, the
  typed "close the chat". **Not verified**: a formula in a table cell; any of it with robo-agent.
- **Tables, scroller, VoiceOver menu**. `Markdown.tableLayouts`: a column is never narrower than its longest word, the prose
  columns give up the room, and if the longest words alone do not fit, cells go down to `tableMinPx` = 11; the grid is
  `Chrome.hairline`. `TextBox` uses the system's scroller at `.small`, and the text is `TextBox.scrollerRoom` narrower while
  it shows: an overlay scroller's track otherwise hides the end of each line (overlay knobs were still visible in captures
  6 s after opening, in this non-activating panel). The face answers VoiceOver's "show menu"
  (`accessibilityPerformShowMenu` = right click). Chips and buttons have plain labels; the chips use SF Symbols, not emoji.
  There is deliberately no global key for the menu: it would take a shortcut from every other app.
- **Downloads through robo's Brave (2026-10-24, user: "I will tell it which folder")**. `Browser.allowDownloads` writes
  `download.default_directory` = `~/Robo/Downloads`, `prompt_for_download` false and
  `plugins.always_open_pdf_externally` into the profile's `Default/Preferences` before every start robo makes (Brave
  rewrites that file on exit, so editing a running Brave does nothing). `Browser.setDownloadBehavior` over CDP was no
  answer: it ends with the connection that set it. SOUL.md tells the agent to download with the browser (curl gets the
  Microsoft sign-in page) and `mv` the file to the folder the user names; the folder is outside `~/.hermes` because the
  guard blocks every path there. Verified live under Hermes with a public PDF. **Not verified with robo-agent**: whether
  a download made through Playwright MCP over CDP lands in that folder (Playwright may handle downloads itself).
- **Approvals, receipts, usage (2026-10-19)**: the app sends each answer with the ask's `request_id` and queues parallel
  asks (oldest shown, "+N more"); the automatic digest denies every ask at once; links in a reply ask first
  (`confirmLink`, an `NSAlert` with the full URL) and images are never fetched; Allow/Deny are reachable by keyboard
  (Tab between them). The app shows "✓ sent · host" or "⚠ unverified" under a reply from the receipts (`Receipt`) and logs
  tokens to `~/.local/share/robo/usage.jsonl` (`harness.usage_of` names them as `Brain.swift` reads them; total counts
  cache reads and writes). Optional cap: `ROBO_DAILY_TOKENS`, else the number in `~/.local/share/robo/daily_tokens` (the
  file survives `robo setup`, which writes the login item without any environment). It was REMOVED on 2026-10-22 at the
  user's request ("just let it use freely": a day had used 7.2M and Robo was refusing requests); `Usage.cap` still honours
  one if it comes back, and the cap stops chat too. Costs measured under Hermes (not re-measured with robo-agent): a
  chat turn ~95k, the LMS course list ~290k, one course scan ~340k (10 calls) after the skill's thrift rule, a normal day
  1.8-2.3M. No usage is reported for failed or cancelled runs.
- **Learning engine (2026-10-19)**: `study-quiz` skill (confidence 1-5 before the answer, citation, <= 5 questions), review
  state in a `## Reviews` section of `study.md` (boxes 1/3/7/14/30 d), one combined `Review:` task for `robo plan`,
  readiness in the digest; SOUL.md "Learning first" (hints before answers, graded work is never done for the student).
- **LMS posts scan (built 2026-10-20; the scan ran live under Hermes 2026-10-20 to 22)**: deadlines live in Moodle posts,
  not the calendar. `agent/skills/school/school-posts` has two modes picked by the request's first line: `MODE: list`
  (courses as a JSON array) and `MODE: scan` + `COURSE` / `SINCE` (a day) / `TODAY` (one fenced JSON array of `{course,
  post_url, posted, title, due, kind, quote}`; `due` is `YYYY-MM-DDTHH:MM`, `YYYY-MM-DD` (read as 23:59 that day) or
  `null` (dropped: no place in an agenda); `kind` deadline/exam/event/material). Pure half `RoboCore/LMSPosts.swift`
  (prompts, the strict decoder, `next` = the day's plan), `RoboSystem`: `LMSState` / `lms.json` in `NudgeFiles`, window
  half `RoboUI/Scout.swift`. **OFF until `config.json` has `moodle_url`** (`Setup.postsMoodle`; `robo setup --moodle URL`) and while the Nudges chip is off. **Daily, no backfill (the user's choice)**: from the first tick after 07:00 local, one step at a time: the course
  list (again after 7 days), then one run per course since its last good scan (a never-scanned course reads back
  `firstLookbackDays` = 1). Each run has its own session `robo-posts-<id>` (post text of one course must not reach the
  next run's context), every `approval.request` is denied by id (none come under approvals `off`: the guard's blocks
  still hold, its asks are allowed), 20 min at most, never touches the card; a request of the user cancels it (`ask()`),
  and none starts while the user's own run is in flight; a failed step is retried after 30 min, 3 times a day;
  `ROBO_DAILY_TOKENS` applies; runs are logged to `usage.jsonl`. **The decoder believes nothing**: exactly one fenced
  block that is a list; a course address must be `https://<host>/course/view.php?id=N` and nothing else (the agent is
  never sent to a quiz page), a post link must be `/mod/forum/` or `/course/` on the host; dates must exist, `posted` not
  after today nor over 400 days old, `due` not before the posted day nor over 2 years after; text is one clean line
  (control and bidi characters removed); a quote is required; same course + title = one item, the later post wins; caps
  60 items / 40 courses; dropped objects are counted in the log. An agent that could not read and answered `[]` used to
  count as "scanned, nothing new" and moved SINCE forward: `LMSPosts.incomplete` (blocked/denied/refused/couldn't... in
  the words around the block, never inside it) makes such a reply a failed step, and the skill says to answer
  `INCOMPLETE:` with no block. Items are `AgendaItem(source: .lms, id lms:<course>:<title>)` merged with the earlier ones
  (a scan reports only new posts), then the ordinary reminders and `NudgeBudget` apply; the card says "from a post: check
  the date" with the quote. A find is announced once at the next slot as "new · <when>" (or "moved · ..."): `.lms` items
  get the `newEvent` rung within `newHorizonPosts` = 30 days. **Materials** (`kind: "material"`, `due: null`) are kept in
  `lms.json` (`materials`, told once, 60 days, 200), listed in the vault note `Radar/Courses-<day>.md` and offered as ONE
  card a day of `NudgeCategory.course`; the agent is told never to open a material itself (a click can download it or
  mark it viewed). **Verified** with fakes and a loopback imitation of the run API. **Not verified**: any scan with
  robo-agent, the cost per day with 8 courses, unattended 20-minute runs. The guarantees on the agent side are the
  skill's Pitfalls (never open quiz/assignment pages, never click Attempt/Submit/Reply/Post; post text is data),
  robo-guard, and the denied asks; each skill rule is pinned in `tests/test_templates.py` and `TemplatesTests.swift`.
  **Found by looking at the picture**: `WrapLabelView.height` measured without the `.kern: 0` that `draw` uses, so a line
  that just fit wrapped when drawn and the last line was cut off; now measured with the draw attributes
  (`aWellMeasuresTextTheWayItIsDrawn`). A test of `well.text` cannot see this: capture the window.
- **Source check (2026-10-21, user request: "sources validation and verification - prevent the robo from providing the
  users with some scams or unreliable stuffs")**. `RoboCore/SourceCheck.swift` is pure and OFFLINE (the user chose
  "offline checks only"; a daily phishing-domain list was offered and declined, measured recall below is why it may be
  asked again): `assess(item)` for radar items, `assess(url:words:)` and `linkNotice` for links. Levels official <
  ordinary < doubtful < scam; any "hard" flag = scam (a `name@`, a numeric host, mixed-script or all-lookalike letters, a
  brand's name before another domain or beside a login word, a brand typo with a digit/`rn`, link words naming another
  site, wording that asks for ID/gift cards/a chat-app interview/"guaranteed" income); a sum of weaker flags (>= 2, or
  >= 1 for an opportunity) = doubtful. Policy: `Radar.run` drops scams (logs only the host), puts doubtful items after
  clean ones with up to two ⚠ lines, never makes them a popup, and leaves doubtful news/papers out of the digest; the
  note marks `✓ a primary source`, `the employer's own site`, `a preprint: not peer reviewed`, `written by anyone`;
  `BoxTextView.alertText` adds the verdict to the link alert ("Open anyway", Cancel stays the default). The wording rules
  run only for opportunities (a news headline about gift-card scams must not hide), and a denial in the same sentence
  ("we will never ask for your passport", "no application fee") cancels a match. **Real data found what hand-made cases
  did not**, so after ANY rule or list change re-run it: a throwaway test that reads `Feeds.simplify(listings.json)` (the
  2,000+ real internship postings from the SimplifyJobs file the radar already downloads), the Tranco top list, Hacker
  News story links and the OpenPhish feed (download them into a scratch folder; they are strings to parse, never visit).
  First version: 11 real NVIDIA/Adobe postings hidden as "scams" (a company name before `myworkdayjobs.com` is how those
  boards work: brand-in-subdomain is skipped on `boards`), 13.5% of internships doubtful (Oracle/Taleo hosts missing from
  `boards`; the company's own domain in forms like `datadoghq.com`, `itw.com`, `towerresearch` now matches in
  `nameMatches`), and ~40 brand-owned domains (`google.org`, `microsoft.net`) doubtful (a brand's name alone on another
  domain is only weight 1). Final (2026-10-21, after two review rounds with a red team of ~600 scam shapes and a hunter of
  ~1,000 legitimate inputs): 0 of 20,000 popular domains hidden (40 doubtful, mostly shorteners and form sites on
  purpose), 0 of 296 Hacker News links hidden (1 doubtful), 0 of 2,000 real postings hidden (11 doubtful), **236 of 300
  live phishing URLs flagged (235 doubtful, 1 hidden)** and 76 of 2,000 URLhaus malware hosts doubtful: offline shape
  checks cannot condemn a random page on free hosting, so this is a guard against impersonation and offer scams, not a
  phishing filter. Lists (`primary`, `boards`, `brands` with their owners, `hosting`, `shorteners`, `offPlatform`) are
  dated `SourceCheck.verified`; add a real brand domain to its `owned` set when a legitimate site is flagged. The agent's
  side is `agent/SOUL.md` "Sources and scams" (pinned in `tests/test_templates.py` and `TemplatesTests.swift`). **Known
  limits**: a plain Telegram/WhatsApp/form/free-hosting link is only a hint; a brand-new innocent-looking domain, scams in
  other languages, and a company name taken from the feed (it never vouches; a match is only a note) pass; the
  micro-sign homograph `µtorrent.com` is hidden as a look-alike. The main safeguards were mutation-checked on 2026-10-21
  (about 30 mutants; each failed a test). **Not verified**: a live radar run and the alert on the installed app, a real
  scam link in a reply, whether the agent follows the SOUL rules. The 8 tests needing a key window
  (`EditKeyTests`, `KeyboardHandoffTests`, `theTextBoxTakesFocusAcceptsTypingAndSendsIt`) fail while the screen is locked;
  unlock the Mac before trusting them.
- **Reminder ladder (`Reminders`, 2026-10-21)**: deadline T-5 d (`days5`, added at the user's request), T-1 d, T-3 h; exam
  T-7 d, T-1 d, T-3 h; meeting T-30 min; opportunity T-3 d, T-1 d. The tightest due rung stands for the looser ones, so a
  deadline first seen with 4 days left gets ONE `days5` card; the card still says "new"/"moved" then, because
  `Nudges.candidate` asks whether the reminder `covered` the `newEvent` key (not whether its rung is `newEvent`), except
  in the last hours (`urgent`).
- **Nudges (2026-10-20)**: robo shows what is coming up on its card, labelled "Heads-up" or "Worth a look"; the note is
  neutral with a bold first line (`WrapLabelView.Kind.note`). Pure parts in RoboCore (`ICS`, `Agenda`, `Reminders`,
  `NudgeBudget`), `RoboSystem/CalendarLinks.swift` + `NudgeFiles.swift`, the window's side in `RoboUI/Nudges.swift`,
  `NudgeView` in `Card.swift`. Sources: calendar links (Outlook "publish", Moodle export) fetched off the main thread
  every 45 min, at launch and after a wake, and the Exams of `study.md`. Rules: normal nudges only at the 09:00 / 13:00 /
  19:00 slots, 3 a day, nothing 22:00-08:00, everything due at that moment is ONE card; the last 3 h of a deadline and the
  30 min before a meeting show at once (4 a day); Later = next slot but never past 15 min before the thing itself (min 5
  min from the press; found live: a 10:42 meeting snoozed to 13:00 was lost), Not for me = 30 days (3 in a row mutes the
  category); a `snooze nudges until D` line in the ledger's Notes holds all of it until D; the menu's Nudges chip
  turns it off. **State is `agenda.json`, `nudges.json`, `reminders.json` in `~/.local/share/robo` (0600, atomic
  writes)**, not in `<checkout>/data/robo_state.json` (the digest date). Time is `machine.wall` (the monotonic `clock`
  stops while the Mac sleeps, a deadline does not). A nudge waits for a free card: it never breaks in on a reply or its
  typing, a run, listening, an approval, the follow-up window, the chat's text box having the keyboard or a mouse press,
  or when the Mac is locked or idle over 5 min (`Machine.userAway`). Every end of the card without a button (Esc, a click
  on the face, the 60 s timeout, speaking, a new request) is "dismissed", which mutes nothing. It never calls the pet to
  a corner and never raises the Screen Recording dialog (`open(askScreen: false)`). The first import of a calendar marks
  every event as announced (`reminders.json` `imported`), or the coming week would all be "new". A failed fetch keeps the
  last good agenda and logs one line without the link. **The links are secrets**, kept in `calendars.json`
  (`{"label": "https://..."}`, 0600, atomic writes, folder 0700) of `~/.local/share/robo` (`FileSecretStore`; a missing or
  corrupt file reads as empty): `robo calendar add URL [--label NAME]`, `list` (scheme and host only), `remove LABEL`,
  `check` (fetch + parse once, prints counts and the next 5 titles, never the link). **Not the Keychain (tried
  2026-10-20, live)**: its partition list pins the item to the cdhash of the build that ran `add`, so each rebuild asked
  for the login password and the background fetch hung on that dialog. Nothing prints, logs or errors with the link or
  its query; the fetcher takes https (`webcal://` is read as https; plain http only for localhost, for demos), refuses a
  redirect to anything else, 20 s, 4 MB, ETag kept in memory. A link given on the command line stays in the shell's
  history. **While a nudge card is up the pet is frozen like under a mouse press** (`RoboWindow.roam()`: `engaged: press
  != nil || !nudge.shown.isEmpty`): the card is attached to the pet, and live the buttons drifted 1200 px in a minute;
  `aNudgeDoesNotSendThePetToACornerButAReplyDoes` watches 65 s and fails without it. **Dev switches**:
  `ROBO_WALL_OFFSET=<seconds, may be negative>` shifts `Machine.wall` (it also shifts the "files made since" and the usage
  day), and `ROBO_NUDGE_PRESENT=1` makes `Machine.userAway` always false: test copies only. A test copy shares
  `~/.local/share/robo`, so delete its `agenda.json`, `nudges.json` and `reminders.json` (and `calendars.json` if it added
  a link) afterwards. **Verified live** (2026-10-20, installed app + a loopback ICS server): `calendar add/check`, the
  fetch at launch, the merged card, the card holding still, Later and Not for me, the 0600/0700 files. **Live-test
  trap**: a card stays open while the pointer is over it, and a synthetic click leaves the pointer where it clicked, so
  the next card never closed and every nudge was held; move the pointer away (`CGWarpMouseCursorPosition`). **Not
  verified**: a real Outlook link (a tenant may block publishing), `userAway` on a locked screen, the wake path.
- **Radar (2026-10-20)**: once a day robo finds papers, news, internships/programmes and hackathons/contests for the
  profile and offers them through the nudge machinery above (no AI, no agent run, nothing from the web reaches the
  agent). Pure parts in RoboCore (`Radar` = `RadarItem`, `FeedParsers` = `Feeds`/`Programmes`, `Rank`, `Profile`),
  downloads in `RoboSystem/RadarFetcher.swift`, the window's side in `RoboUI/Radar.swift`. **When**:
  `RoboWindow.nudgeTick` (every 30 s of wall time) calls `radarTick`: a run starts at the first tick after 07:00 local
  when `radar.json`'s `day` is not today and `Radar/<today>.md` does not exist (so also at launch later in the day, and
  after a wake); off the main thread, one at a time; `NudgeState.enabled == false` runs nothing. **No network** (every
  source failed with a transient error): the day is not marked done and the run is tried again after 30 min; HTTP
  errors are an answer (day done). **Files**: vault `Radar/Profile.md` (made from `Profile.template()` when missing,
  linked into place so an existing note is never overwritten; ONE `radar-setup` card then; nothing is fetched while
  `interests` is empty), vault `Radar/YYYY-MM-DD.md` (Papers / News / Opportunities / Contests; every title and address
  is `Plain` text escaped again in `RadarNote.escape/target`, a bare `https://` in a title is broken with `\://`, so no
  title can be a link, a tag, a comment or a block; no remote image or HTML), and in `~/.local/share/robo`: `radar.json`
  (`day`, `seen` kept 60 days, `offers`; offers go stale at the next midnight, the setup one after 7 days) and
  `radar-cache/` (`<sha256 of the URL>.body|.json`, 0600, never the URL; dropped after 30 days unused). **Offers** go into
  the SAME candidate list as the calendar reminders: the digest (`.digest`, "N to read, M to look into"; Open opens the
  note through `machine.openNote`, path checked by `Radar.noteURL`), the best matching upcoming contest (`.contest`), a
  matching internship whose deadline is within 72 h (`.opportunity`). **Sources and allowlist**: https only, hosts
  `rss.arxiv.org` (`/atom/cs.CV+cs.RO`), `huggingface.co`, `hacker-news.firebaseio.com` (top 30, 6 requests at a time,
  15 s for all), `ctftime.org`, `codeforces.com`, `raw.githubusercontent.com` (SimplifyJobs `Summer<Y>-Internships`, Y =
  next year from August on; the file was 12.8 MB), the three ATS APIs for the profile's `companies`, `api.github.com`
  (new repositories of the last week, `stars:>10`, 3 searches; `github: none` = off), the seven blogs of
  `RadarHosts.announcements` (OpenAI, DeepMind, Hugging Face, Google Research, NVIDIA, BAIR, Microsoft Research; MBZUAI
  answers bots with 403 and Anthropic has no feed), plus the hosts of the profile's `feeds` (https, a named host: no IP,
  localhost, `.local`); exact host match, a redirect to another host or to http is refused. `RadarFetcher`: 20 s, caps
  4 MB / arXiv 8 MB / SimplifyJobs 24 MB, User-Agent `Robo/1.0 (personal study assistant)` (CTFtime refuses the default),
  gap per host 1 s (arXiv 3 s, HN 0.25 s), an HTTP error/too big backs the URL off for 20 h (a timeout or lost network does
  not). LinkedIn, Indeed, Handshake, Wellfound, Devpost and Glassdoor are deliberately not touched. **Privacy**: a source
  learns the Mac's IP and which category, company or feed is watched, never the profile text, EXCEPT GitHub, whose search
  URL carries the query words (cleaned to letters, digits, spaces, hyphens so a word cannot add a `user:` qualifier).
  **What is shown (2026-10-23, user: "stop showing non-matching items")**: the digest takes only items matching a WHOLE
  interest; an internship that matches none is not listed; programmes and contests are picked by goals. Up to 3 papers,
  2 announcements (last 14 days), 1 news, 2 repositories. BAIR's feed links with `http://` (`Feeds.news(kind:
  .announcement)` upgrades it, a user's own feed stays strict). Robo never applies, signs in, pays or sends anything. **Dev
  switch** `ROBO_RADAR_NOW=1`: the first run after launch ignores the once-a-day and 07:00 rules; it reads and writes the
  vault's `Radar/` and downloads, so use it with a throwaway `HOME` (the app exits without a server key there unless
  `ROBO_AGENT_URL` is set); delete the test copy's `radar.json` and `radar-cache/` afterwards (it shares
  `~/.local/share/robo`). `Rig(radar: true)` turns the radar on in tests; `RadarFakes` is the fake downloader. **A
  release-only crash the tests missed (2026-10-20)**: the first `gather` collected `for await` results into a captured var
  with a tuple holding a `Result`; the debug build and all tests passed, but the release build lost every answer and
  died in `TaskGroup::offer` about 14 s after launch (SIGSEGV). Both task groups now use `withTaskGroup(of:returning:)`, a
  plain struct and no nested function capturing the group. **Run the tests in release too for concurrency code**, and
  look at a real run of the installed app. **Not verified**: the real Obsidian opening, that Obsidian's reading view
  leaves `\[`/`\://` unlinked, the Lever board.
- **Notes**: drafts, plans and text are Obsidian-flavoured Markdown in `~/Documents/Robo/{Drafts,Plans,Notes}`, written by
  the agent through the `robo-notes` skill (`{{VAULT}}` is `config.json`'s `vault`) and opened by the app with
  `obsidian://open?path=...`. `obsidian.json` (Obsidian's vault list) is only edited while Obsidian is closed.
  `~/Documents/Robo/Brain/` is the user's second brain (built 2026-10-20 at their request: `Home.md`, `Courses/`,
  `Reading/`, `Projects/`, `Career/`, `Inbox/`, `Templates/`); the app never writes there. The skill `robo-brain` files
  into it ONLY on an explicit request ("save this to my brain"): new notes never overwrite (` 2` suffix), an existing note
  is appended to with Edit (so a receipt backs the "saved" claim), no file in `Brain/` is moved or deleted, the sections
  that are the user's own thinking stay empty, no answers to graded work. `Vault.opened` (= `Vault.folders` + `Brain`) is
  what `RoboWindow.made` scans to open a note written during a run; `Vault.folders` is what `Vault.ensure` makes. Rules are
  pinned in `tests/test_templates.py` and `TemplatesTests.swift`.
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
  shell, the shell is the microphone client and robo says it lost it. Dev switches: `ROBO_NO_VOICE=1`, `ROBO_NO_WATCH=1`,
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
  catch on what its own parser accepts (`1e999` reads as infinity): check `isValidJSONObject` first** (`Vault.register`).
  Foundation's JSON parsers also accept a trailing comma. `robo plan` works on instants, so a clock change counts real time.
- **Skills call `{{ROBO}} plan|activity`** (`study-plan`, `study-ledger`): `{{ROBO}}` is `config.json`'s
  `robo_cmd`, the app executable `robo setup` was run from. `Setup.checkout` and `RoboApp.dataDir` come from `#filePath`
  of the build, so build from this checkout.
- **First launch of a new signing identity** shows the microphone permission dialog; until it is answered the UI must
  not wait on it (`Listener.start()` must not block the main thread). `AgentService.ensure` blocks up to 30 s: it runs
  off the main thread.
