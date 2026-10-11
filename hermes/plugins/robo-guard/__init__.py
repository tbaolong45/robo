"""robo-guard: robo may use the whole laptop, but risky actions ask the user first.

Hermes' own approvals (approvals.mode manual) gate the commands it knows are dangerous and every
computer-use action; this plugin asks for the rest (a security review found that ordinary
commands, file and memory writes and fetches ran with no prompt).
Hermes contract (hermes_cli/plugins.py
`_get_pre_tool_call_directive_details`, `_resolve_block_from_details`): a pre_tool_call hook
returning {"action": "approve", "message", "rule_key"} asks the user and a deny, timeout or gate
error blocks the call; {"action": "block", "message"} vetoes it, and any block beats any approve.
- ask: clicking an element whose label is a write word (Send, Reply, Submit, Delete...), a toggle,
  or a ref missing from the latest snapshot; typing anywhere but a search box; any key but
  scrolling and Escape; page dialogs; the password vault; URLs with side effects (sign-out,
  compose, action=, unenrol, subscribe, completion, OAuth redirect_uri...).
- block: raw CDP, browser_exec and JavaScript (browser_console expressions, javascript: URLs),
  which cannot be judged, and skill_manage (installed skills stay as installed).
- ask too: any terminal command but a simple read-only one (the exact command is shown), every
  file write, memory write and web_extract, and opening a site other than the school ones.
- block: anything touching robo's own Hermes setup (~/.hermes, the hermes CLI), so no request
  can switch approvals or this guard off.
- allow: everything else (reading files and pages, searching, school sites).
Refs are read only outside quoted text, a ref listed twice is not trusted, and refs are forgotten
after any click, key, back or screenshot. The rule_key names the tool and the exact action:
without it Hermes uses the bare tool name, so one "always" would approve every later click.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

HOME = Path.home()
PROFILE = Path(__file__).resolve().parents[2]  # <hermes home>/profiles/robo
SCHOOL_HOSTS = {
    "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
    "teams.microsoft.com", "teams.cloud.microsoft", "login.microsoftonline.com",
}
HERMES = re.compile(r"hermes", re.IGNORECASE)
# One plain command that only reads: no pipes, redirects, substitutions, chaining or background.
READ_ONLY = re.compile(
    r"^\s*(ls|pwd|date|whoami|uname|which|cat|head|tail|wc|grep|df|du|free|uptime|tree|file|stat"
    r"|git (status|log|diff|show|branch))\b[^;&|`$<>()\n\\]*$")

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
TOGGLES = {"checkbox", "switch", "radio", "menuitemcheckbox", "menuitemradio"}
SEARCH = re.compile(r"\bsearch", re.IGNORECASE)
MESSAGE = re.compile(r"\b(message|comment|compose|subject|body)", re.IGNORECASE)
# Scrolling, plus Teams' own "go to Chat" shortcut (a ref click on its app bar is unreliable).
SAFE_KEYS = {"escape", "pageup", "pagedown", "arrowup", "arrowdown", "home", "end",
             "control+shift+2", "ctrl+shift+2"}
BLOCKED = {"browser_cdp", "browser_exec", "skill_manage"}
MEMORY_READS = {"read", "view", "list", "search"}
LINE = re.compile(r"^\s*-\s*(\w+)")
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"')
REF = re.compile(r"\[[^\]]*\bref=(e\d+)[^\]]*\]")  # [ref=e5] or [level=2, ref=e5]
FORGET_AFTER = {"browser_click", "browser_press", "browser_back", "browser_vision"}

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}
_hosts: dict[str, str] = {}  # task_id -> host of the page last opened


def _short(text: object, limit: int = 60) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _label(line: str) -> str:
    quoted = QUOTED.search(line)
    return _short(quoted.group(0)[1:-1] if quoted else REF.sub("", line).strip(" -:"))


def _school_hosts() -> set[str]:
    """Outlook/Teams/Microsoft sign-in plus the Moodle host from the profile's .env."""
    try:
        for line in (PROFILE / ".env").read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "MOODLE_BASE_URL":
                return SCHOOL_HOSTS | {urlsplit(value.strip().strip("'\"")).hostname or ""}
    except OSError:
        pass
    return SCHOOL_HOSTS


def _laptop(tool: str, args: dict) -> tuple[str, str] | None:
    """Terminal commands and file writes: robo's own setup is off limits; the rest is shown."""
    if tool == "terminal" or tool.startswith("process"):
        command = str(args.get("command", ""))
        if HERMES.search(command):
            return "block", "robo may not touch its own Hermes setup"
        return None if READ_ONLY.match(command) else ("approve", f"run: {command}")
    path = str(args.get("path", "")) or "(several files)"
    full = Path(path.replace("~", str(HOME), 1)).resolve() if path.startswith(("~", "/")) else None
    if HERMES.search(path) or (full and (HOME / ".hermes") in (full, *full.parents)):
        return "block", "robo may not change its own Hermes setup"
    return "approve", f"{'write' if tool == 'write_file' else 'edit'} {_short(path, 120)}"


def _check(tool: str, args: dict, task: str) -> tuple[str, str] | None:
    """("block", reason) or ("approve", what robo wants to do); None lets the call through."""
    url = unquote(re.sub(r"[\t\r\n]", "", str(args.get("url", ""))))
    if (tool in BLOCKED or (tool == "browser_console" and args.get("expression") is not None)
            or (tool == "browser_navigate" and urlsplit(url).scheme.lower() == "javascript")):
        return "block", "robo may not run raw page code or change its own skills"
    if tool in ("terminal", "write_file", "patch") or tool.startswith("process"):
        return _laptop(tool, args)
    if tool == "memory":
        if str(args.get("action", "")).lower() in MEMORY_READS:
            return None
        note = args.get("content") or args.get("new_text") or args
        return "approve", f'remember "{_short(note, 120)}"'
    if tool == "web_extract":
        return "approve", f"fetch {_short(', '.join(map(str, args.get('urls') or [])), 160)}"
    if tool == "browser_navigate":
        parts = urlsplit(url)
        school = parts.scheme == "https" and (parts.hostname or "") in _school_hosts()
        if school and not BAD_URL.search(url):
            return None
        return "approve", f"open {_short(url, 120)}"
    ref = str(args.get("ref", "")).strip().lstrip("@")
    line = _labels.get(task, {}).get(ref)
    target = f'"{_label(line)}"' if line else f"an unknown element (@{_short(ref, 20)})"
    host = _hosts.get(task)
    on = f" on {host}" if host else ""
    if tool == "browser_click":
        role = (LINE.match(line or "") or [None, ""])[1].lower()
        if line is None or WRITE.search(line) or role in TOGGLES:
            return "approve", f"click {target}{on}"
    elif tool == "browser_type":
        if line is None or not SEARCH.search(line) or WRITE.search(line) or MESSAGE.search(line):
            return "approve", f'type "{_short(args.get("text", ""))}" into {target}{on}'
    elif tool == "browser_press":
        if str(args.get("key", "")).replace(" ", "").lower() not in SAFE_KEYS:
            return "approve", f'press "{_short(args.get("key", ""), 30)}"{on}'
    elif tool == "browser_dialog":
        return "approve", f"{_short(args.get('action', 'answer'), 20)} a page dialog{on}"
    elif tool.startswith("browser_vault_"):
        return "approve", f"use the password vault ({tool}){on}"
    return None


def pre_tool_call(tool_name: str = "", args: dict | None = None, task_id: str = "", **_):
    verdict = _check(tool_name, args if isinstance(args, dict) else {}, task_id or "")
    if verdict is None:
        return None
    action, text = verdict
    if action == "block":
        return {"action": "block", "message": f"robo-guard blocked {tool_name}: {text}. Tell the "
                "user what you wanted to do instead of trying another way."}
    end = "" if text.startswith("run: ") else "."  # a shown command is not followed by a dot
    return {"action": "approve", "message": f"Robo wants to {text}{end}",
            "rule_key": f"robo-guard:{tool_name}:{text}"}


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


def post_tool_call(tool_name: str = "", args: dict | None = None, result: object = "",
                   task_id: str = "", **_):
    task = task_id or ""
    if tool_name in FORGET_AFTER:
        _labels.pop(task, None)
    if tool_name not in ("browser_navigate", "browser_snapshot", "browser_back"):
        return None
    try:
        data = json.loads(result)
        data = data if isinstance(data, dict) else {}
        snapshot = str(data.get("snapshot", ""))
    except (TypeError, ValueError):
        data, snapshot = {}, str(result)
    if tool_name != "browser_snapshot":  # navigate and back report the final URL
        url = data.get("url") if data else (args if isinstance(args, dict) else {}).get("url")
        _hosts[task] = urlsplit(str(url or "")).hostname or ""
    if tool_name != "browser_back":
        _labels[task] = _refs(snapshot)
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_tool_call", post_tool_call)
