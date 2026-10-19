"""robo-guard: robo may do anything on the laptop; only irreversible steps ask the user first.

With approvals.mode off Hermes approves every "ask" below by itself, and only in mode manual does
the user see it. The blocks always hold: they keep robo from rewriting its own setup and school
skills, from doing graded work, and from planting remote content in a note. A regex guard is a
speed bump (raw JS or a terminal can get around it); SOUL.md's graded-work rule is the main control.

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
  compose, action=, OAuth redirect_uri...); a patch that deletes a file; on a mail host Move and
  Junk, and a Send (or a calendar Save with attendees) with the addresses typed in this task
  ("recipients unknown" when none); computer_use steps in Outlook or Teams.
- block: changing robo's installed school-*, study-* and robo-* skills (new skills of its own
  are fine: it learns), and anything touching robo's own Hermes setup (the hermes CLI,
  ~/.hermes, also through symlinks, relative paths, a workdir or patch headers); graded work:
  Moodle quiz attempts, assignment submissions and forum posts (URL, button label, or any click,
  type or key on a quiz-attempt page), raw JavaScript or DevTools on a school site, a terminal
  or execute_code that names /mod/quiz/ or /mod/assign/; a Markdown note that holds a remote
  image or active HTML (Obsidian loads it when the note opens: a leak without a click).
- allow: everything else: any website, typing, toggles, reversible clicks (Like, Pin, Archive),
  file and memory writes, fetches, ordinary commands, raw browser control off school sites.
Refs are read only outside quoted text, a ref listed twice is not trusted, and refs are forgotten
after any click, key, back or screenshot. The rule_key names the tool and the exact action:
without it Hermes uses the bare tool name, so one "always" would approve every later click.
post_tool_call also keeps receipts: one line per state-changing call (no typed text, no page
content) in ~/.local/share/robo/receipts.jsonl, for robo to say "sent" only with evidence.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime
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
OWN_SKILLS = ("school-", "study-", "robo-")  # installed by `robo setup`; skill_manage may not touch
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"')
REF = re.compile(r"\[[^\]]*\bref=(e\d+)[^\]]*\]")  # [ref=e5] or [level=2, ref=e5]
FORGET_AFTER = {"browser_click", "browser_press", "browser_back", "browser_vision"}

GRADED = ("graded work is the student's own: never take, finish or submit it. Offer to explain the "
          "topic, check their draft or write practice questions instead")
QUIZ_ATTEMPT = re.compile(r"/mod/quiz/(?:startattempt|attempt|processattempt|summary)\.php",
                          re.IGNORECASE)
GRADED_URL = re.compile(  # a quiz attempt, an assignment submission, a forum post
    QUIZ_ATTEMPT.pattern + r"|/mod/assign/view\.php\?(?:[^#]*&)?action=(?:submit|editsubmission"
    r"|savesubmission)|/mod/forum/post\.php", re.IGNORECASE)
GRADED_PATH = re.compile(r"/mod/(?:quiz|assign)/", re.IGNORECASE)  # named in a command or script
# Starting an attempt is blocked too: a click opens the attempt page without any URL the guard sees.
GRADED_LABEL = re.compile(
    r"submit assignment|(?:add|edit) submission|finish attempt|submit all and finish"
    r"|attempt quiz|start attempt|re-?attempt|continue (?:your|the last) attempt", re.IGNORECASE)
SAVE_CHANGES = re.compile(r"save changes", re.IGNORECASE)  # the submission form's button
SCHOOL_CLICKS = {"browser_click", "browser_type", "browser_press"}
RAW_JS = {"browser_console", "browser_cdp", "browser_exec"}
MAIL_HOSTS = ("outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
              "outlook.live.com")
SCHOOL_HOSTS = (*MAIL_HOSTS, "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com")
BUTTON = re.compile(r"[-\s]*(?:button|menuitem)\b")  # a snapshot line that is an action
MAIL_ACT = re.compile(r"\b(?:move|junk|spam)\b", re.IGNORECASE)  # Delete asks; Archive is free
SENDS = re.compile(r"\b(?:send|gửi)\b", re.IGNORECASE)
INVITES = re.compile(r"\b(?:save|done|create|schedule)\b", re.IGNORECASE)  # event with attendees
EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
COMPUTER_APPS = re.compile(r"outlook|teams", re.IGNORECASE)  # names and com.microsoft.* bundle ids
LOOK = {"capture", "list_apps", "list_windows", "wait", "scroll"}  # computer_use: no effect
NOTE = re.compile(r"\.(?:md|markdown)$", re.IGNORECASE)  # not robo-make's .html pages
REMOTE = re.compile(  # what Obsidian would fetch or run when the note opens
    r"!\[[^\]]*\](?:\(\s*<?(?:https?:)?//|\[)"  # ![alt](http://x) and ![alt][ref]
    r"|<\s*(?:iframe|script|object|embed)\b"
    r"|<\s*(?:img|video|audio|source)\b[^>]*(?:https?:|[\"'=])//", re.IGNORECASE)
RECEIPT_WORDS = re.compile(r"\b(?:save|move|junk|archive|done|create|schedule)\b", re.IGNORECASE)
SEND_KEYS = {"control+enter", "meta+enter", "alt+s"}  # plain Enter may only be a search
RECEIPTS = ".local/share/robo/receipts.jsonl"
MAX_RECEIPTS = 2000

_labels: dict[str, dict[str, str]] = {}  # task_id -> {"e5": snapshot line}
_pages: dict[str, str] = {}  # task_id -> URL of the page last opened
_typed: dict[str, list[str]] = {}  # task_id -> addresses typed on a mail or Teams page
_apps: dict[str, str] = {}  # task_id -> app of the last computer_use capture
_searched: set[str] = set()  # tasks whose last browser action typed into a search box


def _short(text: object, limit: int = 60) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _label(line: str) -> str:
    quoted = QUOTED.search(line)
    return _short(quoted.group(0)[1:-1] if quoted else REF.sub("", line).strip(" -:"))


def _ref(args: dict) -> str:
    return str(args.get("ref", "")).strip().lstrip("@")


def _host(task: str) -> str:
    return urlsplit(_pages.get(task, "")).hostname or ""


def _on(host: str, *names: str) -> bool:
    return any(host == name or host.endswith("." + name) for name in names if name)


def _moodle() -> str:
    """The user's Moodle host: MOODLE_BASE_URL from robo's profile .env, which Hermes puts in the
    environment only for a single-profile gateway, so read the file beside the plugin as well."""
    url = os.environ.get("MOODLE_BASE_URL", "")
    if not url:
        try:
            env = (Path(__file__).resolve().parents[2] / ".env").read_text()
        except OSError:
            env = ""
        found = re.search(r"^\s*MOODLE_BASE_URL\s*=\s*['\"]?([^'\"\s#]+)", env, re.MULTILINE)
        url = found.group(1) if found else ""
    return urlsplit(url).hostname or ""


def _school(host: str) -> bool:
    """Outlook, Teams or the user's Moodle."""
    return _on(host, *SCHOOL_HOSTS, _moodle())


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
    if GRADED_PATH.search(unquote(plain)):
        return "block", GRADED
    words = {word.rsplit("/", 1)[-1] for word in WORDS.split(plain)}
    return ("approve", f"run: {command}") if words & DANGER_WORDS or DANGER.search(plain) else None


def _ops(args: dict) -> list[tuple[str, str]]:
    """(operation, path) of a write_file or patch call, V4A headers included."""
    ops = [("edit", str(args["path"]))] if args.get("path") else []
    for op, paths in V4A.findall(str(args.get("patch", ""))):
        ops += [(op.lower(), path.strip()) for path in paths.split("->")]
    return ops


def _write(args: dict, task: str) -> tuple[str, str] | None:
    ops = _ops(args)
    if any(_inside_hermes(path, task) for _, path in ops):
        return "block", "robo may not change its own Hermes setup"
    text = " ".join(str(args.get(key, "")) for key in ("content", "new_string", "patch"))
    if any(NOTE.search(path) for _, path in ops) and REMOTE.search(text):
        return "block", ("a note with a remote image or active HTML loads it when Obsidian opens "
                         "the note, which can leak the user's data. Link the page as [text](url)")
    gone = [path for op, path in ops if op == "delete"]
    return ("approve", f"delete {_short(', '.join(gone), 120)}") if gone else None


def _desktop(args: dict, task: str) -> str:
    """The Outlook or Teams step a computer_use call takes ("click in Microsoft Outlook"), else ''.
    Its clicks name an element index, so the app is the one of the task's last capture."""
    app = str(args.get("app") or _apps.get(task, ""))
    action = str(args.get("action", "")).lower()
    if COMPUTER_APPS.search(app) and action not in LOOK:
        return f"{action} in {_short(app, 40)}"
    return ""


def _who(task: str, text: str, page: str) -> str:
    """For a click that mails or invites people: who gets it, as far as the typed addresses tell."""
    typed = _typed.get(task)
    if not (SENDS.search(text) or (typed and "/calendar" in page and INVITES.search(text))):
        return ""
    return f" (to {', '.join(typed)})" if typed else " (recipients unknown)"


def _check(tool: str, args: dict, task: str) -> tuple[str, str] | None:
    """("block", reason) or ("approve", what robo wants to do); None lets the call through."""
    url = unquote(re.sub(r"[\t\r\n]", "", str(args.get("url", ""))))
    if tool == "skill_manage":
        ops = args.get("operations") if isinstance(args.get("operations"), list) else [args]
        if any(str((op or {}).get("name", "")).startswith(OWN_SKILLS) for op in ops):
            return "block", "robo may not change its installed school skills"
        return None
    if tool == "terminal" or tool.startswith("process"):
        return _command(args, task)
    if tool == "execute_code":  # too free-form to judge: only keep it off graded work
        return ("block", GRADED) if GRADED_PATH.search(unquote(str(args.get("code", "")))) else None
    if tool in ("write_file", "patch"):
        return _write(args, task)
    if tool == "computer_use":
        step = _desktop(args, task)
        return ("approve", f"{step} (computer_use)") if step else None
    host, page = _host(task), unquote(_pages.get(task, "")).lower()
    if tool == "browser_navigate":
        scheme = urlsplit(url).scheme.lower()
        if GRADED_URL.search(url):
            return "block", GRADED
        if scheme == "javascript" and _school(host):
            return "block", f"no raw JavaScript on {host}: {GRADED}"
        if scheme in ("http", "https") and not BAD_URL.search(url):
            return None
        return "approve", f"open {_short(url, 120)}"
    if tool in RAW_JS and _school(host):
        return "block", f"no raw JavaScript or DevTools on {host}: {GRADED}"
    if tool in SCHOOL_CLICKS and QUIZ_ATTEMPT.search(page):
        return "block", f"this page is a quiz attempt: {GRADED}"
    line = _labels.get(task, {}).get(_ref(args))
    target = f'"{_label(line)}"' if line else f"an unknown element (@{_short(_ref(args), 20)})"
    on = f" on {host}" if host else ""
    mail = _on(host, *MAIL_HOSTS)
    if tool == "browser_click":
        text = line or ""
        if GRADED_LABEL.search(text) or ("/mod/assign/" in page and SAVE_CHANGES.search(text)):
            return "block", GRADED
        who = _who(task, text, page) if mail else ""
        if line is None or IRREVERSIBLE.search(text) or who or (
                mail and BUTTON.match(text) and MAIL_ACT.search(text)):
            return "approve", f"click {target}{on}{who}"
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


def _evidence(tool: str, args: dict, line: str, task: str) -> str:
    """What a state-changing call did, in a few words (never typed text or page text), else ''."""
    if tool == "browser_click":
        words = IRREVERSIBLE.search(line) or RECEIPT_WORDS.search(line)
        return _label(line) if BUTTON.match(line) and words else ""
    if tool == "browser_press":
        key = args.get("key", "")
        return f"press {_short(key, 30)}" if _key(key) in SEND_KEYS else ""
    if tool in ("write_file", "patch"):
        return _short(", ".join(path for _, path in _ops(args)), 200)
    return _desktop(args, task) if tool == "computer_use" else ""


def _receipt(tool: str, what: str, host: str, ok: bool) -> None:
    """One JSON line in ~/.local/share/robo/receipts.jsonl (dir 0700, file 0600, last 2000)."""
    row = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"), "tool": tool,
           "label_or_path": what, "host": host, "ok": ok}
    path = HOME / RECEIPTS
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.parent.chmod(0o700)
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        path.chmod(0o600)
        lines = path.read_text().splitlines(keepends=True)
        if len(lines) > MAX_RECEIPTS:
            path.write_text("".join(lines[-MAX_RECEIPTS:]))
    except OSError:
        pass  # evidence is best effort: it must never fail the tool call


def post_tool_call(tool_name: str = "", args: dict | None = None, result: object = "",
                   task_id: str = "", status: str = "", **_):
    task, args = task_id or "", args if isinstance(args, dict) else {}
    line = _labels.get(task, {}).get(_ref(args), "")  # read before a click forgets the refs
    if tool_name in FORGET_AFTER:
        _labels.pop(task, None)
    try:
        data = json.loads(result)
    except (TypeError, ValueError):
        data = None
    info = data if isinstance(data, dict) else {}
    host = _host(task)  # of the page the call ran on, before a navigation moves it
    if tool_name == "browser_type" and info.get("success") is True:
        if SEARCH.search(line) and not (MESSAGE.search(line) or IRREVERSIBLE.search(line)):
            _searched.add(task)
        if _on(host, *SCHOOL_HOSTS):  # only the addresses are kept, for the Send question
            seen = [*_typed.get(task, []), *EMAIL.findall(str(args.get("text", "")))]
            _typed[task] = list(dict.fromkeys(seen))[-10:]
    if tool_name == "computer_use" and args.get("action") in ("capture", "focus_app"):
        _apps[task] = str(info.get("app") or args.get("app") or "")
    what = _evidence(tool_name, args, line, task)
    if what and status != "blocked":  # a vetoed or refused call changed nothing
        ok = (status or "ok") == "ok" and not info.get("error") and info.get("success") is not False
        _receipt(tool_name, what, host, ok)
        if ok and tool_name == "browser_click" and SENDS.search(line):
            _typed.pop(task, None)  # the draft is gone
    if tool_name not in ("browser_navigate", "browser_snapshot", "browser_back"):
        return None
    if tool_name != "browser_snapshot":  # navigate and back report the final URL
        _pages[task] = str((info.get("url") if info else args.get("url")) or "")
    if tool_name != "browser_back":
        _labels[task] = _refs(str(result) if data is None else str(info.get("snapshot", "")))
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_tool_call", post_tool_call)
