"""robo-guard: robo's browser holds the user's school logins, so it may only READ school sites.

Hermes contract (hermes_cli/plugins.py `_get_pre_tool_call_directive_details`): a pre_tool_call
callback returning {"action": "block", "message": <str>} vetoes the call and the message becomes
the tool result. Allowlist, fail closed:
- the browser opens only school hosts (Outlook, Teams, Microsoft sign-in, the user's Moodle),
  never sign-out, compose or prefilled-message links;
- clicks only on elements seen in the latest snapshot whose label has no write word (refs are
  forgotten after any click, key or annotated screenshot); no typing, no activating keys;
- tools that cannot be judged or that persist instructions (raw CDP, dialogs, the credential
  vault, skill editing) are off;
- once a session has opened school pages, it cannot fetch other URLs (no posting mail out).
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import urlsplit

PROFILE = Path(__file__).resolve().parents[2]  # <hermes home>/profiles/robo
SCHOOL_HOSTS = (
    "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
    "teams.microsoft.com", "teams.cloud.microsoft", "login.microsoftonline.com",
)
BAD_URL = re.compile(
    r"log_?out|sign_?out|compose|deeplink|/l/(?:chat|call|meetup)|sesskey=|[?&](?:body|message|subject)=",
    re.IGNORECASE,
)
WRITE = re.compile(
    r"\b(send|reply|forward|submit|delete|remove|archive|post|accept|decline|rsvp|tentative"
    r"|mark (?:all )?as|upload|save|sign ?out|log ?out|attempt|flag|move to|junk|new (?:mail|"
    r"message|event|chat|post|meeting)|like|react|join|call|leave|pin|mute|hide|block|report"
    r"|unsubscribe|snooze|enrol|enroll|discard|start|edit|add|create|share|confirm|gửi|trả lời"
    r"|xóa)\b",
    re.IGNORECASE,
)
SCROLL_KEYS = {"escape", "pageup", "pagedown", "arrowup", "arrowdown", "home", "end"}
ALWAYS_BLOCKED = {
    "browser_cdp", "browser_exec", "browser_dialog", "browser_vault_fill",
    "browser_vault_save_login", "browser_vault_enter_code", "skill_manage",
}
REF = re.compile(r"\[(?:ref=)?(e\d+)\]")
FORGET_AFTER = {"browser_click", "browser_press", "browser_back", "browser_vision"}

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}


def _hosts() -> tuple[str, ...]:
    """School hosts plus the Moodle host from the profile's .env (set by `robo setup --moodle`)."""
    moodle = ""
    try:
        for line in (PROFILE / ".env").read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "MOODLE_BASE_URL":
                moodle = urlsplit(value.strip().strip("'\"")).hostname or ""
    except OSError:
        pass
    return SCHOOL_HOSTS + ((moodle,) if moodle else ())


def _school_url(url: str) -> bool:
    parts = urlsplit(str(url).strip())
    return (parts.scheme == "https" and (parts.hostname or "") in _hosts()
            and not BAD_URL.search(url))


def _tainted_file() -> Path:
    return PROFILE / "robo-guard-tainted.json"


def _tainted() -> set[str]:
    try:
        return set(json.loads(_tainted_file().read_text()))
    except (OSError, ValueError, TypeError):
        return set()


def _taint(session_id: str) -> None:
    sessions = _tainted()
    if session_id and session_id not in sessions:
        path = _tainted_file()
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(sorted(sessions | {session_id})))
        tmp.replace(path)


def _reason(tool: str, args: dict, task_id: str, session_id: str) -> str | None:
    if tool in ALWAYS_BLOCKED:
        return "this tool is disabled for robo"
    if tool == "browser_navigate":
        ok = _school_url(args.get("url", ""))
        return None if ok else "robo's browser only opens school sites"
    if tool == "web_extract" and session_id in _tainted():
        return ("this conversation has read school pages, so it cannot open other URLs "
                "(that could leak them); answer from web_search results instead")
    if tool == "browser_console" and args.get("expression"):
        return "JavaScript evaluation is disabled"
    if tool == "browser_type":
        return "typing is disabled"
    if tool == "browser_press":
        key = str(args.get("key", "")).replace(" ", "").lower()
        return None if key in SCROLL_KEYS else f"key {args.get('key')!r} is disabled"
    if tool == "browser_click":
        label = _labels.get(task_id, {}).get(str(args.get("ref", "")).strip().lstrip("@"))
        if label is None:
            return "unknown element: take browser_snapshot() first"
        m = WRITE.search(label)
        return f"looks like a write action ({m.group(0)!r})" if m else None
    return None


def pre_tool_call(tool_name: str = "", args: dict | None = None, task_id: str = "",
                  session_id: str = "", **_):
    reason = _reason(tool_name, args if isinstance(args, dict) else {}, task_id or "",
                     session_id or "")
    if reason is None:
        return None
    return {
        "action": "block",
        "message": f"robo-guard blocked {tool_name}: {reason}. Robo is read-only on school "
        "sites; tell the user what you wanted to do instead of trying another way.",
    }


def post_tool_call(tool_name: str = "", result: object = "", task_id: str = "",
                   session_id: str = "", **_):
    if tool_name in FORGET_AFTER:
        _labels.pop(task_id or "", None)
    if tool_name not in ("browser_navigate", "browser_snapshot"):
        return None
    if tool_name == "browser_navigate":
        _taint(session_id or "")
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
