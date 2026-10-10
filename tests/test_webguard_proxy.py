"""The proxy every web page load goes through: it connects only to public addresses.

Telling the browser which hosts to avoid does not work: Chromium follows an HTTP redirect
inside its own network stack, so a public page can answer `302 Location: http://127.0.0.1:8420/`
and the request goes out before any script of ours sees it (measured: a local server received
the GET). A proxy sees every hop, every image and script, and every tunnelled connection, so the
rule lives there, once:

**The address that is checked is the address that is connected to.** The proxy resolves the name
itself, refuses unless EVERY answer is a public address, and then connects to that address, not to
the name - so a name cannot resolve to something else a moment later (DNS rebinding).

**Only a reader's requests are served:** `CONNECT` (HTTPS, and anything else tunnelled) and plain
`GET`/`HEAD` for `http://`. Nothing else, and never a destination that is not public.

**A refusal is an answer, not a crash,** whatever the client sends; the proxy keeps serving.

Real sockets on 127.0.0.1 are used throughout, but never an outside address: the name resolver
and the outgoing connection are replaced by tables, so "the public internet" is a local echo
server that the test can see.
"""

from __future__ import annotations

import errno
import os
import resource
import select
import socket
import threading
import time
from collections.abc import Iterator

import pytest

from pli import webguard
from pli.webguard import FilteringProxy

PUBLIC = "93.184.216.34"


class Upstream:
    """Stands in for the public internet: records what it is sent, answers, and can echo."""

    def __init__(self, reply: bytes = b"") -> None:
        self.reply = reply
        self.received: list[bytes] = []
        self._server = socket.create_server(("127.0.0.1", 0))
        self.port = self._server.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        conn.settimeout(5)
        try:
            if self.reply:  # a web server: read the request, answer, hang up
                data = b""
                while b"\r\n\r\n" not in data:
                    data += conn.recv(4096)
                self.received.append(data)
                conn.sendall(self.reply)
            else:  # an echo tunnel
                while chunk := conn.recv(4096):
                    self.received.append(chunk)
                    conn.sendall(chunk)
        except OSError:
            pass
        finally:
            conn.close()

    def close(self) -> None:
        self._server.close()


def _dns(**hosts: list[str]):
    """A resolver that knows exactly these names; an address typed as digits resolves to itself."""
    import ipaddress

    table = {name.replace("_", "."): addrs for name, addrs in hosts.items()}

    def resolve(host: str, port: object, *args: object, **kwargs: object) -> list[tuple]:
        try:
            ipaddress.ip_address(host)
            addrs = [host]
        except ValueError:
            if host not in table:
                raise socket.gaierror(f"unknown host {host}") from None
            addrs = table[host]
        return [
            (socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port))
            for a in addrs
        ]

    return resolve


@pytest.fixture
def upstream() -> Iterator[Upstream]:
    server = Upstream(reply=b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")
    yield server
    server.close()


@pytest.fixture
def tunnel() -> Iterator[Upstream]:
    server = Upstream()
    yield server
    server.close()


class Wire:
    """A proxy whose outgoing connections all end at `server`, remembering where they were aimed."""

    def __init__(self, server: Upstream, **hosts: list[str]) -> None:
        self.server = server
        self.aimed: list[tuple[str, int]] = []
        self.proxy = FilteringProxy(
            resolve=_dns(**hosts) if hosts else _dns(), connect=self._connect
        )

    def _connect(self, address: str, port: int, timeout: float) -> socket.socket:
        self.aimed.append((address, port))
        return socket.create_connection(("127.0.0.1", self.server.port), timeout)


def _send(proxy: FilteringProxy, raw: bytes) -> bytes:
    """Send `raw` and return what the proxy said before it hung up (a reset is a hang-up too)."""
    data = b""
    with socket.create_connection(("127.0.0.1", proxy.port), timeout=5) as client:
        try:
            client.sendall(raw)
            client.shutdown(socket.SHUT_WR)  # "that is the whole request"
            while chunk := client.recv(4096):
                data += chunk
        except OSError:
            pass
    return data


def _status(response: bytes) -> str:
    return response.split(b"\r\n", 1)[0].decode()


# --- a tunnel to a public host (HTTPS) --------------------------------------------------------


def test_a_tunnel_to_a_public_host_is_opened_and_carries_bytes_both_ways(tunnel: Upstream) -> None:
    wire = Wire(tunnel, example_org=[PUBLIC])
    with wire.proxy, socket.create_connection(("127.0.0.1", wire.proxy.port), timeout=5) as client:
        client.sendall(b"CONNECT example.org:443 HTTP/1.1\r\nHost: example.org:443\r\n\r\n")
        opening = b""
        while b"\r\n\r\n" not in opening:
            opening += client.recv(4096)
        client.sendall(b"ping")
        echoed = client.recv(4096)

    assert opening.startswith(b"HTTP/1.1 200")
    assert echoed == b"ping"


def test_the_proxy_connects_to_the_address_it_checked_not_to_the_name(tunnel: Upstream) -> None:
    wire = Wire(tunnel, example_org=[PUBLIC])
    with wire.proxy:
        _send(wire.proxy, b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")

    assert wire.aimed == [(PUBLIC, 443)]


def test_the_next_address_is_tried_when_the_first_does_not_answer(tunnel: Upstream) -> None:
    wire = Wire(tunnel, example_org=["93.184.216.35", PUBLIC])
    calls: list[str] = []
    real = wire._connect

    def flaky(address: str, port: int, timeout: float) -> socket.socket:
        calls.append(address)
        if address == "93.184.216.35":
            raise ConnectionRefusedError
        return real(address, port, timeout)

    wire.proxy = FilteringProxy(resolve=_dns(example_org=["93.184.216.35", PUBLIC]), connect=flaky)
    with wire.proxy:
        reply = _send(wire.proxy, b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")

    assert calls == ["93.184.216.35", PUBLIC] and _status(reply).startswith("HTTP/1.1 200")


# --- destinations that are refused ------------------------------------------------------------


@pytest.mark.parametrize(
    "target",
    [
        "127.0.0.1:8420",
        "localhost:8420",
        "[::1]:80",
        "[::ffff:127.0.0.1]:80",
        "[::127.0.0.1]:80",
        "[64:ff9b::7f00:1]:80",
        "10.0.0.5:80",
        "192.168.1.1:80",
        "169.254.169.254:80",
        "100.64.0.1:80",
        "0.0.0.0:80",
        "intranet.example:443",
        "mixed.example:443",
    ],
)
def test_a_tunnel_to_anything_that_is_not_public_is_refused_and_nothing_is_connected(
    tunnel: Upstream, target: str
) -> None:
    wire = Wire(
        tunnel,
        localhost=["127.0.0.1", "::1"],
        intranet_example=["10.0.0.7"],
        mixed_example=[PUBLIC, "127.0.0.1"],
    )
    with wire.proxy:
        reply = _send(wire.proxy, f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())

    assert _status(reply).startswith("HTTP/1.1 403")
    assert wire.aimed == []


@pytest.mark.parametrize("target", ["2130706433:80", "0x7f.1:80", "127.1:80"])
def test_other_spellings_of_loopback_are_refused_by_what_the_system_resolver_says(
    tunnel: Upstream, target: str
) -> None:
    """These are not names, so the real resolver answers without the network."""
    wire = Wire(tunnel)
    wire.proxy = FilteringProxy(connect=wire._connect)  # the real resolver
    with wire.proxy:
        reply = _send(wire.proxy, f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())

    assert _status(reply).startswith("HTTP/1.1 403") and wire.aimed == []


def test_a_name_that_does_not_resolve_or_cannot_be_encoded_is_refused(tunnel: Upstream) -> None:
    wire = Wire(tunnel)
    with wire.proxy:
        unknown = _send(wire.proxy, b"CONNECT nowhere.example:443 HTTP/1.1\r\n\r\n")
        broken = _send(wire.proxy, b"CONNECT a..b:443 HTTP/1.1\r\n\r\n")

    assert _status(unknown).startswith("HTTP/1.1 403") and _status(broken).startswith(
        "HTTP/1.1 403"
    )
    assert wire.aimed == []


# --- plain http -------------------------------------------------------------------------------


def test_a_plain_get_is_forwarded_in_origin_form_without_proxy_headers(upstream: Upstream) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    request = (
        b"GET http://example.org/a/b?c=d HTTP/1.1\r\nHost: example.org\r\n"
        b"Proxy-Connection: keep-alive\r\nProxy-Authorization: Basic eDp5\r\n"
        b"Connection: keep-alive\r\nAccept: text/html\r\n\r\n"
    )
    with wire.proxy:
        reply = _send(wire.proxy, request)

    [sent] = upstream.received
    assert sent.startswith(b"GET /a/b?c=d HTTP/1.1\r\n")
    assert b"Host: example.org" in sent and b"Accept: text/html" in sent
    assert b"Proxy-" not in sent and b"keep-alive" not in sent.lower()
    assert b"Connection: close" in sent
    assert reply.endswith(b"\r\n\r\nhi") and wire.aimed == [(PUBLIC, 80)]


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1:8420/cards",
        "http://localhost/",
        "http://[::1]/",
        "http://192.168.1.1/admin",
        "http://169.254.169.254/latest/meta-data/",
    ],
)
def test_a_plain_request_to_a_private_address_is_refused_and_nothing_is_connected(
    upstream: Upstream, url: str
) -> None:
    wire = Wire(upstream, localhost=["127.0.0.1"])
    with wire.proxy:
        reply = _send(wire.proxy, f"GET {url} HTTP/1.1\r\nHost: x\r\n\r\n".encode())

    assert _status(reply).startswith("HTTP/1.1 403")
    assert wire.aimed == [] and upstream.received == []


@pytest.mark.parametrize(
    ("raw", "status"),
    [
        (b"POST http://example.org/ HTTP/1.1\r\nContent-Length: 0\r\n\r\n", "405"),
        (b"PUT http://example.org/ HTTP/1.1\r\n\r\n", "405"),
        (b"GET /relative HTTP/1.1\r\nHost: example.org\r\n\r\n", "400"),
        (b"GET ftp://example.org/ HTTP/1.1\r\n\r\n", "400"),
        (b"GET http://user:pw@example.org/ HTTP/1.1\r\n\r\n", "400"),
        (b"GET http:///nohost HTTP/1.1\r\n\r\n", "400"),
        (b"CONNECT example.org HTTP/1.1\r\n\r\n", "400"),
        (b"CONNECT example.org:99999 HTTP/1.1\r\n\r\n", "400"),
        (b"CONNECT :443 HTTP/1.1\r\n\r\n", "400"),
    ],
)
def test_anything_but_a_readers_requests_is_refused_without_connecting(
    upstream: Upstream, raw: bytes, status: str
) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy:
        reply = _send(wire.proxy, raw)

    assert _status(reply).startswith(f"HTTP/1.1 {status}")
    assert wire.aimed == []


# --- hostile input and lifetime ---------------------------------------------------------------


def test_garbage_and_oversized_requests_are_dropped_and_the_proxy_keeps_serving(
    upstream: Upstream,
) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy:
        _send(wire.proxy, b"\x00\x01\x02 not http at all\r\n\r\n")
        _send(wire.proxy, b"GET http://example.org/" + b"a" * 40_000 + b" HTTP/1.1\r\n\r\n")
        _send(wire.proxy, b"")
        reply = _send(wire.proxy, b"GET http://example.org/ HTTP/1.1\r\nHost: example.org\r\n\r\n")

    assert reply.endswith(b"hi")


def test_a_client_that_never_finishes_its_request_is_let_go() -> None:
    proxy = FilteringProxy(timeout=0.3)
    with proxy, socket.create_connection(("127.0.0.1", proxy.port), timeout=5) as client:
        client.sendall(b"GET http://example.org/ HTTP/1.1\r\n")  # no blank line, ever
        started = time.monotonic()
        assert client.recv(4096) == b""  # the proxy hung up
        assert time.monotonic() - started < 3


def test_the_proxy_listens_on_loopback_only_and_stops_promptly_when_the_block_ends() -> None:
    proxy = FilteringProxy()
    left = 0.0
    with proxy:
        host, port = proxy.address
        assert host == "127.0.0.1" and proxy.url == f"http://127.0.0.1:{port}"
        socket.create_connection((host, port), timeout=2).close()
        left = time.monotonic()

    assert time.monotonic() - left < 1.0  # not the join timeout: the blocked accept was woken
    assert proxy._acceptor is not None and not proxy._acceptor.is_alive()
    with pytest.raises(OSError):
        socket.create_connection((host, port), timeout=2)


def test_two_proxies_get_two_ports() -> None:
    with FilteringProxy() as first, FilteringProxy() as second:
        assert first.port != second.port


# --- the address rule itself, and the protocol edges --------------------------------------------


def test_a_resolver_that_answers_nothing_or_fails_in_any_way_is_a_refusal(tunnel: Upstream) -> None:
    for resolver in (
        lambda host, port, **kw: [],
        lambda host, port, **kw: (_ for _ in ()).throw(UnicodeError("label empty or too long")),
        lambda host, port, **kw: (_ for _ in ()).throw(socket.gaierror("no such host")),
    ):
        wire = Wire(tunnel)
        wire.proxy = FilteringProxy(resolve=resolver, connect=wire._connect)
        with wire.proxy:
            reply = _send(wire.proxy, b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")

        assert _status(reply).startswith("HTTP/1.1 403") and wire.aimed == []


def test_the_real_resolver_refuses_a_name_that_cannot_be_encoded(tunnel: Upstream) -> None:
    wire = Wire(tunnel)
    wire.proxy = FilteringProxy(connect=wire._connect)
    with wire.proxy:
        reply = _send(wire.proxy, b"CONNECT a..b:443 HTTP/1.1\r\n\r\n")

    assert _status(reply).startswith("HTTP/1.1 403") and wire.aimed == []


def test_an_ipv6_literal_in_brackets_is_understood(tunnel: Upstream) -> None:
    wire = Wire(tunnel)
    with wire.proxy:
        reply = _send(
            wire.proxy, b"CONNECT [2606:2800:220:1:248:1893:25c8:1946]:443 HTTP/1.1\r\n\r\n"
        )

    assert _status(reply).startswith("HTTP/1.1 200")
    assert wire.aimed == [("2606:2800:220:1:248:1893:25c8:1946", 443)]


def test_a_request_head_that_never_ends_is_answered_at_the_size_limit(upstream: Upstream) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy, socket.create_connection(("127.0.0.1", wire.proxy.port), timeout=2) as client:
        client.sendall(b"GET http://example.org/" + b"a" * 40_000)  # no blank line, no end
        try:
            reply = client.recv(4096)  # a timeout here means the proxy kept waiting for more
        except ConnectionResetError:  # it answered and hung up while we were still sending
            reply = b"HTTP/1.1 400 (reset)"

    assert reply.startswith(b"HTTP/1.1 400") and wire.aimed == []


def test_a_request_cut_short_is_not_forwarded(upstream: Upstream) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy:
        _send(wire.proxy, b"GET http://example.org/ HTTP/1.1\r\nHost: example.org\r\n")  # then EOF

    assert wire.aimed == [] and upstream.received == []


def test_bytes_sent_right_behind_the_connect_line_are_not_lost(tunnel: Upstream) -> None:
    wire = Wire(tunnel, example_org=[PUBLIC])
    with wire.proxy:
        reply = _send(wire.proxy, b"CONNECT example.org:443 HTTP/1.1\r\n\r\nclient-hello")

    assert reply.endswith(b"client-hello")  # echoed back by the tunnel's far end


def test_a_client_that_has_said_everything_still_gets_the_whole_tunnel_answer(
    tunnel: Upstream,
) -> None:
    """Half-close: the far end is told the client is done, answers, and hangs up - so the client
    sees the end of the stream instead of waiting for an idle timeout."""
    wire = Wire(tunnel, example_org=[PUBLIC])
    with wire.proxy, socket.create_connection(("127.0.0.1", wire.proxy.port), timeout=2) as client:
        client.sendall(b"CONNECT example.org:443 HTTP/1.1\r\n\r\nping")
        client.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := client.recv(4096):  # a timeout here means the half-close was not passed on
            data += chunk

    assert data.endswith(b"ping")


def test_an_idle_tunnel_is_closed(tunnel: Upstream) -> None:
    wire = Wire(tunnel, example_org=[PUBLIC])
    wire.proxy = FilteringProxy(
        resolve=_dns(example_org=[PUBLIC]), connect=wire._connect, timeout=0.3
    )
    with wire.proxy, socket.create_connection(("127.0.0.1", wire.proxy.port), timeout=3) as client:
        client.sendall(b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")
        data = b""
        while chunk := client.recv(4096):  # nothing more is sent; the proxy must hang up by itself
            data += chunk

    assert data.startswith(b"HTTP/1.1 200")


# --- found by the second security review -----------------------------------------------------


def test_the_default_rule_also_refuses_a_public_looking_address_that_is_this_machines_own(
    monkeypatch: pytest.MonkeyPatch, tunnel: Upstream
) -> None:
    monkeypatch.setattr(webguard, "is_local_address", lambda address: address == PUBLIC)
    wire = Wire(tunnel)
    wire.proxy = FilteringProxy(resolve=_dns(example_org=[PUBLIC]), connect=wire._connect)
    with wire.proxy:
        reply = _send(wire.proxy, b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")

    assert _status(reply).startswith("HTTP/1.1 403") and wire.aimed == []


@pytest.mark.parametrize(
    "raw",
    [
        b"GET http://example.org/ HTTP/1.1\r\nHost: x\nX-A: b\r\n\r\n",  # a bare LF
        b"GET http://example.org/ HTTP/1.1\r\nHost: x\rX-A: b\r\n\r\n",  # a bare CR
        b"GET http://example.org/ HTTP/1.1\r\nHost: x\x00\r\n\r\n",  # a NUL
    ],
    ids=["bare-lf", "bare-cr", "nul"],
)
def test_a_header_with_a_stray_line_break_or_nul_is_refused_not_passed_on(
    upstream: Upstream, raw: bytes
) -> None:
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy:
        reply = _send(wire.proxy, raw)

    assert _status(reply).startswith("HTTP/1.1 400")
    assert wire.aimed == [] and upstream.received == []


def test_a_request_head_trickled_in_is_cut_off_at_a_total_deadline() -> None:
    """One byte at a time, each inside the idle limit, used to keep a connection open for good."""
    proxy = FilteringProxy(timeout=0.6)
    closed_after = None
    with proxy, socket.create_connection(("127.0.0.1", proxy.port), timeout=5) as client:
        started = time.monotonic()
        for byte in b"GET http://example.org/ HTTP/1.1\r\nHost: x" * 3:
            try:
                client.sendall(bytes([byte]))
                if select.select([client], [], [], 0.15)[0] and client.recv(1) == b"":
                    closed_after = time.monotonic() - started
                    break
            except OSError:
                closed_after = time.monotonic() - started
                break

    assert closed_after is not None and closed_after < 2.5


def test_the_number_of_open_connections_is_capped_and_a_closed_one_frees_its_place() -> None:
    with FilteringProxy(max_connections=2) as proxy:
        first = socket.create_connection(("127.0.0.1", proxy.port), timeout=2)
        second = socket.create_connection(("127.0.0.1", proxy.port), timeout=2)
        time.sleep(0.2)
        with socket.create_connection(("127.0.0.1", proxy.port), timeout=2) as third:
            assert third.recv(4096) == b""  # turned away at once

        first.close()
        second.close()
        time.sleep(0.3)
        reply = _send(proxy, b"GET /not-a-proxy-request HTTP/1.1\r\n\r\n")

    assert _status(reply).startswith("HTTP/1.1 400")  # served again


def test_leaving_the_block_cuts_the_connections_still_open(tunnel: Upstream) -> None:
    """A tab that was given up on must not keep its network after the lookup is over."""
    wire = Wire(tunnel, example_org=[PUBLIC])
    with wire.proxy:
        client = socket.create_connection(("127.0.0.1", wire.proxy.port), timeout=3)
        client.sendall(b"CONNECT example.org:443 HTTP/1.1\r\n\r\n")
        assert client.recv(4096).startswith(b"HTTP/1.1 200")

    try:
        assert client.recv(4096) == b""
    except ConnectionResetError:
        pass
    finally:
        client.close()


def test_an_error_while_accepting_does_not_end_the_proxy(
    monkeypatch: pytest.MonkeyPatch, upstream: Upstream
) -> None:
    """Out of file descriptors is an `OSError` too, and it passes: the acceptor used to give up."""
    real = socket.create_server

    class FlakyOnce:
        def __init__(self, inner: socket.socket) -> None:
            self.inner, self.failed = inner, False

        def accept(self) -> tuple[socket.socket, object]:
            if not self.failed:
                self.failed = True
                raise OSError(errno.EMFILE, "Too many open files")
            return self.inner.accept()

        def __getattr__(self, name: str) -> object:
            return getattr(self.inner, name)

    monkeypatch.setattr(webguard.socket, "create_server", lambda *a, **k: FlakyOnce(real(*a, **k)))
    wire = Wire(upstream, example_org=[PUBLIC])
    with wire.proxy:
        reply = _send(wire.proxy, b"GET http://example.org/ HTTP/1.1\r\nHost: example.org\r\n\r\n")

    assert reply.endswith(b"hi")


def test_the_relay_copes_with_file_descriptors_beyond_what_select_can_hold() -> None:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if hard != resource.RLIM_INFINITY and hard < 4096:
        pytest.skip("the file descriptor limit cannot be raised enough")
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 4096), hard))
    try:
        near_a, far_a = socket.socketpair()
        far_b, near_b = socket.socketpair()
        a = socket.socket(fileno=os.dup2(far_a.fileno(), 1500))
        b = socket.socket(fileno=os.dup2(far_b.fileno(), 1501))
        relay = threading.Thread(target=webguard._relay, args=(a, b, 3), daemon=True)
        relay.start()
        near_b.settimeout(2)
        near_a.sendall(b"hello")

        assert near_b.recv(5) == b"hello"
        near_a.close()
        near_b.close()  # both ends done: the relay ends
        relay.join(3)
        assert not relay.is_alive()
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))


def test_reading_a_head_leaves_the_socket_with_its_idle_limit_again() -> None:
    """The head is read against a shrinking deadline; the relay must not inherit what was left."""
    near, far = socket.socketpair()
    with near, far:
        far.sendall(b"GET http://example.org/ HTTP/1.1\r\nHost: x\r\n\r\nleftover")

        head, rest = webguard._read_head(near, 7.5)

        assert near.gettimeout() == 7.5
        assert head.startswith(b"GET ") and rest == b"leftover"
