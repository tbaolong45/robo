import io
import json
import stat
import threading
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


# --- one shared store ---------------------------------------------------------------------------

def test_goals_and_events_are_kept_and_summarised(tmp_path):
    s = Store(tmp_path)
    assert s.add("Pass linear algebra", kind="goal")
    assert s.add("MATH201 midterm 2026-10-20", kind="event")
    text = memory.summary(s.all())
    assert "Goals:\n- Pass linear algebra" in text and "Events:\n- MATH201" in text


def test_another_process_forgetting_is_not_undone(tmp_path):
    served = Store(tmp_path)
    a = served.add("The user likes tea")
    Store(tmp_path).forget(a)  # `robo-agent memory forget`
    served.add("The user owns a bicycle")
    assert [f["text"] for f in served.all()] == ["The user owns a bicycle"]
    assert [f["text"] for f in Store(tmp_path).all()] == ["The user owns a bicycle"]


def test_no_http_call_holds_the_lock(tmp_path):
    s = Store(tmp_path, supermemory_key="k")
    free = []
    http = FakeHTTP({("POST", "/v4/search"): {"results": []}})

    def urlopen(req, timeout=None):
        t = threading.Thread(target=lambda: free.append(s._lock.acquire(timeout=1)
                                                        and (s._lock.release() or True)))
        t.start()
        t.join()
        return http(req, timeout)

    s.urlopen = urlopen
    a = s.add("The user lifts weights")
    s.add("The user lifts heavy weights")  # near duplicate: forget + add
    s.search("gym")
    s.forget(a)
    assert len(free) >= 4 and all(free)


def test_a_search_while_a_reload_replaces_the_rows_still_counts_the_hit(tmp_path):
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = FakeHTTP()
    a = s.add("The user lifts weights")
    other = Store(tmp_path)
    real = s._sm_search

    def racing(query, limit):
        other.add("The user owns a bicycle")  # the file changes while the call is out
        s.all()
        return real(query, limit)

    s._sm_search = racing
    s.search("weights", limit=5)
    assert next(f for f in Store(tmp_path).all() if f["id"] == a)["hits"] == 1


# --- what Supermemory gets ------------------------------------------------------------------------

def test_the_raw_request_never_goes_to_supermemory(tmp_path):
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    s.add("The user likes tea")
    s.context_for("write to my landlord Bob about the rent")
    assert "landlord" not in json.dumps([c[2] for c in http.calls])
    assert [c[1] for c in http.calls] == ["/v4/memories"]  # the fact itself, nothing else


def test_a_search_with_something_private_stays_here(tmp_path):
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    s.search("what did bob@example.com say")
    assert http.calls == []


def test_mirror_false_keeps_a_fact_here(tmp_path):
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    assert s.add("The user corrected Robo: Bob, not Rob", kind="correction", mirror=False)
    assert http.calls == []


def test_counted_habits_never_reach_supermemory(tmp_path, monkeypatch):
    monkeypatch.setattr(memory, "MAX_FACTS", 1)  # a full store: no eviction call either
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    s.set_habits({"a:b": "The user studies at night (5 of 5)."})
    s.set_habits({"a:b": "The user studies at night (6 of 6)."})
    habit = next(f for f in s.all() if f.get("habit_key"))
    s._sm_add(habit)  # the mark holds wherever a row comes from
    assert s.forget(habit["id"])
    s.set_habits({"c:d": "The user reads mail in the morning (7 of 7)."})
    s.set_habits({})
    assert http.calls == []


RAW = "The user corrected Robo: my landlord Bob, not Rob"


def keyed(tmp_path):
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    return s, http


def test_forgetting_an_unmirrored_fact_sends_nothing_even_after_a_restart(tmp_path):
    s, http = keyed(tmp_path)
    a = s.add(RAW, kind="correction", mirror=False)
    assert s.forget(a) and http.calls == []
    b = s.add(RAW, kind="correction", mirror=False)
    again, http2 = keyed(tmp_path)
    assert again.forget(b) and http.calls == [] and http2.calls == []


def test_evicting_an_unmirrored_fact_sends_nothing(tmp_path, monkeypatch):
    s, http = keyed(tmp_path)
    s.add(RAW, kind="correction", mirror=False)
    monkeypatch.setattr(memory, "MAX_FACTS", 1)
    s.add("The user owns a bicycle")
    assert [f["text"] for f in s.all()] == ["The user owns a bicycle"]
    assert [c[:2] for c in http.calls] == [("POST", "/v4/memories")]
    assert "landlord" not in json.dumps(http.calls)


def test_replacing_an_unmirrored_fact_never_sends_its_words(tmp_path):
    s, http = keyed(tmp_path)
    s.add(RAW, kind="correction", mirror=False)
    a = s.add(RAW + " please", kind="correction", mirror=False)
    assert len(s.all()) == 1 and http.calls == []  # still unmirrored
    assert s.add(RAW + " now", kind="correction") == a  # vetted: only the new text goes
    assert [c[:2] for c in http.calls] == [("POST", "/v4/memories")]
    assert http.calls[0][2]["memories"][0]["content"] == RAW + " now"
    assert s.forget(a)  # and now it was sent, so it is taken back
    assert http.calls[-1][:2] == ("DELETE", "/v4/memories")


def test_raw_words_replacing_a_mirrored_fact_take_it_back_and_stay_here(tmp_path):
    s, http = keyed(tmp_path)
    a = s.add(RAW)
    http.calls.clear()
    assert s.add(RAW + " please", kind="correction", mirror=False) == a
    assert [c[:2] for c in http.calls] == [("DELETE", "/v4/memories")]
    assert http.calls[0][2]["content"] == RAW
    http.calls.clear()
    assert s.forget(a) and http.calls == []


def test_a_vetted_fact_is_not_merged_into_a_counted_habit(tmp_path):
    http = FakeHTTP()
    s = Store(tmp_path, supermemory_key="k")
    s.urlopen = http
    s.set_habits({"a:b": "The user studies at night."})
    a = s.add("The user studies at night always")
    assert [c[:2] for c in http.calls] == [("POST", "/v4/memories")]
    assert http.calls[0][2]["memories"][0]["content"] == "The user studies at night always"
    assert {f["id"]: bool(f.get("habit_key")) for f in s.all()}[a] is False and len(s.all()) == 2
