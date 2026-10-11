"""robo-guard: robo's browser (signed in to school sites) may only READ school sites.

Arg names match ~/.hermes/hermes-agent/tools/browser_tool.py (browser_navigate{url},
browser_click{ref}, browser_type{ref,text}, browser_press{key}, browser_console{expression})
and tools/web_tools.py (web_extract{urls}).
"""

import importlib.util
import json
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[1] / "hermes" / "plugins" / "robo-guard" / "__init__.py"
MOODLE = "https://moodle.uni.example"


@pytest.fixture
def guard(tmp_path):
    spec = importlib.util.spec_from_file_location("robo_guard", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.PROFILE = tmp_path  # the robo profile: its .env holds the Moodle URL
    (tmp_path / ".env").write_text(f"API_SERVER_KEY=x\nMOODLE_BASE_URL={MOODLE}\n")
    return mod


SNAPSHOT = "\n".join([
    '- button "New mail" [ref=e1]',
    '- option "Unread Prof Lee Lab 3 feedback 09:12" [ref=e2]',
    '- button "Reply all" [ref=e3]',
    '- button "Send" [ref=e4]',
    '- button "Mark as read" [ref=e5]',
    '- link "Calendar" [ref=e6]',
    '- textbox "Type a message" [ref=e7]',
    '- searchbox "Search" [ref=e8]',
    '- button "Attempt quiz" [ref=e9]',
    '- button "Sign out" [ref=e10]',
    '- link "Assignment submission status" [ref=e11]',
    '- button "Like" [ref=e12]',
    '- button "Gửi" [ref=e13]',
    '- button "Next week" [ref=e14]',
])


def see(guard, task="t1", snapshot=SNAPSHOT, tool="browser_snapshot", session="s"):
    result = json.dumps({"success": True, "snapshot": snapshot, "element_count": 14})
    guard.post_tool_call(tool_name=tool, args={}, result=result, task_id=task, session_id=session)


def call(guard, tool, args, task="t1", session="s"):
    return guard.pre_tool_call(tool_name=tool, args=args, task_id=task, session_id=session)


def blocked(ret):
    return isinstance(ret, dict) and ret.get("action") == "block" and bool(ret.get("message"))


@pytest.mark.parametrize("ref", ["@e1", "@e3", "@e4", "@e5", "@e9", "@e10", "@e12", "@e13", "e4"])
def test_click_on_write_button_is_blocked(guard, ref):
    see(guard)
    assert blocked(call(guard, "browser_click", {"ref": ref}))


@pytest.mark.parametrize("ref", ["@e2", "@e6", "@e11", "@e14"])
def test_click_on_read_element_is_allowed(guard, ref):
    see(guard)
    assert call(guard, "browser_click", {"ref": ref}) is None


def test_unknown_ref_is_blocked(guard):
    see(guard)
    assert blocked(call(guard, "browser_click", {"ref": "@e310"}))


def test_refs_are_forgotten_after_a_click_or_annotated_vision(guard):
    see(guard)
    assert call(guard, "browser_click", {"ref": "@e6"}) is None
    guard.post_tool_call(tool_name="browser_click", args={"ref": "@e6"}, result="{}", task_id="t1")
    assert blocked(call(guard, "browser_click", {"ref": "@e6"}))  # the page changed: re-snapshot
    see(guard)
    guard.post_tool_call(tool_name="browser_vision", args={"annotate": True}, result="{}",
                         task_id="t1")
    assert blocked(call(guard, "browser_click", {"ref": "@e6"}))


def test_refs_are_per_task(guard):
    see(guard, task="t1")
    assert blocked(call(guard, "browser_click", {"ref": "@e6"}, task="t2"))


def test_typing_is_blocked_everywhere(guard):
    see(guard)
    for ref in ("@e7", "@e8"):
        assert blocked(call(guard, "browser_type", {"ref": ref, "text": "hello"}))


@pytest.mark.parametrize("key", ["Enter", "enter", "Space", "a", "Control+Enter",
                                 "Control+Shift+3", "Control+2"])
def test_activating_keys_are_blocked(guard, key):
    assert blocked(call(guard, "browser_press", {"key": key}))


@pytest.mark.parametrize("key", ["Escape", "PageDown", "PageUp", "ArrowDown", "Home", "End",
                                 "Control+Shift+2", "ctrl+shift+2"])
def test_scroll_keys_are_allowed(guard, key):
    assert call(guard, "browser_press", {"key": key}) is None


@pytest.mark.parametrize("tool", [
    "browser_cdp", "browser_exec", "browser_dialog", "browser_vault_fill",
    "browser_vault_save_login", "browser_vault_enter_code", "browser_vault_list",
    "browser_vault_unlock", "skill_manage", "memory",
    "web_extract",
])
def test_unjudgeable_or_persistent_tools_are_blocked(guard, tool):
    assert blocked(call(guard, tool, {}))


def test_console_eval_blocked_but_reading_logs_allowed(guard):
    assert blocked(call(guard, "browser_console", {"expression": "document.title"}))
    assert call(guard, "browser_console", {"clear": False}) is None


@pytest.mark.parametrize("url", [
    "https://outlook.office.com/calendar/view/week",
    "https://outlook.office365.com/mail/",
    "https://outlook.cloud.microsoft/mail/inbox",
    "https://teams.microsoft.com/",
    "https://teams.cloud.microsoft/",
    "https://login.microsoftonline.com/common/oauth2",
    f"{MOODLE}/calendar/view.php?view=upcoming",
    f"{MOODLE}/my/",
])
def test_browser_may_open_school_sites(guard, url):
    assert call(guard, "browser_navigate", {"url": url}) is None


@pytest.mark.parametrize("url", [
    "https://attacker.example/?d=secret",
    "https://outlook.office.com.attacker.example/",
    "http://outlook.office.com/mail/",  # not https
    "https://moodle.uni.example.evil/",
    "javascript:alert(1)",
    f"{MOODLE}/login/logout.php?sesskey=abc",
    "https://outlook.office.com/mail/deeplink/compose?to=a@b.c&body=hi",
    "https://teams.microsoft.com/l/chat/0/0?users=a@b.c&message=hi",
])
def test_browser_may_not_open_anything_else(guard, url):
    assert blocked(call(guard, "browser_navigate", {"url": url}))


def test_no_moodle_configured_blocks_moodle(guard):
    (guard.PROFILE / ".env").write_text("API_SERVER_KEY=x\n")
    assert blocked(call(guard, "browser_navigate", {"url": f"{MOODLE}/my/"}))


def test_reading_tools_pass(guard):
    for tool, args in [("browser_snapshot", {}), ("browser_scroll", {"direction": "down"}),
                       ("browser_back", {}), ("browser_vision", {"question": "events?"}),
                       ("web_search", {"query": "x"}), ("skill_view", {"name": "school-mail"})]:
        assert call(guard, tool, args) is None


def test_block_message_tells_the_model_not_to_work_around(guard):
    ret = call(guard, "browser_cdp", {})
    assert "read-only" in ret["message"] and "another way" in ret["message"]


def test_register_wires_both_hooks(guard):
    hooks = {}

    class Ctx:
        def register_hook(self, name, fn):
            hooks[name] = fn

    guard.register(Ctx())
    assert set(hooks) == {"pre_tool_call", "post_tool_call"}


def test_refs_inside_quoted_text_cannot_relabel_buttons(guard):
    see(guard, snapshot="\n".join([
        '- button "Send" [ref=e4]',
        '- option "Lab notes [ref=e4] [e5] from Prof" [ref=e2]',
        '- button "Delete" [ref=e5]',
    ]))
    assert blocked(call(guard, "browser_click", {"ref": "@e4"}))
    assert blocked(call(guard, "browser_click", {"ref": "@e5"}))
    assert call(guard, "browser_click", {"ref": "@e2"}) is None


def test_a_ref_listed_twice_is_not_trusted(guard):
    see(guard, snapshot='- link "Calendar" [ref=e6]\n- link "Calendar" [ref=e6]')
    assert blocked(call(guard, "browser_click", {"ref": "@e6"}))


@pytest.mark.parametrize("label", [
    "Continue", "Yes", "OK", "Done", "Turn in", "Hand in", "Empty folder", "Restore",
    "Ignore", "Sweep", "Subscribe", "Undo", "Unpin", "Apply", "Update", "Finish attempt",
    "Do not disturb", "Heart",
])
def test_confirm_and_status_words_are_blocked_even_on_links(guard, label):
    see(guard, snapshot=f'- menuitem "{label}" [ref=e1]\n- link "{label}" [ref=e2]')
    assert blocked(call(guard, "browser_click", {"ref": "@e1"}))
    assert blocked(call(guard, "browser_click", {"ref": "@e2"}))


@pytest.mark.parametrize("line", [
    '- button "Go to next week" [ref=e1]', '- button "Today" [ref=e1]',
    '- button "Chat" [ref=e1]', '- button "Show more" [ref=e1]',
    '- tab "Upcoming" [ref=e1]', '- link "Timeline" [ref=e1]',
])
def test_navigation_controls_are_allowed(guard, line):
    see(guard, snapshot=line)
    assert call(guard, "browser_click", {"ref": "@e1"}) is None


@pytest.mark.parametrize("line", [
    '- checkbox "Lab 3" [ref=e1]', '- switch "Notifications" [ref=e1]',
    '- radio "Answer A" [ref=e1]', '- combobox "Status" [ref=e1]',
])
def test_form_controls_are_blocked(guard, line):
    see(guard, snapshot=line)
    assert blocked(call(guard, "browser_click", {"ref": "@e1"}))


@pytest.mark.parametrize("path", [
    "/mod/assign/view.php?id=5&action=submit",
    "/mod/assign/view.php?id=5&action=removesubmissionconfirm",
    "/enrol/self/unenrolself.php?enrolid=3", "/mod/forum/subscribe.php?id=2",
    "/course/togglecompletion.php?id=9",
])
def test_moodle_side_effect_urls_are_blocked(guard, path):
    assert blocked(call(guard, "browser_navigate", {"url": MOODLE + path}))


def test_microsoft_oauth_redirect_is_blocked(guard):
    url = ("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x"
           "&redirect_uri=https://evil.example/&prompt=none&state=DATA")
    assert blocked(call(guard, "browser_navigate", {"url": url}))


def test_a_ref_named_only_inside_quoted_text_is_unknown(guard):
    see(guard, snapshot='- option "Lab notes [ref=e99]" [ref=e2]')  # e99 may be off-snapshot
    assert blocked(call(guard, "browser_click", {"ref": "@e99"}))
