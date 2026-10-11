"""`robo` opens the window. `robo setup` prepares Hermes, `robo signin` opens robo's Brave for
school sign-ins, `robo chat` is a text-only debug REPL."""

from __future__ import annotations

import argparse
import os
import sys
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


def window() -> int:
    """The floating robo: on GNOME Wayland it runs through XWayland, the only way a window can
    place itself and stay on top; voice in through robo.listen."""
    if os.environ.get("DISPLAY") and "QT_QPA_PLATFORM" not in os.environ:
        os.environ["QT_QPA_PLATFORM"] = "xcb"
    from PySide6.QtWidgets import QApplication

    from robo.app import RoboWindow
    from robo.listen import Listener
    from robo.wake import DigestClock

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)  # a Tool window and dialogs come and go; Quit quits
    floating = app.platformName() == "xcb"
    if not floating:
        print("robo: XWayland unavailable, so robo opens as a normal window "
              "(sudo apt install libxcb-cursor0 for the floating face).", file=sys.stderr)
    win = RoboWindow(_client(), DigestClock(STATE), persona=setup.persona_stamp(),
                     floating=floating, listener=Listener)
    win.show()
    return app.exec()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="robo", description=__doc__)
    parser.add_argument("command", nargs="?", choices=["setup", "signin", "chat"])
    parser.add_argument("--moodle", metavar="URL", help="with setup: your Moodle address")
    args = parser.parse_args(argv)
    try:
        if args.command == "setup":
            for line in setup.setup(moodle=args.moodle) or ["already set up, nothing changed"]:
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
