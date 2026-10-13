"""Robo's look: fonts, the speech bubble's Markdown styling and sizing, the typing dots.

The card, header and stylesheet that colour all this per theme live in robo.hud; the colours come
from robo.theme. Nothing here may touch a font before a QGuiApplication exists: QFontDatabase
aborts the process then, and this module is imported before the app is built.
"""

from __future__ import annotations

import functools
import math
import time
from dataclasses import dataclass

from PySide6.QtCore import QPointF, Qt, QTimer
from PySide6.QtGui import (
    QColor,
    QFontDatabase,
    QGuiApplication,
    QPainter,
    QTextBlock,
    QTextBlockFormat,
    QTextCharFormat,
    QTextCursor,
    QTextDocument,
    QTextFormat,
)
from PySide6.QtWidgets import QTextBrowser, QWidget

from robo.theme import CYAN, Theme, accent

BUBBLE_W = 340  # px
TEXT_W = BUBBLE_W - 38  # px of reply text inside the card (19 px of glow and padding each side)

# Fonts: the first one that is installed (SF Mono ships with Xcode's tools, Menlo with macOS,
# DejaVu Sans Mono with most Linux desktops). macOS has no "monospace" family: Qt would fall back
# to the text font. MONO (the list for setFontFamilies) is resolved on first use, see __getattr__.
MONO_STACK = ("SF Mono", "Menlo", "DejaVu Sans Mono")
GAP, LIST_GAP, HEADING_GAP = 8, 3, 4  # px below a paragraph / between list items / under a heading
INDENT = 18  # px per list level (Qt's 40 px wastes a sixth of the bubble)
HEAD_PX = {1: 17, 2: 16, 3: 15}  # heading sizes, 14 below (Qt's 2x / 1.5x is too big)


@functools.cache
def _installed_mono() -> str:
    have = set(QFontDatabase.families())
    return next((f for f in MONO_STACK if f in have), MONO_STACK[-1])


def mono_family() -> str:
    """The monospace family to use, looked up once. Until a QGuiApplication exists the font
    database cannot be read, so this answers the Mac name without remembering it."""
    return _installed_mono() if QGuiApplication.instance() else MONO_STACK[1]


def __getattr__(name: str):
    # Module attributes that need the font database, so they are built when first asked for
    # (`from robo.widgets import STYLE` may run before the QApplication exists).
    if name == "MONO":
        return [mono_family(), "monospace"]
    if name == "DEFAULT":
        return default_look()
    if name == "STYLE":  # the Cyan HUD style sheet; RoboWindow now builds its own per theme
        from robo.hud import qss

        return qss(CYAN)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def qcolor(c: tuple[int, int, int, int]) -> QColor:
    """An (r, g, b, a) tuple from robo.theme as a QColor."""
    return QColor(*c)


def mono_format(fg: str | None = None, bg: str | None = None) -> QTextCharFormat:
    fmt = QTextCharFormat()
    fmt.setFontFamilies([mono_family(), "monospace"])
    fmt.setProperty(QTextFormat.Property.FontPixelSize, 12)
    if fg:
        fmt.setForeground(QColor(fg))
    if bg:
        fmt.setBackground(QColor(bg))
    return fmt


@dataclass(frozen=True, eq=False)
class Look:
    """How `style_markdown` dresses a document. `DEFAULT` is the bubble as it always was;
    robo.hud.md_look makes one per theme."""

    code: QTextCharFormat  # the text of a code block
    inline: QTextCharFormat  # `inline code`
    link: QTextCharFormat
    code_line: QTextBlockFormat  # one line of a code block: the lines together form a box
    head: QTextCharFormat | None = None  # None leaves the headings as Qt's importer made them
    line_h: int = 0  # percent of Qt's line spacing, 0 leaves Qt's own
    indent: int = INDENT
    margin: int | None = None  # QTextDocument margin around the text, None leaves Qt's 4 px


def default_look() -> Look:
    return _default_look(mono_family())


@functools.lru_cache(maxsize=1)
def _default_look(mono: str) -> Look:  # `mono` is the key: a look built before the app is stale
    link = QTextCharFormat()
    link.setForeground(QColor("#7fb2ff"))
    link.setFontUnderline(True)
    line = QTextBlockFormat()
    line.setBackground(QColor("#070b14"))  # a hair darker than the panel: the lines form a box
    line.setTextIndent(8)  # the box's left padding (a block format has no padding of its own)
    line.setNonBreakableLines(False)  # wrap: sideways scrolling in a 340 px bubble is worse
    return Look(mono_format(fg="#bccbe8"), mono_format(bg="#1b2640"), link, line)


def _is_code(block: QTextBlock) -> bool:
    """One line of a code block: the importer's no-wrap lines, or ours (they have a fill)."""
    fmt = block.blockFormat()
    return fmt.nonBreakableLines() or fmt.background().style() != Qt.BrushStyle.NoBrush


def style_markdown(doc: QTextDocument, look: Look | None = None) -> None:
    """Spacing, code, link and heading colours for a document `setMarkdown` just filled.

    `setDefaultStyleSheet` does not reach Markdown, so the blocks and fragments are edited.
    Every value is absolute: calling it again on a styled document changes nothing.
    """
    look = look or default_look()
    prop = QTextBlockFormat.LineHeightTypes.ProportionalHeight.value
    cursor = QTextCursor(doc)
    cursor.beginEditBlock()
    doc.setIndentWidth(look.indent)
    if look.margin is not None:
        doc.setDocumentMargin(look.margin)
    block = doc.begin()
    while block.isValid():
        after = block.next()
        first = block.position()
        if _is_code(block):
            line = QTextBlockFormat(look.code_line)
            line.setBottomMargin(0 if not after.isValid() or _is_code(after) else GAP)
            if look.line_h:
                line.setLineHeight(look.line_h - 12, prop)  # 12 px type: tighter than the text
            cursor.setPosition(first)
            cursor.setPosition(first + block.length() - 1, QTextCursor.MoveMode.KeepAnchor)
            cursor.mergeBlockFormat(line)
            cursor.mergeCharFormat(look.code)
        elif doc.frameAt(first) is doc.rootFrame():  # not a table cell: those stay as they are
            level = block.blockFormat().headingLevel()
            if level:
                gap = HEADING_GAP
            elif block.textList() is not None and after.isValid() and after.textList() is not None:
                gap = LIST_GAP
            else:
                gap = GAP
            spacing = QTextBlockFormat()
            spacing.setTopMargin(0)
            spacing.setBottomMargin(gap if after.isValid() else 0)  # no band under the last block
            if look.line_h:
                spacing.setLineHeight(look.line_h, prop)
            cursor.setPosition(first)
            cursor.mergeBlockFormat(spacing)
            it, runs = block.begin(), []
            while not it.atEnd():  # collect first: changing a format splits the fragments
                frag = it.fragment()
                fmt = frag.charFormat()
                if level and look.head:
                    # A merge cannot remove the importer's FontSizeAdjustment, and while that
                    # property exists (even as 0) it overrides any pixel size: replace the format.
                    head = QTextCharFormat(fmt)
                    head.clearProperty(QTextFormat.Property.FontSizeAdjustment)
                    head.merge(look.head)
                    head.setProperty(QTextFormat.Property.FontPixelSize, HEAD_PX.get(level, 14))
                    runs.append((frag.position(), frag.length(), head, True))
                elif fmt.isAnchor() or fmt.fontFixedPitch():
                    runs.append((frag.position(), frag.length(),
                                 look.link if fmt.isAnchor() else look.inline, False))
                it += 1
            for pos, length, fmt, whole in runs:
                cursor.setPosition(pos)
                cursor.setPosition(pos + length, QTextCursor.MoveMode.KeepAnchor)
                cursor.setCharFormat(fmt) if whole else cursor.mergeCharFormat(fmt)
        block = after
    cursor.endEditBlock()


def _text_height(box: QTextBrowser, cap: int) -> int:
    """Height that shows all of `box`'s text, at most `cap` (0 when empty)."""
    doc = box.document()
    if doc.isEmpty():
        return 0
    doc.setTextWidth(box.viewport().width() or TEXT_W)
    return min(int(doc.size().height()) + 2, cap)  # the document margins are the padding


class TypingDots(QWidget):
    """Messenger-style "typing" dots: three dots in the accent colour that hop in turn while
    robo thinks. Painted straight on the card (no pill)."""

    HOP = 4.0  # px

    def __init__(self, parent: QWidget | None = None, theme: Theme = CYAN):
        super().__init__(parent)
        self.theme, self.hue = theme, theme.hue
        self.setFixedSize(32, 16)
        self.timer = QTimer(self, interval=33, timeout=self.update)

    def restyle(self, theme: Theme, hue: float) -> None:
        """Called by the Card when the theme or the live hue changes."""
        self.theme, self.hue = theme, hue
        self.update()

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
        for i, dy in enumerate(self.offsets(time.monotonic())):
            p.setBrush(qcolor(accent(self.theme, self.hue, 0.55 + 0.45 * -dy / self.HOP)))
            p.drawEllipse(QPointF(5 + 11 * i, 10 + dy), 2.8, 2.8)
        p.end()
