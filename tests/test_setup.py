import plistlib
import re
import stat

import pytest

from robo import setup, vault


def test_set_env_appends_updates_and_keeps_private(tmp_path):
    env = tmp_path / ".env"
    env.write_text("# keep me\nA=1\nB=2\n")
    assert setup.set_env(env, {"B": "3", "C": "4"}) is True
    assert env.read_text() == "# keep me\nA=1\nB=3\nC=4\n"
    assert stat.S_IMODE(env.stat().st_mode) == 0o600
    assert setup.set_env(env, {"B": "3"}) is False


def test_set_env_creates_missing_file(tmp_path):
    env = tmp_path / "sub" / ".env"
    assert setup.set_env(env, {"K": "v"}) is True
    assert env.read_text() == "K=v\n"
    assert stat.S_IMODE(env.stat().st_mode) == 0o600


def test_read_env_ignores_comments_and_quotes(tmp_path):
    env = tmp_path / ".env"
    env.write_text("# X=no\nX='yes'\nY=\"two words\"\nZ\n")
    assert setup.read_env(env) == {"X": "yes", "Y": "two words"}


def test_connection_uses_profile_key_and_host_port(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("ROBO_HERMES_URL", raising=False)
    (tmp_path / ".env").write_text("API_SERVER_PORT=9000\nAPI_SERVER_KEY=host-secret\n")
    (tmp_path / "profiles" / "robo").mkdir(parents=True)
    (tmp_path / "profiles" / "robo" / ".env").write_text("API_SERVER_KEY=robo-secret\n")
    assert setup.connection() == ("http://127.0.0.1:9000/p/robo", "robo-secret")


def test_connection_without_setup_raises(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    try:
        setup.connection()
    except setup.SetupError as e:
        assert "robo setup" in str(e)
    else:
        raise AssertionError("expected SetupError")


def test_setup_is_idempotent_and_restarts_only_on_change(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("SLACK_BOT_TOKEN=x\n")
    templates = tmp_path / "templates"
    (templates / "skills" / "school" / "mail").mkdir(parents=True)
    (templates / "SOUL.md").write_text("soul")
    (templates / "skills" / "school" / "mail" / "SKILL.md").write_text("skill")
    calls = []

    def run(cmd):
        calls.append(cmd)
        if cmd[1:3] == ["profile", "create"]:
            (tmp_path / "profiles" / "robo").mkdir(parents=True)
        if cmd[3:5] == ["config", "set"]:  # like hermes: rewrite the file only on a new value
            cfg = tmp_path / "profiles" / "robo" / "config.yaml"
            line = f"{cmd[5]}: {cmd[6]}\n"
            if line not in (cfg.read_text() if cfg.exists() else ""):
                cfg.write_text((cfg.read_text() if cfg.exists() else "") + line)

    setup.setup(templates=templates, config={"a.b": "1"}, run=run, wait=lambda: True)
    host = setup.read_env(tmp_path / ".env")
    robo = setup.read_env(tmp_path / "profiles" / "robo" / ".env")
    assert host["SLACK_BOT_TOKEN"] == "x" and host["API_SERVER_ENABLED"] == "true"
    assert len(host["API_SERVER_KEY"]) >= 32 and len(robo["API_SERVER_KEY"]) >= 32
    assert host["API_SERVER_KEY"] != robo["API_SERVER_KEY"]
    assert "API_SERVER_ENABLED" not in robo  # served by the host gateway, never its own listener
    assert (tmp_path / "profiles" / "robo" / "SOUL.md").read_text() == "soul"
    assert (tmp_path / "profiles/robo/skills/school/mail/SKILL.md").read_text() == "skill"
    assert calls[0][:5] == ["hermes", "profile", "create", "robo", "--no-alias"]
    assert ["hermes", "-p", "robo", "config", "set", "a.b", "1"] in calls
    assert ["hermes", "gateway", "restart"] in calls

    calls.clear()
    setup.setup(templates=templates, config={"a.b": "1"}, run=run, wait=lambda: True)
    assert not any(c[1:3] == ["profile", "create"] for c in calls)
    assert ["hermes", "gateway", "restart"] not in calls
    assert setup.read_env(tmp_path / ".env")["API_SERVER_KEY"] == host["API_SERVER_KEY"]


def test_config_change_alone_restarts(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    (robo / "config.yaml").write_text("old\n")
    calls = []

    def run(cmd):
        calls.append(cmd)
        if cmd[3:5] == ["config", "set"]:
            (robo / "config.yaml").write_text("new\n")

    done = setup.setup(templates=tmp_path / "none", config={"a": "1"}, run=run, wait=lambda: True)
    assert "updated robo's Hermes config" in done
    assert ["hermes", "gateway", "restart"] in calls


def test_moodle_url_is_stored_and_filled_into_skills(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    templates = tmp_path / "templates"
    (templates / "skills" / "m").mkdir(parents=True)
    (templates / "skills" / "m" / "SKILL.md").write_text("Moodle is {{MOODLE_BASE_URL}}.")
    run = lambda cmd: None  # noqa: E731

    setup.setup(templates=templates, config={}, run=run, wait=lambda: True)
    assert "not set" in (robo / "skills/m/SKILL.md").read_text()

    setup.setup(templates=templates, config={}, run=run, wait=lambda: True,
                moodle="https://moodle.uni.example/")
    assert setup.read_env(robo / ".env")["MOODLE_BASE_URL"] == "https://moodle.uni.example"
    assert (robo / "skills/m/SKILL.md").read_text() == "Moodle is https://moodle.uni.example."


def test_project_path_is_filled_into_skills(tmp_path, monkeypatch):
    """Skills run `uv run --project <this checkout> robo ...`, wherever it was cloned."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    templates = tmp_path / "templates"
    (templates / "skills" / "p").mkdir(parents=True)
    (templates / "skills" / "p" / "SKILL.md").write_text("uv run --project {{ROBO_PROJECT}} robo")

    setup.setup(templates=templates, config={}, run=lambda cmd: None, wait=lambda: True)
    assert (robo / "skills/p/SKILL.md").read_text() == f"uv run --project {setup.PROJECT} robo"
    assert (setup.PROJECT / "pyproject.toml").is_file()


def profile(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    return robo


def test_vault_path_is_filled_into_skills(tmp_path, monkeypatch):
    """Skills and the persona name the vault through {{VAULT}}; vault.VAULT is the only copy."""
    robo = profile(tmp_path, monkeypatch)
    templates = tmp_path / "templates"
    (templates / "skills" / "v").mkdir(parents=True)
    (templates / "skills" / "v" / "SKILL.md").write_text("write to {{VAULT}}/Drafts/<title>.md")

    setup.setup(templates=templates, config={}, run=lambda cmd: None, wait=lambda: True)
    assert (robo / "skills/v/SKILL.md").read_text() == f"write to {vault.VAULT}/Drafts/<title>.md"


def test_every_placeholder_in_the_real_templates_gets_filled(tmp_path, monkeypatch):
    robo = profile(tmp_path, monkeypatch)
    setup.setup(templates=setup.TEMPLATES, config={}, run=lambda cmd: None, wait=lambda: True)
    left = {f"{f.relative_to(robo)}: {m}" for f in robo.rglob("*") if f.suffix == ".md"
            for m in re.findall(r"\{\{[A-Z_]+\}\}", f.read_text())}
    assert not left


@pytest.mark.parametrize("bad", ["moodle.uni.example", "http://moodle.uni.example", "https://"])
def test_moodle_url_must_be_https(tmp_path, monkeypatch, bad):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    with pytest.raises(setup.SetupError):
        setup.setup(templates=tmp_path, config={}, run=lambda c: None, wait=lambda: True,
                    moodle=bad)


def test_persona_stamp_changes_with_soul_or_skills(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    robo = tmp_path / "profiles" / "robo"
    (robo / "skills" / "s").mkdir(parents=True)
    (robo / "SOUL.md").write_text("v1")
    (robo / "skills" / "s" / "SKILL.md").write_text("a")
    first = setup.persona_stamp()
    assert first == setup.persona_stamp() and len(first) == 8
    (robo / "SOUL.md").write_text("v2")
    second = setup.persona_stamp()
    (robo / "skills" / "s" / "SKILL.md").write_text("b")
    assert len({first, second, setup.persona_stamp()}) == 3


@pytest.mark.parametrize(("pasted", "base"), [
    ("https://lms.mbzuai.ac.ae/my/", "https://lms.mbzuai.ac.ae"),
    ("https://lms.uni.example/my/index.php", "https://lms.uni.example"),
    ("https://uni.example/moodle/my/", "https://uni.example/moodle"),
    ("https://uni.example/moodle/", "https://uni.example/moodle"),
    ("https://lms.uni.example/login/index.php", "https://lms.uni.example"),
])
def test_moodle_url_takes_the_base_of_a_pasted_page(pasted, base):
    assert setup._moodle_url(pasted) == base


def test_desktop_installs_the_focus_extension_and_autostart(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setattr(setup.Path, "home", lambda: home)
    enabled = ["ding@rastersoft.com"]
    src = tmp_path / "ext"
    src.mkdir()
    (src / "metadata.json").write_text("{}")
    (src / "extension.js").write_text("x")
    kw = dict(extension=src, robo_cmd="/usr/bin/uv run robo", platform="linux",
              get_enabled=lambda: list(enabled), set_enabled=lambda ids: enabled.__init__(ids))
    done = setup.desktop(**kw)
    ext = home / ".local/share/gnome-shell/extensions/robo-focus@robo"
    assert (ext / "extension.js").read_text() == "x"
    assert enabled == ["ding@rastersoft.com", "robo-focus@robo"]  # others kept
    desktop_file = (home / ".config/autostart/robo.desktop").read_text()
    assert "Exec=/usr/bin/uv run robo" in desktop_file and "Type=Application" in desktop_file
    assert any("log out" in d for d in done)
    assert setup.desktop(**kw) == []  # idempotent


def test_desktop_on_macos_writes_a_launch_agent_and_no_extension(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setattr(setup.Path, "home", lambda: home)
    monkeypatch.setattr(setup.shutil, "which", lambda name: "/opt/homebrew/bin/uv")

    def no_gsettings(*a):
        raise AssertionError("no gsettings on a Mac")

    kw = dict(platform="darwin", get_enabled=no_gsettings, set_enabled=no_gsettings)
    done = setup.desktop(**kw)
    agent = plistlib.loads((home / "Library/LaunchAgents/ai.robo.plist").read_bytes())
    assert agent["Label"] == "ai.robo" and agent["RunAtLoad"] is True
    assert agent["ProgramArguments"] == ["/opt/homebrew/bin/uv", "run", "--project",
                                         str(setup.PROJECT), "robo"]
    assert agent["StandardErrorPath"] == str(home / "Library/Logs/robo.log")
    assert not (home / ".local/share/gnome-shell").exists()
    assert any("log in" in d for d in done)
    assert setup.desktop(**kw) == []  # idempotent


@pytest.mark.parametrize("platform, says", [("linux", "GDK_BACKEND=x11"), ("darwin", "open -a")])
def test_desktop_apps_rule_is_filled_per_os(tmp_path, monkeypatch, platform, says):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(setup.sys, "platform", platform)
    (tmp_path / ".env").write_text("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n")
    robo = tmp_path / "profiles" / "robo"
    robo.mkdir(parents=True)
    (robo / ".env").write_text("API_SERVER_KEY=r\n")
    templates = tmp_path / "templates"
    templates.mkdir()
    (templates / "SOUL.md").write_text("- {{DESKTOP_APPS}}\n")

    setup.setup(templates=templates, config={}, run=lambda cmd: None, wait=lambda: True)
    soul = (robo / "SOUL.md").read_text()
    assert says in soul and "{{" not in soul
