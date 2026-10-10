"""SQLite state: the dedupe ledger, sync cursors, and the calendar block ledger.

One file, no server. Every row is keyed by (source, external_id) so a repeated
sync is always safe to run. `blocks` is the reconciliation ledger that lets the
calendar writer tell what already exists, what moved, and what should be deleted.
"""

from __future__ import annotations

import contextlib
import json
import os
import sqlite3
from datetime import UTC, datetime
from pathlib import Path

from pli.models import Block, ChannelMessage, Course, Deadline, Material

SCHEMA = """
CREATE TABLE IF NOT EXISTS courses (
    source       TEXT NOT NULL,
    external_id  TEXT NOT NULL,
    name         TEXT NOT NULL,
    short_name   TEXT,
    PRIMARY KEY (source, external_id)
);

CREATE TABLE IF NOT EXISTS materials (
    source             TEXT NOT NULL,
    external_id        TEXT NOT NULL,
    course_external_id TEXT NOT NULL,
    name               TEXT NOT NULL,
    rel_path           TEXT NOT NULL,
    url                TEXT,
    mime               TEXT,
    size               INTEGER,
    modified_at        TEXT,
    local_path         TEXT,
    sha256             TEXT,
    summary            TEXT,
    key_concepts       TEXT,
    difficulty         INTEGER,
    estimated_hours    REAL,
    seen_at            TEXT NOT NULL,
    PRIMARY KEY (source, external_id)
);
CREATE INDEX IF NOT EXISTS idx_materials_course ON materials(course_external_id);

CREATE TABLE IF NOT EXISTS deadlines (
    source             TEXT NOT NULL,
    external_id        TEXT NOT NULL,
    course_external_id TEXT NOT NULL,
    course_name        TEXT NOT NULL DEFAULT '',
    title              TEXT NOT NULL,
    due_at             TEXT NOT NULL,
    kind               TEXT NOT NULL,
    url                TEXT,
    first_seen         TEXT NOT NULL,
    last_seen          TEXT NOT NULL,
    PRIMARY KEY (source, external_id)
);
CREATE INDEX IF NOT EXISTS idx_deadlines_due ON deadlines(due_at);

CREATE TABLE IF NOT EXISTS sync_state (
    source TEXT NOT NULL,
    key    TEXT NOT NULL,
    value  TEXT NOT NULL,
    PRIMARY KEY (source, key)
);

CREATE TABLE IF NOT EXISTS blocks (
    block_key       TEXT PRIMARY KEY,
    remote_event_id TEXT,
    calendar_id     TEXT,
    subject         TEXT NOT NULL,
    start_utc       TEXT NOT NULL,
    end_utc         TEXT NOT NULL,
    task_key        TEXT NOT NULL,
    state           TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    source      TEXT NOT NULL,
    external_id TEXT NOT NULL,
    team        TEXT NOT NULL,
    channel     TEXT NOT NULL,
    author      TEXT NOT NULL,
    posted_at   TEXT NOT NULL,
    body        TEXT NOT NULL,
    url         TEXT,
    attachments TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_messages_posted ON messages(posted_at);
"""


def _now() -> str:
    return datetime.now(UTC).isoformat()


def connect_private(path: Path) -> sqlite3.Connection:
    """Open a SQLite file only its owner can read: created mode 0600 (not chmod-ed after),
    and tightened if an earlier run made it looser. The journal copies the file's mode."""
    path.parent.mkdir(parents=True, exist_ok=True)
    os.close(os.open(path, os.O_RDWR | os.O_CREAT, 0o600))
    with contextlib.suppress(OSError):
        os.chmod(path, 0o600)
    return sqlite3.connect(path)


class Store:
    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)
        self.conn = connect_private(self.path)
        self.conn.row_factory = sqlite3.Row
        self._migrate()
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def _migrate(self) -> None:
        """Bring an older database up to the current column names.

        The first version addressed Graph event ids by name; the calendar is now
        reached through a backend, so the column is `remote_event_id`. Renaming
        in place keeps an existing ledger - dropping and recreating the table
        would orphan every event the tool has already written, and the next
        `apply` would duplicate the week rather than adopt it.
        """
        exists = self.conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='blocks'"
        ).fetchone()
        if not exists:
            return
        columns = {row["name"] for row in self.conn.execute("PRAGMA table_info(blocks)")}
        if "graph_event_id" in columns and "remote_event_id" not in columns:
            self.conn.execute("ALTER TABLE blocks RENAME COLUMN graph_event_id TO remote_event_id")
            self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> Store:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # --- sources ---------------------------------------------------------------

    def upsert_course(self, course: Course) -> None:
        self.conn.execute(
            """INSERT INTO courses (source, external_id, name, short_name)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(source, external_id)
               DO UPDATE SET name=excluded.name, short_name=excluded.short_name""",
            (course.source, course.external_id, course.name, course.short_name),
        )
        self.conn.commit()

    def upsert_material(self, m: Material) -> None:
        """Keyed on (source, external_id). A re-uploaded but byte-identical file
        keeps its sha256, so enrichment is not repeated needlessly."""
        self.conn.execute(
            """INSERT INTO materials (
                   source, external_id, course_external_id, name, rel_path, url, mime,
                   size, modified_at, local_path, sha256, summary, key_concepts,
                   difficulty, estimated_hours, seen_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(source, external_id) DO UPDATE SET
                   course_external_id=excluded.course_external_id,
                   name=excluded.name, rel_path=excluded.rel_path, url=excluded.url,
                   mime=excluded.mime, size=excluded.size,
                   modified_at=excluded.modified_at,
                   local_path=COALESCE(excluded.local_path, materials.local_path),
                   sha256=COALESCE(excluded.sha256, materials.sha256),
                   summary=COALESCE(excluded.summary, materials.summary),
                   key_concepts=COALESCE(excluded.key_concepts, materials.key_concepts),
                   difficulty=COALESCE(excluded.difficulty, materials.difficulty),
                   estimated_hours=COALESCE(excluded.estimated_hours, materials.estimated_hours),
                   seen_at=excluded.seen_at""",
            (
                m.source,
                m.external_id,
                m.course_external_id,
                m.name,
                m.rel_path,
                m.url,
                m.mime,
                m.size,
                m.modified_at.isoformat() if m.modified_at else None,
                m.local_path,
                m.sha256,
                m.summary,
                json.dumps(m.key_concepts) if m.key_concepts else None,
                m.difficulty,
                m.estimated_hours,
                _now(),
            ),
        )
        self.conn.commit()

    def upsert_deadline(self, d: Deadline) -> None:
        now = _now()
        self.conn.execute(
            """INSERT INTO deadlines (
                   source, external_id, course_external_id, course_name, title,
                   due_at, kind, url, first_seen, last_seen)
               VALUES (?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(source, external_id) DO UPDATE SET
                   course_external_id=excluded.course_external_id,
                   course_name=excluded.course_name, title=excluded.title,
                   due_at=excluded.due_at, kind=excluded.kind, url=excluded.url,
                   last_seen=excluded.last_seen""",
            (
                d.source,
                d.external_id,
                d.course_external_id,
                d.course_name,
                d.title,
                d.due_at.isoformat(),
                d.kind,
                d.url,
                now,
                now,
            ),
        )
        self.conn.commit()

    def upsert_message(self, m: ChannelMessage) -> None:
        """Keyed on (source, external_id), so re-reading a channel is safe.

        The body is stored exactly as it was posted. A lecturer's own wording is
        the evidence for why a deadline moved, so a paraphrase would destroy the
        only thing that makes the message worth keeping.
        """
        self.conn.execute(
            """INSERT INTO messages (
                   source, external_id, team, channel, author, posted_at, body, url,
                   attachments)
               VALUES (?,?,?,?,?,?,?,?,?)
               ON CONFLICT(source, external_id) DO UPDATE SET
                   team=excluded.team, channel=excluded.channel, author=excluded.author,
                   posted_at=excluded.posted_at, body=excluded.body, url=excluded.url,
                   attachments=excluded.attachments""",
            (
                m.source,
                m.external_id,
                m.team,
                m.channel,
                m.author,
                m.posted_at.isoformat(),
                m.body,
                m.url,
                json.dumps(m.attachments),
            ),
        )
        self.conn.commit()

    def messages(
        self, *, since: datetime | None = None, team: str | None = None
    ) -> list[ChannelMessage]:
        """Stored messages, newest first.

        `since` compares the stored ISO-8601 UTC strings directly. That is sound
        only because every row is written by `upsert_message` in one fixed,
        offset-suffixed format, so lexicographic order and chronological order
        agree.
        """
        clauses: list[str] = []
        args: list[str] = []
        if since is not None:
            clauses.append("posted_at >= ?")
            args.append(since.astimezone(UTC).isoformat())
        if team:
            clauses.append("team = ?")
            args.append(team)
        sql = "SELECT * FROM messages"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        rows = self.conn.execute(sql + " ORDER BY posted_at DESC", tuple(args)).fetchall()
        return [self._to_message(r) for r in rows]

    def materials(self, source: str | None = None) -> list[Material]:
        sql = "SELECT * FROM materials"
        args: tuple[object, ...] = ()
        if source:
            sql += " WHERE source = ?"
            args = (source,)
        rows = self.conn.execute(sql + " ORDER BY course_external_id, name", args).fetchall()
        return [self._to_material(r) for r in rows]

    def deadlines(self, source: str | None = None) -> list[Deadline]:
        sql = "SELECT * FROM deadlines"
        args: tuple[object, ...] = ()
        if source:
            sql += " WHERE source = ?"
            args = (source,)
        rows = self.conn.execute(sql + " ORDER BY due_at", args).fetchall()
        return [self._to_deadline(r) for r in rows]

    @staticmethod
    def _to_material(row: sqlite3.Row) -> Material:
        return Material(
            source=row["source"],
            external_id=row["external_id"],
            course_external_id=row["course_external_id"],
            name=row["name"],
            rel_path=row["rel_path"],
            url=row["url"],
            mime=row["mime"],
            size=row["size"],
            modified_at=datetime.fromisoformat(row["modified_at"]) if row["modified_at"] else None,
            local_path=row["local_path"],
            sha256=row["sha256"],
            summary=row["summary"],
            key_concepts=json.loads(row["key_concepts"]) if row["key_concepts"] else [],
            difficulty=row["difficulty"],
            estimated_hours=row["estimated_hours"],
        )

    @staticmethod
    def _to_message(row: sqlite3.Row) -> ChannelMessage:
        return ChannelMessage(
            source=row["source"],
            external_id=row["external_id"],
            team=row["team"],
            channel=row["channel"],
            author=row["author"],
            posted_at=datetime.fromisoformat(row["posted_at"]),
            body=row["body"],
            url=row["url"],
            attachments=json.loads(row["attachments"]) if row["attachments"] else [],
        )

    @staticmethod
    def _to_deadline(row: sqlite3.Row) -> Deadline:
        return Deadline(
            source=row["source"],
            external_id=row["external_id"],
            course_external_id=row["course_external_id"],
            course_name=row["course_name"],
            title=row["title"],
            due_at=datetime.fromisoformat(row["due_at"]),
            kind=row["kind"],
            url=row["url"],
        )

    # --- sync cursors ----------------------------------------------------------

    def set_state(self, source: str, key: str, value: str) -> None:
        self.conn.execute(
            """INSERT INTO sync_state (source, key, value) VALUES (?,?,?)
               ON CONFLICT(source, key) DO UPDATE SET value=excluded.value""",
            (source, key, value),
        )
        self.conn.commit()

    def get_state(self, source: str, key: str) -> str | None:
        row = self.conn.execute(
            "SELECT value FROM sync_state WHERE source=? AND key=?", (source, key)
        ).fetchone()
        return row["value"] if row else None

    def clear_state(self, source: str, key: str | None = None) -> None:
        if key is None:
            self.conn.execute("DELETE FROM sync_state WHERE source=?", (source,))
        else:
            self.conn.execute("DELETE FROM sync_state WHERE source=? AND key=?", (source, key))
        self.conn.commit()

    # --- calendar block ledger -------------------------------------------------

    def block_ledger(self, calendar_id: str) -> dict[str, sqlite3.Row]:
        rows = self.conn.execute(
            "SELECT * FROM blocks WHERE calendar_id=? AND state='active'", (calendar_id,)
        ).fetchall()
        return {r["block_key"]: r for r in rows}

    def record_block(self, block: Block, *, calendar_id: str, remote_event_id: str | None) -> None:
        self.conn.execute(
            """INSERT INTO blocks (
                   block_key, remote_event_id, calendar_id, subject,
                   start_utc, end_utc, task_key, state, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?)
               ON CONFLICT(block_key) DO UPDATE SET
                   remote_event_id=excluded.remote_event_id,
                   calendar_id=excluded.calendar_id, subject=excluded.subject,
                   start_utc=excluded.start_utc, end_utc=excluded.end_utc,
                   task_key=excluded.task_key, state=excluded.state,
                   updated_at=excluded.updated_at""",
            (
                block.block_key,
                remote_event_id,
                calendar_id,
                block.subject,
                block.start.isoformat(),
                block.end.isoformat(),
                block.task_key,
                "active",
                _now(),
            ),
        )
        self.conn.commit()

    def forget_block(self, block_key: str) -> None:
        self.conn.execute("DELETE FROM blocks WHERE block_key=?", (block_key,))
        self.conn.commit()

    def adopt_block(self, block_key: str, *, calendar_id: str, remote_event_id: str) -> None:
        """Register an event that already exists in the calendar but is missing
        from the local ledger - used after the database has been lost.

        Timings are left blank on purpose: `_drifted` then treats the row as
        stale and refreshes it from the freshly planned block on the next apply.
        """
        self.conn.execute(
            """INSERT OR IGNORE INTO blocks (
                   block_key, remote_event_id, calendar_id, subject,
                   start_utc, end_utc, task_key, state, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (block_key, remote_event_id, calendar_id, "", "", "", "", "active", _now()),
        )
        self.conn.commit()
