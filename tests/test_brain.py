import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest

from robo.brain import BrainError, HermesClient
from robo.events import (
    ApprovalNeeded,
    Delta,
    Feeling,
    RunEnded,
    ToolCompleted,
    ToolStarted,
)

KEY = "sekret-key"


def frame(seq: int, name: str, **fields) -> bytes:
    data = {"event": name, "run_id": "r1", "timestamp": 1.0, **fields, "seq": seq}
    return f"id: {seq}\ndata: {json.dumps(data)}\n\n".encode()


def client(handler, base="http://h:8642") -> HermesClient:
    return HermesClient(base, KEY, httpx.Client(transport=httpx.MockTransport(handler)))


def sse(*chunks: bytes):
    """A handler streaming `chunks` (split anywhere) as the events body."""
    return lambda req: httpx.Response(200, content=iter(chunks))


FULL = b"".join([
    b": open\n\n",
    frame(0, "message.delta", delta="[[feel:happy]] Hel"),
    frame(1, "reasoning.available", text="hmm"),  # post-hoc copy of the reply: ignored
    frame(2, "tool.started", tool="web_search", preview="robots"),
    frame(3, "tool.completed", tool="web_search", duration=1.5, error=False),
    frame(4, "message.interim", text="x", already_streamed=True),
    frame(5, "subagent.spawned", agent="kid"),
    frame(6, "approval.request", command="rm -rf /tmp/x", description="recursive delete",
          choices=["once", "deny"]),
    frame(7, "message.delta", delta="lo"),
    frame(8, "run.completed", output="[[feel:happy]] Hello", completed=True),
    b": stream closed\n\n",
])


def test_events_parses_split_frames():
    chunks = [FULL[i:i + 7] for i in range(0, len(FULL), 7)]
    events = list(client(sse(*chunks)).events("r1"))
    assert events == [
        Delta("[[feel:happy]] Hel"), ToolStarted("web_search", "robots"),
        ToolCompleted("web_search", 1.5, False), ApprovalNeeded("recursive delete"),
        Delta("lo"), RunEnded("completed", output="[[feel:happy]] Hello"),
    ]


@pytest.mark.parametrize("name,fields,want", [
    ("run.failed", {"error": "boom"}, RunEnded("failed", error="boom")),
    ("run.cancelled", {"completed": False}, RunEnded("cancelled")),
    ("run.interrupted", {"error": "shutdown"}, RunEnded("interrupted", error="shutdown")),
])
def test_terminal_events(name, fields, want):
    assert list(client(sse(frame(0, name, **fields))).events("r1")) == [want]


def test_stops_reading_after_terminal_event():
    body = frame(0, "run.completed", output="a") + frame(1, "message.delta", delta="late")
    assert list(client(sse(body)).events("r1")) == [RunEnded("completed", output="a")]


def test_lost_stream_ends_failed():
    events = list(client(sse(frame(0, "message.delta", delta="hi"), b"data: {\"ev")).events("r1"))
    assert events[0] == Delta("hi")
    assert events[1].status == "failed" and events[1].error
    assert len(events) == 2


def test_connection_error_ends_failed():
    def boom(req):
        raise httpx.ConnectError("refused")

    events = list(client(boom).events("r1"))
    assert len(events) == 1 and events[0].status == "failed"
    assert "not running" in events[0].error


def test_http_error_on_stream_ends_failed():
    events = list(client(lambda req: httpx.Response(404, json={"error": {"message": "gone"}}))
                  .events("r1"))
    assert events == [RunEnded("failed", error=events[0].error)]
    assert "gone" in events[0].error


def test_start_run_request_and_prefix_join():
    seen = []

    def handler(req):
        seen.append(req)
        return httpx.Response(202, json={"run_id": "run_9", "status": "started"})

    c = client(handler, base="http://127.0.0.1:8642/p/robo/")
    assert c.start_run("hi", "s1") == "run_9"
    req = seen[0]
    assert (req.method, str(req.url)) == ("POST", "http://127.0.0.1:8642/p/robo/v1/runs")
    assert req.headers["authorization"] == f"Bearer {KEY}"
    assert json.loads(req.content) == {"input": "hi", "session_id": "s1"}


def test_401_is_readable_and_hides_key():
    c = client(lambda req: httpx.Response(401, json={"error": {"message": "Invalid API key"}}))
    with pytest.raises(BrainError) as e:
        c.start_run("hi", "s1")
    assert "key" in str(e.value).lower() and KEY not in str(e.value)


def test_connection_refused_says_not_running():
    def boom(req):
        raise httpx.ConnectError("refused")

    with pytest.raises(BrainError, match="not running"):
        client(boom).stop("r1")


def test_health():
    assert client(lambda req: httpx.Response(200, json={"status": "ok"})).health()
    assert not client(lambda req: httpx.Response(503)).health()

    def boom(req):
        raise httpx.ConnectError("refused")

    assert not client(boom).health()


@pytest.mark.parametrize("allow,choice", [(True, "once"), (False, "deny")])
def test_approve_and_stop_bodies(allow, choice):
    seen = []

    def handler(req):
        seen.append(req)
        return httpx.Response(200, json={})

    c = client(handler, base="http://h/p")
    c.approve("r1", allow)
    c.stop("r1")
    assert str(seen[0].url) == "http://h/p/v1/runs/r1/approval"
    assert json.loads(seen[0].content) == {"choice": choice}
    assert (seen[1].method, str(seen[1].url)) == ("POST", "http://h/p/v1/runs/r1/stop")


def test_ask_splits_feelings_and_strips_output():
    def handler(req):
        if req.method == "POST":
            return httpx.Response(202, json={"run_id": "r1", "status": "started"})
        chunks = [FULL[i:i + 5] for i in range(0, len(FULL), 5)]
        return httpx.Response(200, content=iter(chunks))

    c = client(handler)
    events = list(c.ask("hi", "s1"))
    assert events[0] == Feeling("happy")
    assert "".join(e.text for e in events if isinstance(e, Delta)) == "Hello"
    assert events[-1] == RunEnded("completed", output="Hello")
    assert sum(isinstance(e, RunEnded) for e in events) == 1
    assert c.run_id == "r1"


def test_real_server_streams_incrementally():
    gate = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b": open\n\n" + frame(0, "message.delta", delta="first"))
            self.wfile.flush()
            if gate.wait(5):  # only finish once the client has parsed "first"
                time.sleep(0.05)
                self.wfile.write(frame(1, "run.completed", output="first"))
                self.wfile.write(b": stream closed\n\n")

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        c = HermesClient(f"http://127.0.0.1:{server.server_port}", KEY)
        events = c.events("r1")
        assert next(events) == Delta("first")
        gate.set()
        assert list(events) == [RunEnded("completed", output="first")]
    finally:
        gate.set()
        server.shutdown()
        server.server_close()
