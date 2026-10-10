"""Which addresses may be opened: only the public internet.

A typed address, a search result and a redirect can all point at `localhost`, a router, another
computer on the network or a cloud metadata address. `public_url` turns those away before a
browser is even started (the proxy applies the same rule to every connection the browser makes,
see `test_webguard_proxy.py`).

**A name is judged by what it resolves to, not by how it is spelled:** `2130706433` is
127.0.0.1, and a name with one private answer among its public ones is private. Only `http` and
`https` addresses without a password in them count, and a name that cannot be looked up, or cannot
even be encoded, is refused rather than raising.

The name resolver is a table, so nothing here touches the network.
"""

from __future__ import annotations

import ipaddress
import socket

import pytest

from pli.webguard import host_resolves, is_local_address, is_public_address, public_url

PUBLIC = "93.184.216.34"


def _dns(**hosts: list[str]):
    """A resolver that knows exactly these names (`example_com` stands for `example.com`).

    An address typed as digits resolves to itself, as it does for the real resolver: without
    that, every numeric case below would be refused for being unknown, not for being private.
    """
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
            (socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, 0))
            for a in addrs
        ]

    return resolve


# --- which addresses may be opened ------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com/",
        "https://example.com/a/b?c=d#e",
        "HTTPS://Example.com:8443/x",
        "https://news.example.com",
    ],
)
def test_a_public_website_may_be_opened(url: str) -> None:
    resolve = _dns(example_com=[PUBLIC], news_example_com=["2606:2800:220:1:248:1893:25c8:1946"])

    assert public_url(url, resolve) is True


@pytest.mark.parametrize(
    "url",
    [
        "ftp://example.com/",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,hi",
        "about:blank",
        "chrome://settings",
        "",
        "example.com",
        "//example.com/",
        "http://",
        "http://user:secret@example.com/",
        "http://example.com:99999/",
        " http://example.com/",
        "http://example.com/a b",
        "http://example.com/\x1b[2J",
        "http://example.com/" + "a" * 2100,
    ],
)
def test_anything_that_is_not_a_plain_web_address_is_refused(url: str) -> None:
    assert public_url(url, _dns(example_com=[PUBLIC])) is False


@pytest.mark.parametrize(
    "url",
    [
        "http://localhost/",
        "http://127.0.0.1:8420/cards",
        "http://[::1]/",
        "http://10.0.0.5/",
        "http://172.16.4.2/",
        "http://192.168.1.1/admin",
        "http://169.254.169.254/latest/meta-data/",
        "http://100.64.0.1/",
        "http://0.0.0.0/",
        "http://224.0.0.1/",
        "http://[::ffff:127.0.0.1]/",
        "http://[fe80::1]/",
        "http://[fc00::1]/",
    ],
)
def test_an_address_on_this_machine_or_its_network_is_never_opened(url: str) -> None:
    assert public_url(url, _dns(localhost=["127.0.0.1"])) is False


@pytest.mark.parametrize("url", ["http://2130706433/", "http://0x7f.1/", "http://127.1/"])
def test_other_spellings_of_the_loopback_address_are_refused_too(url: str) -> None:
    """These are not names, so the real resolver answers without the network."""
    assert public_url(url) is False


def test_a_numeric_public_address_is_fine_without_any_lookup() -> None:
    assert public_url(f"http://{PUBLIC}/") is True


def test_a_name_is_judged_by_where_it_points_not_by_how_it_looks() -> None:
    resolve = _dns(intranet_example=["10.0.0.7"], mixed_example=[PUBLIC, "127.0.0.1"])

    assert public_url("http://intranet.example/", resolve) is False
    assert public_url("http://mixed.example/", resolve) is False  # one private answer is enough


def test_a_name_that_does_not_resolve_is_refused() -> None:
    assert public_url("http://nowhere.example/", _dns()) is False


def test_a_resolver_that_answers_nothing_is_not_a_yes() -> None:
    assert public_url("http://example.com/", lambda host, port: []) is False


def test_a_scoped_link_local_answer_is_still_private() -> None:
    def resolve(host: str, port: object) -> list[tuple]:
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("fe80::1%eth0", 0, 0, 2))]

    assert public_url("http://printer.example/", resolve) is False


@pytest.mark.parametrize(
    "url", ["http://a..b/", "http://" + "a" * 64 + ".com/", "http://.example/"]
)
def test_a_name_that_cannot_be_encoded_is_refused_not_an_exception(url: str) -> None:
    """The real resolver raises UnicodeError for these; one poisoned search hit used to abort the
    whole lookup."""
    assert public_url(url) is False


@pytest.mark.parametrize(
    "url", ["http://[::127.0.0.1]/", "http://[::7f00:1]/", "http://[64:ff9b::7f00:1]/"]
)
def test_an_ipv6_form_that_wraps_an_ipv4_address_is_not_public(url: str) -> None:
    """`ipaddress` calls these global; a router may deliver them to the IPv4 address inside."""
    assert public_url(url) is False


@pytest.mark.parametrize("address", [PUBLIC, "8.8.8.8", "2606:2800:220:1:248:1893:25c8:1946"])
def test_a_public_address_is_public(address: str) -> None:
    assert is_public_address(address) is True


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "::1",
        "10.0.0.5",
        "172.16.4.2",
        "192.168.1.1",
        "169.254.169.254",
        "100.64.0.1",
        "0.0.0.0",
        "::",
        "224.0.0.1",  # multicast, which `ipaddress` calls global
        "239.255.255.250",
        "ff02::1",
        "ff0e::1",
        "fe80::1",
        "fe80::1%eth0",
        "fc00::1",
        "::ffff:127.0.0.1",
        "::ffff:10.0.0.1",
        "::127.0.0.1",  # IPv4 inside an IPv6 form that `ipaddress` calls global
        "64:ff9b::7f00:1",
        "::ffff:0:7f00:1",  # IPv4-translated: the IPv4 address is inside again
        "::5efe:a00:1",  # ISATAP
        "::1:7f00:1",
        "fec0::1",  # deprecated site-local
        "not an address",
        "",
    ],
)
def test_everything_else_is_not_public(address: str) -> None:
    assert is_public_address(address) is False


def test_a_mapped_address_is_judged_as_the_ipv4_address_inside() -> None:
    assert is_public_address("::ffff:93.184.216.34") is True
    assert is_public_address("::ffff:192.168.0.1") is False


def test_an_address_that_belongs_to_this_machine_is_recognised_and_other_ones_are_not() -> None:
    """A public address can still be this computer's own (a server with a global IP), and
    anything listening on all its interfaces would answer on it."""
    assert is_local_address("127.0.0.1") is True
    assert is_local_address("93.184.216.34") is False
    assert is_local_address("not an address") is False


# --- does the name exist at all ----------------------------------------------------------------
# A typo, an expired domain and a made-up name all fail `public_url`, and "is not a public website"
# told the student they had reached for a private computer. Found by asking for two addresses that
# do not exist: both got that message.


def test_a_name_that_resolves_exists_whether_or_not_it_is_public() -> None:
    dns = _dns(example_com=[PUBLIC], intranet_example=["10.0.0.5"])

    assert host_resolves("http://example.com/", dns) is True
    assert host_resolves("http://intranet.example/", dns) is True


def test_a_name_that_does_not_resolve_does_not_exist() -> None:
    assert host_resolves("http://nowhere.example/", _dns()) is False


@pytest.mark.parametrize("url", ["http://127.0.0.1:8080/", "http://192.168.1.1/", "http://[::1]/"])
def test_an_address_typed_as_digits_exists(url: str) -> None:
    assert host_resolves(url, _dns()) is True


@pytest.mark.parametrize("error", [socket.gaierror("x"), OSError("x"), ValueError("a..b")])
def test_any_failure_to_look_the_name_up_means_it_does_not_exist(error: Exception) -> None:
    def resolve(host: str, port: object) -> list[tuple]:
        raise error

    assert host_resolves("http://example.com/", resolve) is False


@pytest.mark.parametrize("url", ["", "not a url", "http://", "http://[bad/", "ftp:///x"])
def test_a_line_with_no_usable_name_is_no_claim_either_way(url: str) -> None:
    """Nothing to say about a name that is not there to look up: the caller's other message
    ("not a public website") stands."""
    assert host_resolves(url, _dns()) is True


def test_the_name_is_looked_up_without_a_port() -> None:
    seen: list[tuple] = []

    def resolve(host: str, port: object) -> list[tuple]:
        seen.append((host, port))
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC, 0))]

    host_resolves("https://Example.com:8443/x", resolve)

    assert seen == [("example.com", None)]


def test_a_resolver_that_answers_nothing_means_the_name_does_not_exist() -> None:
    assert host_resolves("http://example.com/", lambda host, port: []) is False
