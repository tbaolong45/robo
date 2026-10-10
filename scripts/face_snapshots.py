"""Render every activity x emotion face into a labelled grid PNG (+ singles, + animator frames).

Usage: QT_QPA_PLATFORM=offscreen uv run python scripts/face_snapshots.py OUT_DIR
"""

from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QFont, QImage, QPainter
from PySide6.QtWidgets import QApplication

from robo.events import ACTIVITIES, EMOTIONS
from robo.face.animator import Animator
from robo.face.expressions import FaceParams, target
from robo.face.widget import render_params

CW, CH, LABEL = 240, 180, 22


def tile(p: FaceParams, t: float = 0.6) -> QImage:
    img = QImage(CW, CH, QImage.Format.Format_ARGB32)
    painter = QPainter(img)
    render_params(painter, QRectF(0, 0, CW, CH), p, t)
    painter.end()
    return img


def grid(rows: list[tuple[str, list[tuple[str, FaceParams]]]]) -> QImage:
    cols = max(len(r[1]) for r in rows)
    size = (LABEL * 4 + cols * CW, LABEL + len(rows) * (CH + LABEL))
    img = QImage(*size, QImage.Format.Format_RGB32)
    img.fill(QColor(30, 30, 30))
    painter = QPainter(img)
    painter.setFont(QFont("Sans", 10))
    painter.setPen(Qt.GlobalColor.white)
    for r, (row_name, cells) in enumerate(rows):
        y = LABEL + r * (CH + LABEL)
        painter.drawText(QRectF(0, y, LABEL * 4, CH), Qt.AlignmentFlag.AlignCenter, row_name)
        for c, (name, p) in enumerate(cells):
            x = LABEL * 4 + c * CW
            painter.drawText(QRectF(x, y - LABEL, CW, LABEL), Qt.AlignmentFlag.AlignCenter, name)
            painter.drawImage(x, y, tile(p))
    painter.end()
    return img


def frames(talking: bool, secs: float, every: int, seed: int) -> list[tuple[str, FaceParams]]:
    a, goal, out, t = Animator(seed), target("talking" if talking else "idle", "neutral"), [], 0.0
    for i in range(int(secs * 120)):
        t += 1 / 120
        p = a.step(goal, 1 / 120, talking, t)
        if i % every == 0:
            out.append((f"t={t:.2f}", p))
    return out


def main(out: Path) -> None:
    QApplication.instance() or QApplication([])
    out.mkdir(parents=True, exist_ok=True)
    rows = [(a, [(e, target(a, e)) for e in EMOTIONS]) for a in ACTIVITIES]
    grid(rows).save(str(out / "face_grid.png"))
    for a, cells in rows:
        for e, p in cells:
            tile(p).save(str(out / f"{a}_{e}.png"))
    # Blink: find the first blink and show frames around it; talking: a short burst.
    a, goal, t, seq = Animator(3), target("idle", "neutral"), 0.0, []
    while t < 8 and not (seq and seq[-1][1].eye_h > 0.95 * goal.eye_h and len(seq) > 6):
        t += 1 / 120
        p = a.step(goal, 1 / 120, False, t)
        if p.eye_h < 0.97 * goal.eye_h or seq:
            seq.append((f"t={t:.3f}", p))
    blink = seq[:: max(1, len(seq) // 6)][:7]
    talk = frames(True, 0.6, 9, 2)[:7]
    grid([("blink", blink), ("talking", talk)]).save(str(out / "face_frames.png"))
    print(out / "face_grid.png", out / "face_frames.png")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "face_snapshots"))
