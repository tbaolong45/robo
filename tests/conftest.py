"""No test may touch the real ~/Robo, the real Obsidian vault or Obsidian's own settings, or open
a real file or app. A test that wants to see something opened patches the opener itself. The
bubble's theme file is a temporary one that turns typing off, so a reply shows at once (a test of
the typing writes its own speed into `theme.CONFIG`)."""

import sys

import pytest

from robo import theme, vault


@pytest.fixture(autouse=True)
def _nothing_real_is_touched(tmp_path_factory, monkeypatch):
    here = tmp_path_factory.mktemp("guard")  # not tmp_path: tests list that folder
    tried = []

    def refuse(*args, **kwargs):
        # Qt prints an exception raised in a slot and carries on, so also fail at teardown.
        tried.append((args, kwargs))
        raise AssertionError(f"a test tried to open something for real: {args} {kwargs}")

    monkeypatch.setattr(vault, "VAULT", here / "Documents" / "Robo")
    monkeypatch.setattr(vault, "obsidian_config", lambda: here / "obsidian" / "obsidian.json")
    monkeypatch.setattr(vault, "_spawn", refuse)
    monkeypatch.setattr(theme, "CONFIG", here / "config" / "robo" / "theme.json")
    theme.CONFIG.parent.mkdir(parents=True)
    theme.CONFIG.write_text('{"tokens": {"cps": 0}}')  # instant typing: exactly the old bubble
    # robo.app pulls in Qt, so only guard it when a test module already imported it.
    app = sys.modules.get("robo.app")
    if app:
        monkeypatch.setattr(app, "OUTPUT_DIR", here / "Robo")
        monkeypatch.setattr(app, "VAULT", here / "Documents" / "Robo")
        monkeypatch.setattr(app, "open_file", refuse)
        monkeypatch.setattr(app, "open_note", refuse)
        monkeypatch.setattr(app, "HealthPoller", refuse)  # no GET to the real gateway
    yield
    assert not tried, f"a test opened something for real: {tried}"
