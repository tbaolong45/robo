import http.server
import queue
import socket
import threading
import time

import httpx
import pytest

from robo.health import HealthPoller

WAIT = 3.0  # generous: a test only waits this long when something is broken


class Reply:
    def __init__(self, status):
        self.status_code = status


class Fake:
    """A `get` that plays `script` (a status or an exception per call; the last repeats)."""

    def __init__(self, *script):
        self.script, self.calls = list(script), []

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        step = self.script[min(len(self.calls), len(self.script)) - 1]
        if isinstance(step, BaseException):
            raise step
        return Reply(step)


def poller(*script, url="http://127.0.0.1:8642/p/robo", every=60.0, retry=0.01):
    """(poller, fake get, states queue); `every` is huge, so only `retry` can explain a poll."""
    get, states = Fake(*script), queue.Queue()
    return HealthPoller(url, states.put, get=get, every=every, retry=retry), get, states


def states_of(p, states, n):
    p.start()
    try:
        return [states.get(timeout=WAIT) for _ in range(n)]
    finally:
        p.stop()


def test_ok_then_waits_every_before_the_next_poll():
    p, get, states = poller(200)  # retry is 10 ms, every is 60 s
    p.start()
    try:
        assert states.get(timeout=WAIT) == "ok"
        time.sleep(0.2)
        assert len(get.calls) == 1 and states.empty()
    finally:
        p.stop()


def test_an_ok_poll_waits_the_every_interval_not_the_retry_one():
    p, get, states = poller(200, every=0.05, retry=60.0)
    assert states_of(p, states, 2) == ["ok", "ok"]


def test_one_failure_is_warn_then_retries_after_retry_not_every():
    p, get, states = poller(500, 200)
    assert states_of(p, states, 2) == ["warn", "ok"]  # every=60: only `retry` can explain this


def test_two_failures_in_a_row_are_bad_and_polling_goes_on_until_recovery():
    p, get, states = poller(500, 500, 500, 200)
    assert states_of(p, states, 4) == ["warn", "bad", "bad", "ok"]


def test_recovery_resets_the_count():
    p, get, states = poller(500, 500, 200, 500, every=0.01)
    assert states_of(p, states, 4) == ["warn", "bad", "ok", "warn"]


def test_poke_polls_at_once():
    p, get, states = poller(200)
    p.start()
    try:
        assert states.get(timeout=WAIT) == "ok"
        p.poke()
        assert states.get(timeout=WAIT) == "ok"  # every=60 s, so only the poke woke it
        assert len(get.calls) == 2
    finally:
        p.stop()


def test_poke_after_a_good_poll_can_turn_it_warn():
    p, get, states = poller(200, 500)
    p.start()
    try:
        assert states.get(timeout=WAIT) == "ok"
        p.poke()
        assert states.get(timeout=WAIT) == "warn"
    finally:
        p.stop()


def test_stop_ends_the_thread_without_waiting_out_the_interval():
    p, get, states = poller(200)
    p.start()
    assert states.get(timeout=WAIT) == "ok"
    p.stop()
    p._thread.join(WAIT)
    assert not p._thread.is_alive()
    assert len(get.calls) == 1


def test_stop_during_the_retry_wait_ends_it_and_stays_quiet():
    p, get, states = poller(500, retry=60.0)
    p.start()
    assert states.get(timeout=WAIT) == "warn"
    p.stop()
    p._thread.join(WAIT)
    assert not p._thread.is_alive()
    assert states.empty()


def test_stop_during_a_slow_poll_reports_nothing():
    inside, release = threading.Event(), threading.Event()
    states = queue.Queue()

    def slow(url, **kwargs):
        inside.set()
        release.wait(WAIT)
        return Reply(200)

    p = HealthPoller("http://h", states.put, get=slow)
    p.start()
    assert inside.wait(WAIT)
    p.stop()
    release.set()
    p._thread.join(WAIT)
    assert not p._thread.is_alive()
    assert states.empty()  # the window is closing; nobody is listening any more


@pytest.mark.parametrize(("base", "health"), [
    ("http://127.0.0.1:8642/p/robo", "http://127.0.0.1:8642/health"),
    ("http://127.0.0.1:8642", "http://127.0.0.1:8642/health"),
    ("http://127.0.0.1:9/p/robo", "http://127.0.0.1:9/health"),  # ROBO_HERMES_URL for a red LED
])
def test_health_url_is_the_gateway_root_plus_health(base, health):
    p, get, states = poller(200, url=base)
    states_of(p, states, 1)
    assert [url for url, _ in get.calls] == [health]


def test_no_auth_header_short_timeout_and_no_environment_proxy():
    p, get, states = poller(200)
    states_of(p, states, 1)
    (_, kwargs), = get.calls
    assert kwargs == {"timeout": 1.5, "trust_env": False}  # no headers=, so no key can leak


@pytest.mark.parametrize("boom", [
    httpx.ConnectError("refused"), httpx.ReadTimeout("slow"), httpx.InvalidURL("bad"),
    OSError("network down"), ValueError("x"), RuntimeError("x"), Exception("x"),
])
def test_any_exception_is_a_failure_and_never_escapes(boom):
    p, get, states = poller(boom, boom, 200)
    assert states_of(p, states, 3) == ["warn", "bad", "ok"]


def test_a_reply_without_a_status_code_is_a_failure_not_a_crash():
    replies = iter([object(), Reply(200)])
    states = queue.Queue()
    p = HealthPoller("http://h", states.put, get=lambda url, **kw: next(replies), retry=0.01)
    assert states_of(p, states, 2) == ["warn", "ok"]


@pytest.mark.parametrize("status", [204, 301, 401, 404, 500, 503])
def test_only_200_is_ok(status):
    p, get, states = poller(status)
    assert states_of(p, states, 1) == ["warn"]


def test_a_callback_that_raises_does_not_kill_the_poller():
    seen = queue.Queue()

    def on_state(state):
        seen.put(state)
        if seen.qsize() == 1:
            raise RuntimeError("the UI is gone")

    p = HealthPoller("http://h", on_state, get=Fake(200), every=60.0)
    p.start()
    try:
        assert seen.get(timeout=WAIT) == "ok"
        p.poke()
        assert seen.get(timeout=WAIT) == "ok"
    finally:
        p.stop()


# --- the real httpx.get against a throwaway loopback server (never the live gateway) ------------


class Gateway(http.server.BaseHTTPRequestHandler):
    seen: list[tuple[str, dict]] = []

    def do_GET(self):
        type(self).seen.append((self.path, dict(self.headers)))
        self.send_response(200 if self.path == "/health" else 404)
        self.end_headers()

    def log_message(self, *args):
        pass


def test_default_getter_hits_health_without_credentials_and_sees_a_closed_port_as_warn(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:1")  # trust_env=False must ignore this
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:1")
    Gateway.seen = []
    server = http.server.HTTPServer(("127.0.0.1", 0), Gateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        states = queue.Queue()
        up = HealthPoller(f"http://127.0.0.1:{server.server_port}/p/robo", states.put)
        up.start()
        assert states.get(timeout=WAIT) == "ok"
        up.stop()
    finally:
        server.shutdown()
        server.server_close()
    (path, headers), = Gateway.seen
    assert path == "/health"
    assert not {k.lower() for k in headers} & {"authorization", "proxy-authorization", "cookie"}

    with socket.socket() as s:  # a port nothing listens on
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    down = HealthPoller(f"http://127.0.0.1:{port}/p/robo", states.put)
    down.start()
    try:
        assert states.get(timeout=WAIT) == "warn"
    finally:
        down.stop()
