"""State store: upsert idempotency, enrichment preservation, ledger behaviour."""

from __future__ import annotations

import os
import stat
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from pli.db import Store
from pli.models import Block, ChannelMessage, Course, Deadline, Material

NOW = datetime(2026, 9, 28, 9, 0, tzinfo=UTC)


@pytest.fixture
def store(tmp_path):
    with Store(tmp_path / "state.db") as s:
        yield s


def _material(external_id: str = "m1", **overrides) -> Material:
    base = {
        "source": "stub",
        "external_id": external_id,
        "course_external_id": "CS301",
        "name": "week1.pdf",
        "rel_path": "CS301/week1.pdf",
        "url": "https://example.test/week1.pdf",
        "mime": "application/pdf",
        "size": 1234,
        "modified_at": NOW,
    }
    return Material(**{**base, **overrides})


def _deadline(external_id: str = "d1", **overrides) -> Deadline:
    base = {
        "source": "stub",
        "external_id": external_id,
        "course_external_id": "CS301",
        "course_name": "CS301 Algorithms",
        "title": "Problem Set 1",
        "due_at": NOW + timedelta(days=3),
        "kind": "assignment",
        "url": "https://example.test/ps1",
    }
    return Deadline(**{**base, **overrides})


def _block(key: str = "k1", *, minutes: int = 60) -> Block:
    return Block(
        block_key=key,
        task_key="t1",
        subject="CS301 Algorithms",
        start=NOW,
        end=NOW + timedelta(minutes=minutes),
    )


# --- courses -------------------------------------------------------------------


def test_course_upsert_updates_in_place(store):
    store.upsert_course(Course(source="stub", external_id="CS301", name="Algorithms"))
    store.upsert_course(
        Course(source="stub", external_id="CS301", name="Algorithms & Data", short_name="CS301")
    )
    rows = store.conn.execute("SELECT * FROM courses").fetchall()
    assert len(rows) == 1
    assert rows[0]["name"] == "Algorithms & Data"
    assert rows[0]["short_name"] == "CS301"


def test_same_external_id_from_two_sources_coexist(store):
    store.upsert_course(Course(source="moodle", external_id="42", name="From Moodle"))
    store.upsert_course(Course(source="teams", external_id="42", name="From Teams"))
    assert len(store.conn.execute("SELECT * FROM courses").fetchall()) == 2


# --- materials -----------------------------------------------------------------


def test_material_roundtrip_preserves_fields(store):
    store.upsert_material(_material())
    (got,) = store.materials()
    assert got.name == "week1.pdf"
    assert got.size == 1234
    assert got.modified_at == NOW
    assert got.key_concepts == []


def test_material_resync_keeps_enrichment(store):
    """A re-sync reports the same file with no enrichment; the enrichment survives.

    This is what makes a nightly sync safe to run over a corpus that has already
    been summarised - without the COALESCE, every run would wipe Phase 4's work.
    """
    store.upsert_material(
        _material(
            local_path="/data/materials/stub/CS301/week1.pdf",
            sha256="a" * 64,
            summary="Covers asymptotic notation.",
            key_concepts=["big-O", "amortised"],
            difficulty=3,
            estimated_hours=4.0,
        )
    )
    store.upsert_material(_material())  # plain re-sync, no enrichment fields

    (got,) = store.materials()
    assert got.local_path == "/data/materials/stub/CS301/week1.pdf"
    assert got.sha256 == "a" * 64
    assert got.summary == "Covers asymptotic notation."
    assert got.key_concepts == ["big-O", "amortised"]
    assert got.difficulty == 3
    assert got.estimated_hours == 4.0


def test_material_resync_still_updates_volatile_fields(store):
    store.upsert_material(_material(size=1234))
    store.upsert_material(_material(size=9999, url="https://example.test/v2.pdf"))
    (got,) = store.materials()
    assert got.size == 9999
    assert got.url == "https://example.test/v2.pdf"


def test_materials_filter_by_source(store):
    store.upsert_material(_material("a"))
    store.upsert_material(_material("b", source="teams"))
    assert len(store.materials()) == 2
    assert len(store.materials(source="teams")) == 1


# --- deadlines -----------------------------------------------------------------


def test_deadline_upsert_moves_the_due_date(store):
    store.upsert_deadline(_deadline())
    later = NOW + timedelta(days=10)
    store.upsert_deadline(_deadline(due_at=later))
    (got,) = store.deadlines()
    assert got.due_at == later
    assert len(store.deadlines()) == 1


def test_deadlines_are_ordered_by_due_date(store):
    store.upsert_deadline(_deadline("late", due_at=NOW + timedelta(days=9)))
    store.upsert_deadline(_deadline("soon", due_at=NOW + timedelta(days=1)))
    assert [d.external_id for d in store.deadlines()] == ["soon", "late"]


def test_deadline_first_seen_is_not_clobbered(store):
    store.upsert_deadline(_deadline())
    first = store.conn.execute("SELECT first_seen FROM deadlines").fetchone()["first_seen"]
    store.upsert_deadline(_deadline(title="Problem Set 1 (revised)"))
    row = store.conn.execute("SELECT * FROM deadlines").fetchone()
    assert row["first_seen"] == first
    assert row["title"] == "Problem Set 1 (revised)"


# --- messages ------------------------------------------------------------------


def _message(external_id: str = "m1", **overrides) -> ChannelMessage:
    base = {
        "source": "teams",
        "external_id": external_id,
        "team": "CS301 Algorithms",
        "channel": "General",
        "author": "Dr Somchai",
        "posted_at": NOW,
        "body": "Quiz 3 moved to Friday.",
        "url": "https://teams.microsoft.com/l/message/1",
        "attachments": ["spec.pdf"],
    }
    return ChannelMessage(**{**base, **overrides})


def test_message_reread_does_not_duplicate(store):
    """Reading the same channel twice is the normal case - a channel is re-read
    every sync and most posts have not changed. The id has to make that safe."""
    store.upsert_message(_message())
    store.upsert_message(_message())
    assert len(store.messages()) == 1


def test_message_upsert_corrects_the_body_in_place(store):
    store.upsert_message(_message())
    store.upsert_message(_message(body="Quiz 3 moved to Monday."))
    (got,) = store.messages()
    assert got.body == "Quiz 3 moved to Monday."


def test_message_body_is_stored_verbatim(store):
    """The body is the evidence for why a deadline moved. Normalising it - even
    with a harmless-looking strip - would destroy the thing worth keeping."""
    nasty = "ยกเลิกคลาส | บรรทัดที่สอง\n  leading and trailing  "
    store.upsert_message(_message(body=nasty))
    (got,) = store.messages()
    assert got.body == nasty


def test_messages_are_newest_first(store):
    store.upsert_message(_message("older", posted_at=NOW - timedelta(days=2)))
    store.upsert_message(_message("newer", posted_at=NOW))
    assert [m.external_id for m in store.messages()] == ["newer", "older"]


def test_messages_since_filters_by_age(store):
    store.upsert_message(_message("old", posted_at=NOW - timedelta(days=10)))
    store.upsert_message(_message("recent", posted_at=NOW))
    got = store.messages(since=NOW - timedelta(days=1))
    assert [m.external_id for m in store.messages(since=NOW - timedelta(days=1))] == ["recent"]
    assert got[0].posted_at == NOW


def test_messages_can_be_scoped_to_one_team(store):
    store.upsert_message(_message("a", team="CS301 Algorithms"))
    store.upsert_message(_message("b", team="CS302 Networks"))
    assert [m.external_id for m in store.messages(team="CS302 Networks")] == ["b"]


def test_message_timestamps_stay_timezone_aware(store):
    """A naive timestamp here would make every duration comparison against a
    deadline a guess, so the round trip must preserve the zone."""
    store.upsert_message(_message())
    (got,) = store.messages()
    assert got.posted_at.tzinfo is not None
    assert got.posted_at == NOW


def test_message_course_identity_is_the_team_name(store):
    store.upsert_message(_message(team="CS301 Algorithms"))
    (got,) = store.messages()
    assert got.course == "CS301 Algorithms"


# --- sync cursors --------------------------------------------------------------


def test_state_set_get_overwrite(store):
    """Cursors hold the high-water mark of the last successful read, so a
    repeated sync resumes rather than re-reading every channel from scratch."""
    assert store.get_state("teams", "messages:COMP1010/General") is None
    store.set_state("teams", "messages:COMP1010/General", NOW.isoformat())
    later = (NOW + timedelta(hours=1)).isoformat()
    store.set_state("teams", "messages:COMP1010/General", later)
    assert store.get_state("teams", "messages:COMP1010/General") == later


def test_clear_state_one_key_or_all(store):
    store.set_state("teams", "a", "1")
    store.set_state("teams", "b", "2")
    store.set_state("moodle", "c", "3")

    store.clear_state("teams", "a")
    assert store.get_state("teams", "a") is None
    assert store.get_state("teams", "b") == "2"

    store.clear_state("teams")
    assert store.get_state("teams", "b") is None
    assert store.get_state("moodle", "c") == "3"  # other sources untouched


# --- block ledger --------------------------------------------------------------


def test_block_ledger_is_scoped_to_one_calendar(store):
    store.record_block(_block("k1"), calendar_id="calA", remote_event_id="e1")
    store.record_block(_block("k2"), calendar_id="calB", remote_event_id="e2")
    assert set(store.block_ledger("calA")) == {"k1"}
    assert set(store.block_ledger("calB")) == {"k2"}


def test_record_block_is_idempotent_on_block_key(store):
    store.record_block(_block("k1"), calendar_id="calA", remote_event_id="e1")
    store.record_block(_block("k1"), calendar_id="calA", remote_event_id="e1")
    assert len(store.conn.execute("SELECT * FROM blocks").fetchall()) == 1


def test_forget_block_removes_the_row(store):
    store.record_block(_block("k1"), calendar_id="calA", remote_event_id="e1")
    store.forget_block("k1")
    assert store.block_ledger("calA") == {}


def test_adopt_block_records_an_orphan_event(store):
    """Adoption must never overwrite a real ledger row - it is a recovery path."""
    store.adopt_block("k1", calendar_id="calA", remote_event_id="orphan1")
    (row,) = store.block_ledger("calA").values()
    assert row["remote_event_id"] == "orphan1"
    assert row["start_utc"] == ""  # blank provenance, so `_drifted` refreshes it

    store.adopt_block("k1", calendar_id="calA", remote_event_id="orphan2")
    (row,) = store.block_ledger("calA").values()
    assert row["remote_event_id"] == "orphan1"  # INSERT OR IGNORE


def test_store_is_usable_as_a_context_manager(tmp_path):
    path = tmp_path / "state.db"
    with Store(path) as s:
        s.upsert_course(Course(source="stub", external_id="C1", name="C"))
    with Store(path) as s:
        assert len(s.conn.execute("SELECT * FROM courses").fetchall()) == 1


def test_the_state_file_holds_chat_text_so_only_its_owner_can_read_it(tmp_path: Path) -> None:
    path = tmp_path / "data" / "state.db"

    Store(path).close()

    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_a_state_file_made_earlier_with_looser_rights_is_tightened(tmp_path: Path) -> None:
    path = tmp_path / "state.db"
    path.touch(mode=0o644)

    Store(path).close()

    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
