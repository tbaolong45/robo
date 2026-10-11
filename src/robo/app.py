"""Robo on the desktop: a floating face with a speech bubble; Hermes runs in a worker thread.

Floating mode (X11/XWayland) is a frameless, always-on-top, see-through window that drifts around
the screen edges (robo.roam). Otherwise the same widgets live in an ordinary window.
"""

from __future__ import annotations

import contextlib
import socket
import threading
import time
from collections.abc import Callable
from datetime import date

from PySide6.QtCore import QObject, QPoint, Qt, QTimer, Signal
from PySide6.QtGui import QGuiApplication, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from robo import mind as minds
from robo.brain import BrainError
from robo.events import ApprovalNeeded, Delta, Event, Listening, RunEnded, UserSent
from robo.face.widget import FaceWidget
from robo.roam import Rect, Roamer
from robo.wake import DigestClock, WakeWatcher, wait_for_network

DIGEST_PROMPT = "Give me my school digest for today (use the school digest skill)."
FACE = (128, 96)  # px, the floating face
BUBBLE_W = 340  # px
TEXT_MAX = 300  # px of reply text before the bubble scrolls
HEARD_MAX = 140  # characters of your own question shown above the reply
APPROVAL_MAX = 300  # characters of an approval request (a long command) shown
CLOSE_AFTER = 20.0  # s a finished reply stays up (longer while the mouse is over it)
FOLLOW_UP_S = 10.0  # s after an answer when you can reply without saying "robo"
DRAG = 6  # px of movement that turns a click on the face into a drag
STYLE = """
QWidget { color: #d8e6ff; font-size: 14px; }
QFrame#panel { background: rgba(14, 20, 34, 238); border: 1px solid #2a3a5c; border-radius: 14px; }
QTextBrowser, QLineEdit { background: transparent; border: none; }
QLineEdit { background: #121a2b; border: 1px solid #1f2b44; border-radius: 8px; padding: 5px; }
QPushButton { background: #1b2640; border: none; border-radius: 8px; padding: 5px 10px; }
QPushButton:hover { background: #26355a; }
QLabel#status, QLabel#heard { color: #7f93b8; font-size: 12px; }
QScrollBar:vertical { background: transparent; width: 6px; }
QScrollBar::handle:vertical { background: #2a3a5c; border-radius: 3px; }
QScrollBar::add-line, QScrollBar::sub-line { height: 0; }
"""


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


class RoboWindow(QWidget):
    resumed = Signal()  # the machine woke up (emitted from the wake watcher's thread)

    def __init__(self, client, clock: DigestClock, *, today: Callable[[], date] = date.today,
                 network: Callable[[], bool] | None = None, watch_wake: bool = True,
                 persona: str = "", floating: bool = False, listener=None):
        super().__init__()
        self.client, self.clock, self.today, self.persona = client, clock, today, persona
        self.network = network or _online
        self.floating = floating
        self.session_id = ""
        self.mind = minds.initial(time.monotonic())
        self.busy = False
        self.digest_day: date | None = None  # the day a running digest counts for
        self.reply = ""
        self.lock = threading.Lock()  # run_id/cancel are shared with the worker thread
        self.run_id: str | None = None
        self.cancel = False
        self.pending = ""  # a question asked during a run, asked when it ends
        self.listening = False
        self.close_at = 0.0  # when the finished reply's bubble closes (0 = not scheduled)
        self.press: QPoint | None = None  # global position of a mouse press on the face
        self.moving = False  # the compositor is dragging robo (startSystemMove)
        self.drag_end = QTimer(self, singleShot=True, interval=600, timeout=self._drag_done)
        self.bridge = _Bridge()
        self.bridge.event.connect(self._on_event)
        self.bridge.heard.connect(self._on_heard)
        self.bridge.note.connect(self._on_note)
        self.resumed.connect(self._maybe_digest)
        self.roamer: Roamer | None = None
        self._build()
        if floating:
            area = QGuiApplication.primaryScreen().availableGeometry()
            self.roamer = Roamer(Rect(area.x(), area.y(), area.width(), area.height()),
                                 (self.width(), self.height()))
            self.move(*map(int, self.roamer.pos))
            QTimer(self, interval=33, timeout=self._roam).start()
            QGuiApplication.primaryScreen().availableGeometryChanged.connect(
                lambda g: self.roamer.set_screen(Rect(g.x(), g.y(), g.width(), g.height())))
        self.ticker = QTimer(self, interval=100, timeout=self._tick)
        self.ticker.start()
        self.watcher = WakeWatcher(self.resumed.emit) if watch_wake else None
        if self.watcher:
            self.watcher.start()
        self.listener = listener(self._wake, self.bridge.heard.emit, self.bridge.note.emit) \
            if listener else None
        if self.listener and not self.listener.start():
            self.listener = None
        QTimer.singleShot(0, self._maybe_digest)

    def _build(self) -> None:
        self.setWindowTitle("Robo")
        self.setStyleSheet(STYLE)
        if self.floating:
            self.setWindowFlags(Qt.WindowType.FramelessWindowHint
                                | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
            self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.panel = QFrame(objectName="panel")
        self.panel.setFixedWidth(BUBBLE_W)
        self.heard = QLabel("", objectName="heard", wordWrap=True)
        self.status = QLabel("", objectName="status")
        self.bubble = QTextBrowser(openExternalLinks=True)
        self.bubble.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        # Resize after the document finished laying out (resizing inside its signal re-enters
        # the text layout and aborts); one timer also coalesces a burst of streamed deltas.
        self.sizer = QTimer(self, singleShot=True, interval=0, timeout=self._size_text)
        self.bubble.document().contentsChanged.connect(self.sizer.start)
        self.approval_text = QLabel(wordWrap=True)
        self.allow, self.deny = QPushButton("Allow"), QPushButton("Deny")
        self.allow.clicked.connect(lambda: self._approve("once"))
        self.deny.clicked.connect(lambda: self._approve("deny"))
        self.approval = QWidget()
        box = QVBoxLayout(self.approval)
        box.setContentsMargins(0, 0, 0, 0)
        box.addWidget(self.approval_text)
        row = QHBoxLayout()
        for button in (self.allow, self.deny):
            row.addWidget(button)
        box.addLayout(row)
        self.approval.hide()
        self.menu = QWidget()  # right-click: robo's menu inside its bubble (a popup menu needs
        menu_row = QHBoxLayout(self.menu)  # a pointer grab XWayland refuses a Tool window)
        menu_row.setContentsMargins(0, 0, 0, 0)
        for label, fn in (("📚 Digest", lambda: self.ask(DIGEST_PROMPT)), ("⌨ Type", self._type),
                          ("📌 Stay", self._toggle_stay), ("✕ Quit", self.close)):
            button = QPushButton(label)
            button.clicked.connect(lambda _=False, fn=fn: (self._hide_menu(), fn()))
            menu_row.addWidget(button)
        self.menu.hide()
        self.input = QLineEdit(placeholderText="Type and press Enter")
        self.input.returnPressed.connect(self.send)
        self.input.setVisible(not self.floating)  # floating: voice, or "Type a message…"
        inner = QVBoxLayout(self.panel)
        for w in (self.menu, self.heard, self.status, self.bubble, self.approval, self.input):
            inner.addWidget(w)
        self.face = FaceWidget(self, radius=22 if self.floating else 0)
        self.face.setFixedSize(*FACE) if self.floating else self.face.setMinimumHeight(220)
        self.face.installEventFilter(self)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, activated=self._escape)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(*(4,) * 4 if self.floating else (9,) * 4)
        layout.addWidget(self.panel, 0, Qt.AlignmentFlag.AlignHCenter)
        layout.addWidget(self.face, 0, Qt.AlignmentFlag.AlignHCenter)
        if self.floating:
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
        shown = text if len(text) <= HEARD_MAX else text[:HEARD_MAX - 1] + "…"
        self.heard.setText("" if self.digest_day else f"You: {shown}")
        self.bubble.clear()
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
        self.approval.hide()
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
        self._on_event(Listening(False))
        self._say(text)

    def _say(self, text: str) -> None:
        """Show a short local message (no model involved)."""
        self.heard.setText("")
        self.bubble.setMarkdown(text)
        self._open(close_after=8.0)

    # --- UI thread -----------------------------------------------------------------------

    def _on_event(self, ev: Event) -> None:
        self.mind = minds.react(self.mind, ev, time.monotonic())
        match ev:
            case Listening(on=True):
                self.stop()  # speaking over robo interrupts its answer
                self.heard.setText("")
                self.bubble.clear()
                self._open()
            case UserSent():
                self._open()
            case Delta(text=t):
                self.reply += t
                self.bubble.setMarkdown(self.reply)
                self.bubble.moveCursor(self.bubble.textCursor().MoveOperation.End)
            case ApprovalNeeded(desktop=True):
                # The user lets robo drive the desktop freely ("all but irreversible"); "session"
                # covers that kind of desktop step for the rest of this request only.
                self._background(self.client.approve, self.run_id, "session")
                self._show()
                return
            case ApprovalNeeded(description=d):
                d = d if len(d) <= APPROVAL_MAX else d[:APPROVAL_MAX - 1] + "…"
                self.approval_text.setText(f"Allow? {d}")
                self.approval.show()
                self._open()
            case RunEnded(status=status, output=out, error=err):
                with self.lock:
                    self.busy, self.run_id = False, None
                self.approval.hide()
                text = out or self.reply if status == "completed" else err or f"Run {status}."
                if self.listening:  # interrupted by the user speaking: keep listening
                    self.mind = minds.react(self.mind, Listening(True), time.monotonic())
                elif not self.pending:
                    self.bubble.setMarkdown(text)
                if self.digest_day and status == "completed":
                    self.clock.mark(self.digest_day)
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
        self._show()

    def _show(self) -> None:
        m = self.mind
        self.face.set_state(m.activity, m.emotion, m.talking)
        waiting = self.busy and not self.reply or m.activity == "listening"
        dots = "." * (1 + int(time.monotonic() * 3) % 3) if waiting else ""
        label = m.label.rstrip("…") or ("thinking" if waiting else "")
        self.status.setText(f"{label}{dots}" if label else "")
        self.status.setVisible(bool(self.status.text()))
        self.heard.setVisible(bool(self.heard.text()))

    def _size_text(self) -> None:
        """The reply area is as tall as its text (up to TEXT_MAX, then it scrolls)."""
        if not self.floating:
            return
        doc = self.bubble.document()
        doc.setTextWidth(self.bubble.viewport().width() or BUBBLE_W - 30)
        height = min(int(doc.size().height()) + 12, TEXT_MAX) if not doc.isEmpty() else 0
        if height != self.bubble.height() or self.bubble.isHidden() != (height == 0):
            def resize() -> None:
                self.bubble.setFixedHeight(height)
                self.bubble.setVisible(height > 0)
            self._fit(resize)

    def _open(self, close_after: float = 0.0) -> None:
        self.close_at = time.monotonic() + close_after if close_after else 0.0
        if self.panel.isHidden():
            self._fit(self.panel.show)

    def _close_bubble(self) -> None:
        self.close_at = 0.0
        self.menu.hide()
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

    def _roam(self) -> None:
        engaged = self.busy or not self.panel.isHidden() or self.press is not None
        x, y = self.roamer.step(time.monotonic(), self.mind.activity, engaged)
        if (x, y) != (self.x(), self.y()):
            self.move(x, y)

    def eventFilter(self, obj, ev) -> bool:  # noqa: N802 - Qt override
        """Face: click = listen (or open the bubble), drag = move robo and leave it there."""
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
                    self.move(here - self.grab_at)
        elif kind == ev.Type.MouseButtonRelease and left and self.press is not None:
            if self.dragged and self.roamer:
                self.roamer.hold(time.monotonic(), (self.x(), self.y()))
            elif not self.dragged:
                self._clicked()
            self.press = None
        else:
            return False
        return True

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
        self.menu.findChildren(QPushButton)[2].setText(
            "🚶 Wander" if self.roamer and self.roamer.held_until > time.monotonic() + 3600
            else "📌 Stay")
        self._fit(self.menu.show)
        self._open(close_after=8.0)

    def _hide_menu(self) -> None:
        if not self.menu.isHidden():
            self._fit(self.menu.hide)

    def _clicked(self) -> None:
        if not self.busy and not self.panel.isHidden() and self.close_at:
            self._close_bubble()
        elif self.listener:
            self.listener.listen_now()
            self._on_event(Listening(True))  # show it at once (and interrupt an answer)
        elif self.busy:
            self.stop()
        else:
            self._type()

    def _type(self) -> None:
        """A small window of its own: XWayland never focuses robo's Tool window."""
        self.typer = QInputDialog(None, Qt.WindowType.WindowStaysOnTopHint)
        self.typer.setWindowTitle("Ask robo")
        self.typer.setLabelText("Ask robo:")
        self.typer.setStyleSheet("QWidget { background: #0e1422; color: #d8e6ff; }")
        self.typer.textValueSelected.connect(lambda text: text.strip() and self.ask(text.strip()))
        self.typer.show()
        self.typer.raise_()
        self.typer.activateWindow()

    def _toggle_stay(self) -> None:
        if not self.roamer:
            return
        stay = self.roamer.held_until > time.monotonic() + 3600
        self.roamer.hold(time.monotonic(), (self.x(), self.y()), seconds=0 if stay else 10**9)

    def _escape(self) -> None:
        if self.busy:
            self.stop()
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
        if self.watcher:
            self.watcher.stop()
        if self.listener:
            self.listener.stop(wait=0.5)
        super().closeEvent(event)
        QGuiApplication.quit()
