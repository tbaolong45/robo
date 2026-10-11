"""robo-guard: robo may do anything on the laptop; only irreversible steps ask the user first.

Hermes contract (hermes_cli/plugins.py `_get_pre_tool_call_directive_details`,
`_resolve_block_from_details`): a pre_tool_call hook returning {"action": "approve", "message",
"rule_key"} asks the user and a deny, timeout or gate error blocks the call; {"action": "block",
"message"} vetoes it, and any block beats any approve. Hermes' own approvals (mode manual) still
ask for the commands it flags as dangerous.
- ask: a terminal command with an irreversible word anywhere in it (rm, sudo, kill, ssh, mail,
  git push, find -delete, curl uploads...; the full command is shown); clicking a ref missing from
  the latest snapshot or labelled with an irreversible word (Send, Reply, Delete, Accept, Sign out,
  Join, Pay...); Enter, Space and send/call shortcuts, except Enter right after typing into a
  search box; page dialogs; the password vault; non-web URLs and URLs with side effects (sign-out,
  compose, action=, OAuth redirect_uri...); a patch that deletes a file.
- block: raw CDP, browser_exec and JavaScript (console expressions, javascript: URLs), which
  cannot be judged; skill_manage; anything touching robo's own Hermes setup (the hermes CLI,
  ~/.hermes, also through symlinks, relative paths, a workdir or patch headers), so no request can
  switch approvals or this guard off.
- allow: everything else: any website, typing, toggles, reversible clicks (Like, Pin, Archive),
  file and memory writes, fetches and ordinary commands.
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
HERMES = re.compile(r"hermes", re.IGNORECASE)
# A terminal command asks when any word anywhere is one of these (`grep rm notes` over-asks).
DANGER_WORDS = {
    "rm", "rmdir", "unlink", "shred", "dd", "truncate", "sudo", "doas", "pkexec", "su", "run0",
    "kill", "pkill", "killall", "shutdown", "reboot", "poweroff", "halt", "scp", "rsync", "sftp",
    "ssh", "nc", "ncat", "netcat", "socat", "sendmail", "mail", "mailx", "mutt", "crontab",
    "chown", "-delete", "--delete",
}
WORDS = re.compile(r"[\s;&|`$(){}<>,=]+")  # $(...), `...`, chains, pipes, braces, x=rm; $x
DANGER = re.compile(  # a command plus its irreversible flag or subcommand
    r"\bmkfs|\bchmod\b.*\s(-[a-zA-Z]*R|--recursive)"
    r"|\bgit\b.*\b(push|clean|rebase|restore|checkout|reset\b.*--hard"
    r"|branch\b.*\s(-[a-zA-Z]*D|--delete))"
    r"|\b(curl|wget)\b.*\s(-[a-zA-Z]*[dFTX]|--(data|form|upload|json|post|request|method|body))"
    r"|\bsystemctl\b.*\b(stop|disable|mask|kill|isolate)\b"
    r"|\b(npm|pnpm|yarn|cargo|poetry|uv)\b.*\bpublish\b|\btwine\b.*\bupload\b"
    r"|\bgh\b.*\b(create|comment|merge|close|delete|edit|review|reopen|transfer|archive)\b"
    r"|\bgh\s+api\b.*\s(-[a-zA-Z]*[XfF]|--(method|field|raw-field|input))", re.DOTALL)
V4A = re.compile(r"\*\*\*\s*(Update|Add|Delete|Move)\s+File:\s*(.+)")  # patch(mode="patch")

BAD_URL = re.compile(
    r"log_?out|sign_?out|compose|deeplink|/l/(?:chat|call|meetup|meeting)|sesskey=|action="
    r"|unenrol|subscribe|completion|/oauth2/|redirect_uri=|[?&](?:body|message|subject)=",
    re.IGNORECASE,
)
IRREVERSIBLE = re.compile(
    r"\b(send|reply|forward|submit|delete|remove|post|publish|accept|decline|rsvp|tentative"
    r"|unsubscribe|subscribe|unenrol|enrol|enroll|(sign|log)[ -]?out|attempt|finish|turn in"
    r"|hand in|empty|discard|leave|block|report|upload|share|confirm|continue|yes|ok|pay|buy"
    r"|purchase|order|checkout|call|join|sweep|gửi|trả lời|xóa)\b",
    re.IGNORECASE,
)
SEARCH = re.compile(r"\bsearch", re.IGNORECASE)
MESSAGE = re.compile(r"\b(message|comment|compose|subject|body)", re.IGNORECASE)
ACTIVATE = {"enter", "return", "numpadenter", "space"}  # with any modifiers
SHORTCUTS = {"alt+s", "shift+delete", "control+shift+c", "control+shift+u"}  # send, purge, call
BLOCKED = {"browser_cdp", "browser_exec", "skill_manage"}
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"')
REF = re.compile(r"\[[^\]]*\bref=(e\d+)[^\]]*\]")  # [ref=e5] or [level=2, ref=e5]
FORGET_AFTER = {"browser_click", "browser_press", "browser_back", "browser_vision"}

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}
_hosts: dict[str, str] = {}  # task_id -> host of the page last opened
_searched: set[str] = set()  # tasks whose last browser action typed into a search box


def _short(text: object, limit: int = 60) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _label(line: str) -> str:
    quoted = QUOTED.search(line)
    return _short(quoted.group(0)[1:-1] if quoted else REF.sub("", line).strip(" -:"))


def _ref(args: dict) -> str:
    return str(args.get("ref", "")).strip().lstrip("@")


def _key(key: object) -> str:
    """"Shift+ctrl+C" -> "control+shift+c"; a bare " " is "space"."""
    *mods, last = str(key).replace(" ", "").lower().split("+")
    return "+".join([*sorted({"control" if m == "ctrl" else m for m in mods}), last or "space"])


def _resolve(path: str, task: str) -> Path:
    """Where Hermes will write: its own resolver follows the task's cwd; without it, from home."""
    try:
        from tools.file_tools_paths import _resolve_path_for_task
        return Path(_resolve_path_for_task(path, task or "default"))
    except Exception:  # not inside Hermes (tests) or its internals moved
        return (HOME / (str(HOME) + path[1:] if path.startswith("~") else path)).resolve()


def _inside_hermes(path: str, task: str) -> bool:
    full = _resolve(path, task)
    return bool(HERMES.search(path)) or (HOME / ".hermes").resolve() in (full, *full.parents)


def _command(args: dict, task: str) -> tuple[str, str] | None:
    command = str(args.get("command") or args.get("data") or "")  # process_manage: stdin data
    plain = re.sub(r"[\\'\"]", "", command)  # r\m, 'rm', he''rmes
    workdir = str(args.get("workdir") or "")
    if HERMES.search(plain) or (workdir and _inside_hermes(workdir, task)):
        return "block", "robo may not touch its own Hermes setup"
    words = {word.rsplit("/", 1)[-1] for word in WORDS.split(plain)}
    return ("approve", f"run: {command}") if words & DANGER_WORDS or DANGER.search(plain) else None


def _write(args: dict, task: str) -> tuple[str, str] | None:
    ops = [("edit", str(args["path"]))] if args.get("path") else []
    for op, paths in V4A.findall(str(args.get("patch", ""))):
        ops += [(op.lower(), path.strip()) for path in paths.split("->")]
    if any(_inside_hermes(path, task) for _, path in ops):
        return "block", "robo may not change its own Hermes setup"
    gone = [path for op, path in ops if op == "delete"]
    return ("approve", f"delete {_short(', '.join(gone), 120)}") if gone else None


def _check(tool: str, args: dict, task: str) -> tuple[str, str] | None:
    """("block", reason) or ("approve", what robo wants to do); None lets the call through."""
    url = unquote(re.sub(r"[\t\r\n]", "", str(args.get("url", ""))))
    if (tool in BLOCKED or (tool == "browser_console" and args.get("expression") is not None)
            or (tool == "browser_navigate" and urlsplit(url).scheme.lower() == "javascript")):
        return "block", "robo may not run raw page code or change its own skills"
    if tool == "terminal" or tool.startswith("process"):
        return _command(args, task)
    if tool in ("write_file", "patch"):
        return _write(args, task)
    if tool == "browser_navigate":
        if urlsplit(url).scheme.lower() in ("http", "https") and not BAD_URL.search(url):
            return None
        return "approve", f"open {_short(url, 120)}"
    line = _labels.get(task, {}).get(_ref(args))
    target = f'"{_label(line)}"' if line else f"an unknown element (@{_short(_ref(args), 20)})"
    host = _hosts.get(task)
    on = f" on {host}" if host else ""
    if tool == "browser_click":
        if line is None or IRREVERSIBLE.search(line):
            return "approve", f"click {target}{on}"
    elif tool == "browser_press":
        key = _key(args.get("key", ""))
        search = key in ("enter", "return", "numpadenter") and task in _searched
        if (key.rsplit("+", 1)[-1] in ACTIVATE or key in SHORTCUTS) and not search:
            return "approve", f'press "{_short(args.get("key", ""), 30) or "Space"}"{on}'
    elif tool == "browser_dialog":
        return "approve", f"{_short(args.get('action', 'answer'), 20)} a page dialog{on}"
    elif tool.startswith("browser_vault_"):
        return "approve", f"use the password vault ({tool}){on}"
    return None


def pre_tool_call(tool_name: str = "", args: dict | None = None, task_id: str = "", **_):
    task = task_id or ""
    verdict = _check(tool_name, args if isinstance(args, dict) else {}, task)
    if tool_name.startswith("browser_") and tool_name != "browser_snapshot":
        _searched.discard(task)  # focus may move; a search type sets it again once it succeeded
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
    task, args = task_id or "", args if isinstance(args, dict) else {}
    if tool_name in FORGET_AFTER:
        _labels.pop(task, None)
    try:
        data = json.loads(result)
    except (TypeError, ValueError):
        data = None
    info = data if isinstance(data, dict) else {}
    if tool_name == "browser_type" and info.get("success") is True:
        line = _labels.get(task, {}).get(_ref(args), "")
        if SEARCH.search(line) and not (MESSAGE.search(line) or IRREVERSIBLE.search(line)):
            _searched.add(task)
    if tool_name not in ("browser_navigate", "browser_snapshot", "browser_back"):
        return None
    if tool_name != "browser_snapshot":  # navigate and back report the final URL
        url = info.get("url") if info else args.get("url")
        _hosts[task] = urlsplit(str(url or "")).hostname or ""
    if tool_name != "browser_back":
        _labels[task] = _refs(str(result) if data is None else str(info.get("snapshot", "")))
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_tool_call", post_tool_call)
