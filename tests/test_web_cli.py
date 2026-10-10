"""`pli agent` gets a web lookup, which starts nothing until a question needs it.

The command hands the loop a callable; the browser is only started when that callable is
used, so opening the agent, asking about mail, or asking a general question never launches
Chromium. `WEB_ENABLED=false` removes the lookup altogether.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from pli import cli
from pli import web as web_module
from pli.config import Settings
from pli.web import WebPage


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(_env_file=None, pli_home=tmp_path / "data", typesafe_api_key="", llm_api_key="")


def _agent_kwargs(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> dict[str, Any]:
    import pli.agent.repl as repl

    seen: dict[str, Any] = {}
    monkeypatch.setattr(cli, "_settings", lambda: settings)
    monkeypatch.setattr(repl, "run", lambda *a, **k: seen.update(k))
    result = CliRunner().invoke(cli.app, ["agent"], input="quit\n")
    assert result.exit_code == 0, result.output
    return seen


def test_web_lookups_are_on_by_default_and_a_setting_turns_them_off(settings: Settings) -> None:
    assert settings.web_enabled is True
    assert Settings(_env_file=None, web_enabled=False).web_enabled is False


def test_the_agent_is_given_a_web_lookup_and_no_browser_is_created_until_it_is_used(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    created: list[int] = []

    class Reader:
        def __init__(self) -> None:
            created.append(1)

        def read_all(self, urls: list[str]) -> list[None]:
            return [None for _ in urls]

    class Client:
        def __init__(self, given: Settings) -> None:
            pass

        def web_search(self, query: str) -> list[object]:
            return []

    monkeypatch.setattr(web_module, "ChromiumReader", Reader)
    monkeypatch.setattr(web_module, "LLMClient", Client)

    kwargs = _agent_kwargs(monkeypatch, settings)

    assert callable(kwargs["web"]) and created == []  # starting the agent opened nothing
    assert kwargs["web"]("hanoi weather") == [] and created == [1]  # the question did


def test_using_the_lookup_reads_pages_with_these_settings(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    calls: list[tuple[Settings, str]] = []
    page = WebPage("https://example.org/", "Example", "text")

    def fake_lookup(given: Settings, target: str) -> list[WebPage]:
        calls.append((given, target))
        return [page]

    monkeypatch.setattr(web_module, "lookup_web", fake_lookup)

    kwargs = _agent_kwargs(monkeypatch, settings)
    pages = kwargs["web"]("hanoi weather")

    assert pages == [page]
    assert calls == [(settings, "hanoi weather")]


def test_with_web_lookups_turned_off_the_agent_gets_none(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    off = settings.model_copy(update={"web_enabled": False})

    assert _agent_kwargs(monkeypatch, off)["web"] is None


def test_the_agent_is_also_given_a_way_to_type_into_a_search_box_that_opens_nothing_until_used(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    created: list[int] = []
    typed: list[tuple[str, int, str, str]] = []

    class Reader:
        def __init__(self) -> None:
            created.append(1)

        def search_site(self, url: str, box: int, label: str, text: str) -> WebPage:
            typed.append((url, box, label, text))
            return WebPage("https://example.org/results", "Results", "text")

    monkeypatch.setattr(web_module, "ChromiumReader", Reader)
    monkeypatch.setattr(web_module, "public_url", lambda url: True)

    kwargs = _agent_kwargs(monkeypatch, settings)

    assert callable(kwargs["site_search"]) and created == []
    pages = kwargs["site_search"]("https://example.org/", 0, "Search", "hello")
    assert [p.url for p in pages] == ["https://example.org/results"] and created == [1]
    assert typed == [("https://example.org/", 0, "Search", "hello")]


def test_with_web_lookups_turned_off_the_agent_cannot_type_either(
    monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    off = settings.model_copy(update={"web_enabled": False})

    assert _agent_kwargs(monkeypatch, off)["site_search"] is None


def test_an_address_that_is_not_public_is_refused_before_anything_is_typed() -> None:
    with pytest.raises(web_module.WebError, match="not a public website"):
        web_module.site_search("http://127.0.0.1:8420/", 0, "Search", "hello")


def test_an_address_that_does_not_exist_is_said_not_to_exist_before_anything_is_typed() -> None:
    with pytest.raises(web_module.WebError, match="could not find a website at gone.example"):
        web_module.site_search(
            "http://gone.example/",
            0,
            "Search",
            "hello",
            is_public=lambda url: False,
            resolves=lambda url: False,
        )


def test_a_public_address_is_not_asked_whether_it_exists_when_typing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Reader:
        def search_site(self, url: str, box: int, label: str, text: str) -> None:
            return None

    monkeypatch.setattr(web_module, "ChromiumReader", Reader)

    pages = web_module.site_search(
        "https://stub-public.invalid/",  # only the injected rule can make this one "public"
        0,
        "Search",
        "hello",
        is_public=lambda url: True,
        resolves=lambda url: pytest.fail("asked whether a public address exists"),
    )

    assert pages == []
