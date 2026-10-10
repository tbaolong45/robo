"""The source contract, the archive path guard, and per-source failure isolation.

`safe_rel_path` and `archive_path` are the only thing standing between an
upstream file name and arbitrary writes to disk. Moodle and Teams both hand us
names a lecturer typed, so every one of them is untrusted input.
"""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

import pytest

from pli.models import Course, Deadline, Material
from pli.sources.base import CHUNK, IngestResult, Source, iter_all

# --- safe_rel_path -----------------------------------------------------------------


def test_slashes_in_names_do_not_become_directories():
    assert Source.safe_rel_path("CS301/Week 3") == "CS301_Week 3"


def test_windows_separators_are_also_neutralised():
    assert Source.safe_rel_path("CS301\\notes") == "CS301_notes"


def test_a_traversal_attempt_cannot_introduce_a_separator():
    rel = Source.safe_rel_path("../../etc/passwd")

    assert "/" not in rel
    assert rel not in ("..", ".", "")
    assert not rel.startswith("..")


def test_an_absolute_path_is_flattened():
    assert not Source.safe_rel_path("/etc/shadow").startswith("/")


def test_each_part_stays_a_separate_component():
    """Parts are joined with '/', so a caller can still tree the archive by course."""
    assert Source.safe_rel_path("CS301", "Week 3", "slides.pdf") == "CS301/Week 3/slides.pdf"


def test_a_blank_name_falls_back_to_a_placeholder():
    """An empty component would collapse the path and lose a level."""
    assert Source.safe_rel_path("") == "_"
    assert Source.safe_rel_path("   ") == "_"
    assert Source.safe_rel_path("...") == "_"


def test_colons_and_quotes_do_not_survive():
    """Legal on Linux, a liability the moment anything syncs the archive."""
    rel = Source.safe_rel_path('Lecture 3: "IO" & streams')
    assert ":" not in rel
    assert '"' not in rel
    assert "&" not in rel


def test_normal_names_are_left_alone():
    assert Source.safe_rel_path("Week 3 - Dynamic Programming (v2).pdf") == (
        "Week 3 - Dynamic Programming (v2).pdf"
    )


def test_unicode_names_survive():
    """`isalnum()` is Unicode-aware; a Thai course name must not become underscores."""
    assert Source.safe_rel_path("การเขียนโปรแกรม") == "การเขียนโปรแกรม"


def test_a_very_long_name_is_truncated_per_part():
    rel = Source.safe_rel_path("x" * 500)
    assert len(rel) == 120


# --- archive_path -------------------------------------------------------------------


def test_archive_path_resolves_inside_the_root(tmp_path):
    dest = Source.archive_path(tmp_path, "CS301/week 3/slides.pdf")
    assert dest == (tmp_path / "CS301/week 3/slides.pdf").resolve()


def test_archive_path_refuses_to_escape_the_root(tmp_path):
    with pytest.raises(ValueError, match="outside the archive"):
        Source.archive_path(tmp_path, "../escaped.pdf")


def test_archive_path_refuses_an_absolute_path(tmp_path):
    with pytest.raises(ValueError, match="outside the archive"):
        Source.archive_path(tmp_path, "/etc/passwd")


def test_a_sibling_directory_sharing_the_prefix_is_still_outside(tmp_path):
    """`/data/materials-evil` starts with `/data/materials` but is not inside it."""
    root = tmp_path / "materials"
    root.mkdir()
    with pytest.raises(ValueError, match="outside the archive"):
        Source.archive_path(root, "../materials-evil/x")


def test_archive_path_allows_the_root_itself(tmp_path):
    assert Source.archive_path(tmp_path, ".") == tmp_path.resolve()


# --- hashing ------------------------------------------------------------------------


def test_sha256_of_a_file_matches_hashlib(tmp_path):
    path = tmp_path / "f.bin"
    path.write_bytes(b"hello world")
    assert Source.sha256_of(path) == hashlib.sha256(b"hello world").hexdigest()


def test_sha256_of_streams_across_chunk_boundaries(tmp_path):
    """A file larger than CHUNK must hash the same as hashing it in one shot."""
    data = b"a" * (CHUNK + 1234)
    path = tmp_path / "big.bin"
    path.write_bytes(data)
    assert Source.sha256_of(path) == hashlib.sha256(data).hexdigest()


def test_sha256_of_an_empty_file(tmp_path):
    path = tmp_path / "empty"
    path.write_bytes(b"")
    assert Source.sha256_of(path) == hashlib.sha256(b"").hexdigest()


def test_sha256_of_bytes_is_the_same_function():
    assert Source.sha256_of_bytes(b"abc") == hashlib.sha256(b"abc").hexdigest()


# --- IngestResult.merge ---------------------------------------------------------------


def _course(name="CS301") -> Course:
    return Course(source="stub", external_id=name.lower(), name=name)


def _material(key="m1") -> Material:
    return Material(
        source="stub",
        external_id=key,
        course_external_id="cs301",
        name="Slides.pdf",
        rel_path="CS301/Slides.pdf",
    )


def _deadline(key="d1") -> Deadline:
    return Deadline(
        source="stub",
        external_id=key,
        course_external_id="cs301",
        title="Problem Set 4",
        due_at=datetime(2026, 10, 2, tzinfo=UTC),
        kind="assignment",
    )


def test_merge_concatenates_every_collection():
    left = IngestResult(courses=[_course()], downloaded=2, skipped=1)
    left.merge(IngestResult(materials=[_material()], deadlines=[_deadline()], downloaded=3))

    assert len(left.courses) == 1
    assert len(left.materials) == 1
    assert len(left.deadlines) == 1
    assert (left.downloaded, left.skipped) == (5, 1)


def test_merge_collects_errors_rather_than_dropping_them():
    left = IngestResult()
    left.merge(IngestResult(errors=["teams: timeout"]))
    assert left.errors == ["teams: timeout"]


def test_merging_an_empty_result_changes_nothing():
    left = IngestResult(courses=[_course()], downloaded=1)
    left.merge(IngestResult())
    assert len(left.courses) == 1
    assert left.downloaded == 1


def test_two_results_do_not_share_lists():
    """The default factory is per-instance; a shared list would leak between sources."""
    a, b = IngestResult(), IngestResult()
    a.courses.append(_course())
    assert b.courses == []


# --- iter_all --------------------------------------------------------------------------


class _FakeSource(Source):
    def __init__(self, name, result=None, raises=None):
        self.name = name
        self._result = result or IngestResult()
        self._raises = raises
        self.calls: list[dict] = []

    def ingest(self, *, store, full=False):
        self.calls.append({"store": store, "full": full})
        if self._raises:
            raise self._raises
        return self._result


def test_iter_all_merges_every_source():
    a = _FakeSource("a", IngestResult(courses=[_course("A")], downloaded=1))
    b = _FakeSource("b", IngestResult(materials=[_material()]))

    total = iter_all([a, b], store=object())

    assert len(total.courses) == 1
    assert len(total.materials) == 1
    assert total.downloaded == 1


def test_one_failing_source_does_not_stop_the_others():
    """A Moodle outage must still leave the Teams half and cached deadlines usable."""
    bad = _FakeSource("moodle", raises=RuntimeError("token rejected"))
    good = _FakeSource("teams", IngestResult(deadlines=[_deadline()]))

    total = iter_all([bad, good], store=object())

    assert len(total.deadlines) == 1
    assert total.errors == ["moodle: RuntimeError: token rejected"]


def test_every_failure_is_recorded_not_just_the_first():
    sources = [_FakeSource(f"s{i}", raises=ValueError("nope")) for i in range(3)]
    total = iter_all(sources, store=object())
    assert len(total.errors) == 3


def test_a_source_is_still_run_after_a_preceding_failure():
    bad = _FakeSource("bad", raises=RuntimeError("boom"))
    good = _FakeSource("good")
    iter_all([bad, good], store=object())
    assert len(good.calls) == 1


def test_full_is_passed_through_to_every_source():
    sources = [_FakeSource("a"), _FakeSource("b")]
    store = object()
    iter_all(sources, store=store, full=True)

    assert all(s.calls == [{"store": store, "full": True}] for s in sources)


def test_base_source_ingest_is_abstract():
    with pytest.raises(NotImplementedError):
        Source().ingest(store=object())


def test_iter_all_over_nothing_is_an_empty_result():
    total = iter_all([], store=object())
    assert total.courses == [] and total.errors == []


def test_a_source_failure_is_reported_by_its_own_name():
    """The error string is the only breadcrumb; it must identify the source."""
    total = iter_all([_FakeSource("teams", raises=KeyError("tab"))], store=object())
    assert total.errors[0].startswith("teams: KeyError")


def test_the_archive_root_need_not_exist_yet(tmp_path):
    """Phase 1 writes nothing, but the guard must not require the directory."""
    assert Source.archive_path(tmp_path / "not-yet", "a/b.pdf")


def test_paths_are_posix_on_every_platform():
    """Backslash joins would produce a single long filename on POSIX."""
    rel = Source.safe_rel_path("a", "b")
    assert "/" in rel
    assert str(Path(rel)) == rel.replace("/", str(Path("/")))
