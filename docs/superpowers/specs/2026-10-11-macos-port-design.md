# Robo on macOS: design

Date: 2026-10-11. Status: approved in chat (approach A, parts 1 and 2), and this file is waiting for review.

## Goal

The user wants to deploy robo from GitHub on their Mac. Done means:

1. **Same features:** robo runs on macOS with the floating face, voice, browsing, making and opening files, activity watching, the daily digest and starting at login.
2. **Mac setup:** the README has a macOS section that works when followed step by step.
3. **Linux unchanged:** the existing Linux code paths and their tests stay as they are.
4. **Tested on a real Mac:** the test suite passes on real macOS in GitHub Actions before the user tries it.

Windows is a later, separate step, and the README marks it as coming.

## Approach

**A: Mac code beside the Linux code**, chosen by `sys.platform`. Each Linux-only piece is already an injectable function: the activity readers, the `WakeWatcher` source and `setup.desktop()`. So each gets a macOS twin in the same module, with no new package and no changes to the Linux code paths.

Approach B was rejected: a `robo/platform/` package per OS would mean more files and more indirection, and it would move Linux code that already works.

## Changes

All Mac paths that home-relative code uses stay the same as on Linux: `~/.hermes`, `~/.local/share/robo`, `~/Robo` and `/tmp/robo-plan`. Hermes uses `~/.hermes` on macOS too (`hermes_constants._get_platform_default_hermes_home`). So the skills and robo-guard don't change.

| Where | macOS behaviour |
|---|---|
| `cli.window` | Set `QT_QPA_PLATFORM="xcb;wayland"` only on Linux. XQuartz sets `DISPLAY` on a Mac, and Qt for macOS has no xcb plugin, so robo would abort. `floating` is true for the `xcb` and `cocoa` platforms. |
| `app.RoboWindow` | Floating mode also sets `WA_MacAlwaysShowToolWindow`. Without it, macOS hides Tool windows whenever robo is not the active app. |
| `app.open_file` | `open <path>` on macOS, `xdg-open` elsewhere. |
| `browser.BINARY` | On macOS: `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`, unless `brave` is on PATH. |
| `browser.pids` | When `/proc` is missing (macOS), parse `ps -axww -o pid=,args=`, using the same exact `--user-data-dir=` token match. |
| `activity` focus | `front_window(windows)`, a pure function: the first on-screen window at layer 0 in Quartz's front-to-back list. It gives `(kCGWindowOwnerName, kCGWindowName or "")`. Robo's own window is at a higher level (`WindowStaysOnTopHint`), so it is skipped. The title is filled only after the user grants Screen Recording. The Quartz call is a thin, lazily imported wrapper. |
| `activity` idle | `CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType)`. |
| `activity` lock | `CGSessionCopyCurrentDictionary().get("CGSSessionScreenIsLocked")`. |
| `activity` sites | History is read from `~/Library/Application Support/BraveSoftware/Brave-Browser/Default/History`. The private copy, host-only SQL and immediate delete stay as on Linux. |
| `activity` files | `mdfind -onlyin ~ 'kMDItemLastUsedDate > $time.iso(since) && kMDItemLastUsedDate <= $time.iso(now)'`, with a parser for its output. It returns `[]` on any error (for example, Spotlight off). |
| `activity` status | On macOS, `extension_status()` returns "on" when `CGPreflightScreenCaptureAccess()` is true. Otherwise it returns "titles need Screen Recording". |
| `wake` | `ClockGap`, a new `SleepSource`. `recv(timeout)` waits `timeout`. If `time.time()` advanced more than `time.monotonic()` by over `GAP_S = 60`, it returns `False` (resumed); otherwise it returns `None`. `time.monotonic()` stops during suspend on macOS and Linux, and wall time does not. `WakeWatcher`'s default source is `Login1` on Linux and `ClockGap` elsewhere. |
| `setup.desktop()` | On macOS it writes `~/Library/LaunchAgents/ai.robo.plist` with Label `ai.robo`, ProgramArguments `[<abs uv>, run, --project, <PROJECT>, robo]`, `RunAtLoad`, `ProcessType Interactive` and a log at `~/Library/Logs/robo.log`. It installs no GNOME extension. It doesn't `launchctl bootstrap`: robo starts at the next login, and the user runs `uv run robo` now. Starting it from setup would open a second robo next to one the user already runs. |
| `hermes/SOUL.md` | The X11 bullet becomes `{{DESKTOP_APPS}}`, which `setup()` fills per OS. On Linux it is today's X11 text. On macOS: "Open GUI apps with `open -a "<App>"`; prefer the terminal or files when they do the job without the GUI." |
| `pyproject.toml` | `jeepney>=0.8; sys_platform == 'linux'` and `pyobjc-framework-Quartz>=11; sys_platform == 'darwin'`. Then refresh `uv.lock`. |

The Hermes config is unchanged. `computer_use.native_wayland` is read only on Linux under Wayland (`cua_backend.py:149`).

## Errors

Every macOS reader fails soft, like the Linux readers:

| Reader | When it fails it returns |
|---|---|
| focus | `("", "")` |
| idle | `0` |
| lock | `False` |
| sites, files | `[]` |

A failed `ps` returns `[]`. `browser.ensure` still detects a running Brave by its CDP port. `ClockGap` can't fail. If the LaunchAgent can't be written, a `SetupError` names the path.

## Testing

Tests are written first and run on Linux with fakes:
- `front_window`: skips higher-layer windows (robo itself) and off-screen windows; the title is empty without a name.
- `pids` from fake `ps` output, including Chromium's space-joined argv and a near-miss data dir.
- The `mdfind` output parser.
- `ClockGap`: a 30-minute wall jump means resumed; a 5 s stall does not. Clocks are injected.
- The LaunchAgent plist (parsed with `plistlib`) on macOS, and the existing `.desktop` path on Linux.
- `DESKTOP_APPS` filled per platform.
- The `cli` platform choice and `open_file` command, with `sys.platform` monkeypatched.

Real-OS tests are skipped where they don't apply:
- **macOS only:** the real Quartz readers return the right types, and `pids()` finds a child process started with a `--user-data-dir=` argument.
- **Both:** the `pids()` test also runs on Linux.

Mutation checks: the `GAP_S` comparison and the layer-0 filter in `front_window`.

CI is `.github/workflows/tests.yml`:
- runs on `ubuntu-latest` and `macos-latest`, on each push to `master` and by hand;
- `uv sync --extra dev`, then `QT_QPA_PLATFORM=offscreen uv run pytest -q` and ruff;
- Ubuntu installs `libportaudio2`, plus the libraries PySide6 needs for offscreen rendering;
- one run costs about 30–40 of the 2,000 free private-repo minutes, because macOS minutes count 10×.

## README

The **Setup** section is split into Linux, which is today's steps, and macOS:

1. Install Homebrew, then `brew install uv gh`. Install Brave (brave.com).
2. Install Hermes with its installer, then run `hermes setup model`, `hermes gateway install` and `hermes computer-use install`.
3. In **System Settings → Privacy & Security**, allow:
   - **Microphone** for the terminal (and for robo when it starts at login);
   - **Accessibility** and **Screen Recording** for cua-driver;
   - optionally, **Screen Recording** for robo, for window titles.
4. Run `gh auth login`, `gh repo clone tbaolong45/robo`, `uv sync --extra dev`, `uv run robo setup --moodle …`, `uv run robo signin` and `uv run robo`.

Windows is listed as "coming".

## Live check on the user's Mac

These can't be checked in CI:

1. The face floats and stays visible when another app is in front.
2. "Robo, …" is heard; macOS asks for the microphone the first time.
3. Robo's Brave keeps its sign-ins after `robo signin`, then after a headless restart. **Open risk:** Chromium on macOS encrypts cookies with a key held in macOS Keychain. If headless mode can't read it, add `--use-mock-keychain` to both the signin and headless launches, and sign in again.
4. `robo activity` shows real app names after a few minutes.
5. Robo makes a diagram and it opens.
6. Robo starts after a re-login (LaunchAgent).
7. After sleep and wake, the digest runs once that day.

## Out of scope

- Hiding the Dock icon. That needs `pyobjc-framework-Cocoa`; add it only if the user asks.
- Showing robo on every Space or over full-screen apps.
- Windows.
