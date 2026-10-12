"""Robo's look: the stylesheet, the speech bubble's Markdown styling and sizing, the typing dots."""

from __future__ import annotations

import math
import time

from PySide6.QtCore import QPointF, Qt, QTimer
from PySide6.QtGui import (
    QColor,
    QPainter,
    QTextBlock,
    QTextBlockFormat,
    QTextCharFormat,
    QTextCursor,
    QTextDocument,
    QTextFormat,
)
from PySide6.QtWidgets import QTextBrowser, QWidget

BUBBLE_W = 340  # px
STYLE = """
QWidget { color: #d8e6ff; font-size: 14px; }
QFrame#panel { background: rgba(14, 20, 34, 238); border: 1px solid #2a3a5c; border-radius: 14px; }
QTextBrowser, QLineEdit { background: transparent; border: none; }
QLineEdit { background: #121a2b; border: 1px solid #1f2b44; border-radius: 8px; padding: 5px; }
QPushButton { background: #1b2640; border: none; border-radius: 8px; padding: 5px 10px; }
QPushButton:hover { background: #26355a; }
QPushButton#allow { background: #2b62e8; color: #fff; }
QPushButton#allow:hover { background: #3f78ff; }
QPushButton#deny { background: transparent; border: 1px solid #2a3a5c; padding: 4px 9px; }
QPushButton#deny:hover { background: #1b2640; }
QLabel#status, QTextBrowser#heard { color: #7f93b8; font-size: 12px; }
QScrollBar:vertical { background: transparent; width: 6px; }
QScrollBar::handle:vertical { background: #2a3a5c; border-radius: 3px; }
QScrollBar::add-line, QScrollBar::sub-line { height: 0; }
"""

# Markdown in the bubble. Qt's importer leaves paragraphs and lists cramped, code in the text font
# (macOS has no "monospace" family, so Qt falls back to the text font) and links dark blue.
MONO = ["Menlo", "DejaVu Sans Mono", "monospace"]  # macOS, Ubuntu, then whatever fontconfig has
GAP, LIST_GAP, HEADING_GAP = 8, 3, 4  # px below a paragraph / between list items / under a heading
INDENT = 18  # px per list level (Qt's 40 px wastes a sixth of the bubble)


def _mono(fg: str | None = None, bg: str | None = None) -> QTextCharFormat:
    fmt = QTextCharFormat()
    fmt.setFontFamilies(MONO)
    fmt.setProperty(QTextFormat.Property.FontPixelSize, 12)
    if fg:
        fmt.setForeground(QColor(fg))
    if bg:
        fmt.setBackground(QColor(bg))
    return fmt


CODE, INLINE_CODE = _mono(fg="#bccbe8"), _mono(bg="#1b2640")
LINK = QTextCharFormat()
LINK.setForeground(QColor("#7fb2ff"))
LINK.setFontUnderline(True)
CODE_LINE = QTextBlockFormat()
CODE_LINE.setBackground(QColor("#070b14"))  # a hair darker than the panel: the lines form a box
CODE_LINE.setTextIndent(8)  # the box's left padding (a block format has no padding of its own)
CODE_LINE.setNonBreakableLines(False)  # wrap: sideways scrolling in a 340 px bubble is worse


def _is_code(block: QTextBlock) -> bool:
    """One line of a code block: the importer's no-wrap lines, or ours (they have a fill)."""
    fmt = block.blockFormat()
    return fmt.nonBreakableLines() or fmt.background().style() != Qt.BrushStyle.NoBrush


def style_markdown(doc: QTextDocument) -> None:
    """Spacing, code and link colours for a document `setMarkdown` just filled.

    `setDefaultStyleSheet` does not reach Markdown, so the blocks and fragments are edited.
    Every value is absolute: calling it again on a styled document changes nothing.
    """
    cursor = QTextCursor(doc)
    cursor.beginEditBlock()
    doc.setIndentWidth(INDENT)
    block = doc.begin()
    while block.isValid():
        after = block.next()
        first = block.position()
        if _is_code(block):
            line = QTextBlockFormat(CODE_LINE)
            line.setBottomMargin(0 if not after.isValid() or _is_code(after) else GAP)
            cursor.setPosition(first)
            cursor.setPosition(first + block.length() - 1, QTextCursor.MoveMode.KeepAnchor)
            cursor.mergeBlockFormat(line)
            cursor.mergeCharFormat(CODE)
        elif doc.frameAt(first) is doc.rootFrame():  # not a table cell: those stay as they are
            if block.blockFormat().headingLevel():
                gap = HEADING_GAP
            elif block.textList() is not None and after.isValid() and after.textList() is not None:
                gap = LIST_GAP
            else:
                gap = GAP
            spacing = QTextBlockFormat()
            spacing.setTopMargin(0)
            spacing.setBottomMargin(gap if after.isValid() else 0)  # no band under the last block
            cursor.setPosition(first)
            cursor.mergeBlockFormat(spacing)
            it, runs = block.begin(), []
            while not it.atEnd():  # collect first: changing a format splits the fragments
                frag = it.fragment()
                fmt = frag.charFormat()
                if fmt.isAnchor() or fmt.fontFixedPitch():
                    look = LINK if fmt.isAnchor() else INLINE_CODE
                    runs.append((frag.position(), frag.length(), look))
                it += 1
            for pos, length, look in runs:
                cursor.setPosition(pos)
                cursor.setPosition(pos + length, QTextCursor.MoveMode.KeepAnchor)
                cursor.mergeCharFormat(look)
        block = after
    cursor.endEditBlock()


def _text_height(box: QTextBrowser, cap: int) -> int:
    """Height that shows all of `box`'s text, at most `cap` (0 when empty)."""
    doc = box.document()
    if doc.isEmpty():
        return 0
    doc.setTextWidth(box.viewport().width() or BUBBLE_W - 30)
    return min(int(doc.size().height()) + 2, cap)  # the document margins are the padding


class TypingDots(QWidget):
    """Messenger-style "typing" bubble: three dots that hop in turn while robo thinks."""

    HOP = 4.0  # px

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setFixedSize(54, 26)
        self.timer = QTimer(self, interval=33, timeout=self.update)

    @staticmethod
    def offsets(t: float) -> list[float]:
        """Vertical offset of each dot at time `t` (a wave running left to right, 1.2 s)."""
        return [-TypingDots.HOP * max(0.0, math.sin((t / 1.2 - i * 0.15) * 2 * math.pi))
                for i in range(3)]

    def showEvent(self, event) -> None:  # noqa: N802 - Qt override
        self.timer.start()

    def hideEvent(self, event) -> None:  # noqa: N802 - Qt override
        self.timer.stop()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(38, 52, 82))
        p.drawRoundedRect(self.rect().adjusted(0, 0, -1, -1), 13, 13)
        for i, dy in enumerate(self.offsets(time.monotonic())):
            p.setBrush(QColor(170, 190, 225, 150 + int(105 * -dy / self.HOP)))
            p.drawEllipse(QPointF(15 + 12 * i, 13 + dy), 3.5, 3.5)
        p.end()
