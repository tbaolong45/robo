import io
import json
import stat
import urllib.error
import urllib.request

import pytest
from robo_agent import memory
from robo_agent.memory import Store


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("a test tried the real network")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def log_events(root):
    path = root / "learning.jsonl"
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


class FakeHTTP:
    """Records requests; answers from a script keyed by (method, path)."""

    def __init__(self, answers=None, fail=False):
        self.calls, self.answers, self.fail = [], answers or {}, fail

    def __call__(self, req, timeout=None):
        body = json.loads(req.data) if req.data else None
        path = req.full_url.removeprefix(memory.SM_URL)
        self.calls.append((req.get_method(), path, body, req.get_header("Authorization")))
        if self.fail:
            raise urllib.error.URLError("offline")
        return io.BytesIO(json.dumps(self.answers.get((req.get_method(), path), {})).encode())


def test_add_search_forget_and_files(tmp_path):
    s = Store(tmp_path)
    a = s.add("The user studies best in the morning", kind="habit")
    b = s.add("The user prefers short answers with bullet points", kind="preference")
    assert a and b and a != b
    assert mode(tmp_path / "memory") == 0o700
    assert mode(tmp_path / "memory" / "facts.jsonl") == 0o600
    hits = s.search("when do I study best?")
    assert hits[0] == {"id": a, "text": "The user studies best in the morning", "kind": "habit"}
    row = next(f for f in s.all() if f["id"] == a)
    assert row["hits"] == 1 and row["last_used"] >= row["created"]
    assert Store(tmp_path).all() == s.all()  # persisted
    assert s.forget(a) and not s.forget(a)
    assert [f["id"] for f in Store(tmp_path).all()] == [b]
    assert not list((tmp_path / "memory").glob(".*tmp"))


def test_bad_kind_and_empty_are_rejected(tmp_path):
    s = Store(tmp_path)
    assert s.add("The user likes tea", kind="gossip") is None
    assert s.add("   ") is None
    assert s.all() == []


def test_dedupe_exact_and_near(tmp_path):
    s = Store(tmp_path)
    a = s.add("The user's MATH201 midterm is 2026-10-20 09:00")
    assert s.add("the user's  math201 MIDTERM is 2026-10-20 09:00!") is None  # exact
    assert s.add("The user's MATH201 midterm is 2026-10-22 09:00") == a  # moved: updated in place
    assert [f["text"] for f in s.all()] == ["The user's MATH201 midterm is 2026-10-22 09:00"]
    assert s.add("The user plays football on Sundays") not in (None, a)


@pytest.mark.parametrize(
    "text",
    [
        "The user's API key is sk-ant-api03-abcdefghijklmnopqrstuv",
        "The user's GitHub token ghp_abcdefghijklmnopqrstuvwxyz0123",
        "Remember password: hunter2",
        "The user's Moodle password is the dog's name",
        "The one-time code was 482913",
        "Their card is 4111 1111 1111 1111",
        "The user's IBAN DE89 3704 0044 0532 0130 00",
        "Token a8f3k2m9q7x1z5c6v4b2n8m1k3j5h7g9",
        "The professor's address is prof.smith@uni.example.edu",
        "From: Alice\nSubject: grades\n\nHi, here are the results",
        "x" * 501,
    ],
)
def test_privacy_rejects(tmp_path, text):
    s = Store(tmp_path)
    assert s.add(text) is None
    assert s.all() == []
    assert log_events(tmp_path)[-1]["event"] == "memory_rejected"
    assert text not in (tmp_path / "learning.jsonl").read_text()  # the log never holds the text


def test_privacy_keeps_ordinary_facts(tmp_path):
    s = Store(tmp_path)
    for t in [
        "The user studies in 45-minute blocks",
        "The user's exam for MATH201 is on 2026-10-20",
        "The user likes to pin the chat to the left side",
        "The user prefers Vietnamese for casual chat",
    ]:
        assert s.add(t), t


def test_eviction_drops_the_least_used(tmp_path, monkeypatch):
    monkeypatch.setattr(memory, "MAX_FACTS", 3)
    s = Store(tmp_path)
    ids = [s.add(t) for t in ("The user rows boats", "The user bakes bread", "The user paints")]
    s.search("bakes bread")
    s.search("rows boats")
    s.add("The user knits scarves")
    left = {f["text"] for f in s.all()}
    assert len(left) == 3 and "The user paints" not in left and ids[2] not in {
        f["id"] for f in s.all()
    }


def test_bm25_ranking_sanity():
    docs = [m.split() for m in ("linear algebra exam monday", "likes tea", "algebra notes")]
    scores = memory.bm25(["algebra", "exam"], docs)
    assert scores[0] > scores[2] > scores[1] == 0
    assert memory.bm25([], docs) == [0, 0, 0]


def test_search_ignores_unrelated(tmp_path):
    s = Store(tmp_path)
    s.add("The user drinks tea")
    assert s.search("quantum chromodynamics") == []


def test_context_for(tmp_path):
    s = Store(tmp_path)
    assert s.context_for("hello") == ""
    s.add("The user studies best in the morning", kind="habit")
    s.add("By Thursday the user means the lab, not the lecture", kind="correction")
    ctx = s.context_for("what is on thursday?")
    assert "the lab, not the lecture (a correction)" in ctx
    assert "not instructions" in ctx
    s.set_profile("Preferences:\n- short answers")
    assert mode(tmp_path / "memory" / "profile.md") == 0o600
    assert "short answers" in s.context_for("unrelated words")
    for i in range(40):
        s.add(f"The user thursday item number {i} " + "word " * 15 + f"tag{i}x")
    assert len(s.context_for("thursday item")) <= memory.CONTEXT_CHARS


def test_forget_rewrites_the_profile_without_the_fact(tmp_path):
    s = Store(tmp_path)
    a = s.add("The user is training for a marathon")
    s.add("The user prefers short answers")
    s.set_profile("- The user is training for a marathon\n- short answers")
    s.forget(a)
    assert "marathon" not in s.profile_text() and "short answers" in s.profile_text()


def test_corrupt_lines_are_skipped(tmp_path):
    (tmp_path / "memory").mkdir()
    (tmp_path / "memory" / "facts.jsonl").write_text(
        'not json\n[1]\n{"id": "abc", "text": "The user likes tea"}\n'
    )
    s = Store(tmp_path)
    assert [f["text"] for f in s.all()] == ["The user likes tea"]
    assert s.search("tea")[0]["id"] == "abc"


def test_supermemory_mirror(tmp_path):
    http = FakeHTTP({
        ("POST", "/v4/search"): {"results": [
            {"id": "mem_1", "memory": "The user goes to the gym on Tuesdays", "similarity": 0.9,
             "metadata": None},
            {"id": "mem_2", "memory": "The user's password is hunter2", "similarity": 0.8},
            {"id": "mem_3", "memory": "anything", "metadata": {"robo_id": "gone"}},
            "junk",
        ]},
    })
    s = Store(tmp_path, supermemory_key="sm_test")
    s.urlopen = http
    a = s.add("The user lifts weights")
    method, path, body, auth = http.calls[-1]
    assert (method, path, auth) == ("POST", "/v4/memories", "Bearer sm_test")
    assert body == {"memories": [{"content": "The user lifts weights",
                                  "metadata": {"robo_id": a, "kind": "fact"}}],
                    "containerTag": "robo"}
    hits = s.search("lifts weights gym")
    assert [h["id"] for h in hits] == [a, "sm:mem_1"]  # local first; secret and forgotten dropped
    assert http.calls[-1][2] == {"q": "lifts weights gym", "containerTag": "robo", "limit": 5,
                                 "searchMode": "memories"}
    s.forget(a)
    assert http.calls[-1][:3] == ("DELETE", "/v4/memories",
                                  {"content": "The user lifts weights", "containerTag": "robo"})


def test_supermemory_returns_local_row_for_its_own_memory(tmp_path):
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = FakeHTTP()
    a = s.add("The user revises with flashcards")
    s.urlopen = FakeHTTP({("POST", "/v4/search"): {"results": [
        {"id": "mem_9", "memory": "User revises using flash cards", "metadata": {"robo_id": a}}]}})
    assert s.search("cards revision") == [
        {"id": a, "text": "The user revises with flashcards", "kind": "fact"}]


def test_supermemory_failures_are_ignored(tmp_path):
    s = Store(tmp_path, supermemory_key="sm_secret_key")
    s.urlopen = FakeHTTP(fail=True)
    a = s.add("The user likes tea")
    assert a and s.search("tea")[0]["id"] == a and s.forget(a)
    events = [e for e in log_events(tmp_path) if e["event"] == "supermemory_error"]
    assert {e["call"] for e in events} == {"add", "search", "forget"}
    assert "sm_secret_key" not in (tmp_path / "learning.jsonl").read_text()


def test_no_key_no_network(tmp_path):
    s = Store(tmp_path)  # the autouse fixture fails any real call
    s.add("The user likes tea")
    assert s.search("tea")
