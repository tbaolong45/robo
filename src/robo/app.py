"""The robo window: face on top, reply bubble, input line; Hermes runs in a worker thread."""

from __future__ import annotations

import contextlib
import socket
import threading
import time
from collections.abc import Callable
from datetime import date

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from robo import mind as minds
from robo.brain import BrainError
from robo.events import ApprovalNeeded, Delta, Event, RunEnded, UserSent
from robo.face.widget import FaceWidget
from robo.wake import DigestClock, WakeWatcher, wait_for_network

DIGEST_PROMPT = "Give me my school digest for today (use the school digest skill)."
STYLE = """
QWidget { background: #090d16; color: #d8e6ff; font-size: 14px; }
QTextBrowser, QLineEdit { background: #121a2b; border: 1px solid #1f2b44; border-radius: 10px;
                          padding: 6px; }
QPushButton { background: #1b2640; border: none; border-radius: 8px; padding: 6px 10px; }
QPushButton:hover { background: #26355a; }
QLabel#status { color: #7f93b8; font-size: 12px; }
"""


def _online() -> bool:
    """The internet is back after a wake (the first site the digest reads answers on 443)."""
    try:
        socket.create_connection(("outlook.office.com", 443), timeout=3).close()
        return True
    except OSError:
        return False


class _Bridge(QObject):
    event = Signal(object)  # emitted from worker threads, delivered on the UI thread


class RoboWindow(QWidget):
    resumed = Signal()  # the machine woke up (emitted from the wake watcher's thread)

    def __init__(self, client, clock: DigestClock, *, today: Callable[[], date] = date.today,
                 network: Callable[[], bool] | None = None, watch_wake: bool = True):
        super().__init__()
        self.client, self.clock, self.today = client, clock, today
        self.network = network or _online
        self.session_id = f"robo-{today().isoformat()}"
        self.mind = minds.initial(time.monotonic())
        self.busy = False
        self.digesting = False
        self.reply = ""
        self.bridge = _Bridge()
        self.bridge.event.connect(self._on_event)
        self.resumed.connect(self._maybe_digest)
        self._build()
        self.ticker = QTimer(self, interval=100, timeout=self._tick)
        self.ticker.start()
        self.watcher = WakeWatcher(self.resumed.emit) if watch_wake else None
        if self.watcher:
            self.watcher.start()
        QTimer.singleShot(0, self._maybe_digest)

    def _build(self) -> None:
        self.setWindowTitle("Robo")
        self.setStyleSheet(STYLE)
        self.resize(380, 560)
        self.face = FaceWidget(self)
        self.face.setMinimumHeight(220)
        self.status = QLabel("", objectName="status")
        self.bubble = QTextBrowser(openExternalLinks=True)
        self.bubble.setPlaceholderText("Ask me anything - or press 📚 for today's school digest.")
        self.approval_text = QLabel(wordWrap=True)
        self.allow, self.deny = QPushButton("Allow once"), QPushButton("Deny")
        self.allow.clicked.connect(lambda: self._approve(True))
        self.deny.clicked.connect(lambda: self._approve(False))
        self.approval = QWidget()
        row = QHBoxLayout(self.approval)
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.approval_text, 1)
        row.addWidget(self.allow)
        row.addWidget(self.deny)
        self.approval.hide()
        self.input = QLineEdit(placeholderText="Type and press Enter (Esc stops)")
        self.input.returnPressed.connect(self.send)
        digest = QPushButton("📚", toolTip="Today's school digest")
        digest.clicked.connect(lambda: self.ask(DIGEST_PROMPT))
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, activated=self.stop)
        bottom = QHBoxLayout()
        bottom.addWidget(self.input, 1)
        bottom.addWidget(digest)
        layout = QVBoxLayout(self)
        layout.addWidget(self.face, 3)
        layout.addWidget(self.status)
        layout.addWidget(self.bubble, 2)
        layout.addWidget(self.approval)
        layout.addLayout(bottom)

    # --- talking to Hermes ---------------------------------------------------------------

    def send(self) -> None:
        text = self.input.text().strip()
        if text and not self.busy:
            self.input.clear()
            self.ask(text)

    def ask(self, text: str, *, wait_network: bool = False) -> None:
        """Start one run (ignored while another is in flight)."""
        if self.busy:
            return
        self.busy, self.reply = True, ""
        self.digesting = text == DIGEST_PROMPT
        self._on_event(UserSent(text))
        threading.Thread(target=self._work, args=(text, wait_network), daemon=True).start()

    def _work(self, text: str, wait_network: bool) -> None:
        emit = self.bridge.event.emit
        try:
            if wait_network and not wait_for_network(self.network):
                emit(RunEnded("failed", error="I can't reach Hermes or the network yet."))
                return
            for ev in self.client.ask(text, self.session_id):
                emit(ev)
        except BrainError as e:
            emit(RunEnded("failed", error=str(e)))
        except Exception as e:  # never leave the window stuck "busy"
            emit(RunEnded("failed", error=f"Something went wrong: {e}"))

    def stop(self) -> None:
        if self.busy and self.client.run_id:
            self._background(self.client.stop, self.client.run_id)

    def _approve(self, allow: bool) -> None:
        self.approval.hide()
        if self.client.run_id:
            self._background(self.client.approve, self.client.run_id, allow)

    def _background(self, fn, *args) -> None:
        def call():
            with contextlib.suppress(BrainError):  # the run's own stream reports what happened
                fn(*args)
        threading.Thread(target=call, daemon=True).start()

    # --- UI thread -----------------------------------------------------------------------

    def _on_event(self, ev: Event) -> None:
        self.mind = minds.react(self.mind, ev, time.monotonic())
        match ev:
            case Delta(text=t):
                self.reply += t
                self.bubble.setMarkdown(self.reply)
                self.bubble.moveCursor(self.bubble.textCursor().MoveOperation.End)
            case ApprovalNeeded(description=d):
                self.approval_text.setText(f"Hermes asks to: {d}")
                self.approval.show()
            case RunEnded(status=status, output=out, error=err):
                self.busy = False
                self.approval.hide()
                text = out or self.reply if status == "completed" else err or f"Run {status}."
                self.bubble.setMarkdown(text)
                if self.digesting and status == "completed":
                    self.clock.mark(self.today())
                self.digesting = False
        self._show()

    def _tick(self) -> None:
        self.mind = minds.tick(self.mind, time.monotonic())
        self._show()

    def _show(self) -> None:
        m = self.mind
        self.face.set_state(m.activity, m.emotion, m.talking)
        self.status.setText(m.label)

    def _maybe_digest(self) -> None:
        if self.clock.due(self.today()) and not self.busy:
            self.ask(DIGEST_PROMPT, wait_network=True)

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt override
        if self.watcher:
            self.watcher.stop()
        super().closeEvent(event)
