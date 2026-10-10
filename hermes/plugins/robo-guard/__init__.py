"""robo-guard: veto write-like browser actions so robo stays read-only on school sites.

Hermes contract (hermes_cli/plugins.py `_get_pre_tool_call_directive_details`): a pre_tool_call
callback that returns {"action": "block", "message": <non-empty str>} vetoes the call, and the
message becomes the tool result. browser_click / browser_type only carry an element ref ("@e5"),
so the guard remembers ref -> snapshot line from browser_navigate / browser_snapshot results
(post_tool_call) and judges the label it last saw. Unknown refs are allowed (fail open).
"""

from __future__ import annotations

import json
import re

WRITE = re.compile(
    r"\b(send|reply|forward|submit|delete|remove|archive|post|accept|decline|rsvp"
    r"|mark (?:all )?as|upload|save|sign ?out|log ?out|attempt|flag|move to|junk)\b",
    re.IGNORECASE,
)
COMPOSE = re.compile(r"\b(message|comment|compose|reply)\b", re.IGNORECASE)
SAFE_KEYS = {"tab", "shift+tab", "escape", "enter", "pageup", "pagedown", "home", "end"}
ALWAYS_BLOCKED = {"browser_cdp", "browser_exec"}  # raw CDP / arbitrary Python: unjudgeable
REF = re.compile(r"\[(?:ref=)?(e\d+)\]")

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}


def _label(task_id: str, ref: object) -> str:
    return _labels.get(task_id, {}).get(str(ref).strip().lstrip("@"), "")


def _verb(text: str) -> str | None:
    m = WRITE.search(text)
    return f"looks like a write action ({m.group(0)!r})" if m else None


def _reason(tool: str, args: dict, task_id: str) -> str | None:
    if tool in ALWAYS_BLOCKED:
        return "raw browser control is disabled"
    if tool == "browser_console" and args.get("expression"):
        return "JavaScript evaluation is disabled"
    if tool == "browser_press":
        key = str(args.get("key", "")).replace(" ", "").lower()
        return None if key in SAFE_KEYS else f"key {args.get('key')!r} is not a navigation key"
    if tool == "browser_click":
        return _verb(_label(task_id, args.get("ref", "")))
    if tool == "browser_type":
        label = _label(task_id, args.get("ref", ""))
        if COMPOSE.search(label):
            return "typing into a message box"
        return _verb(f"{label} {args.get('text', '')}")
    return None


def pre_tool_call(tool_name: str = "", args: dict | None = None, task_id: str = "", **_):
    reason = _reason(tool_name, args if isinstance(args, dict) else {}, task_id or "")
    if reason is None:
        return None
    return {
        "action": "block",
        "message": f"robo-guard blocked {tool_name}: {reason}. Robo is read-only on school "
        "sites; tell the user what you wanted to do instead of trying another way.",
    }


def post_tool_call(tool_name: str = "", result: object = "", task_id: str = "", **_):
    if tool_name not in ("browser_navigate", "browser_snapshot"):
        return None
    try:
        snapshot = str(json.loads(result).get("snapshot", ""))
    except (TypeError, ValueError, AttributeError):
        snapshot = str(result)
    _labels[task_id or ""] = {
        m.group(1): line.strip() for line in snapshot.splitlines() for m in REF.finditer(line)
    }
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_tool_call", post_tool_call)
