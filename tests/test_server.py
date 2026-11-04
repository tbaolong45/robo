"""robo-agent serve against a fake SDK client: the API and SSE contract the app's Brain.swift
reads, auth, stop, approvals, replay, sessions, the system prompt and skills, learning.

The contract, quoted from native/Sources/RoboCore/Brain.swift:
    let data = try await send("POST", "/v1/runs", ["input": text, "session_id": sessionId])
    guard let id = object?["run_id"] as? String else { throw BrainError(...) }
    var request = try makeRequest("GET", "/v1/runs/\\(runId)/events", timeout: 120)
    if let last { request.setValue(last, forHTTPHeaderField: "Last-Event-ID") }
    if line.starts(with: "data:".utf8) {   (and `id:` lines; a frame ends at a blank line)
    guard let name = d["event"] as? String else { return nil }
    case "message.delta": return .delta(d["delta"] as? String ?? "")
    .toolStarted(d["tool"] ...), .toolCompleted(tool: d["tool"] ..., error: d["error"] as? Bool)
    case "approval.request": let what = d["description"] ...; var command = d["command"] ...
        ... desktop: what.hasPrefix("Allow computer_use"), id: d["request_id"] as? String ?? ""
    return .runEnded(status: String(name.dropFirst("run.".count)), output: d["output"] ...,
                     error: d["error"] as? String ?? "")
    (`usage`: input_tokens, output_tokens, total_tokens, cache_read_tokens, cache_write_tokens;
     `runtime`: provider, model)
    if r.statusCode == 401 { throw BrainError("Hermes rejected the API key (401) ...") }
    let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
    var body = ["choice": choice.rawValue]  (+ "request_id" when known)
"""

import asyncio
import json
import sys
import types
from datetime import date
from pathlib import Path

import pytest
import robo_agent
from aiohttp.test_utils import TestClient, TestServer
from claude_agent_sdk import (
    AssistantMessage,
    ResultMessage,
    StreamEvent,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)
from robo_agent import config, harness, server

KEY = "test-server-key"
AUTH = {"Authorization": f"Bearer {KEY}"}


class FakeStore:
    def __init__(self):
        self.root = None

    def context_for(self, text):
        return "- prefers morning study blocks"

    def add(self, text, kind="fact", source="agent"):
        return "m1"

    def search(self, query, limit=5):
        return [{"id": "m1", "text": "MATH201 midterm", "kind": "event"}]

    def forget(self, id):
        return id == "m1"


@pytest.fixture
def learned(monkeypatch, tmp_path):
    """A stand-in for D2's learn module that records what the harness asks of it."""
    calls = []
    fake = types.ModuleType("robo_agent.learn")

    def learned_skills_dir(root):
        path = root / "skills-learned"
        path.mkdir(parents=True, exist_ok=True)
        return path

    async def after_run(record, store, llm, skills_dir, names):
        calls.append(("after_run", record, names))

    async def consolidate(store, llm):
        calls.append(("consolidate",))

    class RunRecord:
        def __init__(self, **kw):
            self.__dict__.update(kw)

    fake.learned_skills_dir, fake.after_run, fake.consolidate = (learned_skills_dir, after_run,
                                                                consolidate)
    fake.RunRecord = RunRecord
    monkeypatch.setitem(sys.modules, "robo_agent.learn", fake)
    monkeypatch.setattr(robo_agent, "learn", fake, raising=False)
    monkeypatch.setattr(harness, "make_llm", lambda key: "llm")
    return calls


@pytest.fixture
def cfg(throwaway_home, learned):
    root = config.runtime(throwaway_home)
    root.mkdir(parents=True)
    (root / "server_key").write_text(KEY + "\n")
    (root / "api_key").write_text("sk-test\n")
    (root / "config.json").write_text(json.dumps({"vault": "/v/Robo", "moodle_url": "https://m.example",
                                                  "robo_cmd": "/apps/robo", "learn": True}))
    return config.load(root)


def text_events(*parts):
    """StreamEvents of one text block per part, as the SDK yields them."""
    out = []
    for part in parts:
        out.append({"type": "content_block_start", "content_block": {"type": "text"}})
        out.append({"type": "content_block_delta", "delta": {"type": "text_delta", "text": part}})
    return [StreamEvent(uuid=str(i), session_id="sdk-1", event=e) for i, e in enumerate(out)]


def result(text="Done.", session="sdk-1", error=False):
    return ResultMessage(
        subtype="error_during_execution" if error else "success", duration_ms=1, duration_api_ms=1,
        is_error=error, num_turns=1, session_id=session, result=text,
        usage={"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100,
               "cache_creation_input_tokens": 20},
        model_usage={"claude-sonnet-5-5": {}}, errors=["boom"] if error else None)


class Fake:
    """Stands in for ClaudeSDKClient: records the options and plays a script. A callable step is
    awaited with the client (to call hooks); anything else is yielded as an SDK message."""

    made = []

    def __init__(self, script):
        self.script = script

    def __call__(self, options):
        self.options = options
        Fake.made.append(self)
        return self

    async def __aenter__(self):
        self.plugin_files = sorted(str(p) for p in
                                   Path(self.options.plugins[0]["path"])
                                   .rglob("SKILL.md"))
        return self

    async def __aexit__(self, *exc):
        return False

    async def query(self, prompt):
        self.prompt = prompt

    async def receive_response(self):
        for step in self.script:
            if callable(step):
                await step(self)
            else:
                yield step

    async def pre(self, tool, args):
        hook = self.options.hooks["PreToolUse"][0].hooks[0]
        return await hook({"tool_name": tool, "tool_input": args}, "tu1", None)


def run(coro):
    return asyncio.run(coro)


async def started(cfg, connect, store=None):
    client = TestClient(TestServer(server.make_app(cfg, lambda: store or FakeStore(), connect)))
    await client.start_server()
    return client


async def ask(client, text="hi", session="s1"):
    r = await client.post("/v1/runs", json={"input": text, "session_id": session}, headers=AUTH)
    assert r.status == 200
    return (await r.json())["run_id"]


def frames(body: str) -> list[tuple[int, dict]]:
    out = []
    for frame in body.split("\n\n"):
        lines = frame.splitlines()
        if lines and lines[0].startswith("id: "):
            assert lines[1].startswith("data: ")
            out.append((int(lines[0][4:]), json.loads(lines[1][6:])))
    return out


async def events(client, run_id, last=None):
    headers = {**AUTH, **({"Last-Event-ID": str(last)} if last else {})}
    r = await client.get(f"/v1/runs/{run_id}/events", headers=headers)
    assert r.status == 200 and r.headers["Content-Type"].startswith("text/event-stream")
    return frames(await r.text())


# --- health and auth ------------------------------------------------------------------------

def test_health_needs_no_key_and_everything_else_does(cfg):
    async def go():
        client = await started(cfg, Fake([]))
        try:
            r = await client.get("/health")
            assert r.status == 200 and (await r.json())["status"] == "ok"
            for headers in ({}, {"Authorization": "Bearer wrong"}, {"Authorization": KEY}):
                r = await client.post("/v1/runs", json={"input": "x", "session_id": "s"},
                                      headers=headers)
                assert r.status == 401
                assert (await r.json())["error"]["message"]
            r = await client.get("/v1/runs/nope/events", headers=AUTH)
            assert r.status == 404 and (await r.json())["error"]["message"] == "no such run"
            r = await client.post("/v1/runs", json={"session_id": "s"}, headers=AUTH)
            assert r.status == 400
        finally:
            await client.close()
    run(go())


def test_without_a_server_key_file_nothing_is_accepted(cfg):
    (cfg.root / "server_key").unlink()

    async def go():
        client = await started(cfg, Fake([]))
        try:
            r = await client.post("/v1/runs", json={"input": "x", "session_id": "s"},
                                  headers={"Authorization": "Bearer "})
            assert r.status == 401
        finally:
            await client.close()
    run(go())


def test_without_an_api_key_the_run_fails_clearly_and_no_client_starts(cfg):
    (cfg.root / "api_key").unlink()
    fake = Fake([])
    Fake.made.clear()

    async def go():
        client = await started(cfg, fake)
        try:
            got = await events(client, await ask(client))
        finally:
            await client.close()
        assert [e["event"] for _, e in got] == ["run.failed"]
        assert "no Anthropic API key" in got[0][1]["error"]
    run(go())
    assert Fake.made == []


def test_the_key_is_read_again_for_each_run(cfg, monkeypatch):
    (cfg.root / "api_key").unlink()

    async def go():
        client = await started(cfg, Fake([result()]))
        try:
            first = await events(client, await ask(client))
            (cfg.root / "api_key").write_text("sk-new\n")  # `robo key set` while serving
            second = await events(client, await ask(client))
        finally:
            await client.close()
        assert first[-1][1]["event"] == "run.failed"
        assert second[-1][1]["event"] == "run.completed"
    run(go())
    assert Fake.made[-1].options.env["ANTHROPIC_API_KEY"] == "sk-new"


# --- the event stream -----------------------------------------------------------------------

def stream_script():
    return [
        *text_events("Let me look."),
        AssistantMessage(content=[TextBlock("Let me look."), ToolUseBlock(
            id="t1", name="mcp__playwright__browser_navigate", input={"url": "https://x.example"})],
            model="m"),
        UserMessage(content=[ToolResultBlock(tool_use_id="t1", content="ok", is_error=False)]),
        AssistantMessage(content=[ToolUseBlock(id="t2", name="Bash", input={"command": "ls"})],
                         model="m"),
        UserMessage(content=[ToolResultBlock(tool_use_id="t2", content="no", is_error=True)]),
        *text_events("Two things are due."),
        result("[[feel:calm]]Two things are due."),
    ]


def test_the_stream_has_the_events_brain_swift_reads(cfg):
    async def go():
        client = await started(cfg, Fake(stream_script()))
        try:
            got = await events(client, await ask(client))
        finally:
            await client.close()
        assert [n for n, _ in got] == list(range(1, len(got) + 1))
        assert [(e["event"], e.get("delta") or e.get("tool")) for _, e in got[:-1]] == [
            ("message.delta", "Let me look."), ("tool.started", "browser_navigate"),
            ("tool.completed", "browser_navigate"), ("tool.started", "Bash"),
            ("tool.completed", "Bash"), ("message.delta", "\n\n"),
            ("message.delta", "Two things are due."),
        ]
        assert [e["error"] for _, e in got if e["event"] == "tool.completed"] == [False, True]
        end = got[-1][1]
        assert end["event"] == "run.completed"
        assert end["output"] == "[[feel:calm]]Two things are due."
        assert end["usage"] == {"input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 100,
                                "cache_write_tokens": 20, "total_tokens": 135}
        assert end["runtime"] == {"model": "claude-sonnet-5-5"}
    run(go())


def test_last_event_id_replays_only_what_came_after(cfg):
    async def go():
        client = await started(cfg, Fake(stream_script()))
        try:
            run_id = await ask(client)
            whole = await events(client, run_id)
            rest = await events(client, run_id, last=3)
        finally:
            await client.close()
        assert rest == whole[3:]
    run(go())


def test_a_failed_result_is_run_failed(cfg):
    async def go():
        client = await started(cfg, Fake([result("", error=True)]))
        try:
            got = await events(client, await ask(client))
        finally:
            await client.close()
        assert got[-1][1]["event"] == "run.failed" and "boom" in got[-1][1]["error"]
    run(go())


def test_a_quiet_stream_sends_keepalive_comments(cfg, monkeypatch):
    monkeypatch.setattr(server, "PING_S", 0.05)

    async def slow(client):
        await asyncio.sleep(0.2)

    async def go():
        client = await started(cfg, Fake([slow, result()]))
        try:
            r = await client.get(f"/v1/runs/{await ask(client)}/events", headers=AUTH)
            body = await r.text()
        finally:
            await client.close()
        assert ": ping\n\n" in body and frames(body)[-1][1]["event"] == "run.completed"
    run(go())


def test_stop_cancels_the_run(cfg):
    async def forever(client):
        await asyncio.Event().wait()

    async def go():
        client = await started(cfg, Fake([*text_events("Working"), forever]))
        try:
            run_id = await ask(client)
            await asyncio.sleep(0.05)
            r = await client.post(f"/v1/runs/{run_id}/stop", headers=AUTH)
            assert r.status == 200
            got = await events(client, run_id)
        finally:
            await client.close()
        assert [e["event"] for _, e in got] == ["message.delta", "run.cancelled"]
    run(go())


# --- approvals ------------------------------------------------------------------------------

def manual(cfg):
    cfg.approvals = "manual"
    return cfg


async def read_until(response, name):
    """Read SSE lines until an event called `name`; its data."""
    while True:
        line = (await response.content.readline()).decode()
        if line.startswith("data: ") and json.loads(line[6:])["event"] == name:
            return json.loads(line[6:])


@pytest.mark.parametrize("choice,allowed", [("once", True), ("session", True), ("deny", False)])
def test_an_ask_waits_for_the_users_answer(cfg, choice, allowed):
    decisions = []

    async def rm(client):
        decisions.append(await client.pre("Bash", {"command": "rm notes.txt"}))
        decisions.append(await client.pre("Bash", {"command": "rm notes.txt"}))

    async def go():
        client = await started(manual(cfg), Fake([rm, result()]))
        try:
            run_id = await ask(client)
            stream = await client.get(f"/v1/runs/{run_id}/events", headers=AUTH)
            asked = await read_until(stream, "approval.request")
            assert asked["description"] == "Robo wants to run: rm notes.txt"
            assert asked["command"] == "" and asked["request_id"]
            r = await client.post(f"/v1/runs/{run_id}/approval", headers=AUTH,
                                  json={"choice": choice, "request_id": asked["request_id"]})
            assert r.status == 200
            if choice != "session":  # the same command asks again
                again = await read_until(stream, "approval.request")
                r = await client.post(f"/v1/runs/{run_id}/approval", headers=AUTH,
                                      json={"choice": choice})  # no id: the oldest ask
                assert r.status == 200 and again["request_id"] != asked["request_id"]
            await read_until(stream, "run.completed")
            r = await client.post(f"/v1/runs/{run_id}/approval", headers=AUTH,
                                  json={"choice": "once"})
            assert r.status == 404
        finally:
            await client.close()
    run(go())
    out = [d["hookSpecificOutput"] for d in decisions]
    assert [o["permissionDecision"] for o in out] == ["allow" if allowed else "deny"] * 2
    if not allowed:
        assert "BLOCKED" in out[0]["permissionDecisionReason"]
        assert "do NOT retry" in out[0]["permissionDecisionReason"].replace("Do NOT", "do NOT")


def test_an_unanswered_ask_is_denied_after_the_timeout(cfg, monkeypatch):
    monkeypatch.setattr(harness, "APPROVAL_S", 0.05)
    decisions = []

    async def rm(client):
        decisions.append(await client.pre("Bash", {"command": "rm x"}))

    async def go():
        client = await started(manual(cfg), Fake([rm, result()]))
        try:
            await events(client, await ask(client))
        finally:
            await client.close()
    run(go())
    assert decisions[0]["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_approvals_off_allows_asks_but_blocks_still_hold(cfg):
    decisions = []

    async def calls(client):
        decisions.append(await client.pre("Bash", {"command": "rm x"}))
        key = "~/.local/share/robo/agent/api_key"
        decisions.append(await client.pre("Read", {"file_path": key}))
        decisions.append(await client.pre("mcp__playwright__browser_navigate",
                                          {"url": "https://m.example/mod/quiz/attempt.php"}))
        hook = client.options.hooks["PreToolUse"][0].hooks[0]
        decisions.append(await hook({"tool_input": {}}, "t", None))  # a guard error: fail closed

    async def go():
        client = await started(cfg, Fake([calls, result()]))
        try:
            got = await events(client, await ask(client))
        finally:
            await client.close()
        assert "approval.request" not in [e["event"] for _, e in got]
    run(go())
    assert cfg.approvals == "off"
    out = [d["hookSpecificOutput"] for d in decisions]
    assert [o["permissionDecision"] for o in out] == ["allow", "deny", "deny", "deny"]
    assert "graded work" in out[2]["permissionDecisionReason"]


# --- config, prompt, skills, sessions, learning --------------------------------------------

def test_config_defaults_to_approvals_off(tmp_path):
    cfg = config.load(tmp_path / "missing")
    assert (cfg.approvals, cfg.port, cfg.learn) == ("off", 8765, True)
    assert cfg.model == "claude-sonnet-5-5"
    (tmp_path / "config.json").write_text('{"approvals": "manual", "port": 9000, "extra": 1}')
    assert (config.load(tmp_path).approvals, config.load(tmp_path).port) == ("manual", 9000)
    (tmp_path / "config.json").write_text('{"approvals": "sometimes"}')
    assert config.load(tmp_path).approvals == "manual"  # unknown: ask rather than allow
    (tmp_path / "config.json").write_text("not json")
    assert config.load(tmp_path).approvals == "off"


def test_the_run_gets_the_persona_memory_skills_and_tools(cfg):
    fake = Fake([result()])

    async def go():
        client = await started(cfg, fake)
        try:
            await events(client, await ask(client, "plan my day"))
        finally:
            await client.close()
    run(go())
    o = fake.options
    assert fake.prompt == "plan my day"
    assert o.system_prompt.startswith("# Robo") and "{{" not in o.system_prompt
    assert o.system_prompt.endswith("- prefers morning study blocks")
    assert o.model == cfg.model and o.cwd == str(cfg.home) and o.setting_sources == []
    assert o.tools == harness.TOOLS and "mcp__playwright" in o.allowed_tools
    pw = o.mcp_servers["playwright"]
    assert pw["command"] == "npx" and harness.PLAYWRIGHT in pw["args"]
    assert "http://127.0.0.1:9333" in pw["args"] and "robo" in o.mcp_servers
    assert o.env["CLAUDE_CONFIG_DIR"] == str(cfg.root / "claude")
    names = {p.split("/")[-2] for p in fake.plugin_files}
    assert {"school-mail", "robo-notes", "study-plan"} <= names
    plan = next(p for p in fake.plugin_files if "/study-plan/" in p)
    assert not Path(plan).exists()  # the rendered skills go with the run


def test_skills_are_filled_from_the_config(cfg, tmp_path):
    plugin = config.render_skills(cfg, tmp_path / "plugin")
    text = (plugin / "skills" / "study-plan" / "SKILL.md").read_text()
    assert "/apps/robo plan --tasks" in text and "{{" not in text
    notes = (plugin / "skills" / "robo-notes" / "SKILL.md").read_text()
    assert "/v/Robo/Drafts/" in notes
    moodle = (plugin / "skills" / "school-moodle" / "SKILL.md").read_text()
    assert "`https://m.example`" in moodle
    assert json.loads((plugin / ".claude-plugin" / "plugin.json").read_text())["name"] == "robo"


def test_a_learned_skill_is_added_but_never_replaces_a_built_in_one(cfg, tmp_path):
    learned = tmp_path / "learned"
    for name in ("school-mail", "my-habit"):
        (learned / name).mkdir(parents=True)
        (learned / name / "SKILL.md").write_text(f"---\nname: {name}\n---\nlearned\n")
    plugin = config.render_skills(cfg, tmp_path / "plugin", learned)
    assert (plugin / "skills" / "my-habit" / "SKILL.md").read_text().endswith("learned\n")
    assert "learned" not in (plugin / "skills" / "school-mail" / "SKILL.md").read_text()


def test_a_session_resumes_the_sdk_conversation(cfg):
    first, second = Fake([result(session="sdk-abc")]), Fake([result(session="sdk-abc")])

    async def go():
        client = await started(cfg, first)
        try:
            await events(client, await ask(client, session="robo-day"))
        finally:
            await client.close()
        client = await started(cfg, second)
        try:
            await events(client, await ask(client, session="robo-day"))
        finally:
            await client.close()
    run(go())
    assert first.options.resume is None and second.options.resume == "sdk-abc"
    assert json.loads((cfg.root / "sessions.json").read_text()) == {"robo-day": "sdk-abc"}


def test_each_run_is_learned_from_and_the_profile_consolidated_once_a_day(cfg, learned):
    async def tool_then_done(client):
        hook = client.options.hooks["PostToolUse"][0].hooks[0]
        await hook({"hook_event_name": "PostToolUse", "tool_name": "mcp__robo__memory_add",
                    "tool_input": {}, "tool_response": "ok"}, "t", None)

    async def go():
        client = await started(cfg, Fake([tool_then_done, result("Sure.")]))
        try:
            await events(client, await ask(client, "first"))
            await events(client, await ask(client, "no, I meant tomorrow"))
            await asyncio.sleep(0.01)
        finally:
            await client.close()
    run(go())
    runs = [c for c in learned if c[0] == "after_run"]
    assert len(runs) == 2 and [c[0] for c in learned].count("consolidate") == 1
    record, names = runs[1][1], runs[1][2]
    assert (record.user_text, record.reply, record.ok, record.previous_reply) == (
        "no, I meant tomorrow", "Sure.", True, "Sure.")
    assert record.tools == [("memory_add", True)] and "school-digest" in names
    assert (cfg.root / "consolidated").read_text().strip() == date.today().isoformat()


def test_learning_is_off_when_the_config_says_so(cfg, learned):
    cfg.learn = False

    async def go():
        client = await started(cfg, Fake([result()]))
        try:
            await events(client, await ask(client))
        finally:
            await client.close()
    run(go())
    assert learned == []


def test_the_memory_server_is_an_in_process_sdk_server():
    srv = harness.memory_server(FakeStore())
    assert srv["name"] == "robo" and srv["type"] == "sdk"
