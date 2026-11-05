"""One run of the agent: the Claude Agent SDK on DeepSeek, with persona, skills, memory and guard.

The app's events come out of `Run.emit` in the shape Brain.swift reads (see server.py). Every tool
call passes robo-guard first: the PreToolUse hook answers allow or deny for every call (robo has
the whole laptop), and PostToolUse leaves a receipt. No permission mode is set: the CLI forces
"default" while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB keeps the key out of Bash's environment, so the
tools are allowed by name and the hook's explicit "allow" answers the rest. The guard's patterns
are a speed bump; `boundary` is the wall: the CLI's deny rules for Read, Edit, Grep and Glob, and on
macOS a sandbox around Bash (checked by tests/test_e2e.py against the real CLI).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import sys
import uuid
from datetime import date
from pathlib import Path

from .config import AGENT, API_BASE, Config, builtin_skills, render_skills, soul
from .guard import Guard
from .memory import private_reason

TOOLS = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch", "Skill"]
PLAYWRIGHT = "@playwright/mcp@0.0.83"
CDP = "http://127.0.0.1:9333"  # robo's own Brave, started by the app
PREFIXES = ("mcp__playwright__", "mcp__robo__")
APPROVAL_S = 120
CHEAP_MODEL = "deepseek-flash"
LLM_S = 60
TERMINAL = {"run.completed", "run.failed", "run.cancelled"}
DENIED = ("BLOCKED: the user denied this. Do NOT retry it or try another way; tell the user what "
          "you wanted to do.")
LOST = "No conversation found"  # the CLI's words when the transcript of a resume is gone
# Runs nobody asked for in words: what they read comes from pages and must not teach anything.
AUTOMATED_SESSIONS = ("robo-posts-", "robo-eval-")
DIGEST_PROMPT = "Give me my school digest for today (use the school digest skill)."  # Window.swift
TRACE_ARGS = ("command", "file_path", "path", "url", "pattern", "glob", "element", "key")
TRACE_CLIP = 200
_background: set[asyncio.Task] = set()  # learning outlives its run; keep a reference


def short(name: str) -> str:
    for prefix in PREFIXES:
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


def spawn(coro) -> None:
    task = asyncio.create_task(coro)
    _background.add(task)
    task.add_done_callback(_background.discard)


class Run:
    """One request's events (replayed to any reader) and its pending approvals."""

    def __init__(self, text: str, session_id: str):
        self.id = "run_" + uuid.uuid4().hex
        self.input, self.session_id = text, session_id
        self.events: list[dict] = []
        self.task: asyncio.Task | None = None
        self.asks: dict[str, tuple[asyncio.Future, str]] = {}  # request_id -> (answer, rule_key)
        self.approved: set[str] = set()  # rule keys answered "session"
        self.sdk_session = ""  # the SDK's id for this conversation, from its result
        self.trace: list[str] = []  # each tool call in a line, for the learner
        self._tick = asyncio.Event()

    @property
    def done(self) -> bool:
        return bool(self.events) and self.events[-1]["event"] in TERMINAL

    def emit(self, event: str, **fields) -> None:
        if self.done:
            return
        self.events.append({"event": event, "run_id": self.id, **fields})
        if event in TERMINAL:
            for answer, _ in self.asks.values():
                if not answer.done():
                    answer.set_result("deny")
        self._tick.set()
        self._tick = asyncio.Event()

    async def wait(self, seen: int, timeout: float) -> None:
        """Until there are more than `seen` events, or `timeout` seconds."""
        tick = self._tick
        if len(self.events) <= seen:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(tick.wait(), timeout)

    async def ask(self, description: str, rule_key: str) -> str:
        """Show the user an approval and wait for "once", "session" or "deny" (120 s: deny)."""
        request_id = uuid.uuid4().hex
        answer = asyncio.get_running_loop().create_future()
        self.asks[request_id] = (answer, rule_key)
        self.emit("approval.request", description=description, command="", request_id=request_id)
        try:
            choice = await asyncio.wait_for(answer, APPROVAL_S)
        except TimeoutError:
            choice = "deny"
        finally:
            self.asks.pop(request_id, None)
        if choice == "session":
            self.approved.add(rule_key)
        return choice

    def answer(self, choice: str, request_id: str | None = None) -> bool:
        """Answer the named ask, or the oldest one; False when there is none."""
        if not request_id:
            request_id = next(iter(self.asks), None)
        entry = self.asks.get(request_id or "")
        if entry is None or entry[0].done():
            return False
        entry[0].set_result(choice)
        return True


# --- state in R --------------------------------------------------------------------------

def _write(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(text)
    os.replace(tmp, path)


def sessions(cfg: Config) -> dict[str, str]:
    """robo's session id -> the SDK's session id, to resume a conversation."""
    try:
        data = json.loads((cfg.root / "sessions.json").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def remember_session(cfg: Config, session_id: str, sdk_id: str) -> None:
    data = sessions(cfg)
    data[session_id] = sdk_id
    _write(cfg.root / "sessions.json", json.dumps(dict(list(data.items())[-200:]), indent=1))


def forget_session(cfg: Config, session_id: str) -> None:
    data = sessions(cfg)
    data.pop(session_id, None)
    _write(cfg.root / "sessions.json", json.dumps(data, indent=1))


def consolidate_due(cfg: Config) -> bool:
    """True once a day: the first call of the day also marks the day."""
    stamp, today = cfg.root / "consolidated", date.today().isoformat()
    try:
        if stamp.read_text(encoding="utf-8").strip() == today:
            return False
    except OSError:
        pass
    _write(stamp, today + "\n")
    return True


# --- the SDK side ------------------------------------------------------------------------

def api_base() -> str:
    """DeepSeek; the tests and CLAUDE.md's offline recipe reroute it with ANTHROPIC_BASE_URL."""
    return os.environ.get("ANTHROPIC_BASE_URL") or API_BASE


def make_llm(key: str):
    """The cheap model for learning: (system, prompt) -> text, bounded in time and length."""
    import anthropic

    # Both credentials, or the client fills the other from a real Anthropic key in the environment.
    client = anthropic.AsyncAnthropic(api_key=key, auth_token=key, base_url=api_base(),
                                      max_retries=1, timeout=LLM_S)

    async def llm(system: str, prompt: str) -> str:
        message = await asyncio.wait_for(client.messages.create(
            model=CHEAP_MODEL, max_tokens=2000, system=system,
            messages=[{"role": "user", "content": prompt}],
            thinking={"type": "disabled"}), LLM_S)  # thinking could use up the 2000 tokens
        return "".join(block.text for block in message.content if block.type == "text")

    return llm


def memory_server(store):
    """The in-process MCP server `robo`: memory_add, memory_search, memory_forget."""
    from claude_agent_sdk import create_sdk_mcp_server, tool

    def reply(text: str, error: bool = False) -> dict:
        out = {"content": [{"type": "text", "text": text}]}
        return {**out, "is_error": True} if error else out

    @tool("memory_add", "Remember one short, durable fact about the user (a preference, a goal, "
          "an exam date). Never a secret or a password.",
          {"type": "object", "properties": {
              "text": {"type": "string"},
              "kind": {"type": "string", "enum": ["fact", "preference", "goal", "event"]}},
           "required": ["text"]})
    async def memory_add(args):
        added = await asyncio.to_thread(store.add, str(args.get("text", "")),
                                        str(args.get("kind") or "fact"), "agent")
        return reply(f"saved as {added}") if added else reply("not saved (refused)", error=True)

    @tool("memory_search", "Search what robo remembers about the user.",
          {"type": "object", "properties": {"query": {"type": "string"},
                                            "limit": {"type": "integer"}}, "required": ["query"]})
    async def memory_search(args):
        limit = max(1, min(int(args.get("limit") or 5), 20))
        found = await asyncio.to_thread(store.search, str(args.get("query", "")), limit)
        return reply("\n".join(f"{f['id']} [{f['kind']}] {f['text']}" for f in found) or "nothing")

    @tool("memory_forget", "Forget one remembered fact by its id (from memory_search).",
          {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]})
    async def memory_forget(args):
        gone = await asyncio.to_thread(store.forget, str(args.get("id", "")))
        return reply("forgotten" if gone else "no such id", error=not gone)

    return create_sdk_mcp_server("robo", "1.0.0", [memory_add, memory_search, memory_forget])


def trace_line(tool: str, args: dict, ok: bool, error: object = "") -> str:
    """One tool call for the learner: the arguments that say what was done (never typed text or a
    file's content), clipped, with anything private replaced."""
    def clean(text: str) -> str:
        text = " ".join(text.split())[:TRACE_CLIP]
        return "[redacted]" if private_reason(text) else text

    parts = [f"{name}={clean(args[name].split('?')[0] if name == 'url' else args[name])}"
             for name in TRACE_ARGS if isinstance(args.get(name), str) and args[name].strip()]
    outcome = "ok" if ok else "FAILED: " + clean(str(error))
    return " ".join([tool, *parts]) + " -> " + outcome


def hooks(run: Run, cfg: Config, guard: Guard, used: list[tuple[str, bool]]) -> dict:
    from claude_agent_sdk import HookMatcher

    def decide(decision: str, reason: str = "") -> dict:
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                       "permissionDecision": decision,
                                       "permissionDecisionReason": reason or "robo-guard"}}

    def deny(reason: str) -> dict:
        return decide("deny", reason)

    async def pre(data, tool_use_id, context):
        try:
            if data.get("cwd"):  # a `cd` in Bash moves the CLI's folder for the next calls
                guard.cwd = Path(data["cwd"])
            verdict = guard.pre(short(data["tool_name"]), data.get("tool_input") or {})
            if verdict is None:
                return decide("allow")
            if verdict["action"] == "block":
                return deny(verdict["message"])
            if cfg.approvals == "off" or verdict["rule_key"] in run.approved:
                return decide("allow")
            choice = await run.ask(verdict["message"], verdict["rule_key"])
            return decide("allow") if choice in ("once", "session") else deny(DENIED)
        except Exception as e:  # a hook that raises lets the call through: fail closed instead
            return deny(f"robo-guard failed ({type(e).__name__}); the call was not made.")

    async def post(data, tool_use_id, context):
        ok = data.get("hook_event_name") != "PostToolUseFailure"
        tool = short(str(data.get("tool_name", "")))
        used.append((tool, ok))
        args = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        run.trace.append(trace_line(tool, args, ok, data.get("error", "")))
        with contextlib.suppress(Exception):  # evidence is best effort
            guard.post(tool, data.get("tool_input") or {},
                       data.get("tool_response") if ok else data.get("error", ""), ok)
        return {}

    return {"PreToolUse": [HookMatcher(hooks=[pre], timeout=APPROVAL_S + 30)],
            "PostToolUse": [HookMatcher(hooks=[post])],
            "PostToolUseFailure": [HookMatcher(hooks=[post])]}


def boundary(cfg: Config) -> dict:
    """What the CLI enforces whatever the guard's patterns miss. `open` alone stays outside Bash's
    sandbox, or no app could start (it needs Launch Services); a command that chains it stays in."""
    home = cfg.home.resolve()
    shared = home / ".local" / "share" / "robo"
    closed = [str(cfg.root.resolve()), str(home / ".hermes")]
    fixed = [str(AGENT.resolve()), str(shared / "receipts.jsonl"), str(shared / "usage.jsonl")]
    # `//` starts an absolute path in a permission rule
    deny = [f"Read(/{p}/**)" for p in closed] + [f"Edit(/{p}/**)" for p in closed + fixed[:1]]
    deny += [f"Edit(/{p})" for p in fixed[1:]]
    out = {"settings": json.dumps({"permissions": {"deny": deny},
                                   "disableSkillShellExecution": True})}
    if sys.platform == "darwin":
        out["sandbox"] = {
            "enabled": True, "failIfUnavailable": True, "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False, "excludedCommands": ["open:*"],
            "filesystem": {"denyRead": closed, "allowWrite": ["/"],
                           "denyWrite": closed + fixed},
            # any host, through the sandbox's proxy; loopback stays closed: Brave's debugging port
            # and robo's own service are not for Bash (Playwright runs outside this sandbox)
            "network": {"allowedDomains": ["*"]}}
    return out


def options(run: Run, cfg: Config, key: str, store, plugin: Path, guard: Guard,
            used: list[tuple[str, bool]]):
    from claude_agent_sdk import ClaudeAgentOptions

    shared = cfg.home / ".local" / "share" / "robo"
    skills = sorted(f"robo:{path.parent.name}" for path in plugin.glob("skills/*/SKILL.md"))
    return ClaudeAgentOptions(
        tools=TOOLS, system_prompt=soul(cfg), model=cfg.model, cwd=str(cfg.home),
        allowed_tools=[*TOOLS, "mcp__playwright", "mcp__robo"],
        resume=sessions(cfg).get(run.session_id),
        include_partial_messages=True, setting_sources=[], skills=skills, **boundary(cfg),
        plugins=[{"type": "local", "path": str(plugin)}], strict_mcp_config=True,
        mcp_servers={
            "playwright": {"command": "npx", "args": [
                "-y", PLAYWRIGHT, "--cdp-endpoint", CDP, "--output-dir", str(shared / "browser")]},
            "robo": memory_server(store)},
        hooks=hooks(run, cfg, guard, used),
        # Both credentials, so a real Anthropic key in the environment can't reach DeepSeek.
        env={"ANTHROPIC_API_KEY": key, "ANTHROPIC_AUTH_TOKEN": key,
             "ANTHROPIC_BASE_URL": api_base(), "ANTHROPIC_DEFAULT_HAIKU_MODEL": CHEAP_MODEL,
             "CLAUDE_CONFIG_DIR": str(cfg.root / "claude"),
             "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",  # the key stays out of Bash's environment
             "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})


def usage_of(result) -> dict:
    """The SDK's usage in the names Brain.swift reads (total counts cache reads and writes)."""
    u = result.usage or {}
    n = {k: int(u.get(k) or 0) for k in ("input_tokens", "output_tokens",
                                         "cache_read_input_tokens", "cache_creation_input_tokens")}
    return {"input_tokens": n["input_tokens"], "output_tokens": n["output_tokens"],
            "cache_read_tokens": n["cache_read_input_tokens"],
            "cache_write_tokens": n["cache_creation_input_tokens"], "total_tokens": sum(n.values())}


async def stream(run: Run, client, used) -> tuple[str, bool]:
    """Turn the SDK's messages into the app's events; (the reply, whether it completed)."""
    from claude_agent_sdk import (
        AssistantMessage,
        ResultMessage,
        StreamEvent,
        ToolResultBlock,
        ToolUseBlock,
        UserMessage,
    )

    names: dict[str, str] = {}  # tool_use_id -> short name
    texts = 0
    async for message in client.receive_response():
        if isinstance(message, StreamEvent) and message.parent_tool_use_id is None:
            event = message.event
            if event.get("type") == "content_block_start" and \
                    event.get("content_block", {}).get("type") == "text":
                texts += 1
                if texts > 1:
                    run.emit("message.delta", delta="\n\n")
            elif event.get("type") == "content_block_delta" and \
                    event.get("delta", {}).get("type") == "text_delta":
                run.emit("message.delta", delta=event["delta"].get("text", ""))
        elif isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, ToolUseBlock):
                    names[block.id] = short(block.name)
                    run.emit("tool.started", tool=names[block.id])
        elif isinstance(message, UserMessage) and isinstance(message.content, list):
            for block in message.content:
                if isinstance(block, ToolResultBlock) and block.tool_use_id in names:
                    run.emit("tool.completed", tool=names.pop(block.tool_use_id),
                             error=bool(block.is_error))
        elif isinstance(message, ResultMessage):
            run.sdk_session = message.session_id
            if message.is_error or message.subtype != "success":
                why = "; ".join(map(str, message.errors or [])) or message.result or message.subtype
                run.emit("run.failed", error=f"the agent stopped: {why}")
                return message.result or "", False
            models = list((message.model_usage or {}).keys())
            run.emit("run.completed", output=message.result or "", usage=usage_of(message),
                     runtime={"model": models[0] if models else ""})
            return message.result or "", True
    run.emit("run.failed", error="the agent ended without a result")
    return "", False


async def execute(run: Run, cfg: Config, store, connect=None, previous: dict | None = None):
    """Run one request to its end event. `connect(options)` makes the SDK client (tests fake it)."""
    key = cfg.key("api_key", "DEEPSEEK_API_KEY")
    if not key:
        run.emit("run.failed", error="no DeepSeek API key: run `robo key set deepseek` in "
                 "Terminal and ask again.")
        return
    if connect is None:
        from claude_agent_sdk import ClaudeSDKClient as connect
    from . import learn

    plugin = cfg.root / "runs" / run.id
    used: list[tuple[str, bool]] = []
    reply, ok = "", False
    try:
        learned = learn.learned_skills_dir(cfg.root)
        render_skills(cfg, plugin, learned)
        # In the turn, not the system prompt: a resumed session keeps its first system prompt.
        context = await asyncio.to_thread(store.context_for, run.input)
        turn = f"{context}\n---\n{run.input}" if context else run.input
        guard = Guard(cfg.home, runtime=cfg.root, own=[AGENT], moodle=cfg.moodle_url or "")

        async def attempt():
            async with connect(options(run, cfg, key, store, plugin, guard, used)) as client:
                await client.query(turn)
                return await stream(run, client, used)

        try:
            reply, ok = await attempt()
        except Exception as e:
            if LOST not in str(e) or run.events:
                raise
            forget_session(cfg, run.session_id)  # its transcript is gone: start the session anew
            reply, ok = await attempt()
        if run.sdk_session:
            remember_session(cfg, run.session_id, run.sdk_session)
    except asyncio.CancelledError:
        run.emit("run.cancelled")
        raise
    except Exception as e:
        run.emit("run.failed", error=f"the agent failed: {type(e).__name__}: {e}")
    finally:
        shutil.rmtree(plugin, ignore_errors=True)
    if cfg.learn and run.events[-1]["event"] != "run.cancelled":
        previous = previous if previous is not None else {}
        last, previous[run.session_id] = previous.get(run.session_id), reply
        if run.session_id.startswith(AUTOMATED_SESSIONS) or run.input.strip() == DIGEST_PROMPT:
            return
        llm = make_llm(key)
        record = learn.RunRecord(session_id=run.session_id, user_text=run.input, reply=reply,
                                 tools=used, trace=run.trace, ok=ok, previous_reply=last)
        names = {path.parent.name for path in builtin_skills()}
        due = consolidate_due(cfg)

        async def job():  # in this order: the day's profile must see this run's facts
            await learn.after_run(record, store, llm, learn.learned_skills_dir(cfg.root), names)
            if due:
                await learn.daily(store, llm)

        spawn(job())
