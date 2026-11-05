"""robo-guard: robo may do anything on the laptop; only irreversible steps ask the user first.

The PreToolUse decision of every tool call: block, ask or allow. With approvals "off" an ask is
allowed by the harness itself, and only in "manual" does the user see it. The blocks always hold:
they keep robo from reading its keys or rewriting its own setup and skills, from doing graded work,
and from planting remote content in a note. A regex guard is a speed bump (raw JS or Bash can get
around it). For the keys the wall is harness.boundary (the CLI's deny rules and Bash's sandbox);
for graded work SOUL.md's rule is the main control.

Tool shapes (Claude Agent SDK built-ins, Playwright MCP 0.0.83 with the `mcp__playwright__`
prefix stripped): Bash{command}, Write{file_path, content}, Edit{file_path, old_string,
new_string}, Read{file_path}, Glob/Grep{path, pattern}; browser_navigate{url},
browser_tabs{action, url}, browser_click{element, target}, browser_type{element, target, text,
submit}, browser_press_key{key}, browser_fill_form{fields: [{name, type, target, value}]},
browser_evaluate{function}, browser_run_code_unsafe{code}, browser_handle_dialog{accept},
browser_file_upload{paths}, browser_drop{paths, data}. `target` is a snapshot ref ("e5") or a
selector. A Playwright result is Markdown: `### Page` with `- Page URL: <url>`, and `### Snapshot`
with the page inline (```yaml) or as a link to a .yml file.
- ask: a Bash command with an irreversible word anywhere in it (rm, sudo, kill, ssh, mail, git
  push, find -delete, curl uploads...; the full command is shown); clicking a target missing from
  the latest snapshot or labelled with an irreversible word (Send, Reply, Delete, Accept, Sign out,
  Join, Pay...); Enter, Space and send/call shortcuts (also typing with submit), except Enter
  right after typing into a search box; page dialogs; file uploads; non-web URLs and URLs with side
  effects (sign-out, compose, action=, OAuth redirect_uri...); on a mail host Move and Junk, and a
  Send (or a calendar Save with attendees) with the addresses typed in this run ("recipients
  unknown" when none).
- block: robo's own setup: anything in its runtime folder R (keys, config, memory, sessions, the
  rendered and learned skills; read or write) or in ~/.hermes (robo's Brave profile with the
  school sign-in cookies lives there), a Grep or Glob whose search would cover either of them,
  writes to its code and built-in skills, its receipt and usage logs; Brave's debugging port in
  Bash or a URL; an app or script started with `open` (the one command outside the sandbox); graded
  work: Moodle quiz attempts, assignment submissions and forum posts (URL, button label, or any
  click, type or key on a quiz-attempt page; on any other /mod/quiz/ or /mod/assign/ page everything
  but a click on a known link), browser_run_code_unsafe anywhere, raw JavaScript on a school site,
  Bash or browser code that names /mod/quiz/ or /mod/assign/; a Markdown note that holds a remote
  image or active HTML (Obsidian loads it when the note opens: a leak without a click).
- allow: everything else.
Refs are read only outside quoted text, a ref listed twice is not trusted, and a call that changes
the page without returning its snapshot forgets them. The rule_key names the tool and the exact
action, so "session" approves only that action again. `post` also keeps receipts: one line per
state-changing call (no typed text, no page content) in ~/.local/share/robo/receipts.jsonl, for the
app to say "sent" only with evidence.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlsplit

# A Bash command asks when any word anywhere is one of these (`grep rm notes` over-asks).
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
DEBUG_PORT = re.compile(
    r":9333\b|/json/(?:list|version|new|protocol)\b|/devtools/(?:page|browser)/", re.IGNORECASE)
# `open` alone runs outside Bash's sandbox (harness.boundary), and whatever it starts does too.
OPENS_CODE = re.compile(
    r"^\s*open\b(?:[^;&|\n]*\.(?:app|command|tool|terminal|workflow|scpt|sh|py|pl|rb)\b"
    r"|[^;&|\n]*\s-a\s*(?:terminal|iterm|script editor|automator))", re.IGNORECASE)
INSTALLED = re.compile(r"^\s*open\s+-a\s+(?:/System)?/Applications/[^/]+\.app/?\s*$")
# Robo's own setup named in a command or path: the runtime folder, its keys, its code, its logs.
OWN_WORDS = re.compile(
    r"\.local/share/robo/agent|robo[-_]agent|server_key|supermemory_key|ANTHROPIC_API_KEY"
    r"|ANTHROPIC_AUTH_TOKEN|DEEPSEEK_API_KEY"
    r"|SUPERMEMORY_API_KEY|receipts\.jsonl|usage\.jsonl|\.hermes\b", re.IGNORECASE)

BAD_URL = re.compile(
    r"log_?out|sign_?out|compose|deeplink|/l/(?:chat|call|meetup|meeting)|sesskey=|[?&;#]action="
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
QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"')
REF = re.compile(r"\[[^\]]*\bref=([a-z0-9]+)[^\]]*\]")  # [ref=e5], [ref=f1e5], [level=2, ref=e5]
REF_ARG = re.compile(r"^@?([a-z]*\d*e\d+)$")  # a target that is a ref, not a selector
PAGE_URL = re.compile(r"^- Page URL: (\S+)", re.MULTILINE)
INLINE_SNAPSHOT = re.compile(r"^### Snapshot\n```yaml\n(.*?)\n```", re.MULTILINE | re.DOTALL)
SNAPSHOT_FILE = re.compile(r"^### Snapshot\n- \[Snapshot\]\(([^)]+)\)", re.MULTILINE)
# A call that changes the page: its refs no longer hold unless its result carries the new snapshot.
CHANGES_PAGE = {"browser_click", "browser_press_key", "browser_navigate", "browser_navigate_back",
                "browser_tabs", "browser_evaluate", "browser_run_code_unsafe",
                "browser_handle_dialog", "browser_drag", "browser_drop", "browser_select_option"}

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
LINK = re.compile(r"[-\s]*link\b")  # a snapshot line that only goes somewhere
ON_PAGE = {"browser_click", "browser_type", "browser_press_key", "browser_fill_form",
           "browser_select_option", "browser_file_upload", "browser_drop", "browser_drag",
           "browser_handle_dialog", "browser_evaluate", "browser_run_code_unsafe"}
RAW_JS = {"browser_evaluate": "function", "browser_run_code_unsafe": "code"}
MAIL_HOSTS = ("outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
              "outlook.live.com")
SCHOOL_HOSTS = (*MAIL_HOSTS, "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com")
BUTTON = re.compile(r"[-\s]*(?:button|menuitem)\b")  # a snapshot line that is an action
MAIL_ACT = re.compile(r"\b(?:move|junk|spam)\b", re.IGNORECASE)  # Delete asks; Archive is free
SENDS = re.compile(r"\b(?:send|gửi)\b", re.IGNORECASE)
INVITES = re.compile(r"\b(?:save|done|create|schedule)\b", re.IGNORECASE)  # event with attendees
EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
NOTE = re.compile(r"\.(?:md|markdown)$", re.IGNORECASE)  # not robo-make's .html pages
REMOTE = re.compile(  # what Obsidian would fetch or run when the note opens
    r"!\[[^\]]*\](?:\(\s*<?(?:https?:)?//|\[)"  # ![alt](http://x) and ![alt][ref]
    r"|<\s*(?:iframe|script|object|embed)\b"
    r"|<\s*(?:img|video|audio|source)\b[^>]*(?:https?:|[\"'=])//", re.IGNORECASE)
RECEIPT_WORDS = re.compile(r"\b(?:save|move|junk|archive|done|create|schedule)\b", re.IGNORECASE)
SEND_KEYS = {"control+enter", "meta+enter", "alt+s"}  # plain Enter may only be a search
RECEIPT_TOOLS = {"browser_click": "browser_click", "browser_press_key": "browser_press",
                 "Write": "write_file", "Edit": "patch"}  # the kinds Receipt.swift reads
MAX_RECEIPTS = 2000
MAX_SNAPSHOT = 4_000_000


def short(text: object, limit: int = 60) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _plain_path(text: str) -> str:
    """For matching only: /mod//quiz/, /mod/./quiz/, /mod/x/../quiz/ and %2Fmod%252Fquiz all read
    /mod/quiz (the server would read them so)."""
    text = unquote(unquote(re.sub(r"[\t\r\n]", "", text))).replace("\\", "/")
    text = re.sub(r"/(?:\.?/)+", "/", text)
    while (shorter := re.sub(r"/[^/?#]+/\.\.(?=/)", "", text, count=1)) != text:
        text = shorter
    return text


def _label(line: str) -> str:
    quoted = QUOTED.search(line)
    return short(quoted.group(0)[1:-1] if quoted else REF.sub("", line).strip(" -:"))


def _on(host: str, *names: str) -> bool:
    return any(host == name or host.endswith("." + name) for name in names if name)


def _key(key: object) -> str:
    """"Shift+ctrl+C" -> "control+shift+c"; a bare " " is "space"."""
    *mods, last = str(key).replace(" ", "").lower().split("+")
    return "+".join([*sorted({"control" if m == "ctrl" else m for m in mods}), last or "space"])


def refs(snapshot: str) -> dict[str, str]:
    """ref -> its snapshot line; refs inside quoted text and refs seen twice are dropped."""
    seen: dict[str, str] = {}
    twice: set[str] = set()
    for line in snapshot.splitlines():
        for ref in REF.findall(QUOTED.sub('""', line)):
            if ref in seen:
                twice.add(ref)
            seen[ref] = line.strip()
    return {ref: line for ref, line in seen.items() if ref not in twice}


def text_of(result: object) -> str:
    """A tool result as text: MCP content blocks, {"content": [...]}, or anything else."""
    if isinstance(result, dict) and "content" in result:
        result = result["content"]
    if isinstance(result, list):
        return "\n".join(str(b.get("text", "")) if isinstance(b, dict) else str(b) for b in result)
    return result if isinstance(result, str) else json.dumps(result, default=str)


class Guard:
    """The decisions and the page memory of one run."""

    def __init__(self, home: Path, *, runtime: Path, own: list[Path] | None = None,
                 moodle: str = "", cwd: Path | None = None):
        self.home = Path(home)
        self.cwd = Path(cwd or home)
        # neither read nor written: R (keys, memory, sessions) and ~/.hermes (Brave's school logins)
        self.secret = [Path(runtime).resolve(), (self.home / ".hermes").resolve()]
        self.own = [*self.secret, *(Path(p).resolve() for p in own or [])]  # never written
        self.receipts = self.home / ".local" / "share" / "robo" / "receipts.jsonl"
        self.own += [self.receipts.resolve(), self.receipts.with_name("usage.jsonl").resolve()]
        self.moodle = urlsplit(moodle or "").hostname or ""
        self.snapshots = self.home / ".local" / "share" / "robo" / "browser"  # Playwright's
        self.labels: dict[str, str] = {}  # "e5" -> snapshot line
        self.page = ""  # URL of the page last seen
        self.typed: list[str] = []  # addresses typed on a mail or Teams page
        self.searched = False  # the last browser action typed into a search box

    # --- helpers ---------------------------------------------------------------------------

    def _resolve(self, path: str) -> Path:
        if path.startswith("~"):
            path = str(self.home) + path[1:]
        return (self.cwd / path).resolve()  # an absolute path stays itself

    def _inside(self, path: str, places: list[Path]) -> bool:
        if OWN_WORDS.search(path):
            return True
        full = self._resolve(path)
        return any(place == full or place in full.parents for place in places)

    def _covers(self, tool: str, args: dict) -> bool:
        """A Grep or Glob that would search R or ~/.hermes: its folder (the current one when none is
        given) plus the literal start of its file pattern is in one of them or above one."""
        given = str(args.get("path") or "")
        files = str(args.get("pattern" if tool == "Glob" else "glob") or "")
        if OWN_WORDS.search(given) or OWN_WORDS.search(files):
            return True
        literal = []
        for part in files.split("/"):
            if re.search(r"[*?\[{]", part):
                break
            literal.append(part)
        root = self._resolve(os.path.join(given or ".", "/".join(literal)))
        return any(s == root or s in root.parents or root in s.parents for s in self.secret)

    def _host(self) -> str:
        return urlsplit(self.page).hostname or ""

    def _school(self, host: str) -> bool:
        """Outlook, Teams or the user's Moodle."""
        return _on(host, *SCHOOL_HOSTS, self.moodle)

    def _target(self, args: dict) -> tuple[str, str | None]:
        """(the target as given, its snapshot line or None when it is no known ref)."""
        target = str(args.get("target") or args.get("ref") or "").strip()
        ref = REF_ARG.match(target)
        return target, self.labels.get(ref[1]) if ref else None

    def _who(self, text: str, page: str) -> str:
        """For a click that mails or invites people: who gets it, as far as typed addresses tell."""
        if not (SENDS.search(text) or (self.typed and "/calendar" in page
                                       and INVITES.search(text))):
            return ""
        return f" (to {', '.join(self.typed)})" if self.typed else " (recipients unknown)"

    # --- the decision ----------------------------------------------------------------------

    def _command(self, command: str) -> tuple[str, str] | None:
        plain = re.sub(r"[\\'\"]", "", command)  # r\m, 'rm', robo''_agent
        plain = re.sub(r"/(?:\.?/)+", "/", plain)  # a//b, a/./b
        if OWN_WORDS.search(plain) or any(str(p) in plain for p in self.own):
            return "block", "robo may not touch its own setup, keys or logs"
        if GRADED_PATH.search(_plain_path(plain)):
            return "block", GRADED
        if DEBUG_PORT.search(plain):
            return "block", "Brave's debugging port is only for the browser tools"
        if OPENS_CODE.search(plain) and not INSTALLED.search(plain):
            return "block", "`open` runs outside the sandbox: it may start installed apps, not code"
        words = {word.rsplit("/", 1)[-1] for word in WORDS.split(plain)}
        if words & DANGER_WORDS or DANGER.search(plain):
            return "approve", f"run: {command}"
        return None

    def _write(self, path: str, text: str) -> tuple[str, str] | None:
        if self._inside(path, self.own):
            return "block", "robo may not change its own setup, skills or logs"
        if NOTE.search(path) and REMOTE.search(text):
            return "block", ("a note with a remote image or active HTML loads it when Obsidian "
                             "opens the note, which can leak the user's data. Link the page as "
                             "[text](url)")
        return None

    def check(self, tool: str, args: dict) -> tuple[str, str] | None:
        """("block", reason) or ("approve", what robo wants to do); None lets the call through."""
        if tool == "Bash":
            return self._command(str(args.get("command", "")))
        if tool in ("Write", "Edit"):
            text = " ".join(str(args.get(k, "")) for k in ("content", "new_string"))
            return self._write(str(args.get("file_path", "")), text)
        if tool == "Read":
            path = str(args.get("file_path") or "")
            if path and self._inside(path, self.secret):
                return "block", "robo may not read its own keys and setup"
            return None
        if tool in ("Glob", "Grep"):
            if self._covers(tool, args):
                return "block", ("this search would cover robo's keys: give it a `path` that holds "
                                 "neither ~/.local/share/robo/agent nor ~/.hermes")
            return None
        if DEBUG_PORT.search(str(args.get("url", ""))):
            return "block", "Brave's debugging port is only for the browser tools"
        if not tool.startswith("browser_"):
            return None
        url = unquote(re.sub(r"[\t\r\n]", "", str(args.get("url", ""))))
        host, page = self._host(), _plain_path(self.page).lower()
        if tool == "browser_navigate" or (tool == "browser_tabs" and url):
            scheme = urlsplit(url).scheme.lower()
            if GRADED_URL.search(_plain_path(url)):
                return "block", GRADED
            if scheme == "javascript" and self._school(host):
                return "block", f"no raw JavaScript on {host}: {GRADED}"
            if scheme in ("http", "https") and not BAD_URL.search(url):
                return None
            return "approve", f"open {short(url, 120)}"
        if tool == "browser_run_code_unsafe":  # no skill needs it, and it can drive any page
            return "block", f"no raw browser code: {GRADED}"
        if tool in RAW_JS and (self._school(host) or GRADED_PATH.search(
                _plain_path(str(args.get(RAW_JS[tool], ""))))):
            return "block", f"no raw JavaScript on {host or 'this page'}: {GRADED}"
        if tool in ON_PAGE and QUIZ_ATTEMPT.search(page):
            return "block", f"this page is a quiz attempt: {GRADED}"
        target, line = self._target(args)
        if tool in ON_PAGE and GRADED_PATH.search(page) and not (
                tool == "browser_click" and line and LINK.match(line)):
            # a button's label may be in any language: only links lead off these pages
            return "block", f"this page holds graded work: {GRADED}"
        known = f'"{_label(line)}"' if line else f"an unknown element ({short(target, 30)})"
        on = f" on {host}" if host else ""
        mail = _on(host, *MAIL_HOSTS)
        if tool == "browser_click":
            text = line or ""
            named = f"{text} {'' if line else target} {args.get('element', '')}"
            if GRADED_LABEL.search(named) or ("/mod/assign/" in page and SAVE_CHANGES.search(text)):
                return "block", GRADED
            who = self._who(text, page) if mail else ""
            if line is None or IRREVERSIBLE.search(text) or who or (
                    mail and BUTTON.match(text) and MAIL_ACT.search(text)):
                return "approve", f"click {known}{on}{who}"
        elif tool == "browser_type" and args.get("submit"):
            text = line or ""
            if not (line and SEARCH.search(text) and not (MESSAGE.search(text)
                                                          or IRREVERSIBLE.search(text))):
                return "approve", f"type into {known} and press Enter{on}"
        elif tool == "browser_press_key":
            key = _key(args.get("key", ""))
            search = key in ("enter", "return", "numpadenter") and self.searched
            if (key.rsplit("+", 1)[-1] in ACTIVATE or key in SHORTCUTS) and not search:
                return "approve", f'press "{short(args.get("key", ""), 30) or "Space"}"{on}'
        elif tool == "browser_handle_dialog":
            return "approve", f"{'accept' if args.get('accept') else 'dismiss'} a page dialog{on}"
        elif tool in ("browser_file_upload", "browser_drop") and args.get("paths"):
            return "approve", f"upload {short(', '.join(map(str, args['paths'])), 120)}{on}"
        return None

    def pre(self, tool: str, args: dict) -> dict | None:
        """The verdict as {"action": "block"|"approve", "message", "rule_key"}; None allows."""
        verdict = self.check(tool, args if isinstance(args, dict) else {})
        if tool.startswith("browser_") and tool != "browser_snapshot":
            self.searched = False  # focus may move; a search type sets it again once it worked
        if verdict is None:
            return None
        action, text = verdict
        if action == "block":
            return {"action": "block", "message": f"robo-guard blocked {tool}: {text}. Tell the "
                    "user what you wanted to do instead of trying another way."}
        end = "" if text.startswith("run: ") else "."  # a shown command is not followed by a dot
        return {"action": "approve", "message": f"Robo wants to {text}{end}",
                "rule_key": f"robo-guard:{tool}:{text}"}

    # --- after the call --------------------------------------------------------------------

    def _snapshot(self, text: str) -> str | None:
        """The page snapshot a Playwright result carries, inline or in its .yml file."""
        inline = INLINE_SNAPSHOT.search(text)
        if inline:
            return inline[1]
        link = SNAPSHOT_FILE.search(text)
        if not link:
            return None
        for path in (self._resolve(link[1]), self.snapshots / Path(link[1]).name):
            try:
                if path.is_file() and path.stat().st_size <= MAX_SNAPSHOT:
                    return path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
        return None

    def _evidence(self, tool: str, args: dict, line: str) -> str:
        """What a state-changing call did, in a few words (never typed text or page text)."""
        if tool == "browser_click":
            words = IRREVERSIBLE.search(line) or RECEIPT_WORDS.search(line)
            return _label(line) if BUTTON.match(line) and words else ""
        if tool == "browser_press_key":
            key = args.get("key", "")
            return f"press {short(key, 30)}" if _key(key) in SEND_KEYS else ""
        if tool in ("Write", "Edit"):
            return short(args.get("file_path", ""), 200)
        return ""

    def receipt(self, tool: str, what: str, host: str, ok: bool) -> None:
        """One JSON line in receipts.jsonl (dir 0700, file 0600, the last 2000 kept)."""
        row = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"), "tool": tool,
               "label_or_path": what, "host": host, "ok": ok}
        path = self.receipts
        try:
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.parent.chmod(0o700)
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            path.chmod(0o600)
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
            if len(lines) > MAX_RECEIPTS:
                path.write_text("".join(lines[-MAX_RECEIPTS:]), encoding="utf-8")
        except OSError:
            pass  # evidence is best effort: it must never fail the tool call

    def post(self, tool: str, args: dict, result: object = "", ok: bool = True) -> None:
        """Learn from a call that ran (`ok` False: it failed) and keep its receipt."""
        args = args if isinstance(args, dict) else {}
        text = text_of(result)
        failed = not ok or text.lstrip().startswith("### Error")
        _, line = self._target(args)  # read before the page changes
        line = line or ""
        host = self._host()  # of the page the call ran on, before a navigation moves it
        if not failed and tool == "browser_type":
            if SEARCH.search(line) and not (MESSAGE.search(line) or IRREVERSIBLE.search(line)):
                self.searched = not args.get("submit")
            if _on(host, *SCHOOL_HOSTS):  # only the addresses are kept, for the Send question
                seen = [*self.typed, *EMAIL.findall(str(args.get("text", "")))]
                self.typed = list(dict.fromkeys(seen))[-10:]
        if not failed and tool == "browser_fill_form" and _on(host, *SCHOOL_HOSTS):
            values = " ".join(str(f.get("value", "")) for f in args.get("fields") or []
                              if isinstance(f, dict))
            self.typed = list(dict.fromkeys([*self.typed, *EMAIL.findall(values)]))[-10:]
        what = self._evidence(tool, args, line)
        if what:
            self.receipt(RECEIPT_TOOLS[tool], what, host if tool.startswith("browser_") else "",
                         not failed)
            if not failed and tool == "browser_click" and SENDS.search(line):
                self.typed = []  # the draft is gone
        if failed or not tool.startswith("browser_"):
            return  # a call that failed changed nothing: the refs still hold
        url = PAGE_URL.search(text)
        if url:
            self.page = url[1]
        snapshot = self._snapshot(text)
        if snapshot is not None:
            self.labels = refs(snapshot)
        elif tool in CHANGES_PAGE:
            self.labels = {}
