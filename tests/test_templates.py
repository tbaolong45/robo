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
    assert names == school | {"study-ledger", "study-plan", "robo-make", "robo-notes"}


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


def skill_text(name: str) -> str:
    return (HERMES / "skills" / "school" / name / "SKILL.md").read_text(encoding="utf-8")


def note_headers() -> dict[str, dict[str, str]]:
    """The property blocks of robo-notes' example notes, by their `type`."""
    heads = re.findall(r"^---\n(.*?)\n---\n", skill_text("robo-notes").split("\n---\n", 1)[1],
                       re.S | re.M)
    props = [dict(ln.split(": ", 1) for ln in head.splitlines()) for head in heads]
    return {p["type"]: p for p in props}


def test_robo_notes_names_the_vault_folders_and_properties():
    # The app opens notes that sit directly in these folders; the app track relies on the names.
    text = skill_text("robo-notes")
    for folder in ("Drafts", "Plans", "Notes"):
        assert f"{{{{VAULT}}}}/{folder}/" in text
    headers = note_headers()
    assert set(headers) == {"draft", "plan", "note"}
    common = {"type", "created", "tags", "source"}
    extra = {"draft": {"to", "subject", "status"}, "plan": {"date", "status"}, "note": set()}
    for kind, props in headers.items():
        assert set(props) == common | extra[kind], kind
        assert props["source"] == "robo" and props["tags"] == f"[robo, robo/{kind}]", kind
        assert re.fullmatch(r"\d{4}-\d\d-\d\d", props["created"])
    assert headers["draft"]["status"] == "unsent" and headers["plan"]["status"] == "proposed"


def test_each_robo_notes_example_is_captioned_with_its_own_folder():
    text = skill_text("robo-notes")
    captions = re.findall(r"^(Plan|Draft|Text) note \(`\{\{VAULT\}\}/(\w+)/", text, re.M)
    assert {(kind.lower(), folder) for kind, folder in captions} == {
        ("plan", "Plans"), ("draft", "Drafts"), ("text", "Notes")}
    # ...and the header under each caption has the matching type.
    assert list(note_headers()) == ["plan", "draft", "note"]


def test_robo_notes_signs_with_the_users_name_not_a_hard_coded_one():
    text = skill_text("robo-notes")
    assert re.search(r"Best regards,\n<your first name>\n", text)
    flat = " ".join(text.split()).lower()  # the sentence wraps across lines in the skill
    assert "sign with the user's name from memory, never a placeholder" in flat


def test_robo_notes_declares_the_terminal_it_tells_the_agent_to_use():
    assert "terminal" in re.search(r"requires_toolsets: \[(.*)\]", skill_text("robo-notes"))[1]


@pytest.mark.parametrize(("name", "heading", "phrase"), [
    ("robo-notes", "Format", "a message or an essay has none of them"),  # only mail is unsent
    ("robo-notes", "Where", "hermes"),  # robo-guard blocks any path that contains it
    ("school-mail", "Drafting", "only after the draft row is found"),
    ("study-plan", "Adding to the calendar", "only if every block was added"),
    ("school-digest", "Output", "after 20:00"),
])
def test_skill_rules_that_keep_notes_truthful(name, heading, phrase):
    assert phrase in section(skill_text(name), heading), f"{name}: '## {heading}' lost '{phrase}'"


def test_robo_notes_leaves_opening_the_note_to_the_app():
    text = skill_text("robo-notes")
    assert "do NOT open Obsidian" in text
    assert not any("obsidian://" in p.read_text(encoding="utf-8") for p in SKILLS)


def section(text: str, heading: str) -> str:
    """The body of `## heading` up to the next `## `; the frontmatter is never part of one."""
    found = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    assert found, f"no '## {heading}' section"
    return found[1]


def test_section_check_ignores_frontmatter():
    only_listed = "---\nrelated_skills: [robo-notes]\n---\n## Output\nPaste the plan here.\n"
    assert "robo-notes" in only_listed and "robo-notes" not in section(only_listed, "Output")


def test_soul_sends_drafts_plans_and_text_to_robo_notes():
    soul = (HERMES / "SOUL.md").read_text(encoding="utf-8")
    assert "robo-notes" in section(soul, "Drafts, plans and text")


@pytest.mark.parametrize(("name", "heading"), [
    ("robo-make", "When to Use"),  # hands notes and plans over
    ("study-plan", "Output"),
    ("school-mail", "Drafting"),
    ("school-digest", "Procedure"),
])
def test_skills_send_drafts_plans_and_text_to_robo_notes(name, heading):
    # The instruction itself, not just the related_skills line, must name the skill.
    text = skill_text(name)
    assert "robo-notes" in section(text, heading), f"{name}: '## {heading}' lost its robo-notes"
    assert "robo-notes" in re.search(r"related_skills: \[(.*)\]", text)[1], name


def test_templates_do_not_keep_the_old_behaviour():
    # Notes used to be HTML or .md files in ~/Robo, and plans and drafts were bubble text.
    make = skill_text("robo-make")
    assert ".md" not in make and "styled `.html`" not in make
    soul = (HERMES / "SOUL.md").read_text(encoding="utf-8")
    for para in re.split(r"\n(?=- |#|\n)", soul):  # a bullet is one paragraph
        if "~/Robo" in para:  # the robo-make bullet: only what needs a browser lives there now
            assert "robo-make" in para and "notes" not in para.lower(), para
    for name in ("study-plan", "school-digest"):
        assert not re.search(r"^- \d\d:\d\d-", skill_text(name), re.M), f"{name} lists blocks"
    assert "Plan for today" not in skill_text("school-digest")


def test_templates_use_only_placeholders_setup_fills():
    used = {
        key for p in HERMES.rglob("*") if p.is_file() and "__pycache__" not in p.parts
        for key in re.findall(r"\{\{(\w+)\}\}", p.read_text(encoding="utf-8"))
    }
    assert used <= {"MOODLE_BASE_URL", "ROBO_PROJECT", "DESKTOP_APPS", "VAULT"}
    assert "VAULT" in used
