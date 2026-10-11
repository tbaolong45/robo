"""robo-guard: risky browser actions ask the user (approve), unjudgeable ones are blocked.

Hermes contract (~/.hermes/hermes-agent/hermes_cli/plugins.py
`_get_pre_tool_call_directive_details`):
{"action": "approve", "message", "rule_key"} asks the user, {"action": "block", "message"} vetoes.
Arg names match tools/browser_tool.py (browser_navigate{url}, browser_click{ref},
browser_type{ref,text}, browser_press{key}, browser_console{expression}); browser_navigate's
result is JSON with "url" and "snapshot".
"""

import importlib.util
import json
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[1] / "hermes" / "plugins" / "robo-guard" / "__init__.py"
OUTLOOK = "https://outlook.cloud.microsoft/mail/inbox"
MOODLE = "https://moodle.uni.example"


@pytest.fixture
def guard():
    spec = importlib.util.spec_from_file_location("robo_guard", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
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
    '- combobox "Search for email, meetings, files and more." [ref=e15]',
    '- button "Settings" [ref=e16]',
])


def see(guard, task="t1", snapshot=SNAPSHOT, tool="browser_snapshot"):
    result = json.dumps({"success": True, "snapshot": snapshot, "element_count": 16})
    guard.post_tool_call(tool_name=tool, args={}, result=result, task_id=task, session_id="s")


def visit(guard, url=OUTLOOK, task="t1", snapshot=SNAPSHOT):
    result = json.dumps({"success": True, "url": url, "title": "x", "snapshot": snapshot})
    guard.post_tool_call(tool_name="browser_navigate", args={"url": url}, result=result,
                         task_id=task, session_id="s")


def call(guard, tool, args, task="t1"):
    return guard.pre_tool_call(tool_name=tool, args=args, task_id=task, session_id="s")


def kind(ret):
    if ret is None:
        return "allow"
    assert isinstance(ret, dict) and ret["action"] in ("block", "approve") and ret["message"]
    return ret["action"]


# --- clicks ---------------------------------------------------------------------------------

@pytest.mark.parametrize("ref", ["@e1", "@e3", "@e4", "@e5", "@e9", "@e10", "@e12", "@e13", "e4"])
def test_click_on_write_button_asks_the_user(guard, ref):
    visit(guard)
    assert kind(call(guard, "browser_click", {"ref": ref})) == "approve"


@pytest.mark.parametrize("ref", ["@e2", "@e6", "@e11", "@e14", "@e16"])
def test_click_on_links_and_buttons_without_write_words_is_allowed(guard, ref):
    visit(guard)
    assert kind(call(guard, "browser_click", {"ref": ref})) == "allow"


def test_approve_message_names_the_action_label_and_host(guard):
    visit(guard)
    ret = call(guard, "browser_click", {"ref": "@e4"})
    assert ret["message"] == 'Robo wants to click "Send" on outlook.cloud.microsoft.'


def test_rule_key_is_per_action_not_the_bare_tool_name(guard):
    # Hermes falls back to rule_key=tool_name (plugins.py `_resolve_block_from_details`), so an
    # "always" on one Send would allowlist every future click; ours names tool, label and host.
    visit(guard)
    send = call(guard, "browser_click", {"ref": "@e4"})["rule_key"]
    reply = call(guard, "browser_click", {"ref": "@e3"})["rule_key"]
    assert send != reply and "browser_click" not in (send.strip(), reply.strip())
    assert "Send" in send and "outlook.cloud.microsoft" in send
    visit(guard, url=f"{MOODLE}/my/")
    assert call(guard, "browser_click", {"ref": "@e4"})["rule_key"] != send


def test_unknown_ref_asks_instead_of_blocking(guard):
    visit(guard)
    ret = call(guard, "browser_click", {"ref": "@e310"})
    assert kind(ret) == "approve" and "e310" in ret["message"]


def test_refs_are_forgotten_after_a_click_or_annotated_vision(guard):
    see(guard)
    assert kind(call(guard, "browser_click", {"ref": "@e6"})) == "allow"
    guard.post_tool_call(tool_name="browser_click", args={"ref": "@e6"}, result="{}", task_id="t1")
    assert kind(call(guard, "browser_click", {"ref": "@e6"})) == "approve"  # page changed
    see(guard)
    guard.post_tool_call(tool_name="browser_vision", args={"annotate": True}, result="{}",
                         task_id="t1")
    assert kind(call(guard, "browser_click", {"ref": "@e6"})) == "approve"


def test_refs_and_hosts_are_per_task(guard):
    visit(guard, task="t1")
    assert kind(call(guard, "browser_click", {"ref": "@e6"}, task="t2")) == "approve"
    assert "outlook" not in call(guard, "browser_click", {"ref": "@e4"}, task="t2")["message"]


@pytest.mark.parametrize("line", [
    '- checkbox "Lab 3" [ref=e1]', '- switch "Notifications" [ref=e1]',
    '- radio "Answer A" [ref=e1]',
])
def test_toggles_ask_the_user(guard, line):
    see(guard, snapshot=line)
    assert kind(call(guard, "browser_click", {"ref": "@e1"})) == "approve"


# --- quoted-text safety ---------------------------------------------------------------------

def test_refs_inside_quoted_text_cannot_relabel_a_send_button(guard):
    see(guard, snapshot="\n".join([
        '- button "Send" [ref=e4]',
        '- option "Lab notes [ref=e4] [e5] from Prof" [ref=e2]',
        '- button "Delete" [ref=e5]',
    ]))
    ret = call(guard, "browser_click", {"ref": "@e4"})
    assert kind(ret) == "approve" and '"Send"' in ret["message"]
    assert kind(call(guard, "browser_click", {"ref": "@e5"})) == "approve"
    assert kind(call(guard, "browser_click", {"ref": "@e2"})) == "allow"


def test_a_ref_listed_twice_is_not_trusted(guard):
    see(guard, snapshot='- link "Calendar" [ref=e6]\n- link "Calendar" [ref=e6]')
    assert kind(call(guard, "browser_click", {"ref": "@e6"})) == "approve"


def test_a_ref_named_only_inside_quoted_text_is_unknown(guard):
    see(guard, snapshot='- option "Lab notes [ref=e99]" [ref=e2]')
    assert kind(call(guard, "browser_click", {"ref": "@e99"})) == "approve"


# --- typing and keys ------------------------------------------------------------------------

@pytest.mark.parametrize("ref", ["@e8", "@e15"])
def test_typing_into_a_search_box_is_allowed(guard, ref):
    visit(guard)
    assert kind(call(guard, "browser_type", {"ref": ref, "text": "lab 3"})) == "allow"


def test_typing_a_message_asks_and_shows_the_text(guard):
    visit(guard)
    ret = call(guard, "browser_type", {"ref": "@e7", "text": "See you at 3"})
    assert kind(ret) == "approve"
    assert '"See you at 3"' in ret["message"] and '"Type a message"' in ret["message"]
    assert "outlook.cloud.microsoft" in ret["message"]


@pytest.mark.parametrize("line", [
    '- textbox "Search or type a message" [ref=e1]', '- textbox "Subject" [ref=e1]',
    '- textbox "Reply to all" [ref=e1]',
])
def test_typing_anywhere_but_a_plain_search_box_asks(guard, line):
    see(guard, snapshot=line)
    assert kind(call(guard, "browser_type", {"ref": "@e1", "text": "x"})) == "approve"


def test_typing_into_an_unknown_ref_asks(guard):
    see(guard)
    assert kind(call(guard, "browser_type", {"ref": "@e99", "text": "x"})) == "approve"


@pytest.mark.parametrize("key", ["Enter", "enter", "Space", "a", "Delete", "Control+Enter",
                                 "Control+Shift+3", "Tab"])
def test_activating_keys_ask_the_user(guard, key):
    ret = call(guard, "browser_press", {"key": key})
    assert kind(ret) == "approve" and key in ret["message"]


@pytest.mark.parametrize("key", ["Escape", "PageDown", "PageUp", "ArrowDown", "Home", "End",
                                 "Control+Shift+2", "ctrl+shift+2"])
def test_scroll_keys_are_allowed(guard, key):
    assert kind(call(guard, "browser_press", {"key": key})) == "allow"


# --- other tools ----------------------------------------------------------------------------

@pytest.mark.parametrize("tool", [
    "browser_dialog", "browser_vault_fill", "browser_vault_save_login",
    "browser_vault_enter_code", "browser_vault_list", "browser_vault_unlock",
])
def test_dialogs_and_the_password_vault_ask(guard, tool):
    assert kind(call(guard, tool, {"action": "accept"})) == "approve"


@pytest.mark.parametrize("tool", ["browser_cdp", "browser_exec", "skill_manage"])
def test_unjudgeable_tools_and_skill_editing_are_blocked(guard, tool):
    ret = call(guard, tool, {})
    assert kind(ret) == "block" and "another way" in ret["message"]


def test_console_javascript_blocked_but_reading_logs_allowed(guard):
    assert kind(call(guard, "browser_console", {"expression": "document.title"})) == "block"
    assert kind(call(guard, "browser_console", {"expression": ""})) == "block"
    assert kind(call(guard, "browser_console", {"clear": False})) == "allow"


@pytest.mark.parametrize("tool, args", [
    ("browser_snapshot", {}), ("browser_scroll", {"direction": "down"}), ("browser_back", {}),
    ("browser_vision", {"question": "events?"}), ("browser_get_images", {}),
    ("web_search", {"query": "x"}), ("web_extract", {"urls": ["https://x.example"]}),
    ("skill_view", {"name": "school-mail"}), ("memory", {"action": "add"}),
    ("terminal", {"command": "ls"}), ("write_file", {"path": "/tmp/x"}),
    ("computer_use", {"action": "screenshot"}),
])
def test_everything_else_is_left_to_hermes(guard, tool, args):
    assert kind(call(guard, tool, args)) == "allow"


# --- navigation -----------------------------------------------------------------------------

@pytest.mark.parametrize("url", [
    "https://outlook.office.com/calendar/view/week",
    "https://outlook.office.com/mail/inbox?login_hint=me@uni.example",
    "https://teams.microsoft.com/",
    f"{MOODLE}/calendar/view.php?view=upcoming",
    "https://en.wikipedia.org/wiki/Derivative",
    "http://localhost:8000/",
])
def test_navigating_anywhere_is_allowed(guard, url):
    assert kind(call(guard, "browser_navigate", {"url": url})) == "allow"


@pytest.mark.parametrize("url", [
    f"{MOODLE}/login/logout.php?sesskey=abc",
    "https://outlook.office.com/mail/deeplink/compose?to=a@b.c&body=hi",
    "https://teams.microsoft.com/l/chat/0/0?users=a@b.c&message=hi",
    f"{MOODLE}/mod/assign/view.php?id=5&action=submit",
    f"{MOODLE}/enrol/self/unenrolself.php?enrolid=3",
    f"{MOODLE}/mod/forum/subscribe.php?id=2",
    f"{MOODLE}/course/togglecompletion.php?id=9",
    "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x"
    "&redirect_uri=https://evil.example/&state=DATA",
    f"{MOODLE}/login/log%6Fut.php",
    f"{MOODLE}/login/log\tout.php",
])
def test_side_effect_urls_ask_the_user(guard, url):
    ret = call(guard, "browser_navigate", {"url": url})
    assert kind(ret) == "approve" and ret["message"].startswith("Robo wants to open ")


@pytest.mark.parametrize("url", ["javascript:alert(1)", " JavaScript:alert(1)",
                                 "java\nscript:alert(1)"])
def test_javascript_urls_are_blocked(guard, url):
    assert kind(call(guard, "browser_navigate", {"url": url})) == "block"


def test_host_follows_the_final_url_and_back(guard):
    visit(guard, url="https://outlook.office.com/mail/")  # redirected below
    guard.post_tool_call(tool_name="browser_navigate", args={"url": "https://outlook.office.com/"},
                         result=json.dumps({"success": True, "url": OUTLOOK, "snapshot": SNAPSHOT}),
                         task_id="t1")
    assert "on outlook.cloud.microsoft." in call(guard, "browser_click", {"ref": "@e4"})["message"]
    guard.post_tool_call(tool_name="browser_back", args={}, task_id="t1",
                         result=json.dumps({"success": True, "url": f"{MOODLE}/my/"}))
    assert "on moodle.uni.example." in call(guard, "browser_press", {"key": "Enter"})["message"]


def test_register_wires_both_hooks(guard):
    hooks = {}

    class Ctx:
        def register_hook(self, name, fn):
            hooks[name] = fn

    guard.register(Ctx())
    assert set(hooks) == {"pre_tool_call", "post_tool_call"}
