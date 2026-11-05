"""The real service and `anthropic` client against a fake DeepSeek on loopback: no network."""

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from aiohttp.test_utils import TestClient, TestServer
from robo_agent import chat, config, server

KEY = "ds-CANARYKEY"
AUTH = {"Authorization": "Bearer srv"}


class FakeDeepSeek:
    """Answers each request with `parts`, streamed, or HTTP `status`; keeps what it was sent."""

    def __init__(self):
        self.parts, self.status, self.hold = ["[[feel:happy]]Hel", "lo"], 200, threading.Event()
        self.hold.set()
        self.requests = []
        self.break_after_first = False
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                api.requests.append({"key": self.headers.get("x-api-key"), "path": self.path,
                                     "bearer": self.headers.get("authorization"), "body": body})
                if api.status != 200:
                    data = json.dumps({"error": {"message": "no balance"}}).encode()
                    self.send_response(api.status)
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()

                def send(name, **data):
                    frame = json.dumps({"type": name, **data})
                    self.wfile.write(f"event: {name}\ndata: {frame}\n\n".encode())
                    self.wfile.flush()

                usage = {"input_tokens": 1, "output_tokens": 1}
                send("message_start", message={
                    "id": "m", "type": "message", "role": "assistant", "content": [],
                    "model": body["model"], "stop_reason": None, "stop_sequence": None,
                    "usage": usage})
                send("content_block_start", index=0, content_block={"type": "text", "text": ""})
                send("content_block_delta", index=0,
                     delta={"type": "text_delta", "text": api.parts[0]})
                api.hold.wait(10)
                if api.break_after_first:
                    self.close_connection = True
                    return
                for part in api.parts[1:]:
                    send("content_block_delta", index=0,
                         delta={"type": "text_delta", "text": part})
                send("content_block_stop", index=0)
                send("message_delta", delta={"stop_reason": "end_turn", "stop_sequence": None},
                     usage=usage)
                send("message_stop")

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.http.server_port}"
        threading.Thread(target=self.http.serve_forever, daemon=True).start()


@pytest.fixture
def api(monkeypatch):
    fake = FakeDeepSeek()
    monkeypatch.setenv("ANTHROPIC_BASE_URL", fake.url)
    yield fake
    fake.hold.set()
    fake.http.shutdown()


@pytest.fixture
def cfg(throwaway_home):
    root = config.runtime(throwaway_home)
    root.mkdir(parents=True, mode=0o700)
    (root / "api_key").write_text(KEY + "\n")
    (root / "server_key").write_text("srv\n")
    return config.Config(root=root)


def talk(cfg, *steps):
    """Run async `steps(client)` in order against a served app; their results, in a list."""

    async def go():
        client = TestClient(TestServer(server.make_app(cfg)))
        await client.start_server()
        try:
            return [await step(client) for step in steps]
        finally:
            await client.close()

    return asyncio.run(go())


async def read_events(client, run_id, headers=AUTH):
    stream = await client.get(f"/v1/runs/{run_id}/events", headers=headers)
    frames = (await stream.read()).decode().split("\n\n")
    return [json.loads(line[6:]) for frame in frames for line in frame.split("\n")
            if line.startswith("data: ")]


def asks(text, session="s1"):
    async def step(client):
        r = await client.post("/v1/runs", json={"input": text, "session_id": session}, headers=AUTH)
        return await read_events(client, (await r.json())["run_id"])

    return step


def test_a_reply_streams_as_the_events_the_app_reads(api, cfg):
    [events] = talk(cfg, asks("hi"))
    assert [e["event"] for e in events] == ["message.delta", "message.delta", "run.completed"]
    assert [e["delta"] for e in events[:2]] == ["[[feel:happy]]Hel", "lo"]
    assert events[-1]["output"] == "[[feel:happy]]Hello"


def test_the_request_has_the_persona_the_model_and_no_tools(api, cfg):
    talk(cfg, asks("hi"))
    [request] = api.requests
    assert request["path"].endswith("/v1/messages")
    body = request["body"]
    assert body["model"] == "deepseek-flash" and body["stream"] is True
    assert "You are Robo" in str(body["system"]) and "no tools" in str(body["system"])
    assert "tools" not in body
    assert body["messages"] == [{"role": "user", "content": "hi"}]


def test_a_session_remembers_its_turns_and_another_session_does_not(api, cfg):
    talk(cfg, asks("one"), asks("two"), asks("other", "s2"))
    assert api.requests[1]["body"]["messages"] == [
        {"role": "user", "content": "one"},
        {"role": "assistant", "content": "[[feel:happy]]Hello"},
        {"role": "user", "content": "two"}]
    assert api.requests[2]["body"]["messages"] == [{"role": "user", "content": "other"}]


def test_a_long_session_is_cut_to_the_newest_messages(api, cfg):
    talk(cfg, *[asks(str(i)) for i in range(chat.MAX_MESSAGES)])
    sent = api.requests[-1]["body"]["messages"]
    assert len(sent) == chat.MAX_MESSAGES + 1 and sent[-1]["content"] == str(chat.MAX_MESSAGES - 1)


def test_a_real_anthropic_key_in_the_environment_never_reaches_deepseek(api, cfg, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "ANTHROPIC-KEY-CANARY")
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC-TOKEN-CANARY")
    talk(cfg, asks("hi"))
    assert (api.requests[0]["key"], api.requests[0]["bearer"]) == (KEY, f"Bearer {KEY}")


def test_the_environment_key_wins_over_the_file(api, cfg, monkeypatch):
    monkeypatch.setenv("DEEPSEEK_API_KEY", "from-env")
    talk(cfg, asks("hi"))
    assert api.requests[0]["key"] == "from-env"


def test_without_a_key_the_run_fails_clearly_and_nothing_is_sent(api, cfg):
    (cfg.root / "api_key").unlink()
    [events] = talk(cfg, asks("hi"))
    assert [e["event"] for e in events] == ["run.failed"]
    assert "robo key set deepseek" in events[0]["error"] and not api.requests


def test_a_new_key_is_used_without_a_restart(api, cfg):
    def new_key(client):
        (cfg.root / "api_key").write_text("new\n")
        return asks("two")(client)

    talk(cfg, asks("one"), new_key)
    assert [r["key"] for r in api.requests] == [KEY, "new"]


def test_an_api_error_fails_the_run_and_leaves_the_history_alone(api, cfg):
    api.status = 402

    async def recovers(client):
        api.status = 200
        return await asks("two")(client)

    failed, _ = talk(cfg, asks("one"), recovers)
    assert failed[-1]["event"] == "run.failed" and "no balance" in failed[-1]["error"]
    assert api.requests[-1]["body"]["messages"] == [{"role": "user", "content": "two"}]


def test_an_empty_reply_fails_the_run_and_is_not_remembered(api, cfg):
    api.parts = ["", ""]

    async def recovers(client):
        api.parts = ["fine"]
        return await asks("two")(client)

    failed, _ = talk(cfg, asks("one"), recovers)
    assert [e["event"] for e in failed][-1] == "run.failed" and "empty" in failed[-1]["error"]
    assert api.requests[-1]["body"]["messages"] == [{"role": "user", "content": "two"}]


def test_a_stream_that_breaks_midway_fails_the_run_and_is_not_remembered(api, cfg):
    api.parts = ["partial"]
    api.break_after_first = True

    async def recovers(client):
        api.break_after_first = False
        return await asks("two")(client)

    failed, _ = talk(cfg, asks("one"), recovers)
    assert [e["event"] for e in failed] == ["message.delta", "run.failed"]
    assert api.requests[-1]["body"]["messages"] == [{"role": "user", "content": "two"}]


def test_stop_cancels_the_run_and_a_stopped_turn_is_not_remembered(api, cfg):
    api.hold.clear()

    async def stopped(client):
        r = await client.post("/v1/runs", json={"input": "one", "session_id": "s1"}, headers=AUTH)
        run_id = (await r.json())["run_id"]
        while not api.requests:
            await asyncio.sleep(0.01)
        await client.post(f"/v1/runs/{run_id}/stop", headers=AUTH)
        api.hold.set()
        return await read_events(client, run_id)

    events, _ = talk(cfg, stopped, asks("two"))
    assert events[-1]["event"] == "run.cancelled"
    assert api.requests[-1]["body"]["messages"] == [{"role": "user", "content": "two"}]


def test_a_reader_can_resume_after_the_last_event_it_saw(api, cfg):
    async def resumes(client):
        r = await client.post("/v1/runs", json={"input": "hi", "session_id": "s1"}, headers=AUTH)
        run_id = (await r.json())["run_id"]
        await read_events(client, run_id)
        return await read_events(client, run_id, {**AUTH, "Last-Event-ID": "2"})

    [events] = talk(cfg, resumes)
    assert [e["event"] for e in events] == ["run.completed"]


def test_only_health_works_without_the_server_key(api, cfg):
    async def checks(client):
        health = await client.get("/health")
        runs = await client.post("/v1/runs", json={"input": "hi", "session_id": "s1"})
        wrong = await client.post("/v1/runs", json={"input": "hi", "session_id": "s1"},
                                  headers={"Authorization": "Bearer nope"})
        return health.status, runs.status, wrong.status

    assert talk(cfg, checks) == [(200, 401, 401)]
    assert not api.requests


@pytest.mark.parametrize("body", [{"input": "", "session_id": "s"}, {"input": "hi"},
                                  {"input": 1, "session_id": "s"}])
def test_a_bad_request_is_refused(api, cfg, body):
    async def bad(client):
        return (await client.post("/v1/runs", json=body, headers=AUTH)).status

    assert talk(cfg, bad) == [400]


def test_old_settings_in_the_config_are_ignored(throwaway_home):
    root = config.runtime(throwaway_home)
    root.mkdir(parents=True)
    (root / "config.json").write_text(json.dumps(
        {"port": 9000, "model": "deepseek-v4-pro", "approvals": "off", "learn": True}))
    loaded = config.load(root)
    assert (loaded.port, loaded.model) == (9000, "deepseek-v4-pro")
    assert config.load(throwaway_home / "missing").model == config.DEFAULT_MODEL
