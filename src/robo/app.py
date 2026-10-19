"""Robo on the desktop: a floating face with a speech bubble; Hermes runs in a worker thread.

Floating mode (X11/XWayland) is a frameless, always-on-top, see-through window that drifts around
the screen edges (robo.roam). Otherwise the same widgets live in an ordinary window.
"""

from __future__ import annotations

import contextlib
import functools
import math
import random
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import replace
from datetime import date
from pathlib import Path

from PySide6.QtCore import QObject, QPoint, Qt, QTimer, Signal
from PySide6.QtGui import (
    QColor,
    QCursor,
    QGuiApplication,
    QKeySequence,
    QShortcut,
    QTextCharFormat,
    QTextCursor,
)
from PySide6.QtWidgets import (
    QGridLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from robo import hud
from robo import mind as minds
from robo import theme as themes
from robo.brain import BrainError
from robo.events import ApprovalNeeded, Delta, Event, Feeling, Listening, RunEnded, UserSent
from robo.face.animator import look_at
from robo.face.widget import FaceWidget
from robo.health import HealthPoller
from robo.roam import Rect, Roamer
from robo.typewriter import Pace, Typewriter
from robo.vault import FOLDERS, VAULT, open_note
from robo.wake import DigestClock, WakeWatcher, wait_for_network
from robo.widgets import TypingDots, _text_height, style_markdown

DIGEST_PROMPT = "Give me my school digest for today (use the school digest skill)."
FACE = (128, 96)  # px, the floating face
TEXT_MAX = 300  # px of reply text before the bubble scrolls
HEARD_PX = 90  # px of your own (possibly long) question above the reply; then it scrolls
APPROVAL_MAX = 300  # characters of an approval request (a long command) shown
CLOSE_AFTER = 20.0  # s a reply stays up after its last letter (longer while the mouse is over it)
TYPE_S = 0.033  # s between typing steps (30 Hz; 0.030 if a slow machine struggles)
SOLID_S = 0.5  # s the caret stays solid after a letter, then it blinks
CARET_S = 1.6  # s the caret keeps blinking once the reply is all there
SKIP_PX = 4  # px a press and release on the reply may be apart and still be a click to skip
WATCH_PAUSED = Path.home() / ".local/share/robo/watch.paused"  # exists = watching paused
OUTPUT_DIR = Path.home() / "Robo"  # what robo makes (diagrams, pages, documents); see SOUL.md
OPEN_MAX = 3  # notes and files opened after one request, together
FOLLOW_UP_S = 10.0  # s after an answer when you can reply without saying "robo"
DRAG = 6  # px of movement that turns a click on the face into a drag
FIDGETS = ("curious", "happy", "playful", "calm")  # what a bored robo shows now and then
FIDGET_EVERY = (40.0, 120.0)  # s between those moods while it idles


def open_file(path: Path) -> None:
    """Open a file robo made in the user's default app for it."""
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    subprocess.Popen([opener, str(path)], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _screen_rects() -> tuple[Rect, ...]:
    """The usable area (below the menu bar, beside the Dock) of every connected screen."""
    areas = (s.availableGeometry() for s in QGuiApplication.screens())
    return tuple(Rect(a.x(), a.y(), a.width(), a.height()) for a in areas)


def _newest(found: Iterable[Path], started: float) -> list[Path]:
    """The files among `found` written since `started`, newest first, at most OPEN_MAX."""
    try:
        files = [f for f in found if f.is_file() and f.stat().st_mtime >= started]
        return sorted(files, key=lambda f: f.stat().st_mtime, reverse=True)[:OPEN_MAX]
    except OSError:
        return []


def _made_since(started: float) -> list[Path]:
    """Files in OUTPUT_DIR written during this request, newest first."""
    return _newest(OUTPUT_DIR.rglob("*"), started)


def _notes_since(started: float) -> list[Path]:
    """Obsidian notes (.md in the vault's Drafts, Plans, Notes) written during this request."""
    return _newest((n for folder in FOLDERS for n in (VAULT / folder).rglob("*.md")), started)


def _online() -> bool:
    """The internet is back after a wake (the first site the digest reads answers on 443)."""
    try:
        socket.create_connection(("outlook.office.com", 443), timeout=3).close()
        return True
    except OSError:
        return False


class _Bridge(QObject):
    event = Signal(object)  # Hermes events, from the worker thread
    heard = Signal(str)  # a transcribed voice command, from the listener thread
    note = Signal(str)  # a listener problem worth showing once
    link = Signal(str)  # the Hermes gateway's health: "ok", "warn" or "bad" (robo.health)


class RoboWindow(QWidget):
    resumed = Signal()  # the machine woke up (emitted from the wake watcher's thread)

    def __init__(self, client, clock: DigestClock, *, today: Callable[[], date] = date.today,
                 network: Callable[[], bool] | None = None, watch_wake: bool = True,
                 persona: str = "", floating: bool = False, listener=None, watcher=None,
                 health: str = ""):
        super().__init__()
        self.client, self.clock, self.today, self.persona = client, clock, today, persona
        self.network = network or _online
        self.floating = floating
        self.watcher_ = watcher  # activity watching (robo.activity.Watcher)
        self.theme = themes.load()
        self.theme_stamp = themes.stamp()  # theme.json as read (a hand edit shows at the menu)
        self.session_id = ""
        self.mind = minds.initial(time.monotonic())
        self.busy = False
        self.digest_day: date | None = None  # the day a running digest counts for
        self.auto_digest = False  # that digest started by itself (start-up, wake), not from 📚
        self.reply = ""
        self.lock = threading.Lock()  # run_id/cancel are shared with the worker thread
        self.run_id: str | None = None
        self.cancel = False
        self.pending = ""  # a question asked during a run, asked when it ends
        self.started_at = 0.0  # when the current request began (files made since then open)
        self.listening = False
        self.close_at = 0.0  # when the finished reply's bubble closes (0 = not scheduled)
        self.close_after = 0.0  # s the bubble stays once the reply is typed (0 = until closed)
        self.tw = Typewriter(Pace(cps=self.theme.cps))  # how much of the reply is on screen
        self.typed = False  # the reply is all on screen (the footer showed, the close timer ran)
        self.last_tick = self.last_char = self.typed_at = -math.inf  # when the typing last ran,
        self.mouth = False  # a letter showed, finished; the mouth moves (tw.revealing, last seen)
        self.skip_at: QPoint | None = None  # a press on the reply, until its release
        self.answered_at = -math.inf  # when the last answer ended (the next question follows up)
        self.link, self.noted = "unknown", False  # Hermes LED; the listener reported a problem
        self.press: QPoint | None = None  # global position of a mouse press on the face
        self.moving = False  # the compositor is dragging robo (startSystemMove)
        self.cursor, self.cursor_moved = QPoint(), -math.inf  # the pointer, and when it last moved
        self.fidget_at = time.monotonic() + random.uniform(*FIDGET_EVERY)
        self.drag_end = QTimer(self, singleShot=True, interval=600, timeout=self._drag_done)
        self.bridge = _Bridge()
        self.bridge.event.connect(self._on_event)
        self.bridge.heard.connect(self._on_heard)
        self.bridge.note.connect(self._on_note)
        self.bridge.link.connect(self._on_link)
        self.resumed.connect(self._maybe_digest)
        self.poller = HealthPoller(health, self.bridge.link.emit) if health else None
        self.roamer: Roamer | None = None
        self._build()
        if floating:
            self.roamer = Roamer(_screen_rects(), (self.width(), self.height()))
            self.move(*map(int, self.roamer.pos))
            QTimer(self, interval=33, timeout=self._roam).start()
            gui = QGuiApplication.instance()
            gui.screenAdded.connect(self._screen_added)
            for screen in QGuiApplication.screens():
                screen.availableGeometryChanged.connect(self._screens_changed)
            for signal in (gui.screenRemoved, gui.primaryScreenChanged):
                signal.connect(self._screens_changed)
        self.ticker = QTimer(self, interval=100, timeout=self._tick)
        self.ticker.start()
        self.watcher = WakeWatcher(self.resumed.emit) if watch_wake else None
        if self.watcher:
            self.watcher.start()
        if watcher:
            watcher.pause(WATCH_PAUSED.exists())
            watcher.start()
        self.listener = listener(self._wake, self.bridge.heard.emit, self.bridge.note.emit) \
            if listener else None
        if self.listener and not self.listener.start():
            self.listener = None
        if self.poller:
            self.poller.start()
        QTimer.singleShot(0, self._maybe_digest)

    def _build(self) -> None:
        t = self.theme
        self.setWindowTitle("Robo")
        self.setStyleSheet(hud.qss(t))
        self.look = hud.md_look(t)
        if self.floating:
            self.setWindowFlags(Qt.WindowType.FramelessWindowHint
                                | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
            self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
            # macOS hides Tool windows whenever robo is not the active app; a pet stays out.
            self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)
        self.panel = hud.Card(t)  # paints its own frame; everything lays out in panel.inner
        self.quote = hud.Quote(t)  # what you said, in full: label, bar, "↳ FOLLOW-UP", the text
        self.heard = self.quote.text
        self.status = hud.MicroLabel("", t, px=11, spacing=0.2, bold=False)
        self.typing = TypingDots(theme=t)
        self.status_row = QWidget()  # takes room only while the dots or the label show (_show)
        row_layout = QHBoxLayout(self.status_row)
        row_layout.setContentsMargins(0, 0, 0, 0)
        row_layout.setSpacing(8)
        row_layout.addWidget(self.typing)
        row_layout.addWidget(self.status)
        row_layout.addStretch(1)  # the dots sit at the left, like a chat bubble
        self.status_row.hide()
        self.bubble = QTextBrowser(objectName="reply", openExternalLinks=True)
        self.bubble.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.bubble.document().setDocumentMargin(0)
        self.bubble.viewport().installEventFilter(self)  # a click on the reply skips the typing
        self.caret = hud.Caret(self.bubble.viewport(), t)  # at the end of the letters shown
        # Resize after the document finished laying out (resizing inside its signal re-enters
        # the text layout and aborts); one timer also coalesces a burst of streamed deltas.
        self.sizer = QTimer(self, singleShot=True, interval=0, timeout=self._size_text)
        self.bubble.document().contentsChanged.connect(self.sizer.start)
        self.heard.document().contentsChanged.connect(self.sizer.start)
        self.revealer = QTimer(self, interval=round(TYPE_S * 1000), timeout=self._reveal)
        self.footer = QLabel("", objectName="footer", wordWrap=True)  # notes and files opened
        self.footer.setTextFormat(Qt.TextFormat.PlainText)
        self.footer.hide()
        self.approval_label = hud.MicroLabel("APPROVAL ▸", t, tone="warn")
        self.approval_text = QLabel(wordWrap=True, objectName="well")
        self.approval_text.setTextFormat(Qt.TextFormat.PlainText)  # a command is not markup
        self.allow = QPushButton("Allow", objectName="allow")  # the accent; Deny is the quiet one
        self.deny = QPushButton("Deny", objectName="deny")
        self.allow.clicked.connect(lambda: self._approve("once"))
        self.deny.clicked.connect(lambda: self._approve("deny"))
        self.approval = QWidget()
        box = QVBoxLayout(self.approval)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(6)
        box.addWidget(self.approval_label)
        box.addWidget(self.approval_text)
        row = QHBoxLayout()
        row.setSpacing(8)
        for button in (self.allow, self.deny):
            row.addWidget(button)
        box.addLayout(row)
        self.approval.hide()
        self.menu = QWidget()  # right-click: robo's menu inside its bubble (a popup menu needs
        menu = QGridLayout(self.menu)  # a pointer grab XWayland refuses a Tool window)
        menu.setContentsMargins(0, 0, 0, 0)
        menu.setSpacing(6)

        def action(label: str, fn: Callable[[], None]) -> QPushButton:
            button = QPushButton(label)
            button.clicked.connect(lambda: (self._hide_menu(), fn()))
            return button

        self.stay = action("📌 Stay", self._toggle_stay)  # both change with the state (_show_menu)
        self.watch = action("⏸ Watch", self._toggle_watch)
        self.themer = QPushButton("🎨 Theme")  # opens the swatches; the menu stays up
        self.themer.clicked.connect(self._toggle_picker)
        # Six columns: 3 + 3 chips, each 2 wide; without a watcher Theme and Quit take 3 each.
        top = (action("📚 Digest", lambda: self.ask(DIGEST_PROMPT)), action("💬 Type", self._type),
               self.stay)
        low = (self.watch, self.themer, action("✕ Quit", self.close))
        if not self.watcher_:
            self.watch.setParent(self.menu)  # never shown (_show_menu), so not in the grid
            low = low[1:]
        for i, button in enumerate(top):
            menu.addWidget(button, 0, 2 * i, 1, 2)
        for i, button in enumerate(low):
            menu.addWidget(button, 1, 6 // len(low) * i, 1, 6 // len(low))
        for column in range(6):
            menu.setColumnStretch(column, 1)
        self.menu.hide()
        self.picker = hud.Picker(t.key, t)  # a sibling of the menu: its own grid of swatches
        self.picker.picked.connect(self._pick_theme)
        self.picker.hide()
        self.input = QLineEdit(placeholderText="▸ Type and press Enter")
        self.input.returnPressed.connect(self.send)
        self.input.setVisible(not self.floating)  # floating: voice, or "Type a message…"
        for w in (self.menu, self.picker, self.quote, self.status_row, self.bubble, self.footer,
                  self.approval, self.input):
            self.panel.inner.addWidget(w)
        self.face = FaceWidget(self, radius=22 if self.floating else 0)
        self.face.setFixedSize(*FACE) if self.floating else self.face.setMinimumHeight(220)
        self.face.set_theme(functools.partial(themes.hue_for, t), t.face_bg, snap=True)
        self.face.installEventFilter(self)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, activated=self._escape)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(*(4,) * 4 if self.floating else (9,) * 4)
        layout.setSpacing(3)
        layout.addWidget(self.panel, 0, Qt.AlignmentFlag.AlignHCenter)
        layout.addWidget(self.face, 0, Qt.AlignmentFlag.AlignHCenter)
        if self.floating:
            self._size_text()  # empty boxes take no room (else the menu opens two 192 px bands)
            self._fit(self.panel.hide)
        else:
            self.resize(380, 560)

    # --- talking to Hermes ---------------------------------------------------------------

    def send(self) -> None:
        text = self.input.text().strip()
        if text and not self.busy:
            self.input.clear()
            self.ask(text)

    def ask(self, text: str, *, wait_network: bool = False) -> None:
        """Start one run; while another is in flight, stop it and ask this one after it."""
        if self.busy:
            self.pending = text
            self.stop()
            return
        day = self.today()
        self.busy, self.reply, self.run_id, self.cancel = True, "", None, False
        # One Hermes session per day and persona version (see setup.persona_stamp).
        self.session_id = "-".join(filter(None, ("robo", day.isoformat(), self.persona)))
        self.digest_day = day if text == DIGEST_PROMPT else None
        self.auto_digest = wait_network and self.digest_day is not None
        self.started_at = time.time()  # files robo makes from now on are opened when it's done
        shown = bool(self.tw.text) and not self.panel.isHidden()  # an answer is still up, or just
        follow = shown or time.monotonic() - self.answered_at < FOLLOW_UP_S  # was: follows it up
        self._set_heard("" if self.digest_day else text, follow)
        self._clear_reply()
        self._on_event(UserSent(text))
        threading.Thread(target=self._work, args=(text, wait_network), daemon=True).start()

    def _work(self, text: str, wait_network: bool) -> None:
        emit = self.bridge.event.emit
        try:
            if wait_network and not wait_for_network(lambda: self.cancel or self.network()):
                emit(RunEnded("failed", error="I can't reach the internet yet."))
                return
            if self.cancel:
                emit(RunEnded("cancelled"))
                return
            for ev in self.client.ask(text, self.session_id, started=self._started):
                emit(ev)
        except BrainError as e:
            if self.poller:
                self.poller.poke()  # is the gateway down? the LED says so within a second
            emit(RunEnded("failed", error=str(e)))
        except Exception as e:  # never leave the window stuck "busy"
            emit(RunEnded("failed", error=f"Something went wrong: {e}"))

    def _started(self, run_id: str) -> None:
        """Worker thread: the run exists now; stop it at once if a stop came first."""
        with self.lock:
            self.run_id, cancel = run_id, self.cancel
        if cancel:
            with contextlib.suppress(BrainError):
                self.client.stop(run_id)

    def stop(self) -> None:
        with self.lock:
            if not self.busy:
                return
            self.cancel, run_id = True, self.run_id
        if run_id:
            self._background(self.client.stop, run_id)

    def _approve(self, choice: str) -> None:
        self._fit(self.approval.hide)
        if self.run_id:
            self._background(self.client.approve, self.run_id, choice)

    def _background(self, fn, *args) -> None:
        def call():
            with contextlib.suppress(BrainError):  # the run's own stream reports what happened
                fn(*args)
        threading.Thread(target=call, daemon=True).start()

    # --- voice ---------------------------------------------------------------------------

    def _wake(self) -> None:
        """Listener thread: robo was called by name - it listens."""
        self.bridge.event.emit(Listening(True))

    def _on_heard(self, text: str) -> None:
        self._on_event(Listening(False))
        if text.strip():
            self.ask(text.strip())
        elif not self.busy:
            self._say("Sorry, I didn't catch that.")

    def _on_note(self, text: str) -> None:
        self.noted = True  # the MIC light shows it until robo listens again
        self._on_event(Listening(False))
        self._say(text)

    def _on_link(self, state: str) -> None:
        self.link = state
        self._show()

    def _say(self, text: str) -> None:
        """Show a short local message (no model involved), typed like an answer. During a run
        it is not the end of the reply: Hermes goes on and RunEnded finishes it."""
        self._set_heard("")
        self._clear_reply()
        self._feed(text, end=not self.busy)
        self._open(close_after=8.0)

    # --- UI thread -----------------------------------------------------------------------

    def _on_event(self, ev: Event) -> None:
        self.mind = minds.react(self.mind, ev, time.monotonic())
        match ev:
            case Listening(on=True):
                self.stop()  # speaking over robo interrupts its answer
                self.noted = False
                self._set_heard("")
                self._clear_reply()
                self._open()
            case UserSent():
                self._open()
            case Delta(text=t):
                self.reply += t
                self._feed(self.reply)
            case ApprovalNeeded(desktop=True):
                # The user lets robo drive the desktop freely ("all but irreversible"); "session"
                # covers that kind of desktop step for the rest of this request only.
                self._background(self.client.approve, self.run_id, "session")
                self._show()
                return
            case ApprovalNeeded(description=d):
                d = d if len(d) <= APPROVAL_MAX else d[:APPROVAL_MAX - 1] + "…"
                self.approval_text.setText(d)
                self._fit(self.approval.show)  # room for the buttons: the window grows
                self._open()
            case RunEnded(status=status, output=out, error=err):
                with self.lock:
                    self.busy, self.run_id = False, None
                self._fit(self.approval.hide)
                text = out or self.reply if status == "completed" else err or f"Run {status}."
                if self.listening:  # interrupted by the user speaking: keep listening
                    self.mind = minds.react(self.mind, Listening(True), time.monotonic())
                if self.digest_day and status == "completed":
                    self.clock.mark(self.digest_day)
                if status == "completed":
                    self.answered_at = time.monotonic()
                lines = []
                if status == "completed" and not self.listening:
                    notes = _notes_since(self.started_at)
                    files = _made_since(self.started_at)[:OPEN_MAX - len(notes)]
                    for n in notes:  # the automatic digest opens behind what you are doing
                        with contextlib.suppress(OSError):
                            open_note(n, front=not self.auto_digest)
                    for f in files:
                        with contextlib.suppress(OSError):
                            open_file(f)
                    if notes:
                        lines.append(f"📓 In Obsidian: {', '.join(n.stem for n in notes)}")
                    if files:
                        lines.append(f"📂 Opened {', '.join(f.name for f in files)}")
                if not self.listening and not self.pending:
                    self.footer.setText("\n".join(lines))  # shown when the typing is done
                    self._feed(text, end=True)
                if self.listener and status == "completed" and not self.pending:
                    self.listener.follow_up(FOLLOW_UP_S)  # a reply needs no "robo"
                self.digest_day = None
                self._open(close_after=0.0 if self.listening else CLOSE_AFTER)
                if self.pending:
                    text, self.pending = self.pending, ""
                    QTimer.singleShot(0, lambda: self.ask(text))
        self.listening = self.mind.activity == "listening"
        self._show()

    def _tick(self) -> None:
        now = time.monotonic()
        self.mind = minds.tick(self.mind, now)
        if self.close_at and now >= self.close_at and not self.busy:
            if self.panel.underMouse():
                self.close_at = now + 5
            else:
                self._close_bubble()
        self._alive(now)
        self._show()

    def _alive(self, now: float) -> None:
        """Pet behaviour: the eyes follow the pointer while it moves (else lead the walk), and
        an idle robo now and then shows a mood."""
        here = QCursor.pos()
        if here != self.cursor:
            self.cursor, self.cursor_moved = here, now
        c = self.face.mapToGlobal(self.face.rect().center())
        self.face.set_look(look_at((c.x(), c.y()), (here.x(), here.y()), now - self.cursor_moved,
                                   self.roamer.heading if self.roamer else 0))
        if now >= self.fidget_at:
            self.fidget_at = now + random.uniform(*FIDGET_EVERY)
            if self.mind.activity == "idle" and not self.busy and self.panel.isHidden():
                self.mind = minds.react(self.mind, Feeling(random.choice(FIDGETS)), now)

    def _show(self) -> None:
        m, tw, now = self.mind, self.tw, time.monotonic()
        # The mouth follows the letters appearing, not the stream: while some are still due the
        # face keeps talking (the mind goes idle at RunEnded), but an error keeps its sad face.
        typing = tw.pending
        activity = "talking" if typing and m.activity in ("idle", "talking") else m.activity
        self.face.set_state(activity, m.emotion, tw.revealing if typing else m.talking)
        self.panel.set_hue(themes.live_hue(self.theme, self.face.params.hue, m.activity))
        mic = hud.mic_state(self.listener, m.activity, self.noted)
        self.panel.header.set_status(self.link, mic)
        self.panel.header.set_phase(now)
        self._caret(now)
        listening = m.activity == "listening"
        thinking = self.busy and not self.reply and not listening
        label = "listening" if listening else m.label if thinking else ""
        self.status.setText(label)  # e.g. "searching the web…" beside the dots
        shown = (thinking, bool(label))  # the typing dots, the label
        if shown != (self.typing.isVisibleTo(self), self.status.isVisibleTo(self)):
            def apply() -> None:
                self.typing.setVisible(shown[0])
                self.status.setVisible(shown[1])
                self.status_row.setVisible(any(shown))
            self._fit(apply)

    def _caret(self, now: float) -> None:
        """Shown while the reply types and for CARET_S after: solid just after a letter, else
        blinking (waiting for Hermes, or in a pause)."""
        tw = self.tw
        show = bool(tw.text) and not tw.instant and (not tw.done or now < self.typed_at + CARET_S)
        if self.caret.isHidden() == show:
            self.caret.setVisible(show)
        if show:
            blink = int(now * 1000 / self.theme.caret_ms) % 2 == 0
            self.caret.set_on(now - self.last_char < SOLID_S or blink)

    # --- the reply: typed letter by letter ------------------------------------------------

    def _set_heard(self, text: str, follow_up: bool = False) -> None:
        """What you said, above the answer (hidden when there is none, as for the digest)."""
        self.heard.setPlainText(text)
        self.quote.tag.setVisible(follow_up and bool(text))
        if not self.floating:  # floating: _size_text shows it together with its height
            self.quote.setVisible(bool(text))

    def _clear_reply(self) -> None:
        """A new exchange: nothing of the last reply stays (text, typing, caret, footer, timer)."""
        self.tw.reset()
        self.revealer.stop()
        self.typed, self.mouth, self.close_at = False, False, 0.0
        self.bubble.clear()
        self.caret.hide()
        self.footer.setText("")
        if not self.footer.isHidden():
            self._fit(self.footer.hide)

    def _feed(self, text: str, end: bool = False) -> None:
        """Hand the typewriter the reply so far (`end`: that is all of it, as Hermes finished)."""
        self.tw.end(text) if end else self.tw.feed(text)
        self._resume()

    def _resume(self) -> None:
        """Start typing if letters are due; else everything is there: show it and finish."""
        tw = self.tw
        if tw.pending:
            self.close_at = 0.0  # a reply is never closed under the reader
            if not self.revealer.isActive():
                self.last_tick = time.monotonic() - TYPE_S
                self.revealer.start()
                self._reveal()  # the first letters now, not a step later
        else:
            self._render()
            self._settle()

    def _reveal(self) -> None:
        """One typing step: the letters due, the mouth, and the end."""
        now, tw = time.monotonic(), self.tw
        dt, self.last_tick = min(now - self.last_tick, 0.1), now
        if tw.advance(dt):
            self.last_char = now
            self._render()
        if tw.revealing != self.mouth:
            self.mouth = tw.revealing
            self._show()
        self._settle()

    def _settle(self) -> None:
        """Nothing is due any more: stop the steps; when Hermes is done too, the reply is typed."""
        if not self.tw.pending:
            self.revealer.stop()
            if self.tw.done and not self.typed:
                self._typed()

    def _typed(self) -> None:
        """The reply is all on screen: show the footer and let the bubble close in a while."""
        self.typed, self.typed_at = True, time.monotonic()
        if self.footer.text() and self.footer.isHidden():
            self._fit(self.footer.show)
        if self.close_after and not self.busy:
            self.close_at = self.typed_at + self.close_after
        self._show()

    def _render(self) -> None:
        """Put the typewriter's view into the bubble: the Markdown of the prefix, its last word
        laid out but invisible (so a word that will not fit the line wraps before it appears),
        the box sized, scrolled to the end if it was, and the caret at the last letter."""
        bar, doc = self.bubble.verticalScrollBar(), self.bubble.document()
        md, hidden = self.tw.view()
        keep = bar.value()
        at_end = keep >= bar.maximum() - 4  # not scrolled up by the reader
        self.bubble.setMarkdown(md)  # which resets the bar to the top
        style_markdown(doc, self.look)
        end = doc.characterCount() - 1
        if hidden:
            clear = QTextCharFormat()
            clear.setForeground(QColor(0, 0, 0, 0))
            clear.setBackground(QColor(0, 0, 0, 0))
            cursor = QTextCursor(doc)
            cursor.setPosition(max(0, end - hidden))
            cursor.setPosition(end, QTextCursor.MoveMode.KeepAnchor)
            cursor.mergeCharFormat(clear)
        self._size_text()
        bar.setValue(bar.maximum() if at_end else keep)
        cursor = QTextCursor(doc)
        cursor.setPosition(max(0, end - hidden))
        self.caret.place(self.bubble.cursorRect(cursor))

    def _skip(self) -> None:
        """Show the whole reply now, and whatever still arrives (click on the reply, Esc)."""
        if self.tw.text and not self.tw.done and not self.tw.skipped:
            self.tw.skip()
            self._resume()

    def _size_text(self) -> None:
        """Your question and the reply are as tall as their text, up to a cap, then scroll."""
        if not self.floating:
            return
        shell = {self.heard: self.quote, self.bubble: self.bubble}  # what shows or hides with it
        wanted = {box: _text_height(box, cap) for box, cap in ((self.heard, HEARD_PX),
                                                                (self.bubble, TEXT_MAX))}
        if any(h != box.height() or shell[box].isHidden() != (h == 0) for box, h in wanted.items()):
            fresh = any(h and shell[box].isHidden() for box, h in wanted.items())

            def resize() -> None:
                for box, h in wanted.items():
                    box.setFixedHeight(h)
                    shell[box].setVisible(h > 0)
            self._fit(resize)
            if fresh:  # a hidden box had no real width when measured: measure again, laid out
                self.sizer.start()

    def _open(self, close_after: float = 0.0) -> None:
        """Show the bubble; it closes `close_after` s after the reply is typed (0: stays)."""
        self.close_after = close_after
        armed = close_after and not self.tw.pending  # while it types, _typed arms the timer
        self.close_at = time.monotonic() + close_after if armed else 0.0
        if self.panel.isHidden():
            self._fit(self.panel.show)

    def _close_bubble(self) -> None:
        self.close_at = 0.0
        self.menu.hide()
        self.picker.hide()
        if self.floating and not self.panel.isHidden():
            self._fit(self.panel.hide)

    def _fit(self, change: Callable[[], None]) -> None:
        """Apply `change` (show/hide the bubble) and resize, keeping the face where it is."""
        face = self.pos() + self.face.pos()  # before `change`: Qt moves the face at once
        change()
        if not self.floating:
            return
        self.panel.layout().activate()
        self.layout().activate()
        self.setFixedSize(self.layout().totalSizeHint())
        self.layout().setGeometry(self.rect())  # place the children now, not at the next event
        if self.roamer:
            self.roamer.resize((self.width(), self.height()))
            self.roamer.pos = (face.x() - self.face.x(), face.y() - self.face.y())
            self.roamer.resize((self.width(), self.height()))  # and keep it on screen
            self.move(*map(int, self.roamer.pos))

    def _screen_added(self, screen) -> None:
        screen.availableGeometryChanged.connect(self._screens_changed)
        self._screens_changed()

    def _screens_changed(self, *_) -> None:
        """A monitor came, went or resized: keep robo on the screens that are left. Looked up
        after the event, because a removed screen is still listed while its signal runs."""
        def refit() -> None:
            rects = _screen_rects()
            if rects:  # none for a moment while a display sleeps: keep the last layout
                self.roamer.set_screens(rects)
        QTimer.singleShot(0, refit)

    def _roam(self) -> None:
        engaged = self.press is not None or self.moving  # the user has it: freeze
        # it walks to a corner and stays; the right-click menu opens the bubble too, but it must
        # not leave before the user can press Stay
        called = self.busy or (not self.panel.isHidden() and self.menu.isHidden())
        x, y = self.roamer.step(time.monotonic(), self.mind.activity, engaged, called)
        if (x, y) != (self.x(), self.y()):
            self.move(x, y)

    def eventFilter(self, obj, ev) -> bool:  # noqa: N802 - Qt override
        """Face: click = listen (or open the bubble), drag = move robo and leave it there.
        Reply: click = show the rest of the typing now."""
        if obj is self.bubble.viewport():
            return self._skip_click(ev)
        if obj is not self.face:
            return False
        kind = ev.type()
        button = getattr(ev, "button", lambda: None)()
        left = button == Qt.MouseButton.LeftButton
        if kind == ev.Type.MouseButtonPress and button == Qt.MouseButton.RightButton:
            self._show_menu()
        elif kind == ev.Type.MouseButtonPress and left:
            self.moving = False  # any earlier compositor drag is over
            self.press, self.dragged = ev.globalPosition().toPoint(), False
            self.grab_at = self.press - self.pos()
        elif kind == ev.Type.MouseMove and self.press is not None:
            here = ev.globalPosition().toPoint()
            if self.dragged or (here - self.press).manhattanLength() > DRAG:
                self.dragged = True
                if self.floating and self._system_move():
                    self.press, self.moving = None, True  # Mutter moves it; see moveEvent
                    self.drag_end.start()
                elif self.floating:
                    to = here - self.grab_at
                    self.move(to)
                    if self.roamer:  # else the roam tick pulls it back to where it was
                        self.roamer.hold(time.monotonic(), (to.x(), to.y()))
        elif kind == ev.Type.MouseButtonRelease and left and self.press is not None:
            if self.dragged and self.roamer:
                self.roamer.hold(time.monotonic(), (self.x(), self.y()))
            elif not self.dragged:
                self._clicked()
            self.press = None
        else:
            return False
        return True

    def _skip_click(self, ev) -> bool:
        """A click (press and release close together) on the reply, not on a link, skips the
        typing. Never takes the event: links and selecting text work as always."""
        kind, left = ev.type(), getattr(ev, "button", lambda: None)() == Qt.MouseButton.LeftButton
        if kind == ev.Type.MouseButtonPress and left:
            self.skip_at = ev.position().toPoint()
        elif kind == ev.Type.MouseButtonRelease and left and self.skip_at is not None:
            here, start, self.skip_at = ev.position().toPoint(), self.skip_at, None
            if ((here - start).manhattanLength() < SKIP_PX and not self.bubble.anchorAt(here)
                    and not self.bubble.textCursor().hasSelection()):
                self._skip()
        return False

    def _system_move(self) -> bool:
        """Let the compositor drag the window (XWayland ignores client moves mid-drag)."""
        handle = self.windowHandle()
        return bool(handle and handle.startSystemMove())

    def moveEvent(self, event) -> None:  # noqa: N802 - Qt override
        if self.moving and self.roamer:
            self.roamer.hold(time.monotonic(), (self.x(), self.y()))
            self.drag_end.start()  # the drag is over once the moves stop for a moment
        super().moveEvent(event)

    def _drag_done(self) -> None:
        self.moving = False

    def _show_menu(self) -> None:
        if themes.stamp() != self.theme_stamp:  # theme.json was edited by hand: show it now
            self.theme_stamp = themes.stamp()
            self.apply_theme(themes.load())
        self.stay.setText(
            "🧭 Wander" if self.roamer and self.roamer.stays(time.monotonic()) else "📌 Stay")
        self.watch.setText("▶ Watch" if self.watcher_ and self.watcher_.paused else "⏸ Watch")
        self.watch.setVisible(bool(self.watcher_))
        self._fit(self.menu.show)
        self._open(close_after=8.0)

    def _hide_menu(self) -> None:
        if not self.menu.isHidden():
            self._fit(lambda: (self.menu.hide(), self.picker.hide()))

    def _toggle_picker(self) -> None:
        self._fit(lambda: self.picker.setVisible(self.picker.isHidden()))
        self._open(close_after=8.0)

    def _pick_theme(self, key: str) -> None:
        """A swatch was clicked: switch now, and remember it (a file we cannot write still
        leaves the new look on for this run)."""
        self.apply_theme(themes.load(choice=key))
        themes.save_choice(key)
        self.theme_stamp = themes.stamp()
        self._open(close_after=8.0)

    def apply_theme(self, t: themes.Theme) -> None:
        """Switch the look live, nothing restarts: style sheet, Markdown look, face colours,
        card, typing speed, sizes."""
        self.theme = t
        self.setStyleSheet(hud.qss(t))
        self.look = hud.md_look(t)
        self.face.set_theme(functools.partial(themes.hue_for, t), t.face_bg)
        self.panel.set_theme(t)  # restyles the header, quote, labels, dots and caret too
        self.panel.set_hue(themes.live_hue(t, self.face.params.hue, self.mind.activity))
        self.picker.set_current(t.key)
        self.tw.set_pace(replace(self.tw.pace, cps=t.cps))
        self._render()  # the reply in the new look
        self._resume()  # a faster speed may be done, a slower one starts again
        self._fit(lambda: None)  # fonts and gaps changed every height

    def _clicked(self) -> None:
        if not self.busy and not self.panel.isHidden() and self.close_at:
            self._close_bubble()
        elif self.listener and self.listener.running:  # a dead one must not leave robo "listening"
            self.listener.listen_now()
            self._on_event(Listening(True))  # show it at once (and interrupt an answer)
        elif self.busy:
            self.stop()
        else:
            self._type()

    def _type(self) -> None:
        """A small window of its own: XWayland never focuses robo's Tool window."""
        self.typer = QInputDialog(None, Qt.WindowType.WindowStaysOnTopHint)
        self.typer.setScreen(self.screen())  # beside robo, not on the primary screen
        self.typer.setWindowTitle("Ask robo")
        self.typer.setLabelText("Ask robo:")
        self.typer.setStyleSheet(f"QWidget {{ background: {self.theme.bg_top}; "
                                 f"color: {self.theme.text}; }}")
        self.typer.textValueSelected.connect(lambda text: text.strip() and self.ask(text.strip()))
        self.typer.show()
        self.typer.raise_()
        self.typer.activateWindow()

    def _toggle_watch(self) -> None:
        """Pause or resume activity watching; the choice survives a restart."""
        if not self.watcher_:
            return
        paused = not self.watcher_.paused
        self.watcher_.pause(paused)
        with contextlib.suppress(OSError):
            WATCH_PAUSED.parent.mkdir(parents=True, exist_ok=True)
            WATCH_PAUSED.touch() if paused else WATCH_PAUSED.unlink(missing_ok=True)

    def _toggle_stay(self) -> None:
        if not self.roamer:
            return
        stay = self.roamer.stays(time.monotonic())
        self.roamer.hold(time.monotonic(), (self.x(), self.y()), seconds=0 if stay else 10**9)

    def _escape(self) -> None:
        if self.busy:
            self.stop()
        elif self.tw.pending:
            self._skip()  # first Esc shows the rest, the next one closes
        else:
            self._close_bubble()

    def _maybe_digest(self) -> None:
        if self.clock.due(self.today()) and not self.busy:
            self.ask(DIGEST_PROMPT, wait_network=True)

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt override
        """Never leave a run (maybe acting on the laptop) going with nobody watching."""
        with self.lock:
            busy, self.cancel = self.busy, self.busy
        for _ in range(30 if busy else 0):  # a run being created gets its id within moments
            with self.lock:
                run_id = self.run_id
            if run_id:
                with contextlib.suppress(BrainError):
                    self.client.stop(run_id)
                break
            time.sleep(0.1)
        if self.poller:
            self.poller.stop()
        if self.watcher:
            self.watcher.stop()
        if self.listener:
            self.listener.stop(wait=0.5)
        if self.watcher_:
            self.watcher_.stop()
        super().closeEvent(event)
        QGuiApplication.quit()
