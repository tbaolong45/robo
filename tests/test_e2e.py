"""The real SDK and CLI against a fake Anthropic-format API on loopback: no key, no network.

The tests in test_server.py fake the client, so they cannot see what the CLI really does with the
options (it keeps a resumed session's first system prompt, for one). These can: the fake API plays
a script of tool calls found in the request (`SCRIPT:[...]`), records every request, and answers
the learner's calls too. `npx` is a fake Playwright MCP server.
"""

import asyncio
import contextlib
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import claude_agent_sdk
import pytest
from aiohttp.test_utils import TestClient, TestServer
from robo_agent import config, harness, server
from robo_agent.memory import Store

CLI = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
pytestmark = pytest.mark.skipif(not CLI.exists(), reason="this SDK build has no bundled CLI")
macos = pytest.mark.skipif(sys.platform != "darwin", reason="robo's sandbox is macOS only")

KEY = "sk-ant-CANARYKEY000"
AUTH = {"Authorization": "Bearer srv"}
FAKE_MCP = """#!{python}
import json, socket, sys
TOOLS = ["browser_navigate", "browser_snapshot", "browser_click"]
page = "https://x.example/"
for line in sys.stdin:
    m = json.loads(line)
    method = m.get("method")
    if method == "initialize":
        r = {{"protocolVersion": m["params"]["protocolVersion"], "capabilities": {{"tools": {{}}}},
             "serverInfo": {{"name": "playwright", "version": "0"}}}}
    elif method == "tools/list":
        r = {{"tools": [{{"name": t, "description": t, "inputSchema": {{"type": "object"}}}}
                       for t in TOOLS]}}
    elif method == "tools/call":
        page = m["params"].get("arguments", {{}}).get("url", page)
        # Playwright reaches Brave's debugging port on loopback: the sandbox must not stop that.
        socket.create_connection(("127.0.0.1", {port}), 3).close()
        text = ("loopback-reached\\n### Page\\n- Page URL: " + page + "\\n### Snapshot\\n```yaml\\n"
                '- button "Open" [ref=e5]\\n- button "Send" [ref=e6]\\n```')
        r = {{"content": [{{"type": "text", "text": text}}]}}
    elif "id" not in m:
        continue
    else:
        r = {{}}
    print(json.dumps({{"jsonrpc": "2.0", "id": m["id"], "result": r}}), flush=True)
"""


def blocks(message):
    content = message["content"]
    return content if isinstance(content, list) else [{"type": "text", "text": content}]


class FakeApi:
    def __init__(self):
        self.requests, self.facts, self.skill = [], [], {"action": "none"}
        self.type = "other"
        api = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def send_json(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self.send_json(200, {"data": []})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])) or b"{}")
                if "count_tokens" in self.path:
                    return self.send_json(200, {"input_tokens": 1})
                api.requests.append({"key": self.headers.get("x-api-key"),
                                     "bearer": self.headers.get("authorization"), "body": body})
                return api.answer(self, body)

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.http.server_port
        self.url = f"http://127.0.0.1:{self.port}"
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    @staticmethod
    def system(body):
        s = body.get("system") or ""
        return s if isinstance(s, str) else " ".join(b.get("text", "") for b in s)

    def answer(self, handler, body):
        system = self.system(body)
        if "long-term memory of Robo" in system:
            return self.reply(handler, body, json.dumps({"facts": self.facts, "type": self.type}))
        if "You improve Robo" in system:
            return self.reply(handler, body, json.dumps(self.skill))
        if "short profile of the user" in system:
            return self.reply(handler, body, body["messages"][-1]["content"])
        step = self.next_step(body["messages"])
        return self.reply(handler, body, "[[feel:happy]]hello" if step is None else None, step)

    @staticmethod
    def next_step(messages):
        start, script = None, None
        for i, m in enumerate(messages):
            if m["role"] == "user":
                for b in blocks(m):
                    if b.get("type") == "text" and "SCRIPT:" in b["text"]:
                        start, script = i, json.loads(b["text"].split("SCRIPT:", 1)[1])
        if script is None:
            return None
        done = sum(1 for m in messages[start + 1:] if m["role"] == "assistant")
        return script[done] if done < len(script) else None

    def reply(self, handler, body, text, tool=None):
        usage = {"input_tokens": 1, "output_tokens": 1}
        mid = f"msg_{len(self.requests)}"
        if not body.get("stream"):
            return handler.send_json(200, {
                "id": mid, "type": "message", "role": "assistant", "model": body["model"],
                "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                "stop_sequence": None, "usage": usage})
        handler.send_response(200)
        handler.send_header("content-type", "text/event-stream")
        handler.send_header("connection", "close")
        handler.end_headers()
        handler.close_connection = True

        def ev(name, **fields):
            data = json.dumps({"type": name, **fields})
            handler.wfile.write(f"event: {name}\ndata: {data}\n\n".encode())

        ev("message_start", message={
            "id": mid, "type": "message", "role": "assistant", "model": body["model"],
            "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage})
        if tool is None:
            ev("content_block_start", index=0, content_block={"type": "text", "text": ""})
            ev("content_block_delta", index=0, delta={"type": "text_delta", "text": text})
        else:
            ev("content_block_start", index=0, content_block={
                "type": "tool_use", "id": "toolu_" + mid, "name": tool["tool"], "input": {}})
            ev("content_block_delta", index=0, delta={
                "type": "input_json_delta", "partial_json": json.dumps(tool["input"])})
        ev("content_block_stop", index=0)
        ev("message_delta", delta={"stop_reason": "end_turn" if tool is None else "tool_use",
                                   "stop_sequence": None}, usage={"output_tokens": 1})
        ev("message_stop")

    @property
    def main(self):
        """The requests of the agent itself (the learner's carry no tools)."""
        return [r["body"] for r in self.requests if r["body"].get("tools")]

    def of(self, words):
        """The learner's requests whose system prompt holds `words`."""
        return [r["body"] for r in self.requests if words in self.system(r["body"])]

    def results(self):
        """(tool name, is_error, text) of every tool call in the latest agent request."""
        calls, out = {}, []
        for m in self.main[-1]["messages"]:
            for b in blocks(m):
                if b.get("type") == "tool_use":
                    calls[b["id"]] = b["name"]
                elif b.get("type") == "tool_result":
                    out.append((calls[b["tool_use_id"]], bool(b.get("is_error")),
                                json.dumps(b.get("content"))))
        return out


@pytest.fixture
def api(monkeypatch, tmp_path, throwaway_home):
    fake = FakeApi()
    tools = tmp_path / "bin"
    tools.mkdir()
    npx = tools / "npx"
    npx.write_text(FAKE_MCP.format(python=sys.executable, port=fake.port))
    npx.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tools}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("ANTHROPIC_BASE_URL", fake.url)
    # Whatever else the CLI might call goes nowhere; only the fake API is reachable.
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        monkeypatch.setenv(name, "http://127.0.0.1:9")
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    for name in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"):
        monkeypatch.delenv(name, raising=False)
    yield fake
    fake.http.shutdown()


@pytest.fixture
def cfg(throwaway_home):
    root = config.runtime(throwaway_home)
    root.mkdir(parents=True, mode=0o700)
    (root / "api_key").write_text(KEY)
    (root / "server_key").write_text("srv")
    return config.Config(root=root, vault=str(throwaway_home / "vault"))


async def ask(client, text, session="s1", answer=None):
    r = await client.post("/v1/runs", json={"input": text, "session_id": session}, headers=AUTH)
    run_id = (await r.json())["run_id"]
    stream = await client.get(f"/v1/runs/{run_id}/events", headers=AUTH)
    events = []
    while line := await stream.content.readline():
        if line.startswith(b"data: "):
            event = json.loads(line[6:])
            events.append(event)
            if event["event"] == "approval.request":
                await client.post(f"/v1/runs/{run_id}/approval", headers=AUTH,
                                  json={"choice": answer, "request_id": event["request_id"]})
    # the run's task ends just after its last event: it saves the session id then
    while any(getattr(t.get_coro(), "__name__", "") == "execute" for t in asyncio.all_tasks()):
        await asyncio.sleep(0.02)
    return events


def session(cfg, *turns, **kw):
    """Run the requests through the real service and return each one's events."""
    async def go():
        shared = Store(cfg.root)
        client = TestClient(TestServer(server.make_app(cfg, lambda: shared)))
        await client.start_server()
        try:
            out = [await ask(client, turn, **kw) for turn in turns]
            while harness._background:  # learning runs in the background
                await asyncio.gather(*list(harness._background), return_exceptions=True)
            return out
        finally:
            await client.close()
    return asyncio.run(asyncio.wait_for(go(), 180))


def script(*steps):
    return "SCRIPT:" + json.dumps(steps)


def bash(command, **more):
    return {"tool": "Bash", "input": {"command": command, "description": "x", **more}}


def last_user_text(body):
    """All the text after the last assistant message (the CLI adds messages of its own)."""
    turn = []
    for m in reversed(body["messages"]):
        if m["role"] == "assistant":
            break
        turn += [b.get("text", "") for b in blocks(m) if b.get("type") == "text"]
    return " ".join(reversed(turn))


# --- the run itself -------------------------------------------------------------------------

def test_a_real_anthropic_key_in_the_environment_never_reaches_the_provider(api, cfg, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "ANTHROPIC-KEY-CANARY")
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC-TOKEN-CANARY")
    session(cfg, script(bash("echo hi")))
    assert api.requests and {r["body"]["model"] for r in api.requests} == {"deepseek-flash"}
    assert {r["key"] for r in api.requests} == {KEY}
    assert {r["bearer"] for r in api.requests} == {f"Bearer {KEY}"}


def test_the_learners_model_sends_only_the_deepseek_key(api, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "ANTHROPIC-KEY-CANARY")
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC-TOKEN-CANARY")
    with contextlib.suppress(Exception):  # the fake's answer is not the point
        asyncio.run(harness.make_llm(KEY)("system", "hi"))
    [request] = api.requests[:1]
    assert (request["key"], request["bearer"]) == (KEY, f"Bearer {KEY}")
    assert request["body"]["model"] == "deepseek-flash"
    assert request["body"]["thinking"] == {"type": "disabled"}


def test_a_run_uses_the_plain_key_and_streams_the_events_brain_swift_reads(api, cfg):
    [events] = session(cfg, script(bash("echo hi")))
    assert {r["key"] for r in api.requests} == {KEY}
    names = [e["event"] for e in events]
    assert names[:2] == ["tool.started", "tool.completed"] and names[-1] == "run.completed"
    assert events[0]["tool"] == "Bash" and events[1]["error"] is False
    assert any(e["event"] == "message.delta" and e["delta"] for e in events)
    end = events[-1]
    assert end["output"].startswith("[[feel:happy]]") and end["runtime"]["model"] == cfg.model
    assert end["usage"]["total_tokens"] > 0


def test_the_users_own_claude_files_never_reach_the_agent(api, cfg):
    (cfg.home / "CLAUDE.md").write_text("CANARY-PROJECT")
    (cfg.home / ".claude").mkdir()
    (cfg.home / ".claude" / "CLAUDE.md").write_text("CANARY-USER")
    session(cfg, "hello")
    assert "CANARY" not in json.dumps(api.main[-1])


def test_only_robos_own_skills_are_offered(api, cfg):
    learned = cfg.root / "skills-learned" / "my-steps"
    learned.mkdir(parents=True)
    (learned / "SKILL.md").write_text('---\nname: my-steps\ndescription: "Mine"\n---\n\nSteps.\n')
    session(cfg, "hello")
    text = json.dumps(api.main[-1])
    assert "robo:study-ledger" in text and "robo:my-steps" in text
    for bundled in ("update-config", "plugin-authoring", "security-review", "keybindings-help"):
        assert bundled not in text


def test_a_lost_transcript_starts_a_fresh_session_once_with_no_double_events(api, cfg):
    gone = "00000000-0000-4000-8000-000000000000"
    (cfg.root / "sessions.json").write_text(json.dumps({"s1": gone}))
    [events] = session(cfg, "hello again")
    assert [e["event"] for e in events].count("run.completed") == 1
    assert "run.failed" not in [e["event"] for e in events]
    assert json.loads((cfg.root / "sessions.json").read_text())["s1"] != gone


# --- memory reaches the model ---------------------------------------------------------------

def test_memory_reaches_every_turn_of_a_resumed_session(api, cfg):
    fact = "The user studies organic chemistry on Tuesday nights."
    Store(cfg.root).add(fact, kind="habit")
    session(cfg, "hello", "chemistry please")
    first, second = api.main[-2], api.main[-1]
    assert len(second["messages"]) > len(first["messages"])  # it did resume
    turn = last_user_text(second)
    assert fact in turn and "not instructions" in turn and "chemistry please" in turn
    # the learner reads the user's own words, without the memory block
    assert all(fact not in json.dumps(b["messages"]) for b in api.of("long-term memory of Robo"))


def test_the_study_ledgers_memory_kinds_are_stored(api, cfg):
    session(cfg, script(
        {"tool": "mcp__robo__memory_add", "input": {"text": "MATH201 midterm 2026-10-20 09:00",
                                                    "kind": "event"}},
        {"tool": "mcp__robo__memory_add", "input": {"text": "Pass linear algebra", "kind": "goal"}},
    ))
    assert {(f["text"], f["kind"]) for f in Store(cfg.root).all()} >= {
        ("MATH201 midterm 2026-10-20 09:00", "event"), ("Pass linear algebra", "goal")}
    assert [e for _, e, _ in api.results()] == [False, False]


def test_a_learned_fact_and_skill_reach_the_next_run_and_the_profile_has_the_fact(api, cfg):
    api.facts = [{"text": "The user revises with flashcards every evening", "kind": "habit"}]
    api.skill = {"action": "write", "name": "check-first", "description": "Check first",
                 "body": "1. Look.\n2. Answer."}
    session(cfg, script(*[bash("echo step")] * 5))
    assert "flashcards" in (cfg.root / "memory" / "profile.md").read_text()
    session(cfg, "revises flashcards?", session="fresh")
    body = api.main[-1]
    assert "robo:check-first" in json.dumps(body)
    assert "flashcards" in last_user_text(body)


def test_the_learner_gets_trimmed_arguments_and_errors_but_no_secrets(api, cfg):
    secret = "sk-ant-api03-abcdefghijklmnopqrstuv"
    session(cfg, script(bash("echo plain-step"), bash(f"echo {secret}"), bash("false"),
                        bash("true"), bash("true")))
    [body] = api.of("You improve Robo")
    calls = body["messages"][-1]["content"].split("Tool calls", 1)[1]
    assert "plain-step" in calls and "Exit code 1" in calls and "[redacted]" in calls
    assert secret not in calls


def test_an_automated_run_teaches_nothing(api, cfg):
    session(cfg, "Scan the course", session="robo-posts-abc123")
    assert api.of("long-term memory of Robo") == [] and api.of("You improve Robo") == []
    assert not (cfg.root / "activity.jsonl").exists()


def test_a_user_run_leaves_activity_without_its_words(api, cfg):
    api.type = "study"
    session(cfg, "quiz me on eigenvalues please")
    [row] = [json.loads(x) for x in (cfg.root / "activity.jsonl").read_text().splitlines()]
    assert row["type"] == "study" and "eigenvalues" not in json.dumps(row)


# --- the guard, through the real CLI --------------------------------------------------------

def key_results(api):
    return [r for r in api.results() if KEY in r[2] or "COOKIE-CANARY" in r[2]]


def secrets_in_place(cfg):
    profile = cfg.home / ".hermes" / "profiles"
    profile.mkdir(parents=True)
    (profile / "cookies").write_text("COOKIE-CANARY")


def test_read_grep_and_glob_cannot_reach_the_key(api, cfg):
    secrets_in_place(cfg)
    session(cfg, script(
        {"tool": "Grep", "input": {"pattern": "CANARY", "output_mode": "content"}},
        {"tool": "Grep", "input": {"pattern": "CANARY", "path": ".local/share",
                                   "output_mode": "content"}},
        {"tool": "Grep", "input": {"pattern": "CANARY", "path": ".", "glob": ".hermes/**",
                                   "output_mode": "content"}},
        {"tool": "Glob", "input": {"pattern": "**/api_key"}},
        {"tool": "Read", "input": {"file_path": ".local/share/robo/agent/api_key"}},
        {"tool": "Read", "input": {"file_path": ".hermes/profiles/cookies"}},
    ))
    assert key_results(api) == []
    assert all(error for _, error, _ in api.results())


@macos
def test_the_sandbox_stops_bash_reaching_the_key_and_leaves_the_rest_usable(api, cfg):
    secrets_in_place(cfg)
    subprocess.run(["git", "init", "-q", str(cfg.home / "repo")], check=True)
    (cfg.home / "Documents").mkdir()
    (cfg.home / "Documents" / "ordinary.txt").write_text("ORDINARY")
    key = str(cfg.root / "api_key").replace("/robo/", "/ro'+'bo/")
    session(cfg, script(
        bash("cd .local/share/robo && cat agent/api_key"),
        bash("cat ~/.local//share/robo/agent/api_key"),
        bash(f"python3 -c \"print(open('{key}').read())\""),
        bash("cat ~/.he*/profiles/cookies"),
        bash("cat .local/share/ro*/agen*/api_key", dangerouslyDisableSandbox=True),
        bash("ps eww $PPID"),
        bash("printenv"),
        bash(f"curl -s -m 3 --noproxy '*' -o /dev/null {api.url}/x; echo rc=$?"),
        bash("cat Documents/ordinary.txt"),
        bash("mkdir -p Robo vault/Notes && echo a > Robo/a.txt && echo b > vault/Notes/b.md "
             "&& cat Robo/a.txt vault/Notes/b.md"),
        bash("cd repo && echo y > f && git add f && git -c user.name=a -c user.email=a@b.c "
             "commit -qm m && git log --oneline | wc -l | tr -d ' '"),
    ))
    results = api.results()
    assert len(results) == 11 and key_results(api) == []
    assert "rc=0" not in results[7][2]  # loopback, so Brave's debugging port, is closed to Bash
    assert "ORDINARY" in results[8][2] and "a\\nb" in results[9][2]
    assert results[10][2].strip('"').startswith("1"), results[10][2]
    # the model is told what the sandbox closes
    assert "git clone" in json.dumps(api.main[-1]["system"])


@macos
def test_the_sandbox_stops_bash_rewriting_robos_own_setup(api, cfg):
    planted = config.AGENT / ".sandbox-test"
    try:
        session(cfg, script(bash(f"cd {config.AGENT.parent} && echo x > agen''t/.sandbox-test")))
        assert not planted.exists()
    finally:
        planted.unlink(missing_ok=True)


def test_inline_shell_in_a_skill_does_not_run(api, cfg):
    marker = cfg.home / "ran.txt"
    learned = cfg.root / "skills-learned" / "setup-steps"
    learned.mkdir(parents=True)
    (learned / "SKILL.md").write_text(
        f'---\nname: setup-steps\ndescription: "Setup"\n---\n\nSetup: !`touch {marker}`\n')
    session(cfg, script({"tool": "Skill", "input": {"skill": "robo:setup-steps"}}))
    assert not marker.exists()
    assert api.results()[0][1] is False  # the skill itself did load, from a folder in R


def test_the_browser_goes_through_the_guard_with_the_real_hook_shapes(api, cfg):
    cfg.approvals = "manual"
    pw = "mcp__playwright__"
    quiz = "https://m.example/mod//quiz/attempt.php"
    [events] = session(cfg, script(
        {"tool": pw + "browser_navigate", "input": {"url": "https://x.example/"}},
        {"tool": pw + "browser_click", "input": {"target": "e5", "element": "Open"}},
        {"tool": pw + "browser_click", "input": {"target": "e6", "element": "Send"}},
        {"tool": pw + "browser_navigate", "input": {"url": quiz}},
    ), answer="deny")
    asks = [e["description"] for e in events if e["event"] == "approval.request"]
    assert asks == ['Robo wants to click "Send" on x.example.']  # e5 is known and harmless
    results = api.results()
    assert [e for _, e, _ in results] == [False, False, True, True]
    assert "loopback-reached" in results[0][2]  # the MCP server is outside Bash's sandbox
    assert "graded work" in results[3][2]
