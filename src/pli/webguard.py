"""Keeping a throwaway browser on the public internet.

A web page is written by a stranger and the browser runs on a computer that also holds your mail
and sits on your network. Whatever a page, a redirect or a search result points at, the browser
must only ever reach public addresses - not `localhost` (this agent's own helper services among
them), not a router, not another computer on your network.

Telling the browser which addresses to avoid does not work: Chromium follows an HTTP redirect
inside its own network stack, so `302 Location: http://127.0.0.1:8420/` from a public page sends
the request before any hook of ours runs (measured: a local server received the GET). So every
connection the browser makes goes through `FilteringProxy`, which sees every hop.

**The address that is checked is the address that is connected to.** The proxy resolves the name
itself, refuses unless EVERY answer is a public address, then connects to that address - not to
the name - so the name cannot resolve to something else a moment later (DNS rebinding).

**Only a reader's requests are served:** `CONNECT` (HTTPS, and anything else tunnelled) and plain
`GET`/`HEAD` of an `http://` address. A refusal is an answer, never a crash.

`public_url` is the same rule applied to an address before a browser is even started, so a typed
`http://localhost:8420` or a poisoned search hit is turned away without launching anything.
"""

from __future__ import annotations

import contextlib
import ipaddress
import re
import selectors
import socket
import threading
import time
from collections.abc import Callable, Iterator
from types import TracebackType
from urllib.parse import urlsplit

__all__ = ["FilteringProxy", "is_local_address", "is_public_address", "public_url"]

#: Longest address `public_url` considers.
MAX_URL = 2_048
#: Longest request head (request line and headers) the proxy reads. Chromium's are far smaller.
HEAD_MAX = 16_384
#: A connection idle this long is dropped, on either side.
IDLE_SECONDS = 30
#: Longest the proxy waits to connect to a destination.
CONNECT_SECONDS = 10
#: Connections served at once; more are closed on arrival. One lookup is three browsers.
MAX_CONNECTIONS = 64

#: IPv6 ranges that are not public, or that carry an IPv4 address inside them (`::127.0.0.1`,
#: `64:ff9b::7f00:1`, `::ffff:0:7f00:1`, `::5efe:a00:1`): `ipaddress` calls most of them global, and
#: a router may deliver them to the IPv4 address inside. The whole of `::/8` goes, except the
#: IPv4-mapped form, which is judged as the IPv4 address it wraps. Site-local `fec0::/10` is
#: deprecated private space.
_NOT_PUBLIC_V6 = (ipaddress.ip_network("::/8"), ipaddress.ip_network("fec0::/10"))
#: A stray CR, LF or NUL inside a request head: not HTTP, and passed on it would split a header.
_BAD_HEAD = re.compile(rb"\x00|\r(?!\n)|(?<!\r)\n")
#: Headers that describe the hop to the proxy, not the request. Dropped when forwarding.
_HOP_HEADERS = {b"proxy-connection", b"proxy-authorization", b"connection", b"keep-alive"}


def is_public_address(address: str) -> bool:
    """True for an IP address on the public internet: not private, loopback, link-local,
    carrier-grade NAT, multicast, reserved, or an IPv6 form wrapping an IPv4 address."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.version == 6:
        if ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        elif any(ip in net for net in _NOT_PUBLIC_V6):
            return False
    return ip.is_global and not ip.is_multicast


def is_local_address(address: str) -> bool:
    """True when `address` is one of this computer's own (it can be bound to): anything listening
    on all of its interfaces would answer on it, public or not."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    family = socket.AF_INET6 if ip.version == 6 else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as probe:
        try:
            probe.bind((address, 0))
        except OSError:
            return False
    return True


def _allowed(address: str) -> bool:
    return is_public_address(address) and not is_local_address(address)


def public_url(url: str, resolve: Callable[..., list] = socket.getaddrinfo) -> bool:
    """True only for an `http(s)` address without a password whose name resolves to public
    addresses alone. A name that does not resolve, or cannot be encoded, is refused."""
    if not url or len(url) > MAX_URL or any(ch.isspace() or not ch.isprintable() for ch in url):
        return False
    try:
        parts = urlsplit(url)
        host = parts.hostname
        parts.port  # noqa: B018 - raises ValueError for a port that is not a number in range
    except ValueError:
        return False
    if parts.scheme.lower() not in ("http", "https") or not host or "@" in parts.netloc:
        return False
    try:
        infos = resolve(host, None)
    except (OSError, ValueError):  # not found, or a name that cannot be encoded (`a..b`)
        return False
    addresses = {str(info[4][0]) for info in infos}
    return bool(addresses) and all(is_public_address(a) for a in addresses)


def host_resolves(url: str, resolve: Callable[..., list] = socket.getaddrinfo) -> bool:
    """False when `url` names a host that does not exist: no address at all, public or private.

    A typo and a made-up name fail `public_url` like a router does, and "is not a public website"
    told the student they had reached for a private computer. A line with no name in it makes no
    claim (True): the caller's other message stands."""
    try:
        host = urlsplit(url).hostname
    except ValueError:
        return True
    if not host:
        return True
    try:
        return bool(resolve(host, None))
    except (OSError, ValueError):  # not found, or a name that cannot be encoded (`a..b`)
        return False


def _connect(address: str, port: int, timeout: float) -> socket.socket:
    return socket.create_connection((address, port), timeout)


class FilteringProxy:
    """A forward proxy on 127.0.0.1 that connects only to public addresses.

    Use as a context manager; hand `url` to the browser as its proxy. `resolve`, `connect` and
    `allow` are the name lookup, the outgoing connection and the rule for an address (replaced in
    tests, so that a local server can stand in for "the public internet").
    """

    def __init__(
        self,
        *,
        resolve: Callable[..., list] = socket.getaddrinfo,
        connect: Callable[[str, int, float], socket.socket] = _connect,
        allow: Callable[[str], bool] = _allowed,
        timeout: float = IDLE_SECONDS,
        max_connections: int = MAX_CONNECTIONS,
    ) -> None:
        self._resolve, self._connect, self._allow = resolve, connect, allow
        self._timeout = timeout
        self._slots = threading.BoundedSemaphore(max_connections)
        self._live: set[socket.socket] = set()
        self._live_lock = threading.Lock()
        self._server: socket.socket | None = None
        self._acceptor: threading.Thread | None = None

    def __enter__(self) -> FilteringProxy:
        self._server = socket.create_server(("127.0.0.1", 0))
        self._acceptor = threading.Thread(target=self._accept, daemon=True)
        self._acceptor.start()
        return self

    def __exit__(
        self,
        kind: type[BaseException] | None,
        error: BaseException | None,
        trace: TracebackType | None,
    ) -> None:
        server, self._server = self._server, None
        if server is not None:
            with contextlib.suppress(OSError):
                server.shutdown(socket.SHUT_RDWR)  # wakes the thread blocked in accept()
            server.close()
        if self._acceptor is not None:
            self._acceptor.join(timeout=2)
        with self._live_lock:
            leftover = list(self._live)
        for connection in leftover:  # a tab given up on must not keep its network
            with contextlib.suppress(OSError):
                connection.shutdown(socket.SHUT_RDWR)

    @property
    def address(self) -> tuple[str, int]:
        assert self._server is not None, "the proxy is not running"
        host, port = self._server.getsockname()[:2]
        return host, port

    @property
    def port(self) -> int:
        return self.address[1]

    @property
    def url(self) -> str:
        host, port = self.address
        return f"http://{host}:{port}"

    # --- serving --------------------------------------------------------------------------

    def _accept(self) -> None:
        while (server := self._server) is not None:
            try:
                client, _ = server.accept()
            except OSError:
                if self._server is None:  # the listening socket was closed
                    return
                time.sleep(0.05)  # out of file descriptors, say: wait for some, do not give up
                continue
            if not self._slots.acquire(blocking=False):
                client.close()
                continue
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    @contextlib.contextmanager
    def _held(self, connection: socket.socket) -> Iterator[socket.socket]:
        """`connection` for the length of the block: known to the proxy, closed at the end."""
        with self._live_lock:
            self._live.add(connection)
        try:
            with connection:
                yield connection
        finally:
            with self._live_lock:
                self._live.discard(connection)

    def _serve(self, client: socket.socket) -> None:
        try:
            with self._held(client):
                self._handle(client)
        finally:
            self._slots.release()

    def _handle(self, client: socket.socket) -> None:
        try:
            try:
                head, rest = _read_head(client, self._timeout)
                method, target = _request_line(head)
            except (ValueError, UnicodeError):
                return _refuse(client, 400)
            if method == "CONNECT":
                self._tunnel(client, target, rest)
            elif method in ("GET", "HEAD"):
                self._forward(client, method, target, head)
            else:
                _refuse(client, 405)
        except OSError:
            return  # the client went away, or the destination did

    def _tunnel(self, client: socket.socket, target: str, rest: bytes) -> None:
        try:
            host, port = _host_port(target)
        except ValueError:
            return _refuse(client, 400)
        upstream = self._open(host, port)
        if upstream is None:
            return _refuse(client, 403)
        with self._held(upstream):
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if rest:
                upstream.sendall(rest)
            _relay(client, upstream, self._timeout)

    def _forward(self, client: socket.socket, method: str, target: str, head: bytes) -> None:
        try:
            parts = urlsplit(target)
            port = parts.port or 80
            host = parts.hostname
        except ValueError:
            return _refuse(client, 400)
        if parts.scheme != "http" or not host or "@" in parts.netloc:
            return _refuse(client, 400)
        upstream = self._open(host, port)
        if upstream is None:
            return _refuse(client, 403)
        path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        headers = [
            line
            for line in head.split(b"\r\n")[1:]
            if line.split(b":", 1)[0].strip().lower() not in _HOP_HEADERS
        ]
        request = f"{method} {path} HTTP/1.1\r\n".encode("ascii", "replace")
        request += b"".join(line + b"\r\n" for line in headers) + b"Connection: close\r\n\r\n"
        with self._held(upstream):
            upstream.sendall(request)
            _relay(client, upstream, self._timeout)

    def _open(self, host: str, port: int) -> socket.socket | None:
        """A connection to `host`, or None: unless every address it resolves to is public."""
        try:
            infos = self._resolve(host, port, type=socket.SOCK_STREAM)
            addresses = list(dict.fromkeys(str(info[4][0]) for info in infos))
        except (OSError, ValueError):
            return None
        if not all(self._allow(a) for a in addresses):
            return None
        for address in addresses:
            with contextlib.suppress(OSError):
                return self._connect(address, port, CONNECT_SECONDS)
        return None


def _read_head(client: socket.socket, seconds: float) -> tuple[bytes, bytes]:
    """The request head (without the blank line) and any bytes that arrived after it.

    The whole head has `seconds` to arrive, not each piece of it: one byte at a time, each inside
    the idle limit, would otherwise hold a connection open for good. The socket is left with
    `seconds` as its idle limit again.
    """
    end = time.monotonic() + seconds
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > HEAD_MAX:
            raise ValueError("request head too long")
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("request head too slow")
        client.settimeout(remaining)
        chunk = client.recv(4096)
        if not chunk:
            raise ValueError("connection closed before the request was complete")
        data += chunk
    client.settimeout(seconds)
    head, _, rest = data.partition(b"\r\n\r\n")
    if _BAD_HEAD.search(head):
        raise ValueError("a stray CR, LF or NUL in the request head")
    return head, rest


def _request_line(head: bytes) -> tuple[str, str]:
    method, target, _version = head.split(b"\r\n", 1)[0].decode("ascii").split(" ", 2)
    return method, target


def _host_port(target: str) -> tuple[str, int]:
    """`example.org:443` or `[::1]:443` as (host, port); ValueError for anything else."""
    host, _, port = target.rpartition(":")
    host = host.removeprefix("[").removesuffix("]")
    if not host or not port.isdigit() or not 0 < int(port) < 65536:
        raise ValueError(f"not a host:port: {target!r}")
    return host, int(port)


_REASONS = {400: "Bad Request", 403: "Forbidden", 405: "Method Not Allowed"}


def _refuse(client: socket.socket, status: int) -> None:
    line = f"HTTP/1.1 {status} {_REASONS[status]}"
    client.sendall(f"{line}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())


def _relay(a: socket.socket, b: socket.socket, idle: float) -> None:
    """Copy bytes both ways until both sides are done or nothing moves for `idle` seconds.

    A side that has finished sending is passed on as a half-close, and the other direction keeps
    going: a client may send its whole request and then wait for the reply. (A selector, not
    `select.select`, which fails for a descriptor numbered 1024 or more.)
    """
    with selectors.DefaultSelector() as selector:
        selector.register(a, selectors.EVENT_READ)
        selector.register(b, selectors.EVENT_READ)
        while selector.get_map():
            events = selector.select(idle)
            if not events:
                return
            for key, _ in events:
                source = key.fileobj
                target = b if source is a else a
                data = source.recv(65536)
                if data:
                    target.sendall(data)
                else:
                    selector.unregister(source)
                    with contextlib.suppress(OSError):
                        target.shutdown(socket.SHUT_WR)
