"""Hermes templates: SKILL.md frontmatter passes Hermes' skill_manage validator, SOUL.md emotions.

Rules mirrored from ~/.hermes/hermes-agent/tools/skill_manager_tool.py `_validate_frontmatter`
(name + description required, VALID_NAME_RE, description <= SKILL_PROMPT_DESC_LIMIT = 60 for new
skills) and the YAML error "mapping values not allowed here" (an unquoted value with ': ').
"""

import json
import re
from pathlib import Path

import pytest

from robo.events import EMOTIONS

HERMES = Path(__file__).resolve().parents[1] / "hermes"
SKILLS = sorted((HERMES / "skills").glob("*/*/SKILL.md"))
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def frontmatter(path: Path) -> tuple[dict[str, str], str]:
    text = path.read_text(encoding="utf-8")
    assert text.startswith("---\n"), "must start with YAML frontmatter"
    head, sep, body = text[4:].partition("\n---\n")
    assert sep, "frontmatter is not closed"
    fields = {}
    for line in head.splitlines():
        key, _, value = line.strip().partition(": ")
        value = value.strip()
        quoted = value[:1] in "\"'[" and value != ""
        assert quoted or ": " not in value, f"unquoted ': ' in {key!r} breaks YAML"
        if not line.startswith(" ") and key:
            fields[key.rstrip(":")] = value.strip("\"'")
    return fields, body


def test_all_school_skills_exist():
    names = {p.parent.name for p in SKILLS}
    school = {f"school-{n}" for n in ("timetable", "mail", "teams", "moodle", "digest")}
    assert names == school | {"study-ledger", "study-plan", "robo-make"}


@pytest.mark.parametrize("path", SKILLS, ids=lambda p: p.parent.name)
def test_related_skills_exist(path):
    related = re.search(r"related_skills: \[(.*)\]", path.read_text(encoding="utf-8"))
    assert related, "metadata.hermes.related_skills is missing"
    names = {p.parent.name for p in SKILLS}
    assert {n.strip() for n in related[1].split(",")} <= names - {path.parent.name}


@pytest.mark.parametrize("path", SKILLS, ids=lambda p: p.parent.name)
def test_skill_frontmatter_passes_hermes_validator(path):
    fields, body = frontmatter(path)
    assert fields["name"] == path.parent.name
    assert NAME_RE.match(fields["name"]) and len(fields["name"]) <= 64
    desc = fields["description"]
    assert 0 < len(desc) <= 60 and desc.endswith("."), f"{len(desc)} chars: {desc!r}"
    assert f'description: "{desc}"' in path.read_text(encoding="utf-8"), "quote the description"
    assert body.strip()


def test_frontmatter_check_catches_unquoted_colon(tmp_path):
    bad = tmp_path / "SKILL.md"
    bad.write_text("---\nname: x\ndescription: Digest: classes.\n---\nbody\n")
    with pytest.raises(AssertionError, match="unquoted"):
        frontmatter(bad)


def test_soul_lists_exactly_the_app_emotions():
    soul = (HERMES / "SOUL.md").read_text(encoding="utf-8")
    line = next(ln for ln in soul.splitlines() if ln.startswith("neutral,"))
    assert tuple(e.strip(" .") for e in line.split(",")) == EMOTIONS
    assert set(re.findall(r"\[\[feel:(\w+)\]\]", soul)) <= set(EMOTIONS)


def test_guard_plugin_is_enabled_in_setup_config():
    # Toolsets and memory are robo.setup's policy (tests/test_setup.py); the guard must stay on.
    from robo.setup import CONFIG

    assert "robo-guard" in json.loads(CONFIG["plugins.enabled"])


def test_robo_gets_the_whole_laptop_and_keeps_its_setup_safe():
    from robo.setup import CONFIG, TOOLSETS

    assert json.loads(CONFIG["platform_toolsets.api_server"]) == TOOLSETS
    assert {"terminal", "file", "computer_use", "browser"} <= set(TOOLSETS)
    assert CONFIG["approvals.mode"] == "off"  # the user granted all permissions
    assert json.loads(CONFIG["approvals.deny"]) == ["*hermes*"]


@pytest.mark.parametrize("path", sorted(p for p in HERMES.rglob("*") if p.is_file()
                                        and "__pycache__" not in p.parts), ids=str)
def test_templates_hold_no_machine_paths(path):
    """robo setup fills {{ROBO_PROJECT}}; a fixed /home/... path breaks on another laptop."""
    assert not re.search(r"/home/[a-z]", path.read_text(encoding="utf-8"))


def test_soul_leaves_the_desktop_apps_rule_to_setup():
    soul = (HERMES / "SOUL.md").read_text(encoding="utf-8")
    assert "- {{DESKTOP_APPS}}\n" in soul and "GDK_BACKEND" not in soul
