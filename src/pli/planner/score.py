"""Judge tasks: priority, duration, energy. The only LLM touchpoint in the plan.

This module never places anything on a calendar - a separate deterministic
packer owns that. Everything here degrades: no API key, a timeout, malformed
JSON or a failed field all fall back to `heuristic_scores`.
"""

from __future__ import annotations

import json
from datetime import datetime

from pydantic import BaseModel, Field, ValidationError

from pli.config import Settings, StudyConfig
from pli.llm.client import LLMClient, LLMError
from pli.models import Energy, Task

MAX_MINUTES = 20 * 60

_SYSTEM = """You triage a student's coursework. For every task you are given,
return a realistic judgement.

Reply with STRICT JSON only - no prose, no markdown fences - as an object:
{"tasks": [{"key": "...", "priority": 0.0, "estimated_minutes": 60,
            "energy": "deep", "detail": "..."}]}

Rules:
- `key` must be echoed back EXACTLY as given. Never invent keys, never omit a task.
- `priority` is a float from 0.0 to 1.0; higher means more important and urgent.
- `estimated_minutes` is a whole number of minutes of focused work, estimated
  realistically for a student who is learning the material, not an expert.
- `energy` is "deep" (needs concentration) or "shallow" (mechanical, low focus).
- `detail` is ONE short sentence on how to tackle the task."""


class _Judged(BaseModel):
    """One element of the model's reply, validated."""

    key: str
    priority: float = 0.5
    estimated_minutes: int
    energy: Energy = "shallow"
    detail: str = ""


class _Batch(BaseModel):
    tasks: list[_Judged] = Field(default_factory=list)


def score_tasks(
    tasks: list[Task],
    *,
    settings: Settings,
    study_config: StudyConfig,
    now: datetime,
) -> list[Task]:
    """Return tasks with priority/estimated_minutes/energy/detail filled in.

    Same keys, same order as `tasks`. Tasks already past due are never sent to
    the model - they keep their heuristic score, so no token is spent judging
    work that can no longer be scheduled. One batched LLM call; any failure
    falls back to the heuristic.
    """
    fallback = {t.key: t for t in heuristic_scores(tasks, study_config=study_config, now=now)}
    open_tasks = [t for t in tasks if t.due_at > now]
    client = LLMClient(settings)
    if not open_tasks or not client.available:
        return [fallback[t.key] for t in tasks]

    try:
        raw = client.complete_json(_SYSTEM, _user_prompt(open_tasks, now=now))
    except LLMError:
        return [fallback[t.key] for t in tasks]

    judged: dict[str, _Judged] = {}
    for item in _items(raw):
        try:
            model = _Judged.model_validate(item)
        except ValidationError:
            continue  # this task keeps its heuristic score
        judged.setdefault(model.key, model)

    scored: list[Task] = []
    for task in tasks:
        model = judged.get(task.key) if task.due_at > now else None
        if model is None:
            scored.append(fallback[task.key])
            continue
        scored.append(
            task.model_copy(
                update={
                    "priority": min(1.0, max(0.0, model.priority)),
                    "estimated_minutes": _clamp_minutes(model.estimated_minutes, study_config),
                    "energy": model.energy,
                    "detail": " ".join(model.detail.split())[:300] or fallback[task.key].detail,
                }
            )
        )
    return scored


def heuristic_scores(tasks: list[Task], *, study_config: StudyConfig, now: datetime) -> list[Task]:
    """Deterministic scoring - no network, no randomness, always usable."""
    urgent_within = max(1.0, float(study_config.deadlines.urgent_within_days))
    scored: list[Task] = []
    for task in tasks:
        days = max(0.0, (task.due_at - now).total_seconds() / 86400)
        priority = (1.0 / (1.0 + days / urgent_within)) * study_config.weight_for(task.course)
        minutes = task.estimated_minutes
        if minutes <= 0:  # carried no estimate
            minutes = study_config.study.session_max_minutes
        scored.append(
            task.model_copy(
                update={
                    "priority": min(1.0, max(0.0, priority)),
                    "estimated_minutes": _clamp_minutes(minutes, study_config),
                    "energy": task.energy or "shallow",
                    "detail": _fallback_detail(task),
                }
            )
        )
    return scored


def _clamp_minutes(value: int, study_config: StudyConfig) -> int:
    lo = max(1, study_config.study.session_min_minutes)
    return max(lo, min(int(value), MAX_MINUTES))


def _fallback_detail(task: Task) -> str:
    due = task.due_at.strftime("%a %d %b")
    return f"{task.course}: work through '{task.title}' in ranked chunks before it is due {due}."


def _items(raw: dict) -> list:
    """Accept {"tasks": [...]}; tolerate a bare list or dict-of-keyed-tasks."""
    payload = raw.get("tasks", raw) if isinstance(raw, dict) else raw
    if isinstance(payload, dict):
        payload = list(payload.values())
    return [i for i in payload if isinstance(i, dict)] if isinstance(payload, list) else []


def _user_prompt(tasks: list[Task], *, now: datetime) -> str:
    """The full task list as compact JSON - one call scores all of them."""
    lines = [
        {
            "key": t.key,
            "title": t.title,
            "course": t.course,
            "due_at": t.due_at.isoformat(),
            "estimated_minutes": t.estimated_minutes,
            "energy": t.energy,
        }
        for t in tasks
    ]
    return f"Current time: {now.isoformat()}\n\nTasks:\n{json.dumps(lines, ensure_ascii=False)}"
