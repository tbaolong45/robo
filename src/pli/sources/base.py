"""The source contract every ingester implements, plus the shared file archive.

Moodle (Phase 2), Teams (Phase 3) and the Phase 1 stub all yield the same two
types, so the planner never learns where a deadline came from.
"""

from __future__ import annotations

import hashlib
import unicodedata
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from pli.models import Course, Deadline, Material

CHUNK = 1 << 20  # 1 MiB


@dataclass
class IngestResult:
    """What one source produced in a single run."""

    courses: list[Course] = field(default_factory=list)
    materials: list[Material] = field(default_factory=list)
    deadlines: list[Deadline] = field(default_factory=list)
    downloaded: int = 0
    skipped: int = 0
    errors: list[str] = field(default_factory=list)

    def merge(self, other: IngestResult) -> None:
        self.courses.extend(other.courses)
        self.materials.extend(other.materials)
        self.deadlines.extend(other.deadlines)
        self.downloaded += other.downloaded
        self.skipped += other.skipped
        self.errors.extend(other.errors)


def _is_keepable(char: str) -> bool:
    """Whether a character may appear in an archived file name.

    `str.isalnum()` alone is not enough: it is False for combining marks, so
    "การเขียนโปรแกรม" would lose its vowel signs - and, worse, distinct course
    names would collapse onto the same file. Unicode letters and marks are kept;
    separators, controls and everything else become '_'.
    """
    if char in " ._-()[]":
        return True
    return char.isalnum() or unicodedata.category(char)[0] in {"L", "M"}


class Source:
    """Base class. Subclasses implement `ingest` and optionally `download`."""

    name: str = "base"

    def ingest(self, *, store: object, full: bool = False) -> IngestResult:
        raise NotImplementedError

    # --- archive helpers shared by every source -------------------------------

    @staticmethod
    def safe_rel_path(*parts: str) -> str:
        """Build a filesystem-safe relative path from untrusted source names.

        Course and file names routinely contain '/' and ':' which would escape
        the archive root if used verbatim.
        """
        cleaned = []
        for part in parts:
            piece = str(part).strip().replace("\\", "_").replace("/", "_")
            piece = "".join(c if _is_keepable(c) else "_" for c in piece)
            piece = piece.strip(" .") or "_"
            cleaned.append(piece[:120])
        return "/".join(cleaned)

    @staticmethod
    def archive_path(root: Path, rel_path: str) -> Path:
        dest = (root / rel_path).resolve()
        root_resolved = root.resolve()
        if not dest.is_relative_to(root_resolved):
            raise ValueError(f"refusing to write outside the archive: {rel_path!r}")
        return dest

    @staticmethod
    def sha256_of(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as fh:
            while chunk := fh.read(CHUNK):
                digest.update(chunk)
        return digest.hexdigest()

    @staticmethod
    def sha256_of_bytes(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()


def iter_all(sources: Iterable[Source], *, store: object, full: bool = False) -> IngestResult:
    """Run each source in turn, isolating failures.

    A source that raises must not take down the others - a Moodle token outage
    still has to leave the Teams half and the cached deadlines usable.
    """
    total = IngestResult()
    for source in sources:
        try:
            total.merge(source.ingest(store=store, full=full))
        except Exception as exc:  # noqa: BLE001 - deliberate isolation boundary
            total.errors.append(f"{source.name}: {type(exc).__name__}: {exc}")
    return total
