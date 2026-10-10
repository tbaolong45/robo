"""Task scoring: the LLM path, and the deterministic path it must always have.

The governing rule is that scoring is an optimisation, never a dependency - an
outage, a missing key or garbage output must all land on the heuristic.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

import pytest

from pli.config import Settings, StudyConfig
from pli.llm.client import LLMError
from pli.models import Task
from pli.planner import score as score_mod
from pli.planner.score import heuristic_scores, score_tasks

NOW = datetime(2026, 9, 28, 9, 0, tzinfo=UTC)


def _settings(key: str = "") -> Settings:
    return Settings(_env_file=None, llm_api_key=key, llm_model="test-model")


def _task(key: str = "t1", *, days: float = 3, **overrides) -> Task:
    base = {
        "key": key,
        "title": "Problem Set 1",
        "course": "CS301 Algorithms",
        "due_at": NOW + timedelta(days=days),
        "estimated_minutes": 120,
    }
    return Task(**{**base, **overrides})


class StubLLM:
    """Stands in for LLMClient; records what it was asked."""

    def __init__(self, reply=None, *, boom: bool = False):
        self.reply = reply
        self.boom = boom
        self.available = True
        self.calls: list[tuple[str, str]] = []

    def complete_json(self, system, user, **kwargs):
        self.calls.append((system, user))
        if self.boom:
            raise LLMError("upstream is down")
        return self.reply


@pytest.fixture
def stub(monkeypatch):
    """Install a stub LLMClient and hand it back."""

    def install(reply=None, *, boom: bool = False) -> StubLLM:
        stub = StubLLM(reply, boom=boom)
        monkeypatch.setattr(score_mod, "LLMClient", lambda settings: stub)
        return stub

    return install


# --- the heuristic fallback ------------------------------------------------------


def test_heuristic_is_deterministic():
    tasks = [_task("a"), _task("b", days=6)]
    cfg = StudyConfig()
    first = heuristic_scores(tasks, study_config=cfg, now=NOW)
    second = heuristic_scores(tasks, study_config=cfg, now=NOW)
    assert [t.priority for t in first] == [t.priority for t in second]


def test_sooner_work_ranks_higher():
    tasks = [_task("soon", days=1), _task("later", days=10)]
    scored = heuristic_scores(tasks, study_config=StudyConfig(), now=NOW)
    assert scored[0].priority > scored[1].priority


def test_priority_stays_within_bounds_even_when_overdue():
    scored = heuristic_scores([_task(days=-5)], study_config=StudyConfig(), now=NOW)
    assert 0.0 <= scored[0].priority <= 1.0


def test_course_weights_multiply_the_priority():
    cfg = StudyConfig(weights={"CS301 Algorithms": 2.0})
    plain = heuristic_scores([_task()], study_config=StudyConfig(), now=NOW)[0]
    weighted = heuristic_scores([_task()], study_config=cfg, now=NOW)[0]
    assert weighted.priority == pytest.approx(min(1.0, plain.priority * 2.0))
    assert weighted.priority > plain.priority


def test_heuristic_always_produces_a_detail_line():
    (scored,) = heuristic_scores([_task()], study_config=StudyConfig(), now=NOW)
    assert scored.detail.strip()


def test_heuristic_always_produces_a_positive_duration():
    (scored,) = heuristic_scores([_task(estimated_minutes=0)], study_config=StudyConfig(), now=NOW)
    assert scored.estimated_minutes > 0


def test_no_estimate_means_a_full_session_and_not_the_minimum():
    """A zero estimate is "nobody has judged this yet", not "this takes no time".

    It is the duration a task has when the source gave no material to estimate
    from - `tasks.build_tasks` seeds exactly the same value - so the heuristic
    has to restore the session ceiling rather than let the floor rescue it. A
    task silently booked for the 45-minute minimum disappears from the week.
    """
    (scored,) = heuristic_scores([_task(estimated_minutes=0)], study_config=StudyConfig(), now=NOW)
    assert scored.estimated_minutes == StudyConfig().study.session_max_minutes


def test_heuristic_preserves_keys_and_order():
    tasks = [_task("z", days=4), _task("a", days=2)]
    scored = heuristic_scores(tasks, study_config=StudyConfig(), now=NOW)
    assert [t.key for t in scored] == ["z", "a"]


# --- degradation ------------------------------------------------------------------


def test_no_api_key_skips_the_model_entirely():
    """`available` is False, so no client is even constructed."""
    tasks = [_task()]
    result = score_tasks(tasks, settings=_settings(), study_config=StudyConfig(), now=NOW)
    expected = heuristic_scores(tasks, study_config=StudyConfig(), now=NOW)
    assert [t.priority for t in result] == [t.priority for t in expected]


def test_a_model_outage_falls_back_instead_of_raising(stub):
    stub(boom=True)
    tasks = [_task()]
    result = score_tasks(tasks, settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    expected = heuristic_scores(tasks, study_config=StudyConfig(), now=NOW)
    assert [t.priority for t in result] == [t.priority for t in expected]


def test_garbage_output_falls_back(stub):
    stub({"not": "the shape we asked for"})
    result = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert (
        result[0].priority
        == heuristic_scores([_task()], study_config=StudyConfig(), now=NOW)[0].priority
    )


def test_nothing_open_means_no_model_call(stub):
    spy = stub({"tasks": []})
    past = [_task(days=-2)]
    score_tasks(past, settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert spy.calls == []


# --- the model path ---------------------------------------------------------------


def _reply(**overrides) -> dict:
    base = {
        "key": "t1",
        "priority": 0.9,
        "estimated_minutes": 240,
        "energy": "deep",
        "detail": "Start with the recurrence relations.",
    }
    return {"tasks": [{**base, **overrides}]}


def test_model_judgement_is_applied(stub):
    stub(_reply())
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.priority == pytest.approx(0.9)
    assert scored.estimated_minutes == 240
    assert scored.energy == "deep"
    assert scored.detail == "Start with the recurrence relations."


def test_the_model_is_called_once_for_the_whole_batch(stub):
    spy = stub({"tasks": [_reply()["tasks"][0], {**_reply()["tasks"][0], "key": "t2"}]})
    score_tasks(
        [_task("t1"), _task("t2")], settings=_settings("k"), study_config=StudyConfig(), now=NOW
    )
    assert len(spy.calls) == 1  # batching is what bounds the token cost


def test_the_prompt_carries_every_task_key(stub):
    spy = stub({"tasks": []})
    score_tasks(
        [_task("key-one"), _task("key-two")],
        settings=_settings("k"),
        study_config=StudyConfig(),
        now=NOW,
    )
    _, user = spy.calls[0]
    assert "key-one" in user and "key-two" in user


def test_keys_and_order_are_preserved(stub):
    stub(
        {
            "tasks": [
                {"key": "b", "priority": 0.3, "estimated_minutes": 60},
                {"key": "a", "priority": 0.8, "estimated_minutes": 60},
            ]
        }
    )
    scored = score_tasks(
        [_task("a"), _task("b")], settings=_settings("k"), study_config=StudyConfig(), now=NOW
    )
    assert [t.key for t in scored] == ["a", "b"]
    assert scored[0].priority == pytest.approx(0.8)


def test_title_and_course_are_never_rewritten_by_the_model(stub):
    stub(_reply(title="MODEL INVENTED THIS", course="WRONG"))
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.title == "Problem Set 1"
    assert scored.course == "CS301 Algorithms"


def test_an_out_of_range_priority_is_clamped(stub):
    stub(_reply(priority=17.0))
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.priority == 1.0


def test_an_absurd_duration_is_clamped_to_the_ceiling(stub):
    stub(_reply(estimated_minutes=99999))
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.estimated_minutes == score_mod.MAX_MINUTES


def test_an_unknown_task_key_from_the_model_is_ignored(stub):
    stub({"tasks": [{"key": "hallucinated", "priority": 1.0, "estimated_minutes": 30}]})
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.key == "t1"


def test_a_malformed_entry_degrades_alone(stub):
    """One bad element must not discard the good judgements beside it."""
    stub(
        {
            "tasks": [
                {"key": "t1", "priority": "not-a-float", "estimated_minutes": 60},
                {"key": "t2", "priority": 0.7, "estimated_minutes": 90},
            ]
        }
    )
    scored = score_tasks(
        [_task("t1"), _task("t2")], settings=_settings("k"), study_config=StudyConfig(), now=NOW
    )
    assert scored[1].priority == pytest.approx(0.7)  # good one applied
    assert scored[0].priority != 0.7  # bad one fell back


def test_a_missing_task_in_the_reply_falls_back(stub):
    stub(_reply())  # only mentions t1
    scored = score_tasks(
        [_task("t1"), _task("t2")], settings=_settings("k"), study_config=StudyConfig(), now=NOW
    )
    assert len(scored) == 2


def test_a_bare_list_reply_is_accepted(stub):
    stub([{"key": "t1", "priority": 0.6, "estimated_minutes": 60}])
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.priority == pytest.approx(0.6)


def test_a_keyed_dict_reply_is_accepted(stub):
    stub({"t1": {"key": "t1", "priority": 0.4, "estimated_minutes": 60}})
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.priority == pytest.approx(0.4)


def test_a_chatty_detail_is_truncated(stub):
    stub(_reply(detail="x" * 5000))
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert len(scored.detail) <= 300


def test_a_blank_detail_falls_back_to_the_heuristic_line(stub):
    stub(_reply(detail="   "))
    (scored,) = score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    assert scored.detail.strip()


def test_past_due_tasks_are_never_sent_to_the_model(stub):
    """No reason to spend tokens judging work whose deadline has passed."""
    spy = stub(_reply(priority=0.99))
    past = _task("old", days=-3)
    scored = score_tasks([past], settings=_settings("k"), study_config=StudyConfig(), now=NOW)

    assert spy.calls == []
    assert [t.key for t in scored] == ["old"]
    assert scored[0].priority != pytest.approx(0.99)


def test_a_past_due_task_keeps_its_fallback_in_a_mixed_batch(stub):
    """Work whose deadline has passed is filtered out of the batch, not just out
    of the prompt.

    Judgements are applied back by key, so a reply that happens to name a task
    already past its deadline would otherwise overwrite the fallback score of
    work that can no longer be scheduled - usually a model echoing a key it saw
    in an earlier call.
    """
    stub(
        {
            "tasks": [
                {"key": "old", "priority": 0.99, "estimated_minutes": 30},
                {"key": "t1", "priority": 0.9, "estimated_minutes": 60},
            ]
        }
    )
    tasks = [_task("old", days=-3), _task("t1")]
    scored = {
        t.key: t
        for t in score_tasks(tasks, settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    }
    (expected,) = heuristic_scores([_task("old", days=-3)], study_config=StudyConfig(), now=NOW)

    assert scored["old"].priority == pytest.approx(expected.priority)
    assert scored["old"].estimated_minutes == expected.estimated_minutes
    assert scored["t1"].priority == pytest.approx(0.9)  # the open task is still judged


def test_an_empty_task_list_is_handled(stub):
    stub({"tasks": []})
    assert score_tasks([], settings=_settings("k"), study_config=StudyConfig(), now=NOW) == []


def test_the_prompt_is_valid_json_for_the_model(stub):
    spy = stub({"tasks": []})
    score_tasks([_task()], settings=_settings("k"), study_config=StudyConfig(), now=NOW)
    _, user = spy.calls[0]
    json.loads(user.split("Tasks:\n", 1)[1])  # the task block is machine-readable
