"""`robo` opens the floating robo. `robo setup` prepares Hermes, `robo signin` opens robo's Brave
for school sign-ins, `robo chat` is a text-only REPL, `robo activity` summarises what you did on
this laptop, `robo plan` packs study blocks into free time (JSON in, JSON out)."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import MutableMapping
from datetime import date
from pathlib import Path

from robo import browser, setup
from robo.brain import BrainError, HermesClient
from robo.events import Delta, Feeling, RunEnded, ToolStarted

STATE = Path(__file__).resolve().parents[2] / "data" / "robo_state.json"


def _client() -> HermesClient:
    """Hermes client, after making sure robo's Brave is up for school browsing."""
    url, key = setup.connection()
    try:
        browser.ensure(setup.brave_dir())
    except browser.BrowserError as e:  # chat still works; school questions will say so
        print(f"robo: {e}", file=sys.stderr)
    return HermesClient(url, key)


def chat() -> int:
    client = _client()
    session = f"robo-chat-{date.today().isoformat()}-{setup.persona_stamp()}"
    while True:
        try:
            text = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            return 0
        if not text:
            continue
        try:
            for ev in client.ask(text, session):
                match ev:
                    case Feeling(emotion=e):
                        print(f"[{e}] ", end="", flush=True)
                    case Delta(text=t):
                        print(t, end="", flush=True)
                    case ToolStarted(tool=t):
                        print(f"\n  ({t}…)", flush=True)
                    case RunEnded(status=s, error=err):
                        print("" if s == "completed" else f"\n[{s}] {err}")
        except KeyboardInterrupt:
            if client.run_id:
                client.stop(client.run_id)
            print("\n[stopped]")
        except BrainError as e:
            print(f"[error] {e}")


FLOATING = ("xcb", "cocoa")  # Qt platforms where a window may place itself and stay on top


def _use_xwayland(env: MutableMapping[str, str], platform: str = sys.platform) -> None:
    """On GNOME Wayland only XWayland lets a window place itself and stay on top. Linux only:
    XQuartz sets DISPLAY on a Mac too, and Qt for macOS has no xcb plugin."""
    if platform == "linux" and env.get("DISPLAY") and "QT_QPA_PLATFORM" not in env:
        env["QT_QPA_PLATFORM"] = "xcb;wayland"  # Qt aborts on plain "xcb" if it cannot load


def window() -> int:
    """The floating robo: on GNOME Wayland it runs through XWayland, the only way a window can
    place itself and stay on top; voice in through robo.listen."""
    _use_xwayland(os.environ)
    from PySide6.QtWidgets import QApplication

    from robo.activity import ActivityStore, Watcher, ensure_ledger
    from robo.app import RoboWindow
    from robo.listen import Listener
    from robo.wake import DigestClock

    ensure_ledger()
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)  # a Tool window and dialogs come and go; Quit quits
    floating = app.platformName() in FLOATING
    if not floating:
        print("robo: XWayland unavailable, so robo opens as a normal window "
              "(sudo apt install libxcb-cursor0 for the floating face).", file=sys.stderr)
    win = RoboWindow(_client(), DigestClock(STATE), persona=setup.persona_stamp(),
                     floating=floating, listener=Listener, watcher=Watcher(ActivityStore()))
    win.show()
    return app.exec()


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["plan"]:  # robo plan --tasks ... --busy ... (used by the study-plan skill)
        from robo import plan

        return plan.main(argv[1:])
    parser = argparse.ArgumentParser(prog="robo", description=__doc__)
    parser.add_argument("command", nargs="?", choices=["setup", "signin", "chat", "activity"])
    parser.add_argument("--moodle", metavar="URL", help="with setup: your Moodle address")
    parser.add_argument("--days", type=int, default=1, help="with activity: how many days")
    parser.add_argument("--day", type=date.fromisoformat, help="with activity: last day")
    args = parser.parse_args(argv)
    if args.command == "activity":  # what the user did on this laptop (read by the study skills)
        from robo import activity

        print(activity.summary(activity.ActivityStore(), day=args.day, days=args.days))
        return 0
    try:
        if args.command == "setup":
            done = setup.setup(moodle=args.moodle) + setup.desktop()
            for line in done or ["already set up, nothing changed"]:
                print(f"- {line}")
            return 0
        if args.command == "signin":
            lms = setup.read_env(setup.profile_dir() / ".env").get("MOODLE_BASE_URL")
            browser.signin(setup.brave_dir(), (lms,) if lms else ())
            print("Sign in to Outlook, Teams" + (" and your LMS" if lms else "") + " in the Brave "
                  "window that opened. When Microsoft asks \"Stay signed in?\", choose Yes, or "
                  "the sign-in is lost when robo's browser restarts.")
            input("Press Enter here when you are signed in everywhere... ")
            browser.stop(setup.brave_dir())  # robo works in the background from now on
            browser.ensure(setup.brave_dir())
            print("Done: robo's browser runs in the background with those logins.")
            return 0
        return chat() if args.command == "chat" else window()
    except (setup.SetupError, browser.BrowserError) as e:
        print(f"robo: {e}", file=sys.stderr)
        return 1
