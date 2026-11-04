"""Every test runs in a throwaway HOME with no keys in the environment, so nothing can read or
write the real ~/.local/share/robo, ~/.hermes or the user's keys."""

import pytest


@pytest.fixture(autouse=True)
def throwaway_home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for name in ("ANTHROPIC_API_KEY", "SUPERMEMORY_API_KEY", "ROBO_SERVER_KEY"):
        monkeypatch.delenv(name, raising=False)
    return home
