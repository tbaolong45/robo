"""FaceWidget: paints FaceParams as a glowing Vector-style robot face."""

from __future__ import annotations

import math
import time

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen, QRadialGradient
from PySide6.QtWidgets import QWidget

from robo.face.animator import Animator
from robo.face.expressions import FaceParams, target

W, H = 320.0, 240.0  # logical canvas; scaled to fit the widget
EYE_X, EYE_Y, EYE_W, EYE_H = 64.0, 102.0, 66.0, 78.0
MOUTH_Y, MOUTH_W = 176.0, 46.0
BG = QColor(9, 13, 22)


def _colour(p: FaceParams, alpha: float = 1.0, value: float = 1.0) -> QColor:
    return QColor.fromHsvF((p.hue % 360) / 360, min(1, max(0, p.sat)), value, alpha)


def _clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return min(hi, max(lo, v))


def _eye(p: FaceParams, side: int, ox: float, oy: float) -> QPainterPath:
    """One eye (side -1 left, +1 right) with lids carved out."""
    s = 1 + 0.22 * p.skew * side
    shut = 1 - 0.92 * _clamp(p.wink) if side < 0 else 1.0
    w, h = EYE_W * p.eye_w * s, max(4.0, EYE_H * p.eye_h * s * shut)
    cx, cy = W / 2 + side * EYE_X + ox, EYE_Y + oy
    r = QRectF(cx - w / 2, cy - h / 2, w, h)
    rad = min(w, h) / 2 * _clamp(p.eye_round)
    path = QPainterPath()
    path.addRoundedRect(r, rad, rad)
    inner, outer = (r.right(), r.left()) if side < 0 else (r.left(), r.right())
    top, ang = _clamp(p.lid_top), max(-1.0, min(1.0, p.lid_angle))
    yi, yo = r.top() + h * (top + ang / 2), r.top() + h * (top - ang / 2)
    if max(yi, yo) > r.top():
        dx, dy = (outer - inner) / 2, (yo - yi) / 2  # extend the lid line past both edges
        a, b = QPointF(inner - dx, yi - dy), QPointF(outer + dx, yo + dy)
        lid = QPainterPath(a)
        for pt in (b, QPointF(b.x(), r.top() - h), QPointF(a.x(), r.top() - h)):
            lid.lineTo(pt)
        path = path.subtracted(lid)
    bot = _clamp(p.lid_bottom)
    if bot > 0.01 and (side > 0 or p.wink < 0.5):
        cheek = QPainterPath()
        ew = w * 1.5
        top_y = r.bottom() - h * bot * 1.1
        cheek.addEllipse(QRectF(cx - ew / 2, top_y, ew, h * 1.6))
        path = path.subtracted(cheek)
    return path


def _pen(col: QColor, width: float) -> QPen:
    return QPen(col, width, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap,
                Qt.PenJoinStyle.RoundJoin)


def _glow(painter: QPainter, path: QPainterPath, p: FaceParams, base: float = 0.0) -> None:
    """Soft halo: stacked faint strokes, widest first, so alpha builds toward the shape."""
    painter.setBrush(Qt.BrushStyle.NoBrush)
    for i in range(7):
        painter.setPen(_pen(_colour(p, 0.045 * (0.3 + p.glow)), base + 30 - 4 * i))
        painter.drawPath(path)


def _glow_fill(painter: QPainter, path: QPainterPath, p: FaceParams) -> None:
    _glow(painter, path, p)
    painter.setPen(_pen(_colour(p), 5))  # same-colour stroke softens lid corners
    painter.setBrush(_colour(p))
    painter.drawPath(path)


def _mouth(painter: QPainter, p: FaceParams, oy: float) -> None:
    w = MOUTH_W * p.mouth_w
    cx, cy = W / 2, MOUTH_Y + oy
    bend = 14 * max(-1.0, min(1.0, p.mouth_curve))
    path = QPainterPath(QPointF(cx - w / 2, cy - bend / 2))
    path.quadTo(QPointF(cx, cy + bend * 1.5), QPointF(cx + w / 2, cy - bend / 2))
    opening = 26 * _clamp(p.mouth_open)
    if opening > 1.5:
        path.quadTo(QPointF(cx, cy + bend * 1.5 + opening * 2), QPointF(cx - w / 2, cy - bend / 2))
        path.closeSubpath()
        painter.setBrush(_colour(p, 0.9, 0.85))
    else:
        painter.setBrush(Qt.BrushStyle.NoBrush)
    brush = painter.brush()
    _glow(painter, path, p, -6)
    painter.setBrush(brush)
    painter.setPen(_pen(_colour(p), 5))
    painter.drawPath(path)


def _blob(painter: QPainter, c: QPointF, rx: float, ry: float, col: QColor) -> None:
    g = QRadialGradient(c, max(rx, ry))
    g.setColorAt(0, col)
    edge = QColor(col)
    edge.setAlpha(0)
    g.setColorAt(1, edge)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(g)
    painter.drawEllipse(c, rx, ry)


def _text(painter: QPainter, pos: QPointF, s: str, size: float, col: QColor) -> None:
    f = QFont()
    f.setPointSizeF(size)
    f.setBold(True)
    painter.setFont(f)
    painter.setPen(col)
    painter.drawText(pos, s)


def _effects(painter: QPainter, p: FaceParams, t: float, oy: float) -> None:
    fx, accent = p.effects, _colour(p)
    if "blush" in fx or "sparkle" in fx:
        for side in (-1, 1):
            _blob(painter, QPointF(W / 2 + side * (EYE_X + 18), EYE_Y + 50 + oy), 20, 10,
                  QColor(255, 110, 150, 120))
    if "sweat" in fx:
        x, y = W / 2 + EYE_X + 46, EYE_Y - 30 + oy + 3 * math.sin(t * 3)
        drop = QPainterPath(QPointF(x, y - 13))
        drop.cubicTo(QPointF(x + 2, y - 6), QPointF(x + 8, y), QPointF(x + 8, y + 4))
        drop.arcTo(QRectF(x - 8, y - 4, 16, 16), 0, -180)
        drop.cubicTo(QPointF(x - 8, y), QPointF(x - 2, y - 6), QPointF(x, y - 13))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(130, 200, 255, 220))
        painter.drawPath(drop)
    if "question" in fx:
        _text(painter, QPointF(W / 2 + EYE_X + 34, EYE_Y - 38 + oy + 3 * math.sin(t * 2)),
              "?", 26, accent)
    if "zzz" in fx:
        for i in range(3):
            k = (t * 0.4 + i / 3) % 1
            col = _colour(p, math.sin(math.pi * k) * 0.9)
            _text(painter, QPointF(W / 2 + 70 + 22 * k + 6 * i, 70 - 45 * k), "z", 10 + 8 * k, col)
    if "dots" in fx:
        for i in range(3):
            a = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(t * 5 - i * 1.1))
            _blob(painter, QPointF(W / 2 + EYE_X + 34 + i * 14, 30 - i * 6 + oy), 6, 6,
                  _colour(p, a))
    if "gear" in fx:
        c = QPointF(W / 2 + EYE_X + 52, 36 + oy)
        for i in range(8):
            ang = t * 4 + i * math.pi / 4
            a = 0.15 + 0.85 * (i / 7)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(_colour(p, a))
            painter.drawEllipse(QPointF(c.x() + 11 * math.cos(ang), c.y() + 11 * math.sin(ang)),
                                2.6, 2.6)
    if "pulse" in fx:
        for i in range(2):
            k = (t * 0.8 + i / 2) % 1
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(_pen(_colour(p, 0.6 * (1 - k)), 3))
            for side in (-1, 1):
                rr = 18 + 22 * k
                cx = W / 2 + side * (EYE_X + EYE_W / 2 + 6)
                box = QRectF(cx - rr, EYE_Y + oy - rr, 2 * rr, 2 * rr)
                painter.drawArc(box, (0 if side > 0 else 180) * 16 - 35 * 16, 70 * 16)
    if "sparkle" in fx:
        for i, (x, y, s) in enumerate(((W / 2 - EYE_X - 48, 52, 9), (W / 2 + EYE_X + 50, 44, 12))):
            s *= 0.75 + 0.25 * math.sin(t * 4 + i * 2)
            star = QPainterPath(QPointF(x, y - s))
            star.quadTo(QPointF(x, y), QPointF(x + s, y))
            star.quadTo(QPointF(x, y), QPointF(x, y + s))
            star.quadTo(QPointF(x, y), QPointF(x - s, y))
            star.quadTo(QPointF(x, y), QPointF(x, y - s))
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor(255, 236, 170, 230))
            painter.drawPath(star)


def render_params(painter: QPainter, rect: QRectF, p: FaceParams, t: float = 0.0) -> None:
    """Paint face `p` into `rect` (aspect kept, centred). `t` drives effect animation."""
    painter.save()
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    rect = QRectF(rect)
    g = QRadialGradient(rect.center(), max(rect.width(), rect.height()) * 0.7)
    g.setColorAt(0, QColor(18, 26, 42))
    g.setColorAt(1, BG)
    painter.fillRect(rect, g)
    k = min(rect.width() / W, rect.height() / H)
    painter.translate(rect.center().x() - W * k / 2, rect.center().y() - H * k / 2)
    painter.scale(k, k)
    oy = 3 * p.bob
    ox, gy = 26 * p.gaze_x, 20 * p.gaze_y
    for side in (-1, 1):
        _glow_fill(painter, _eye(p, side, ox, gy + oy), p)
    _mouth(painter, p, oy + 0.4 * gy)
    _effects(painter, p, t, oy)
    painter.restore()


class FaceWidget(QWidget):
    """Animated robot face. Call `set_state`; it animates itself at ~60 fps."""

    def __init__(self, parent: QWidget | None = None, seed: int | None = None,
                 radius: float = 0.0):
        super().__init__(parent)
        self.radius = radius  # > 0: a rounded screen, transparent outside (floating mode)
        self.anim = Animator(seed)
        self.goal = target("idle", "neutral")
        self.talking = False
        self.t0 = self.last = time.monotonic()
        self.params = self.anim.step(self.goal, 0.0, False, 0.0)
        self.timer = QTimer(self, interval=16, timeout=self._tick)
        self.timer.start()
        self.setMinimumSize(160, 120)

    def set_state(self, activity: str, emotion: str, talking: bool = False) -> None:
        self.goal, self.talking = target(activity, emotion), talking

    def _tick(self) -> None:
        now = time.monotonic()
        dt, self.last = min(now - self.last, 0.1), now
        self.params = self.anim.step(self.goal, dt, self.talking, now - self.t0)
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt override
        painter = QPainter(self)
        if self.radius:
            painter.setRenderHint(QPainter.RenderHint.Antialiasing)
            clip = QPainterPath()
            clip.addRoundedRect(QRectF(self.rect()), self.radius, self.radius)
            painter.setClipPath(clip)
        render_params(painter, QRectF(self.rect()), self.params, self.last - self.t0)
        painter.end()
