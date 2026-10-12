"""The holographic card around Robo's answer and everything painted on it.

One glass card (`Card`) with a tail to the face, a header strip (`Header`: name, two LEDs, model
chip), the user's line as a quote (`Quote`), a typing caret (`Caret`) and the theme picker's
miniatures (`Swatch`, `Picker`). Colours, shapes and effects all come from a `robo.theme.Theme`;
this module holds no colour literal. Every line painted in the accent follows the *live* hue (the
face's current hue, see theme.live_hue), so the card is lit by the face.

The card paints its frame in `paintEvent` under its children (they are transparent), from a
pixmap that is rebuilt only when the size, the theme or the hue (in 2 degree steps) changes.
Widgets that follow the theme have `restyle(theme, hue)`; `Card.set_theme` / `Card.set_hue` call
it on every one in the card's tree. The style sheet (`qss`) uses the RESTING hue, so it is built
once per theme and never re-polished at the face's frame rate.
"""

from __future__ import annotations

import math

from PySide6.QtCore import QPointF, QRect, QRectF, QSize, Qt, Signal
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QFontMetrics,
    QImage,
    QLinearGradient,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QRadialGradient,
    QTextBlockFormat,
    QTextCharFormat,
)
from PySide6.QtWidgets import (
    QAbstractButton,
    QGridLayout,
    QLabel,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from robo.theme import (
    CYAN,
    THEMES,
    Theme,
    accent,
    aura_shift,
    chip_text,
    css,
    label_colour,
    rgba,
)
from robo.widgets import BUBBLE_W, INDENT, Look, mono_family, mono_format, qcolor

GLOW = 6  # px of margin around the frame that the glow may use
HEADER_H = 26  # px, the header strip inside the frame
TAIL_W, TAIL_H = 20, 9  # px, the notch pointing at the face
# The card's single layout: 6 glow + 13 padding at the sides, 6 + 26 header + 10 on top, 9 tail
# + 10 at the bottom. The header is a child that is not in the layout (Card.resizeEvent).
MARGINS = (19, 42, 19, 19)
SPACING = 8
BAR, WASH = 2, 5  # px: the quote's accent bar, and the tinted strip it sits on
LED_STATES = {  # state: (dot colour token, label suffix, motion)
    "unknown": ("ring", "", ""),
    "ok": ("led_ok", "", ""),
    "warn": ("led_warn", " …", "blink"),
    "loading": ("led_warn", " …", "blink"),
    "bad": ("led_bad", " ✕", ""),
    "hot": ("accent", "", "pulse"),
    "off": ("ring", " OFF", ""),
}


def _font(px: int, bold: bool = True, spacing: float = 0.0) -> QFont:
    f = QFont(mono_family())
    f.setPixelSize(px)
    f.setBold(bold)
    f.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, spacing)
    return f


def _quantised(hue: float) -> float:
    """The hue in the 2 degree steps the card follows the face in."""
    return round(hue / 2) * 2 % 360


# --- the frame -------------------------------------------------------------------------------

def _corner(t: Theme, r: QRectF) -> float:
    return max(0.0, min(t.corner, min(r.width(), r.height()) / 2 - 1))


def _outline(r: QRectF, t: Theme, tail_x: float) -> QPainterPath:
    """The frame: chamfered or rounded corners, and the tail notch in the bottom edge."""
    c, x0, y0, x1, y1 = _corner(t, r), r.left(), r.top(), r.right(), r.bottom()
    hw = TAIL_W / 2
    tail = ((tail_x + hw, y1), (tail_x, y1 + TAIL_H), (tail_x - hw, y1))
    p = QPainterPath()
    if t.shape == "round" and c > 0:
        p.moveTo(x0 + c, y0)
        p.lineTo(x1 - c, y0)
        p.arcTo(QRectF(x1 - 2 * c, y0, 2 * c, 2 * c), 90, -90)
        p.lineTo(x1, y1 - c)
        p.arcTo(QRectF(x1 - 2 * c, y1 - 2 * c, 2 * c, 2 * c), 0, -90)
        for pt in (*tail, (x0 + c, y1)):
            p.lineTo(*pt)
        p.arcTo(QRectF(x0, y1 - 2 * c, 2 * c, 2 * c), 270, -90)
        p.lineTo(x0, y0 + c)
        p.arcTo(QRectF(x0, y0, 2 * c, 2 * c), 180, -90)
    else:
        pts = [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), *tail,
               (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)]
        p.moveTo(*pts[0])
        for pt in pts[1:]:
            p.lineTo(*pt)
    p.closeSubpath()
    return p


def _bracket(corner: str, r: QRectF, t: Theme) -> QPainterPath:
    """One of the four corner brackets: an arm of `br_len` each way that follows the corner."""
    c, x0, y0, x1, y1 = _corner(t, r), r.left(), r.top(), r.right(), r.bottom()
    n = max(float(t.br_len), c)  # an arm shorter than the chamfer would fold back on itself
    round_ = t.shape == "round" and c > 0
    p = QPainterPath()
    if corner == "tl":
        p.moveTo(x0, y0 + n)
        p.lineTo(x0, y0 + c)
        p.arcTo(QRectF(x0, y0, 2 * c, 2 * c), 180, -90) if round_ else p.lineTo(x0 + c, y0)
        p.lineTo(x0 + n, y0)
    elif corner == "tr":
        p.moveTo(x1 - n, y0)
        p.lineTo(x1 - c, y0)
        p.arcTo(QRectF(x1 - 2 * c, y0, 2 * c, 2 * c), 90, -90) if round_ else p.lineTo(x1, y0 + c)
        p.lineTo(x1, y0 + n)
    elif corner == "br":
        p.moveTo(x1, y1 - n)
        p.lineTo(x1, y1 - c)
        p.arcTo(QRectF(x1 - 2 * c, y1 - 2 * c, 2 * c, 2 * c), 0, -90) if round_ \
            else p.lineTo(x1 - c, y1)
        p.lineTo(x1 - n, y1)
    else:
        p.moveTo(x0 + n, y1)
        p.lineTo(x0 + c, y1)
        p.arcTo(QRectF(x0, y1 - 2 * c, 2 * c, 2 * c), 270, -90) if round_ else p.lineTo(x0, y1 - c)
        p.lineTo(x0, y1 - n)
    return p


def _tile(w: int, h: int, dpr: float, paint) -> QBrush:
    """A texture brush `w` x `h` logical px (scanlines, dot grid) drawn by `paint(painter)`."""
    img = QImage(round(w * dpr), round(h * dpr), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    img.setDevicePixelRatio(dpr)
    p = QPainter(img)
    paint(p)
    p.end()
    pm = QPixmap.fromImage(img)
    pm.setDevicePixelRatio(dpr)
    return QBrush(pm)


def chrome(t: Theme, size: QSize, dpr: float, hue: float) -> QPixmap:
    """The card's frame and surface at `size` (logical px): glow, glass fill, scanlines, sheen,
    grid, aura, header tint and divider, border, corner brackets, tail dot. Transparent
    where nothing is painted; the text goes on top. Slow-ish (about 1 ms): `Card` caches it."""

    def acc(alpha: float = 1.0, dh: float = 0.0) -> QColor:
        return qcolor(accent(t, hue + dh, alpha))

    w, h = size.width(), size.height()
    pm = QPixmap(round(w * dpr), round(h * dpr))
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    body = QRectF(GLOW + 0.5, GLOW + 0.5, w - 2 * GLOW - 1, h - GLOW - TAIL_H - 1)
    path = _outline(body, t, w / 2)
    p.setBrush(Qt.BrushStyle.NoBrush)
    if t.glow:  # halo: faint strokes, widest first, so alpha builds toward the frame
        p.setRenderHint(QPainter.RenderHint.Antialiasing, False)  # ~5 % layers: no visible edge
        for i, width in enumerate((9, 7, 5, 3)):
            pen = QPen(acc(t.glow * 0.035 * (i + 1)), width)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            p.setPen(pen)
            p.drawPath(path)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    fill = QLinearGradient(0, body.top(), 0, body.bottom())
    alpha = max(t.bg_a, 0.90)  # Qt cannot blur the wallpaper: stay mostly opaque
    fill.setColorAt(0, qcolor(rgba(t.bg_top, alpha)))
    fill.setColorAt(1, qcolor(rgba(t.bg_bot, alpha)))
    p.fillPath(path, fill)
    dh = aura_shift(t, hue)
    if t.aura:  # a bloom in the top right corner, shifted toward pink
        bloom = QRadialGradient(QPointF(body.right() - 20, body.top() + 6), 190)
        bloom.setColorAt(0, acc(t.aura, dh))
        bloom.setColorAt(1, acc(0.0, dh))
        p.fillPath(path, bloom)
    if t.scan_a:
        ink = qcolor(rgba(t.scan_c, t.scan_a))
        p.fillPath(path, _tile(1, t.scan_px, dpr, lambda q: q.fillRect(0, 0, 1, 1, ink)))
    if t.grid_a:
        ink = acc(t.grid_a)
        p.fillPath(path, _tile(14, 14, dpr, lambda q: q.fillRect(6, 6, 1, 1, ink)))
    if t.sheen:  # gloss over the top half
        gloss = QLinearGradient(0, body.top(), 0, body.top() + body.height() * 0.5)
        gloss.setColorAt(0, QColor(255, 255, 255, round(255 * t.sheen)))
        gloss.setColorAt(1, QColor(255, 255, 255, 0))
        p.fillPath(path, gloss)
    p.save()  # header tint
    p.setClipPath(path)
    p.fillRect(QRectF(body.left(), body.top(), body.width(), HEADER_H), acc(0.07))
    p.restore()
    y = body.top() + HEADER_H  # divider, and a bright tick under the diamond
    rule = QLinearGradient(body.left(), 0, body.right(), 0)
    rule.setColorAt(0, acc(0.55))
    rule.setColorAt(0.65, acc(0.10))
    rule.setColorAt(1, acc(0.04))
    p.setPen(QPen(QBrush(rule), 1))
    p.drawLine(QPointF(body.left() + 1, y), QPointF(body.right() - 1, y))
    p.setPen(QPen(acc(0.95), 1.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.FlatCap))
    p.drawLine(QPointF(body.left() + 13, y), QPointF(body.left() + 40, y))
    border = QPen(acc(t.border_a), 1.0)
    if t.aura_dh:  # the stroke drifts toward pink from the top left to the bottom right
        sweep = QLinearGradient(body.topLeft(), body.bottomRight())
        sweep.setColorAt(0, acc(t.border_a))
        sweep.setColorAt(1, acc(t.border_a, dh))
        border = QPen(QBrush(sweep), 1.0)
    p.setPen(border)
    p.drawPath(path)
    if t.br_len:
        for corner in ("tl", "tr", "br", "bl"):  # brighter and thicker than the border
            arm = _bracket(corner, body, t)
            for width, a in ((t.br_w + 4, 0.12), (t.br_w, 1.0)):
                p.setPen(QPen(acc(a), width, Qt.PenStyle.SolidLine, Qt.PenCapStyle.FlatCap,
                              Qt.PenJoinStyle.MiterJoin))
                p.drawPath(arm)
    p.setPen(Qt.PenStyle.NoPen)  # the tail's tip: a small bright dot
    p.setBrush(acc(1.0))
    p.drawEllipse(QPointF(w / 2, body.bottom() + TAIL_H - 1.5), 1.5, 1.5)
    p.end()
    return pm


# --- style sheet and Markdown look -----------------------------------------------------------

def qss(t: Theme) -> str:
    """The widgets' style sheet: a pure function of the theme, at its RESTING hue."""
    mono = mono_family()

    def a(alpha: float) -> str:
        return css(accent(t, t.hue, alpha))

    body = f'font-family: "{mono}"; ' if t.body_mono else ""
    return f"""
QWidget {{ color: {t.text}; }}
QTextBrowser, QLineEdit {{ background: transparent; border: none;
    selection-background-color: {a(.35)}; selection-color: {t.text}; }}
QTextBrowser#reply {{ {body}font-size: {t.text_px}px; }}
QTextBrowser#heard {{ color: {t.text_dim}; font-size: 12px; font-style: italic; }}
QLabel#footer {{ color: {t.text_dim}; font-family: "{mono}"; font-size: 11px;
    border-top: 1px solid {a(.22)}; padding-top: 6px; }}
QLabel#well {{ color: {t.text}; font-family: "{mono}"; font-size: 11.5px; background: {a(.07)};
    border: none; border-left: 2px solid {t.led_warn}; padding: 6px 8px;
    border-top-right-radius: {t.radius}px; border-bottom-right-radius: {t.radius}px; }}
QPushButton {{ background: {a(.08)}; border: 1px solid {a(.34)}; border-radius: {t.radius}px;
    padding: 5px 8px; color: {t.text}; font-size: 13px; }}
QPushButton:hover {{ background: {a(.22)}; border-color: {a(.85)}; }}
QPushButton#allow {{ background: {a(1)}; color: {t.on_accent}; border: 1px solid {a(1)};
    font-weight: 600; }}
QPushButton#allow:hover {{ background: {css(label_colour(t, t.hue))}; }}
QPushButton#deny {{ background: transparent; border: 1px solid {css(rgba(t.text_dim, .45))};
    color: {t.text_dim}; }}
QPushButton#deny:hover {{ background: {a(.12)}; color: {t.text}; }}
QLineEdit {{ background: {a(.06)}; border: 1px solid {a(.32)}; border-radius: {t.radius}px;
    padding: 6px 8px; font-size: 13px; }}
QLineEdit:focus {{ border-color: {a(.9)}; }}
QScrollBar:vertical {{ background: transparent; width: 5px; margin: 0; }}
QScrollBar::handle:vertical {{ background: {a(.45)}; border-radius: 2px; min-height: 18px; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
"""


def md_look(t: Theme) -> Look:
    """The theme's Markdown look for `widgets.style_markdown`."""
    link = QTextCharFormat()
    link.setForeground(QColor(t.link))
    link.setFontUnderline(True)
    head = QTextCharFormat()
    head.setForeground(QColor(t.head))
    head.setFontWeight(QFont.Weight.Bold)
    line = QTextBlockFormat()
    line.setBackground(QColor(t.code_bg))
    line.setTextIndent(8)  # the box's left padding
    line.setNonBreakableLines(False)  # wrap, as in the default look
    # The inline code keeps the text colour: `inline_bg` is what the theme guarantees it on.
    return Look(mono_format(fg=t.code_fg), mono_format(bg=t.inline_bg), link, line, head,
                t.line_h, INDENT + (6 if t.body_mono else 0), 0)


# --- widgets ---------------------------------------------------------------------------------

class MicroLabel(QLabel):
    """Tiny monospace text painted in the live accent hue: "YOU ▸", "APPROVAL ▸", the status
    line. `tone` "lab" is the accent's paler label colour, "warn" the warning LED colour, "dim"
    the quiet text colour. It is a QLabel (setText, text) that draws itself."""

    def __init__(self, text: str = "", theme: Theme = CYAN, px: int = 9, spacing: float = 1.4,
                 bold: bool = True, tone: str = "lab", parent: QWidget | None = None):
        super().__init__(text, parent)
        self.theme, self.hue, self.tone = theme, theme.hue, tone
        self.setFont(_font(px, bold, spacing))

    def restyle(self, theme: Theme, hue: float) -> None:
        self.theme, self.hue = theme, hue
        self.update()

    def sizeHint(self) -> QSize:  # noqa: N802 - Qt override
        fm = QFontMetrics(self.font())  # QLabel's own hint ignores the letter spacing
        return QSize(fm.horizontalAdvance(self.text()) + 2, fm.height() + 2)

    minimumSizeHint = sizeHint  # noqa: N815 - Qt override

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        t = self.theme
        ink = {"lab": label_colour(t, self.hue), "warn": rgba(t.led_warn),
               "dim": rgba(t.text_dim)}[self.tone]
        p = QPainter(self)
        p.setFont(self.font())
        p.setPen(qcolor(ink))
        p.drawText(self.rect(), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                   self.text())
        p.end()


class Led(QWidget):
    """A status light with a word: the dot's colour AND the label change with the state, so it
    never relies on colour alone (see LED_STATES). `blink` states flash at 1 Hz and "hot"
    pulses, both driven by the phase (seconds) the app hands to `set_phase`."""

    changed = Signal()  # the label's width changed: the Header lays out again

    def __init__(self, name: str, state: str = "unknown", hot: str | None = None,
                 parent: QWidget | None = None, theme: Theme = CYAN):
        super().__init__(parent)
        self.name, self.hot, self.theme, self.hue = name, hot, theme, theme.hue
        self.state, self._lit, self._pulse = "", True, 1.0  # "": not sized yet
        self.setFont(_font(8, True, 1.0))
        self.set_state(state)

    @property
    def label(self) -> str:
        if self.state == "hot" and self.hot:
            return self.hot
        return self.name + LED_STATES[self.state][1]

    def set_state(self, state: str) -> None:
        if state not in LED_STATES:
            raise ValueError(f"unknown LED state {state!r}")
        if state == self.state:
            return
        self.state = state
        width = 14 + QFontMetrics(self.font()).horizontalAdvance(self.label) + 2
        grew = width != self.width()
        self.setFixedSize(width, HEADER_H)
        self.update()
        if grew:
            self.changed.emit()

    def set_phase(self, t: float) -> None:
        """The clock for blinking and pulsing; repaints only when what is drawn changes."""
        motion = LED_STATES[self.state][2]
        lit = motion != "blink" or int(t * 2) % 2 == 0
        pulse = round(0.5 + 0.5 * math.sin(t * 2 * math.pi * 0.8), 1) if motion == "pulse" else 1.0
        if (lit, pulse) != (self._lit, self._pulse):
            self._lit, self._pulse = lit, pulse
            self.update()

    def restyle(self, theme: Theme, hue: float) -> None:
        self.theme, self.hue = theme, hue
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        t, (token, _, motion) = self.theme, LED_STATES[self.state]
        c = QPointF(7, self.height() / 2)
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        if token == "ring":  # unknown / off: an empty ring
            p.setPen(QPen(qcolor(rgba(t.text_dim)), 1.2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawEllipse(c, 2.4, 2.4)
        elif not self._lit:  # the dark half of a blink
            p.setBrush(qcolor(rgba(t.text_dim, 0.35)))
            p.drawEllipse(c, 2.7, 2.7)
        else:
            dot = accent(t, self.hue) if token == "accent" else rgba(getattr(t, token))
            halo = QRadialGradient(c, 7)
            strength = 60 + 120 * self._pulse if motion == "pulse" else 110
            halo.setColorAt(0, QColor(*dot[:3], round(strength)))
            halo.setColorAt(1, QColor(*dot[:3], 0))
            p.setBrush(halo)
            p.drawEllipse(c, 7, 7)
            p.setBrush(qcolor(dot))
            p.drawEllipse(c, 2.7, 2.7)
        p.setFont(self.font())
        p.setPen(qcolor(rgba(t.text_dim)))
        p.drawText(QRectF(14, 0, self.width() - 14, self.height()),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, self.label)
        p.end()


def mic_state(listener, activity: str, noted: bool = False) -> str:
    """The MIC LED: `listener` is the robo.listen.Listener (None: voice is off, docked or the
    start failed), `activity` the mind's, `noted` that the listener reported a problem."""
    if listener is None:
        return "off"
    if activity == "listening":
        return "hot"
    if noted:
        return "bad"
    return "ok" if listener.ready else "loading"


class Header(QWidget):
    """The strip at the top of the frame: diamond, the bot's name, a Hermes and a microphone LED,
    the model chip on the right. When it is too narrow the chip goes first (under 40 px it is
    hidden), then the LEDs and the name keep their room. The Card puts it at the top of the
    frame (it is not in the card's layout)."""

    def __init__(self, theme: Theme = CYAN, parent: QWidget | None = None):
        super().__init__(parent)
        self.theme, self.hue = theme, theme.hue
        # in the card's theme from the start: nothing restyles them until the hue first moves
        self.link = Led("HERMES", "unknown", parent=self, theme=theme)
        self.mic = Led("MIC", "off", hot="LISTENING", parent=self, theme=theme)
        self.chip: QRect | None = None  # where the model chip is drawn (None: hidden)
        self._chip_text = ""
        self.setFixedHeight(HEADER_H)
        for led in (self.link, self.mic):
            led.changed.connect(self._place)
        self._place()

    def set_status(self, link: str, mic: str) -> None:
        """Both LEDs at once (see LED_STATES for the states)."""
        self.link.set_state(link)
        self.mic.set_state(mic)

    def set_phase(self, t: float) -> None:
        for led in (self.link, self.mic):
            led.set_phase(t)

    def restyle(self, theme: Theme, hue: float) -> None:
        again = theme is not self.theme
        self.theme, self.hue = theme, hue
        if again:  # the name and the chip may differ
            self._place()
        self.update()

    def _name(self) -> tuple[QFont, str]:
        return _font(11, True, 2.4), self.theme.bot_name.upper()

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt override
        self._place()

    def _place(self) -> None:
        font, name = self._name()
        x = 25 + QFontMetrics(font).horizontalAdvance(name) + 14
        for led in (self.link, self.mic):  # 3 px left of the dot's slot: the halo needs room
            led.move(x - 3, 0)
            x += led.width() + 6
        chip = chip_text(self.theme)
        fm = QFontMetrics(_font(9, False, 0.3))
        room = self.width() - 12 - x  # the chip's whole width (text plus 7 px padding each side)
        text = fm.elidedText(chip, Qt.TextElideMode.ElideRight, max(0, room - 14))
        width = fm.horizontalAdvance(text) + 14 if chip else 0
        self._chip_text = text
        self.chip = None if not chip or width < 40 else \
            QRect(self.width() - 12 - width, (HEADER_H - 17) // 2, width, 17)
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        t, hue = self.theme, self.hue
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        p.save()  # the diamond: a halo square and a solid one, turned 45 degrees
        p.translate(14, HEADER_H / 2)
        p.rotate(45)
        p.setBrush(qcolor(accent(t, hue, 0.25)))
        p.drawRect(QRectF(-5, -5, 10, 10))
        p.setBrush(qcolor(accent(t, hue)))
        p.drawRect(QRectF(-3, -3, 6, 6))
        p.restore()
        font, name = self._name()
        p.setFont(font)
        p.setPen(qcolor(label_colour(t, hue)))  # the accent itself is under 4.5:1 on blues
        p.drawText(QRectF(25, 0, self.width() - 25, HEADER_H),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, name)
        if self.chip:
            p.setPen(QPen(qcolor(accent(t, hue, 0.38)), 1))
            p.setBrush(qcolor(accent(t, hue, 0.07)))
            p.drawRoundedRect(QRectF(self.chip).adjusted(0.5, 0.5, -0.5, -0.5), t.radius, t.radius)
            p.setFont(_font(9, False, 0.3))
            p.setPen(qcolor(rgba(t.text_dim)))
            p.drawText(self.chip, Qt.AlignmentFlag.AlignCenter, self._chip_text)
        p.end()


class Quote(QWidget):
    """The user's line: an accent bar on the left, a "YOU ▸" label, optionally "↳ FOLLOW-UP", the
    text (`text`, a QTextBrowser the app sizes and scrolls past HEARD_PX) and a hairline under it.
    Hidden while the text is empty (the automatic digest has no user text)."""

    def __init__(self, theme: Theme = CYAN, parent: QWidget | None = None):
        super().__init__(parent)
        self.theme, self.hue = theme, theme.hue
        self.label = MicroLabel("YOU ▸", theme)
        self.tag = MicroLabel("↳ FOLLOW-UP", theme, tone="dim")
        self.text = QTextBrowser(objectName="heard")
        self.text.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.text.document().setDocumentMargin(0)
        grid = QGridLayout(self)  # one grid, not nested rows (CLAUDE.md: they crashed at exit)
        grid.setContentsMargins(11, 0, 0, 7)  # 7 px under the text: room for the hairline
        grid.setSpacing(2)
        grid.addWidget(self.label, 0, 0)
        grid.addWidget(self.tag, 0, 1, Qt.AlignmentFlag.AlignRight)
        grid.addWidget(self.text, 1, 0, 1, 2)
        grid.setColumnStretch(0, 1)
        self.tag.hide()
        self.hide()

    def set_text(self, text: str, follow_up: bool = False) -> None:
        self.text.setPlainText(text)
        self.tag.setVisible(follow_up)
        self.setVisible(bool(text))

    def restyle(self, theme: Theme, hue: float) -> None:
        self.theme, self.hue = theme, hue
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        t, hue = self.theme, self.hue
        p = QPainter(self)
        p.setPen(Qt.PenStyle.NoPen)
        bar = QLinearGradient(0, 0, 0, self.height())
        bar.setColorAt(0, qcolor(accent(t, hue)))
        bar.setColorAt(1, qcolor(accent(t, hue, 0.30)))
        p.fillRect(QRectF(0, 1, WASH, self.height() - 2 - 7), qcolor(accent(t, hue, 0.10)))
        p.fillRect(QRectF(0, 1, BAR, self.height() - 2 - 7), QBrush(bar))
        hair = QLinearGradient(11, 0, self.width(), 0)  # between the question and the answer
        hair.setColorAt(0, qcolor(accent(t, hue, 0.26)))
        hair.setColorAt(1, qcolor(accent(t, hue, 0.0)))
        p.fillRect(QRectF(11, self.height() - 1, self.width() - 11, 1), QBrush(hair))
        p.end()


class Caret(QWidget):
    """The typing caret: a child of the reply's viewport (never part of the document), a block,
    a bar or an underline in the accent colour. The app calls `place` with the text cursor's
    rectangle and `set_on` to blink it."""

    def __init__(self, viewport: QWidget, theme: Theme = CYAN):
        super().__init__(viewport)
        self.theme, self.hue, self.on = theme, theme.hue, True
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.hide()

    def restyle(self, theme: Theme, hue: float) -> None:
        self.theme, self.hue = theme, hue
        self.update()

    def set_on(self, on: bool) -> None:
        if on != self.on:
            self.on = on
            self.update()

    def place(self, line: QRect) -> QRect:
        """Put the caret at the text cursor's rectangle `line` (viewport coordinates, from
        `QTextEdit.cursorRect`): 0.58 x 1.18 times the text size, centred on the line, always
        inside the viewport. Returns its geometry (a 1 px halo included)."""
        px = self.theme.text_px
        w, h = max(8, round(px * 0.58)), max(10, round(px * 1.18))
        vp = self.parentWidget().rect()
        x = min(max(2, line.x() + 1), max(2, vp.width() - w - 2))
        y = min(max(2, line.y() + (line.height() - h) // 2 + 1), max(2, vp.height() - h - 2))
        box = QRect(x - 1, y - 1, w + 2, h + 2)
        self.setGeometry(box)
        self.raise_()
        return box

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        if not self.on:
            return
        t, r = self.theme, self.rect()
        core = r.adjusted(1, 1, -1, -1)
        p = QPainter(self)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(qcolor(accent(t, self.hue, 0.18)))  # the halo
        p.drawRect(r)
        p.setBrush(qcolor(accent(t, self.hue, 0.95)))
        if t.caret == "bar":
            p.drawRect(core.x(), core.y(), 2, core.height())
        elif t.caret == "under":
            p.drawRect(core.x(), core.bottom() - 1, core.width(), 2)
        else:
            p.drawRect(core)
        p.end()


class Swatch(QAbstractButton):
    """A theme in the picker: a miniature card painted in that theme's OWN colours (resting
    hue), the current one ringed."""

    def __init__(self, theme: Theme, current: bool = False, parent: QWidget | None = None):
        super().__init__(parent)
        self.theme, self.current = theme, current
        self.setFixedSize(54, 34)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(theme.label)
        self.setAccessibleName(theme.label)

    def set_current(self, current: bool) -> None:
        self.current = current
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        t = self.theme

        def acc(alpha: float = 1.0) -> QColor:
            return qcolor(accent(t, t.hue, alpha))

        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = QRectF(self.rect()).adjusted(2, 2, -2, -2)
        fill = QLinearGradient(0, r.top(), 0, r.bottom())
        fill.setColorAt(0, QColor(t.bg_top))
        fill.setColorAt(1, QColor(t.bg_bot))
        p.setBrush(QBrush(fill))
        p.setPen(QPen(acc(0.95 if self.current else 0.35), 1.8 if self.current else 1.0))
        radius = min(t.corner, 7) if t.shape == "round" else 2
        p.drawRoundedRect(r, radius, radius)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(acc())
        p.drawRoundedRect(QRectF(r.left() + 7, r.top() + 7, 18, 3), 1.5, 1.5)
        p.setBrush(QColor(t.text))
        p.drawRoundedRect(QRectF(r.left() + 7, r.top() + 14, 28, 2.5), 1.2, 1.2)
        p.drawRoundedRect(QRectF(r.left() + 7, r.top() + 19, 19, 2.5), 1.2, 1.2)
        p.setBrush(acc())
        p.drawEllipse(QPointF(r.right() - 8, r.bottom() - 7), 3, 3)
        p.end()


class Picker(QWidget):
    """"THEME ▸ CYAN HUD" and one swatch per theme in a single grid. Clicking a swatch emits
    `picked(key)`; the owner applies the theme and calls `set_current`."""

    picked = Signal(str)

    def __init__(self, current: str = "cyan", theme: Theme = CYAN, parent: QWidget | None = None):
        super().__init__(parent)
        self.label = MicroLabel("", theme)
        self.swatches: dict[str, Swatch] = {}
        grid = QGridLayout(self)
        grid.setContentsMargins(0, 2, 0, 0)
        grid.setSpacing(5)
        grid.addWidget(self.label, 0, 0, 1, len(THEMES))
        for i, (key, t) in enumerate(THEMES.items()):
            swatch = Swatch(t, parent=self)
            swatch.clicked.connect(lambda _=False, k=key: self.picked.emit(k))
            self.swatches[key] = swatch
            grid.addWidget(swatch, 1, i)
        self.set_current(current)

    def set_current(self, key: str) -> None:
        self.label.setText(f"THEME ▸ {THEMES[key].label.upper()}" if key in THEMES else "THEME ▸")
        for k, swatch in self.swatches.items():
            swatch.set_current(k == key)


class Card(QWidget):
    """The holographic card: paints its frame under its children, which lay out in `inner` (the
    one QVBoxLayout, margins MARGINS so they clear the glow, header and tail). `header` is a
    child placed at the top of the frame. Fixed width BUBBLE_W; the tail points at the middle
    of the bottom edge, where the face is."""

    def __init__(self, theme: Theme = CYAN, parent: QWidget | None = None):
        super().__init__(parent)
        self.theme, self._hue = theme, _quantised(theme.hue)
        self._pm: QPixmap | None = None
        self._key: tuple | None = None
        self.setFixedWidth(BUBBLE_W)
        self.inner = QVBoxLayout(self)
        self.inner.setContentsMargins(*MARGINS)
        self.inner.setSpacing(SPACING)
        self.header = Header(theme, self)

    @property
    def hue(self) -> float:
        """The live hue (in 2 degree steps) every accent on the card is painted with."""
        return self._hue

    def set_theme(self, theme: Theme) -> None:
        self.theme = theme
        self._restyle()

    def set_hue(self, hue: float) -> bool:
        """Follow the face's hue in 2 degree steps; True when the card repainted."""
        q = _quantised(hue)
        if q == self._hue:
            return False
        self._hue = q
        self._restyle()
        return True

    def _restyle(self) -> None:
        for w in self.findChildren(QWidget):  # the header, LEDs, quote, labels, dots, caret
            restyle = getattr(w, "restyle", None)
            if restyle:
                restyle(self.theme, self._hue)
        self.update()

    def chrome(self) -> QPixmap:
        """The frame pixmap for the current size, theme and hue, built when any of them changed
        (key: size, pixel ratio, hue step, the theme's revision)."""
        dpr = self.devicePixelRatioF()
        key = (self.width(), self.height(), dpr, self._hue, self.theme.rev)
        if key != self._key or self._pm is None:
            self._pm = chrome(self.theme, self.size(), dpr, self._hue)
            self._key = key
        return self._pm

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt override
        self.header.setGeometry(GLOW, GLOW, self.width() - 2 * GLOW, HEADER_H)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        p = QPainter(self)
        p.drawPixmap(0, 0, self.chrome())
        p.end()
