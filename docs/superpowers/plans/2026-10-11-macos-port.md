# Robo on macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to work through this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Robo runs on the user's Mac with the same features it has on Linux. Linux behaviour stays unchanged, and the tests are green on real macOS in GitHub Actions.

**Architecture:** Approach A. Each Linux-only piece gets a macOS twin in the same module, chosen by `sys.platform`. Every twin is injectable, like the readers today, so the Linux test suite covers its logic with fakes. A small number of real-OS tests run only on the matching CI runner.

**Tech Stack:** Python ≥ 3.11, PySide6, pyobjc-framework-Quartz (macOS only), launchd, Spotlight `mdfind`, `ps`, GitHub Actions (`ubuntu-latest` and `macos-latest`).

**Spec:** `docs/superpowers/specs/2026-10-11-macos-port-design.md`

## Global Constraints

- **Linux unchanged:** the Linux code paths keep their current behaviour; only new branches are added. The installed SOUL.md on Linux stays byte-identical.
- **Same paths on macOS:** `~/.hermes`, `~/.local/share/robo`, `~/Robo` and `/tmp/robo-plan`. Skills and robo-guard don't change.
- **Dependencies:** add only `pyobjc-framework-Quartz>=11; sys_platform == 'darwin'`. Mark `jeepney>=0.8; sys_platform == 'linux'`.
- **Style:** ruff with line-length 100 and rules E, F, I, UP, B and SIM. Match the surrounding comment density and idiom.
- **Tests on both OSes:** each test of an OS-specific branch passes the platform explicitly (`platform=` or `monkeypatch.setattr(<module>.sys, "platform", …)`), so it passes on both CI runners. Real-OS tests use `pytest.mark.skipif(sys.platform != …)`.
- **Commands:**
  - tests: `QT_QPA_PLATFORM=offscreen uv run pytest -q`
  - lint: `uv run ruff check src tests scripts hermes`
- **Commits:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Another app becomes active:** robo's floating face must stay visible. Task 2 tests that `WA_MacAlwaysShowToolWindow` is set.
2. **XQuartz is installed** (it sets `DISPLAY` on a Mac): robo must still start on Qt's macOS (`cocoa`) platform instead of aborting on xcb. Task 2 tests `_use_xwayland` on `darwin`.
3. **The home folder has a space** (`/Users/Jane Doe`): `pids()` must still find robo's Brave, so `robo signin` can restart it. Task 3 tests this.
4. **Spotlight is off or slow:** the minute is still recorded, with no files. Task 4 tests a timeout.
5. **A stalled CPU, or the clock set back:** neither may fire the digest. Task 5 tests both.

---

### Task 1: Dependencies per OS

**Files:**
- Modify: `pyproject.toml` (the `dependencies` list)
- Modify: `uv.lock` (regenerated)

**Interfaces:**
- Produces: `import Quartz` works on macOS. `jeepney` is installed only on Linux; every jeepney import is already lazy, inside `activity._call` and `wake.Login1.__init__`.

- [ ] **Step 1: Edit dependencies**

```toml
dependencies = [
    "pyside6>=6.8",
    "httpx>=0.28",
    "jeepney>=0.8; sys_platform == 'linux'",
    "pyobjc-framework-Quartz>=11; sys_platform == 'darwin'",
    "sounddevice>=0.5.6",
    "numpy>=2.4.6",
    "onnx-asr[cpu,hub]>=0.12.0",
]
```

- [ ] **Step 2: Lock and sync**

Run: `uv lock && uv sync --extra dev`
Expected: the lock resolves; `grep -c pyobjc-framework-quartz uv.lock` ≥ 1; the sync installs no pyobjc on Linux.

- [ ] **Step 3: Full suite still green**

Run: `QT_QPA_PLATFORM=offscreen uv run pytest -q && uv run ruff check src tests scripts hermes`
Expected: `724 passed`, `All checks passed!`

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "build: jeepney on Linux only, pyobjc Quartz on macOS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The floating window and opening files on macOS

**Files:**
- Modify: `src/robo/cli.py`: `window()` (the `QT_QPA_PLATFORM` lines and `floating = …`)
- Modify: `src/robo/app.py`: imports, `open_file()`, `RoboWindow._build()` floating branch
- Test: `tests/test_cli.py`, `tests/test_app.py`

**Interfaces:**
- Produces:
  - `cli.FLOATING: tuple[str, ...] = ("xcb", "cocoa")`
  - `cli._use_xwayland(env: MutableMapping[str, str], platform: str) -> None`
  - `app.open_file(path: Path) -> None`, which now uses `open` on darwin

- [ ] **Step 1: Write failing tests**

Append to `tests/test_cli.py`:

```python
def test_xwayland_only_on_linux():
    env = {"DISPLAY": ":0"}
    cli._use_xwayland(env, "linux")
    assert env["QT_QPA_PLATFORM"] == "xcb;wayland"
    mac = {"DISPLAY": "/private/tmp/com.apple.launchd.x/org.xquartz:0"}  # XQuartz sets DISPLAY
    cli._use_xwayland(mac, "darwin")
    assert "QT_QPA_PLATFORM" not in mac
    own = {"DISPLAY": ":0", "QT_QPA_PLATFORM": "wayland"}
    cli._use_xwayland(own, "linux")
    assert own["QT_QPA_PLATFORM"] == "wayland"  # the user's choice wins


def test_robo_floats_on_xwayland_and_macos():
    assert set(cli.FLOATING) == {"xcb", "cocoa"}
```

Append to `tests/test_app.py`:

```python
def test_floating_face_stays_shown_while_another_app_is_active(tmp_path):
    win, _ = floating(tmp_path, FakeClient([]))
    assert win.testAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)


def test_open_file_uses_the_os_opener(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(robo_app.subprocess, "Popen", lambda argv, **kw: calls.append(argv))
    for platform in ("linux", "darwin"):
        monkeypatch.setattr(robo_app.sys, "platform", platform)
        robo_app.open_file(tmp_path / "a.html")
    assert calls == [["xdg-open", str(tmp_path / "a.html")], ["open", str(tmp_path / "a.html")]]
```

- [ ] **Step 2: Run them; they fail**

Run: `QT_QPA_PLATFORM=offscreen uv run pytest -q tests/test_cli.py tests/test_app.py -k "xwayland or floats_on or stays_shown or os_opener"`
Expected: 4 FAIL: `AttributeError: _use_xwayland` / `FLOATING`; the attribute is not set; `robo_app.sys` is missing.

- [ ] **Step 3: Implement**

`src/robo/cli.py`: add `from collections.abc import MutableMapping` to the imports. Add these above `window()`:

```python
FLOATING = ("xcb", "cocoa")  # Qt platforms where a window may place itself and stay on top


def _use_xwayland(env: MutableMapping[str, str], platform: str = sys.platform) -> None:
    """On GNOME Wayland only XWayland lets a window place itself and stay on top. Linux only:
    XQuartz sets DISPLAY on a Mac too, and Qt for macOS has no xcb plugin."""
    if platform == "linux" and env.get("DISPLAY") and "QT_QPA_PLATFORM" not in env:
        env["QT_QPA_PLATFORM"] = "xcb;wayland"  # Qt aborts on plain "xcb" if it cannot load
```

In `window()`, replace the two lines that set `QT_QPA_PLATFORM` with `_use_xwayland(os.environ)`. Replace `floating = app.platformName() == "xcb"` with `floating = app.platformName() in FLOATING`.

`src/robo/app.py`: add `import sys` after `import subprocess`. Replace the body of `open_file`:

```python
def open_file(path: Path) -> None:
    """Open a file robo made in the user's default app for it."""
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    subprocess.Popen([opener, str(path)], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
```

In `_build()`, after `self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)`, add:

```python
            # macOS hides Tool windows whenever robo is not the active app; a pet stays out.
            self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)
```

- [ ] **Step 4: Run tests; they pass**

Run: `QT_QPA_PLATFORM=offscreen uv run pytest -q tests/test_cli.py tests/test_app.py`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/robo/cli.py src/robo/app.py tests/test_cli.py tests/test_app.py
git commit -m "feat(mac): floating face on Qt cocoa, stays shown, files open with open(1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Robo's Brave on macOS

**Files:**
- Modify: `src/robo/browser.py`: imports, `BINARY`, `pids()`
- Test: `tests/test_browser.py`

**Interfaces:**
- Produces:
  - `browser.MAC_BRAVE: str`
  - `browser.find_brave(platform: str = sys.platform, which=shutil.which) -> str`
  - `browser.pids(data_dir: Path, proc: Path = Path("/proc"), ps: Callable[[], str] = _ps) -> list[int]`

- [ ] **Step 1: Write failing tests**

Add `import subprocess`, `import sys` and `from pathlib import Path` to the top of `tests/test_browser.py`. Then append:

```python
def test_find_brave_on_path_else_where_the_installer_puts_it():
    on_path = {"brave-browser": "/usr/bin/brave-browser"}
    assert browser.find_brave("linux", on_path.get) == "/usr/bin/brave-browser"
    assert browser.find_brave("darwin", {}.get) == browser.MAC_BRAVE
    assert browser.MAC_BRAVE == "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    assert browser.find_brave("linux", {}.get) == "brave-browser"


PS = """\
  101 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser --user-data-dir={d} --headless=new
  102 /Applications/Brave Browser.app/Contents/Frameworks/Brave Helper --type=renderer --user-data-dir={d}
  103 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser --user-data-dir={d}2
  104 /bin/zsh -l
"""


def test_pids_without_proc_reads_ps_even_with_a_space_in_home(tmp_path):
    d = tmp_path / "Jane Doe" / "brave"
    assert browser.pids(d, proc=tmp_path / "no-proc", ps=lambda: PS.format(d=d)) == [101, 102]


def test_pids_without_proc_survive_a_failing_ps(tmp_path):
    def boom():
        raise OSError("no ps")

    assert browser.pids(tmp_path, proc=tmp_path / "no-proc", ps=boom) == []


def test_pids_find_a_real_process_through_ps_and_proc(tmp_path):
    d = tmp_path / "brave"
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                          f"--user-data-dir={d}"])
    try:
        assert p.pid in browser.pids(d, proc=tmp_path / "no-proc")  # real ps
        if Path("/proc").is_dir():
            assert p.pid in browser.pids(d)  # real /proc
    finally:
        p.kill()
        p.wait()
```

- [ ] **Step 2: Run them; they fail**

Run: `uv run pytest -q tests/test_browser.py`
Expected: 4 FAIL with `find_brave` / `MAC_BRAVE` missing, and `FileNotFoundError` from `proc.iterdir()`.

- [ ] **Step 3: Implement**

`src/robo/browser.py`: add `import sys` to the imports. Replace the `BINARY` line:

```python
MAC_BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"


def find_brave(platform: str = sys.platform, which: Callable[[str], str | None] = shutil.which,
               ) -> str:
    """Brave on PATH, else where its installer puts it."""
    return (which("brave-browser") or which("brave")
            or (MAC_BRAVE if platform == "darwin" else "brave-browser"))


BINARY = find_brave()
```

Replace `pids()`:

```python
def _ps() -> str:
    """Every process with its full command line (macOS has no /proc)."""
    return subprocess.run(["ps", "-A", "-ww", "-o", "pid=,args="], capture_output=True,
                          text=True, timeout=10).stdout


def pids(data_dir: Path, proc: Path = Path("/proc"), ps: Callable[[], str] = _ps) -> list[int]:
    """Main and child processes of robo's Brave (matched by its exact --user-data-dir)."""
    if not proc.is_dir():  # macOS: a space-bounded match, since a home folder may hold spaces
        flag = f" --user-data-dir={data_dir} "
        try:
            lines = ps().splitlines()
        except (OSError, subprocess.SubprocessError):
            return []
        found = []
        for line in lines:
            pid, _, args = line.strip().partition(" ")
            if pid.isdigit() and flag in f" {args} ":
                found.append(int(pid))
        return sorted(found)
    flag = f"--user-data-dir={data_dir}".encode()
    out = []
    for d in proc.iterdir():
        if d.name.isdigit():
            try:
                # Chromium rewrites its argv in place, joined by spaces, so split on both.
                if flag in (d / "cmdline").read_bytes().replace(b"\0", b" ").split():
                    out.append(int(d.name))
            except OSError:
                pass
    return sorted(out)
```

- [ ] **Step 4: Run tests; they pass**

Run: `uv run pytest -q tests/test_browser.py`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/robo/browser.py tests/test_browser.py
git commit -m "feat(mac): find Brave in /Applications, find its processes via ps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Activity watching on macOS

**Files:**
- Modify: `src/robo/activity.py`: imports, `BRAVE_HISTORY`, a new macOS reader section after `read_files`, and the defaults of `sample()`
- Test: `tests/test_activity.py`

**Interfaces:**
- Produces:
  - `activity.MAC: bool`
  - `activity.front_window(windows: list) -> tuple[str, str]`
  - `activity.mac_focus() -> tuple[str, str]`
  - `activity.mac_idle() -> int`
  - `activity.mac_locked() -> bool`
  - `activity.mac_files(since: float, now: float, *, find: Callable[[str], str] = _mdfind) -> list[str]`
  - `activity._utc(t: float) -> str`
  - `activity.FOCUS, IDLE, LOCKED, FILES`: the readers `sample()` uses on this OS

- [ ] **Step 1: Write failing tests**

Add `import subprocess` and `import sys` to the top of `tests/test_activity.py`. Then append:

```python
# --- macOS readers ------------------------------------------------------------------------------


def win(layer, owner, name=None, alpha=1.0):
    w = {"kCGWindowLayer": layer, "kCGWindowOwnerName": owner, "kCGWindowAlpha": alpha}
    return w | ({"kCGWindowName": name} if name is not None else {})


def test_front_window_is_the_first_visible_normal_window():
    wins = [win(3, "Python", "Robo"),  # robo itself, always on top
            win(25, "Control Centre"),
            win(0, "Ghost", "helper", alpha=0.0),  # an invisible helper window
            win(0, "Code", "activity.py"),
            win(0, "Safari", "Moodle")]
    assert act.front_window(wins) == ("Code", "activity.py")


def test_front_window_without_screen_recording_has_no_title():
    assert act.front_window([win(0, "Code")]) == ("Code", "")
    assert act.front_window([]) == ("", "")


def test_mac_files_asks_spotlight_for_the_window():
    asked = []
    out = "/Users/u/Notes.pdf\n/Users/u/Notes.pdf\n\n/Users/u/a.py\n"
    got = act.mac_files(NOW - 60, NOW, find=lambda q: asked.append(q) or out)
    assert got == ["/Users/u/Notes.pdf", "/Users/u/a.py"]
    assert asked == [f"kMDItemLastUsedDate > $time.iso({act._utc(NOW - 60)}) && "
                     f"kMDItemLastUsedDate <= $time.iso({act._utc(NOW)})"]
    assert act._utc(0) == "1970-01-01T00:00:00Z"


def test_mac_files_is_empty_when_spotlight_is_off_or_slow():
    def slow(query):
        raise subprocess.TimeoutExpired("mdfind", 20)

    assert act.mac_files(NOW - 60, NOW, find=slow) == []


@pytest.mark.skipif(sys.platform != "darwin", reason="real Quartz and Spotlight")
def test_real_mac_readers():
    assert (act.FOCUS, act.IDLE, act.LOCKED, act.FILES) == (
        act.mac_focus, act.mac_idle, act.mac_locked, act.mac_files)
    app, title = act.mac_focus()
    assert isinstance(app, str) and isinstance(title, str)
    assert act.mac_idle() >= 0 and isinstance(act.mac_locked(), bool)
    assert isinstance(act.mac_files(time.time() - 3600, time.time()), list)
    assert "Library/Application Support/BraveSoftware" in str(act.BRAVE_HISTORY)


@pytest.mark.skipif(sys.platform != "linux", reason="GNOME readers")
def test_linux_keeps_the_gnome_readers():
    assert (act.FOCUS, act.IDLE, act.LOCKED, act.FILES) == (
        act.read_focus, act.read_idle, act.read_locked, act.read_files)
    assert ".config/BraveSoftware" in str(act.BRAVE_HISTORY)
```

- [ ] **Step 2: Run them; they fail**

Run: `uv run pytest -q tests/test_activity.py -k "front_window or mac_files or readers"`
Expected: FAIL with `front_window`, `mac_files`, `FOCUS`… missing (the macOS-only test is skipped on Linux).

- [ ] **Step 3: Implement**

`src/robo/activity.py`:
- Add `import subprocess` and `import sys` to the imports.
- Change `from datetime import date, datetime, timedelta` to `from datetime import UTC, date, datetime, timedelta`.
- Replace the `BRAVE_HISTORY` line:

```python
MAC = sys.platform == "darwin"
BRAVE_HISTORY = (Path.home() / ("Library/Application Support" if MAC else ".config")
                 / "BraveSoftware/Brave-Browser/Default/History")
```

Insert this section right after `read_files()` and before `# --- sampling`:

```python
# --- macOS readers (Quartz, Spotlight): no extension needed ------------------------------------


def front_window(windows: list) -> tuple[str, str]:
    """(app, title) of the frontmost normal window in Quartz's front-to-back list. Robo's own
    always-on-top window and the menu bar sit above layer 0; the title needs Screen Recording."""
    for w in windows:
        if w.get("kCGWindowLayer") == 0 and w.get("kCGWindowAlpha", 1) > 0:
            return str(w.get("kCGWindowOwnerName") or ""), str(w.get("kCGWindowName") or "")
    return "", ""


def _quartz():
    import Quartz  # pyobjc-framework-Quartz, installed on macOS only

    return Quartz


def mac_focus() -> tuple[str, str]:
    try:
        q = _quartz()
        opts = q.kCGWindowListOptionOnScreenOnly | q.kCGWindowListExcludeDesktopElements
        return front_window(list(q.CGWindowListCopyWindowInfo(opts, q.kCGNullWindowID) or []))
    except Exception:
        return "", ""


def mac_idle() -> int:
    q = _quartz()
    return int(q.CGEventSourceSecondsSinceLastEventType(
        q.kCGEventSourceStateCombinedSessionState, q.kCGAnyInputEventType))


def mac_locked() -> bool:
    return bool((_quartz().CGSessionCopyCurrentDictionary() or {})
                .get("CGSSessionScreenIsLocked"))


def _utc(t: float) -> str:
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mdfind(query: str) -> str:
    return subprocess.run(["mdfind", "-onlyin", str(Path.home()), query], capture_output=True,
                          text=True, timeout=20).stdout


def mac_files(since: float, now: float, *, find: Callable[[str], str] = _mdfind) -> list[str]:
    """Files Spotlight saw opened in (since, now]; [] when Spotlight is off or slow."""
    query = (f"kMDItemLastUsedDate > $time.iso({_utc(since)}) && "
             f"kMDItemLastUsedDate <= $time.iso({_utc(now)})")
    try:
        found = find(query).splitlines()
    except (OSError, subprocess.SubprocessError):
        return []
    return list(dict.fromkeys(p for p in found if p.startswith("/")))


# What sample() reads on this OS: GNOME D-Bus + recently-used.xbel, or Quartz + Spotlight.
FOCUS, IDLE, LOCKED, FILES = ((mac_focus, mac_idle, mac_locked, mac_files) if MAC
                              else (read_focus, read_idle, read_locked, read_files))
```

Change the `sample()` signature defaults to:

```python
def sample(now: float, since: float, *, focus: Callable[[], tuple[str, str]] = FOCUS,
           idle: Callable[[], int] = IDLE, locked: Callable[[], bool] = LOCKED,
           sites: Callable[[float, float], list[str]] = read_sites,
           files: Callable[[float, float], list[str]] = FILES) -> Sample:
```

Also update the module docstring's last line to: `Kept only in ~/.local/share/robo/activity.db (dir 0700, file 0600) for 30 days. GNOME: focus from robo's extension; macOS: Quartz and Spotlight.`

- [ ] **Step 4: Run tests; they pass**

Run: `uv run pytest -q tests/test_activity.py && uv run ruff check src tests`
Expected: all pass (one skip on Linux); ruff clean.

- [ ] **Step 5: Mutation check**

In `front_window`, change `== 0` to `>= 0` and run `uv run pytest -q tests/test_activity.py -k front_window`.
Expected: FAIL, because robo's own window at layer 3 is returned. Revert.

Change `> 0` (alpha) to `>= 0` and rerun.
Expected: FAIL, because Ghost is returned. Revert.

- [ ] **Step 6: Commit**

```bash
git add src/robo/activity.py tests/test_activity.py
git commit -m "feat(mac): activity via Quartz (front app, idle, lock) and Spotlight (files)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Wake detection anywhere: ClockGap

**Files:**
- Modify: `src/robo/wake.py`: imports, a new `ClockGap` class after `Login1`, and the `WakeWatcher.__init__` default
- Test: `tests/test_wake.py`

**Interfaces:**
- Produces:
  - `wake.GAP_S: int = 60`
  - `wake.ClockGap(wall=time.time, awake=time.monotonic, wait=time.sleep)`, a `SleepSource` with `recv(timeout) -> bool | None` and `close()`
  - `WakeWatcher(on_resume, connect=None, …)`: `None` means `Login1` on Linux and `ClockGap` elsewhere

- [ ] **Step 1: Write failing tests**

In `tests/test_wake.py`, change the import line to:

```python
from robo import wake
from robo.wake import ClockGap, DigestClock, Login1, WakeWatcher, wait_for_network
```

Append:

```python
def clocks():
    t = {"wall": 1000.0, "awake": 50.0}
    gap = ClockGap(wall=lambda: t["wall"], awake=lambda: t["awake"], wait=lambda s: None)
    return t, gap


def step(t, wall, awake=0.5):
    t["wall"] += wall
    t["awake"] += awake


def test_clock_gap_sees_a_sleep_but_not_a_stall_or_a_clock_change():
    t, gap = clocks()
    step(t, 5.5)  # a busy CPU: 5 s late, never asleep
    assert gap.recv(0.5) is None
    step(t, 1800.5)  # lid closed for 30 min
    assert gap.recv(0.5) is False
    step(t, 0.5)
    assert gap.recv(0.5) is None  # once per sleep
    step(t, -3600)  # clock set back an hour
    assert gap.recv(0.5) is None


def test_clock_gap_threshold_is_gap_s():
    t, gap = clocks()
    step(t, wake.GAP_S + 0.5)  # exactly GAP_S ahead of awake time: not yet a sleep
    assert gap.recv(0) is None
    step(t, wake.GAP_S + 1.5)
    assert gap.recv(0) is False


def test_wake_source_per_os(monkeypatch):
    monkeypatch.setattr(wake.sys, "platform", "darwin")
    assert WakeWatcher(lambda: None).connect is ClockGap
    monkeypatch.setattr(wake.sys, "platform", "linux")
    assert WakeWatcher(lambda: None).connect is Login1


def test_watcher_on_clock_gap_calls_on_resume():
    t, gap = clocks()
    woke = threading.Event()
    w = WakeWatcher(woke.set, connect=lambda: gap, poll=0.01)
    assert w.start()
    step(t, 900)
    assert woke.wait(2)
    w.stop()
```

- [ ] **Step 2: Run them; they fail**

Run: `uv run pytest -q tests/test_wake.py`
Expected: ImportError: `ClockGap`.

- [ ] **Step 3: Implement**

`src/robo/wake.py`:
- Add `import sys` to the imports.
- Change the module docstring to: `"""First-wake-of-the-day trigger: a persisted digest date, a resume watcher (login1 on Linux, a clock gap elsewhere), a net wait."""`

Add after the `Login1` class:

```python
GAP_S = 60  # wall time this far ahead of awake time: the machine slept


class ClockGap:
    """A SleepSource for any OS: monotonic time stops while the machine sleeps, wall time
    does not, so a jump between them after a short wait is a resume."""

    def __init__(self, wall: Callable[[], float] = time.time,
                 awake: Callable[[], float] = time.monotonic,
                 wait: Callable[[float], None] = time.sleep):
        self.wall, self.awake, self.wait = wall, awake, wait
        self._last = (wall(), awake())

    def recv(self, timeout: float) -> bool | None:
        self.wait(timeout)
        now = (self.wall(), self.awake())
        slept = (now[0] - self._last[0]) - (now[1] - self._last[1])
        self._last = now
        return False if slept > GAP_S else None

    def close(self) -> None:
        pass
```

In `WakeWatcher.__init__`, change the parameter to `connect: Callable[[], SleepSource] | None = None`. Change the first line of the body to:

```python
        self.on_resume, self.poll, self.retry = on_resume, poll, retry
        self.connect = connect or (Login1 if sys.platform == "linux" else ClockGap)
```

- [ ] **Step 4: Run tests; they pass**

Run: `uv run pytest -q tests/test_wake.py tests/test_app.py`
Expected: all pass.

- [ ] **Step 5: Mutation check**

Change `slept > GAP_S` to `slept >= GAP_S`; `test_clock_gap_threshold_is_gap_s` must FAIL. Change it to `slept > 0`; the stall test must FAIL. Revert both.

- [ ] **Step 6: Commit**

```bash
git add src/robo/wake.py tests/test_wake.py
git commit -m "feat(mac): wake detection by clock gap where there is no login1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Setup on macOS: the LaunchAgent and the desktop-apps rule

**Files:**
- Modify: `src/robo/setup.py`: imports, `desktop()`, a new `_launch_agent()`, a new `DESKTOP_APPS`, and the `fill` in `setup()`
- Modify: `hermes/SOUL.md`: the X11 bullet becomes `- {{DESKTOP_APPS}}`
- Test: `tests/test_setup.py`, `tests/test_templates.py`

**Interfaces:**
- Produces:
  - `setup.desktop(…, platform: str = sys.platform) -> list[str]`
  - `setup.LAUNCH_AGENT = "ai.robo"`
  - `setup.DESKTOP_APPS: dict[str, str]`, keyed by `"linux"` / `"darwin"`

- [ ] **Step 1: Write failing tests**

`tests/test_setup.py`: add `import plistlib` at the top. In `test_desktop_installs_the_focus_extension_and_autostart`, add `platform="linux",` to the `kw = dict(...)` call. Then append:

```python
def test_desktop_on_macos_writes_a_launch_agent_and_no_extension(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setattr(setup.Path, "home", lambda: home)
    monkeypatch.setattr(setup.shutil, "which", lambda name: "/opt/homebrew/bin/uv")

    def no_gsettings(*a):
        raise AssertionError("no gsettings on a Mac")

    kw = dict(platform="darwin", get_enabled=no_gsettings, set_enabled=no_gsettings)
    done = setup.desktop(**kw)
    agent = plistlib.loads((home / "Library/LaunchAgents/ai.robo.plist").read_bytes())
    assert agent["Label"] == "ai.robo" and agent["RunAtLoad"] is True
    assert agent["ProgramArguments"] == ["/opt/homebrew/bin/uv", "run", "--project",
                                         str(setup.PROJECT), "robo"]
    assert agent["StandardErrorPath"] == str(home / "Library/Logs/robo.log")
    assert not (home / ".local/share/gnome-shell").exists()
    assert any("log in" in d for d in done)
    assert setup.desktop(**kw) == []  # idempotent


@pytest.mark.parametrize("platform, says", [("linux", "GDK_BACKEND=x11"), ("darwin", "open -a")])
def test_desktop_apps_rule_is_filled_per_os(tmp_path, monkeypatch, platform, says):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(setup.sys, "platform", platform)
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    templates = tmp_path / "templates"
    templates.mkdir()
    (templates / "SOUL.md").write_text("- {{DESKTOP_APPS}}\n")

    setup.setup(templates=templates, config={}, run=lambda cmd: None, wait=lambda: True)
    soul = (robo / "SOUL.md").read_text()
    assert says in soul and "{{" not in soul
```

Append to `tests/test_templates.py`:

```python
def test_soul_leaves_the_desktop_apps_rule_to_setup():
    soul = (HERMES / "SOUL.md").read_text(encoding="utf-8")
    assert "- {{DESKTOP_APPS}}\n" in soul and "GDK_BACKEND" not in soul
```

- [ ] **Step 2: Run them; they fail**

Run: `uv run pytest -q tests/test_setup.py tests/test_templates.py`
Expected: FAIL with `desktop() got an unexpected keyword argument 'platform'`, `setup.sys` missing, and the SOUL assertion.

- [ ] **Step 3: Implement**

`src/robo/setup.py`: add `import plistlib` and `import sys` to the imports. After `INSTALLED = …`, add:

```python
LAUNCH_AGENT = "ai.robo"  # macOS: ~/Library/LaunchAgents/ai.robo.plist starts robo at login
# SOUL.md's rule for desktop apps (computer_use), per OS.
DESKTOP_APPS = {
    "linux": "computer_use only sees X11 windows on this GNOME Wayland laptop. Open GUI apps for"
             " it from\n  the terminal in X11 mode: GTK `GDK_BACKEND=x11 <app>`, Qt"
             " `QT_QPA_PLATFORM=xcb <app>`,\n  Chromium/Electron `<app> --ozone-platform=x11`."
             " Prefer the terminal or files when they do\n  the job without the GUI.",
    "darwin": "Open GUI apps on this Mac with `open -a \"<App>\"` from the terminal. Prefer the"
              " terminal or\n  files when they do the job without the GUI.",
}
```

The `"linux"` value must reproduce the current SOUL.md lines 42-45 exactly, after `- `. Step 5 checks this byte for byte.

Change `desktop()`:

```python
def desktop(extension: Path = EXTENSION, robo_cmd: str | None = None,
            get_enabled: Callable[[], list[str]] = _enabled_extensions,
            set_enabled: Callable[[list[str]], None] = _set_enabled_extensions,
            platform: str = sys.platform) -> list[str]:
    """Start robo at login; on GNOME also install robo's focus extension (activity watching)."""
    if platform == "darwin":
        return _launch_agent()
    done = []
```

The rest of the Linux body stays unchanged. Add after `desktop()`:

```python
def _launch_agent() -> list[str]:
    """macOS: launchd starts robo at each login. No extension: Quartz gives the focused app."""
    home = Path.home()
    log_file = str(home / "Library/Logs/robo.log")
    data = plistlib.dumps({
        "Label": LAUNCH_AGENT,
        "ProgramArguments": [shutil.which("uv") or "uv", "run", "--project", str(PROJECT), "robo"],
        "RunAtLoad": True, "ProcessType": "Interactive",
        "StandardOutPath": log_file, "StandardErrorPath": log_file,
    })
    path = home / "Library/LaunchAgents" / f"{LAUNCH_AGENT}.plist"
    if path.exists() and path.read_bytes() == data:
        return []
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    except OSError as e:
        raise SetupError(f"Could not write {path}: {e}") from e
    return ["robo now starts when you log in (`uv run robo` starts it now)"]
```

In `setup()`, change the `fill` to:

```python
    fill = {"MOODLE_BASE_URL": read_env(robo_env).get("MOODLE_BASE_URL") or "not set",
            "ROBO_PROJECT": str(PROJECT),
            "DESKTOP_APPS": DESKTOP_APPS["darwin" if sys.platform == "darwin" else "linux"]}
```

`hermes/SOUL.md`: replace the four lines starting `- computer_use only sees X11 windows …` (through `the job without the GUI.`) with the single line `- {{DESKTOP_APPS}}`.

- [ ] **Step 4: Run tests; they pass**

Run: `QT_QPA_PLATFORM=offscreen uv run pytest -q && uv run ruff check src tests scripts hermes`
Expected: all pass; ruff clean.

- [ ] **Step 5: Linux install stays byte-identical**

Run:

```bash
uv run python -c "
from robo import setup; from pathlib import Path
t = (setup.TEMPLATES / 'SOUL.md').read_text().replace('{{DESKTOP_APPS}}', setup.DESKTOP_APPS['linux'])
t = t.replace('{{MOODLE_BASE_URL}}', setup.read_env(setup.profile_dir() / '.env')['MOODLE_BASE_URL'])
print(t == (setup.profile_dir() / 'SOUL.md').read_text())"
```

Expected: `True`. If it prints `False`, fix `DESKTOP_APPS["linux"]` until it prints `True`.

- [ ] **Step 6: Commit**

```bash
git add src/robo/setup.py hermes/SOUL.md tests/test_setup.py tests/test_templates.py
git commit -m "feat(mac): LaunchAgent autostart; SOUL desktop-apps rule filled per OS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: README for macOS

**Files:**
- Modify: `README.md`: the "Setup" section, the "Limits" section and the intro line about the platform

- [ ] **Step 1: Edit the README**

Under `## Setup`, keep the Linux steps as `### Linux (GNOME)`. Add `### macOS` after them:

````markdown
### macOS

Robo runs natively on a Mac (Apple silicon or Intel, macOS 13+). Nothing to log out for.

```bash
# Homebrew (brew.sh), then:
brew install uv gh
# Brave: https://brave.com/download/  (robo uses its own private Brave profile)
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash   # Hermes Agent
hermes setup model                 # sign in to Anthropic (robo uses claude-sonnet-5.5)
hermes gateway install             # Hermes' background service (launchd); robo talks to it
hermes computer-use install        # the driver robo uses to work in desktop apps
hermes computer-use permissions    # grant it Accessibility and Screen Recording
gh auth login && gh repo clone tbaolong45/robo && cd robo   # the repo is private
uv sync --extra dev
uv run robo setup --moodle https://lms.your-school.edu/my/
uv run robo signin                 # sign in to Outlook, Teams and Moodle, then press Enter
uv run robo                        # it also starts by itself at every login from now on
```

Permissions macOS asks for, in **System Settings → Privacy & Security**:
- **Microphone:** asked the first time robo listens. Allow it, or robo can't hear you.
- **Screen Recording** (optional), for your terminal app: only so the activity log has window titles. Without it, robo records app names only.
````

Add `### Windows`: `Not yet: coming next.`

In `## Limits (known)`, add:

```markdown
- **macOS.** Robo shows a Python icon in the Dock, and it stays on the desktop Space where it started (it does not follow you into full-screen apps). Window titles in the activity log need Screen Recording.
```

Retitle the existing "Wayland" and "computer_use sees only X11 windows" bullets as Linux: `**Wayland (Linux).**` and `**computer_use sees only X11 windows (Linux).**`.

In the intro paragraph, after "Its brain is Hermes Agent…", add: `It runs on Linux (GNOME) and macOS.`

- [ ] **Step 2: Check**

Run: `grep -n "### macOS\|### Linux\|### Windows\|runs on Linux" README.md`
Expected: four hits.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: macOS setup and limits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: CI on real Linux and macOS

**Files:**
- Create: `.github/workflows/tests.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: tests
on:
  push:
    branches: [master]
  workflow_dispatch:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    env:
      QT_QPA_PLATFORM: offscreen
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
      - name: Qt and audio libraries (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y libegl1 libgl1 libxkbcommon0 libfontconfig1 libportaudio2
      - run: uv sync --extra dev
      - run: uv run pytest -q
      - run: uv run ruff check src tests scripts hermes
```

- [ ] **Step 2: Commit and push**

```bash
git add .github/workflows/tests.yml
git commit -m "ci: tests on ubuntu and macos

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 3: Watch the run**

Run: `gh run watch $(gh run list --workflow tests.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status`
Expected: both jobs succeed. On failure, run `gh run view <id> --log-failed`. For each failing test:
- **A real macOS bug** (a wrong Quartz constant, a path, an API): write a failing test that pins it, fix it, push.
- **Only this machine's setup** (for example, the test reads a real file that only this laptop has): add `pytest.mark.skipif` with a reason naming the dependency, and give a one-line justification in the commit message.

Repeat until both jobs are green. `test_real_mac_readers` must have run, not been skipped, on macOS. Check with `gh run view <id> --log | grep -c "test_real_mac_readers"`, or by running pytest with `-rs` in a scratch rerun.

---

### Task 9: Whole-branch verification on this laptop

- [ ] **Step 1: Full suite and lint**

Run: `QT_QPA_PLATFORM=offscreen uv run pytest -q && uv run ruff check src tests scripts hermes`
Expected: all pass; clean.

- [ ] **Step 2: Setup is a no-op on Linux**

Run: `uv run robo setup --moodle https://lms.mbzuai.ac.ae`
Expected: `- already set up, nothing changed`. The installed SOUL, skills and autostart are byte-identical, so the gateway is not restarted and the persona stamp is unchanged.

- [ ] **Step 3: Robo still runs here**

Run: `uv run robo activity --days 1 | head -5` and `pgrep -af "robo$"`
Expected: the activity summary prints; the autostarted robo is running.

- [ ] **Step 4: Fresh reviewer**

Dispatch one reviewer subagent on the whole diff since `c34e54f`. Check it against the spec and the Review Focus list. Fix any confirmed findings test-first.

- [ ] **Step 5: Update memory**

Append to `memory/robo-redesign.md`: macOS port commits, CI status, and what still awaits the live check.

---

### Task 10: Live check on the user's Mac (the user is present)

The user does these on the Mac following the README, then reports each result:

1. `uv run robo`: the face floats. Click Finder: the face must stay visible.
2. Say "Robo, what time is it?". macOS asks for the microphone; allow it. Expect an answer.
3. `uv run robo signin`, sign in, press Enter. Then "Robo, what's due this week?" must answer from Moodle.
   - **If it says to sign in again,** headless Brave can't read the Keychain cookie key. Add `"--use-mock-keychain"` to the `argv` in `browser.ensure()` (both headless and visible launches use it) with a test, push, then `git pull` and `robo signin` again.
4. After 5 minutes, `uv run robo activity`: real app names, such as Finder, Brave Browser or Code.
5. "Robo, draw a diagram of the water cycle": the file opens by itself.
6. Log out and in: robo starts by itself.
7. Close the lid for 2 or more minutes on a day the digest hasn't run, then open it: the digest runs.

For each failure, fix it test-first, push, then on the Mac run `git pull` and `uv sync`.
