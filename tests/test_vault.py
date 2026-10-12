import json
import subprocess
from pathlib import Path
from urllib.parse import unquote

import pytest

from robo import vault

# conftest repoints these three on the module in every test; these are the real ones
from robo.vault import VAULT as REAL_VAULT
from robo.vault import _spawn as real_spawn
from robo.vault import obsidian_config as real_config


def config_with(tmp_path, data):
    cfg = tmp_path / "obsidian" / "obsidian.json"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(data if isinstance(data, str) else json.dumps(data, separators=(",", ":")))
    return cfg


def is_running(monkeypatch, running):
    monkeypatch.setattr(vault, "obsidian_running", lambda: running)


OTHER = {"vaults": {"aaaaaaaaaaaaaaaa": {"path": "/elsewhere/notes", "ts": 1, "open": True}},
         "cli": True}


# --- ensure_vault ---------------------------------------------------------------------------


def test_ensure_vault_makes_the_tree_and_registers_it_once(tmp_path, monkeypatch):
    is_running(monkeypatch, False)
    home = tmp_path / "Documents" / "Robo"
    cfg = config_with(tmp_path, OTHER)

    done = vault.ensure_vault(home, cfg)

    assert done == [f"created your Obsidian vault at {home}", "added your Robo vault to Obsidian"]
    assert {p.name for p in home.iterdir()} == {*vault.FOLDERS, ".obsidian"}
    assert list((home / ".obsidian").iterdir()) == []
    data = json.loads(cfg.read_text())
    assert data["cli"] is True  # keys and vaults that are not ours stay as they were
    assert data["vaults"]["aaaaaaaaaaaaaaaa"] == OTHER["vaults"]["aaaaaaaaaaaaaaaa"]
    (token,) = set(data["vaults"]) - {"aaaaaaaaaaaaaaaa"}
    assert len(token) == 16 and int(token, 16) >= 0
    entry = data["vaults"][token]
    assert entry["path"] == str(home) and isinstance(entry["ts"], int)
    assert ": " not in cfg.read_text()  # compact, like Obsidian writes it
    assert [p.name for p in cfg.parent.iterdir()] == ["obsidian.json"]  # no temp file left behind

    assert vault.ensure_vault(home, cfg) == []  # nothing left to do
    assert len(json.loads(cfg.read_text())["vaults"]) == 2


def test_ensure_vault_never_edits_obsidian_while_it_runs(tmp_path, monkeypatch):
    is_running(monkeypatch, True)
    home = tmp_path / "Robo"
    cfg = config_with(tmp_path, OTHER)
    before = cfg.read_bytes()

    done = vault.ensure_vault(home, cfg)

    assert cfg.read_bytes() == before
    assert done[0].startswith("created your Obsidian vault")
    assert "Obsidian is open" in done[1] and "Open folder as vault" in done[1]
    assert str(home) in done[1]


def test_a_vault_obsidian_already_lists_needs_nothing_even_while_it_runs(tmp_path, monkeypatch):
    is_running(monkeypatch, True)
    home = tmp_path / "Robo"
    cfg = config_with(tmp_path, {"vaults": {"b" * 16: {"path": str(home), "ts": 5, "open": True}}})
    vault.ensure_vault(home, cfg)  # makes the folders
    assert vault.ensure_vault(home, cfg) == []


def test_a_missing_obsidian_config_is_a_message_not_an_error(tmp_path, monkeypatch):
    is_running(monkeypatch, False)
    home = tmp_path / "Robo"
    cfg = tmp_path / "nope" / "obsidian.json"

    done = vault.ensure_vault(home, cfg)

    assert "Open folder as vault" in done[-1] and str(home) in done[-1]
    assert not cfg.exists() and (home / "Notes").is_dir()


@pytest.mark.parametrize("text", ["{not json", "[]", '{"vaults": []}', '{"vaults": {"a": 3}}', ""])
def test_a_corrupt_obsidian_config_is_left_alone_with_a_message(tmp_path, monkeypatch, text):
    is_running(monkeypatch, False)
    home = tmp_path / "Robo"
    cfg = config_with(tmp_path, text)

    done = vault.ensure_vault(home, cfg)

    assert cfg.read_text() == text
    assert "Open folder as vault" in done[-1]


def test_an_obsidian_config_without_vaults_gets_the_key(tmp_path, monkeypatch):
    is_running(monkeypatch, False)
    cfg = config_with(tmp_path, {"cli": False})
    vault.ensure_vault(tmp_path / "Robo", cfg)
    data = json.loads(cfg.read_text())
    assert data["cli"] is False and len(data["vaults"]) == 1


def test_an_uncreatable_vault_is_a_message(tmp_path, monkeypatch):
    is_running(monkeypatch, False)
    (tmp_path / "file").write_text("x")
    done = vault.ensure_vault(tmp_path / "file" / "Robo", config_with(tmp_path, OTHER))
    assert len(done) == 1 and done[0].startswith("could not create your Obsidian vault")


def test_ensure_vault_defaults_are_read_when_called(tmp_path, monkeypatch):
    """So a test (or conftest) can repoint VAULT and the config without touching the real ones."""
    is_running(monkeypatch, False)
    cfg = config_with(tmp_path, OTHER)
    monkeypatch.setattr(vault, "VAULT", tmp_path / "Mine")
    monkeypatch.setattr(vault, "obsidian_config", lambda: cfg)
    vault.ensure_vault()
    assert (tmp_path / "Mine" / "Plans").is_dir()
    assert str(tmp_path / "Mine") in cfg.read_text()


# --- opening a note -------------------------------------------------------------------------


def test_the_obsidian_uri_percent_encodes_the_whole_path():
    note = Path("/Users/a b/Documents/Robo/Notes/Plan #1 café 100%.md")
    uri = vault.obsidian_uri(note)
    assert uri == ("obsidian://open?path=%2FUsers%2Fa%20b%2FDocuments%2FRobo%2FNotes%2F"
                   "Plan%20%231%20caf%C3%A9%20100%25.md")
    assert unquote(uri.removeprefix("obsidian://open?path=")) == str(note)


@pytest.mark.parametrize(("platform", "front", "argv"), [
    ("darwin", True, ["open", "URI"]),
    ("darwin", False, ["open", "-g", "URI"]),  # behind what you are doing: the login digest
    ("linux", True, ["xdg-open", "URI"]),
    ("linux", False, ["xdg-open", "URI"]),  # xdg-open has no background flag
])
def test_open_note_uses_the_obsidian_uri_when_it_is_installed(monkeypatch, platform, front, argv):
    monkeypatch.setattr(vault.sys, "platform", platform)
    monkeypatch.setattr(vault, "obsidian_installed", lambda: True)
    note = Path("/v/Notes/a b.md")
    calls = []
    vault.open_note(note, front=front, spawn=calls.append)
    assert calls == [[a.replace("URI", vault.obsidian_uri(note)) for a in argv]]


@pytest.mark.parametrize(("platform", "front", "argv"), [
    ("darwin", True, ["open", "/v/Notes/a b.md"]),
    ("darwin", False, ["open", "-g", "/v/Notes/a b.md"]),
    ("linux", True, ["xdg-open", "/v/Notes/a b.md"]),
])
def test_open_note_falls_back_to_the_os_opener_without_obsidian(monkeypatch, platform, front, argv):
    monkeypatch.setattr(vault.sys, "platform", platform)
    monkeypatch.setattr(vault, "obsidian_installed", lambda: False)
    calls = []
    vault.open_note(Path("/v/Notes/a b.md"), front=front, spawn=calls.append)
    assert calls == [argv]


def test_open_note_does_not_wait_for_the_opener(monkeypatch):
    seen = {}

    def popen(argv, **kw):
        seen.update(argv=argv, **kw)

    monkeypatch.setattr(vault.subprocess, "Popen", popen)
    real_spawn(["open", "x"])
    assert seen["argv"] == ["open", "x"] and seen["start_new_session"] is True
    assert seen["stdout"] == subprocess.DEVNULL  # Popen, not run(): nothing is waited for


# --- what is installed / running ------------------------------------------------------------


def test_on_a_mac_the_default_applications_folders_are_system_and_user(tmp_path, monkeypatch):
    monkeypatch.setattr(vault.Path, "home", lambda: tmp_path)
    assert vault.mac_app_dirs() == (Path("/Applications"), tmp_path / "Applications")


def test_obsidian_installed_on_a_mac_looks_in_both_applications_folders(tmp_path, monkeypatch):
    # The folders are injected: /Applications/Obsidian.app really exists on the dev's Mac.
    monkeypatch.setattr(vault.sys, "platform", "darwin")
    system, user = tmp_path / "system", tmp_path / "user"
    system.mkdir()
    user.mkdir()
    assert vault.obsidian_installed((system, user)) is False  # neither holds it
    (user / "Obsidian.app").mkdir()
    assert vault.obsidian_installed((system, user)) is True  # ~/Applications alone
    (user / "Obsidian.app").rmdir()
    (system / "Obsidian.app").mkdir()
    assert vault.obsidian_installed((system, user)) is True  # /Applications alone


def test_obsidian_installed_on_linux_is_on_the_path_or_a_flatpak(tmp_path, monkeypatch):
    monkeypatch.setattr(vault.sys, "platform", "linux")
    monkeypatch.setattr(vault.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(vault.shutil, "which", lambda name: None)
    assert vault.obsidian_installed() is False
    flatpak = tmp_path / ".local/share/flatpak/exports/bin/md.obsidian.Obsidian"
    flatpak.parent.mkdir(parents=True)
    flatpak.write_text("")
    assert vault.obsidian_installed() is True
    flatpak.unlink()
    monkeypatch.setattr(vault.shutil, "which", lambda name: "/usr/bin/obsidian")
    assert vault.obsidian_installed() is True


@pytest.mark.parametrize(("platform", "name"), [("darwin", "Obsidian"), ("linux", "obsidian")])
def test_obsidian_running_asks_pgrep_for_the_exact_process_name(monkeypatch, platform, name):
    monkeypatch.setattr(vault.sys, "platform", platform)
    asked = []

    def run(argv, **kw):
        asked.append(argv)
        return subprocess.CompletedProcess(argv, 0 if len(asked) == 1 else 1)

    monkeypatch.setattr(vault.subprocess, "run", run)
    assert vault.obsidian_running() is True and vault.obsidian_running() is False
    assert asked[0] == ["pgrep", "-x", name]


def test_obsidian_running_assumes_yes_when_it_cannot_tell(monkeypatch):
    def no_pgrep(*a, **kw):
        raise FileNotFoundError("pgrep")

    monkeypatch.setattr(vault.subprocess, "run", no_pgrep)
    assert vault.obsidian_running() is True  # then its settings are left alone


@pytest.mark.parametrize(("platform", "path"), [
    ("darwin", "Library/Application Support/obsidian/obsidian.json"),
    ("linux", ".config/obsidian/obsidian.json"),
])
def test_obsidian_config_path_per_os(tmp_path, monkeypatch, platform, path):
    monkeypatch.setattr(vault.sys, "platform", platform)
    monkeypatch.setattr(vault.Path, "home", lambda: tmp_path)
    assert real_config() == tmp_path / path


def test_the_vault_lives_in_documents_and_has_the_three_folders():
    """The templates track relies on exactly these names."""
    assert vault.FOLDERS == ("Drafts", "Plans", "Notes")
    assert REAL_VAULT.parts[-2:] == ("Documents", "Robo")
