"""robo-guard: robo's browser holds the user's school logins, so it may only READ school sites.

Hermes contract (hermes_cli/plugins.py `_get_pre_tool_call_directive_details`): a pre_tool_call
callback returning {"action": "block", "message": <str>} vetoes the call and the message becomes
the tool result. Allowlist, fail closed:
- the browser opens only school hosts (Outlook, Teams, Microsoft sign-in, the user's Moodle),
  never URLs with side effects (sign-out, compose, actions, OAuth redirects);
- clicks only on elements from the latest snapshot: links, tabs and list rows without a write
  word, and buttons only when they navigate (next week, Chat, show more...); refs are read only
  outside quoted text, a ref listed twice is not trusted, and refs are forgotten after any
  click, key or screenshot; no typing, no activating keys;
- tools that cannot be judged, fetch arbitrary URLs, or persist instructions across sessions
  (raw CDP, dialogs, the credential vault, web_extract, memory, skill editing) are off.
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
    r"log_?out|sign_?out|compose|deeplink|/l/(?:chat|call|meetup|meeting)|sesskey=|action="
    r"|unenrol|subscribe|completion|/oauth2/|redirect_uri=|[?&](?:body|message|subject)=",
    re.IGNORECASE,
)
WRITE = re.compile(
    r"\b(send|reply|forward|submit|delete|remove|archive|post|accept|decline|rsvp|tentative"
    r"|mark|upload|save|sign ?out|log ?out|attempt|flag|move|junk|new|like|react|join|call"
    r"|leave|pin|unpin|mute|hide|block|report|unsubscribe|subscribe|snooze|enrol|enroll"
    r"|discard|start|edit|add|create|share|confirm|continue|yes|ok|done|turn in|hand in|empty"
    r"|restore|ignore|sweep|undo|apply|update|finish|categori[sz]e|star|available|busy"
    r"|away|disturb|heart|laugh|love|surprised|sad|angry|gửi|trả lời|xóa)\b",
    re.IGNORECASE,
)
READ_ROLES = {"link", "tab", "option", "row", "gridcell", "treeitem", "listitem", "menuitem"}
NAV_BUTTON = re.compile(
    r"\b(next|previous|prev|today|week|month|day|chat|chats|calendar|mail|inbox|timeline"
    r"|upcoming|show more|load more|view|expand|collapse|sort|filter)\b",
    re.IGNORECASE,
)
# Scrolling, plus Teams' own "go to Chat" shortcut (a ref click on its app bar is unreliable).
SAFE_KEYS = {"escape", "pageup", "pagedown", "arrowup", "arrowdown", "home", "end",
             "control+shift+2", "ctrl+shift+2"}
ALWAYS_BLOCKED = {
    "browser_cdp", "browser_exec", "browser_dialog", "browser_vault_fill",
    "browser_vault_save_login", "browser_vault_enter_code", "browser_vault_list",
    "browser_vault_unlock", "skill_manage", "memory",
    "web_extract",
}
LINE = re.compile(r"^\s*-\s*(\w+)")
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"')
REF = re.compile(r"\[ref=(e\d+)\]")
FORGET_AFTER = {"browser_click", "browser_press", "browser_back", "browser_vision"}

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}


def _hosts() -> tuple[str, ...]:
    """School hosts plus the Moodle host from the profile's .env (`robo setup --moodle`)."""
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


def _click(line: str | None) -> str | None:
    """Why clicking this snapshot line is refused (None = allowed)."""
    if line is None:
        return "unknown element: take browser_snapshot() first"
    m = WRITE.search(line)
    if m:
        return f"looks like a write action ({m.group(0)!r})"
    role = (LINE.match(line) or [None, ""])[1].lower()
    if role in READ_ROLES or (role == "button" and NAV_BUTTON.search(line)):
        return None
    return f"only links, tabs, list items and navigation buttons can be clicked, not {role!r}"


def _reason(tool: str, args: dict, task_id: str) -> str | None:
    if tool in ALWAYS_BLOCKED:
        return "this tool is disabled for robo"
    if tool == "browser_navigate":
        ok = _school_url(args.get("url", ""))
        return None if ok else "robo's browser only opens school sites"
    if tool == "browser_console" and args.get("expression"):
        return "JavaScript evaluation is disabled"
    if tool == "browser_type":
        return "typing is disabled"
    if tool == "browser_press":
        key = str(args.get("key", "")).replace(" ", "").lower()
        return None if key in SAFE_KEYS else f"key {args.get('key')!r} is disabled"
    if tool == "browser_click":
        return _click(_labels.get(task_id, {}).get(str(args.get("ref", "")).strip().lstrip("@")))
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


def _refs(snapshot: str) -> dict[str, str]:
    """ref -> its snapshot line; refs inside quoted text and refs seen twice are dropped."""
    seen: dict[str, str] = {}
    twice: set[str] = set()
    for line in snapshot.splitlines():
        for ref in REF.findall(QUOTED.sub('""', line)):
            if ref in seen:
                twice.add(ref)
            seen[ref] = line.strip()
    return {ref: line for ref, line in seen.items() if ref not in twice}


def post_tool_call(tool_name: str = "", result: object = "", task_id: str = "", **_):
    if tool_name in FORGET_AFTER:
        _labels.pop(task_id or "", None)
    if tool_name not in ("browser_navigate", "browser_snapshot"):
        return None
    try:
        snapshot = str(json.loads(result).get("snapshot", ""))
    except (TypeError, ValueError, AttributeError):
        snapshot = str(result)
    _labels[task_id or ""] = _refs(snapshot)
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_tool_call", post_tool_call)
