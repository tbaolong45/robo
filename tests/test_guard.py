"""robo-guard plugin: blocks write-like browser actions, allows reading.

Arg names match ~/.hermes/hermes-agent/tools/browser_tool.py BROWSER_TOOL_SCHEMAS
(browser_click{ref}, browser_type{ref,text}, browser_press{key}, browser_console{expression}).
"""

import importlib.util
import json
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[1] / "hermes" / "plugins" / "robo-guard" / "__init__.py"


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
])


def see(guard, task="t1", snapshot=SNAPSHOT, tool="browser_snapshot"):
    result = json.dumps({"success": True, "snapshot": snapshot, "element_count": 11})
    guard.post_tool_call(tool_name=tool, args={}, result=result, task_id=task)


def call(guard, tool, args, task="t1"):
    return guard.pre_tool_call(tool_name=tool, args=args, task_id=task, session_id="s")


def blocked(ret):
    return isinstance(ret, dict) and ret.get("action") == "block" and bool(ret.get("message"))


@pytest.mark.parametrize("ref", ["@e3", "@e4", "@e5", "@e9", "@e10", "e4"])
def test_click_on_write_button_is_blocked(guard, ref):
    see(guard)
    assert blocked(call(guard, "browser_click", {"ref": ref}))


@pytest.mark.parametrize("ref", ["@e1", "@e2", "@e6", "@e8", "@e11"])
def test_click_on_read_element_is_allowed(guard, ref):
    see(guard)
    assert call(guard, "browser_click", {"ref": ref}) is None


def test_labels_come_from_navigate_results_too(guard):
    see(guard, tool="browser_navigate")
    assert blocked(call(guard, "browser_click", {"ref": "@e4"}))


def test_labels_are_per_task_and_replaced_by_new_snapshot(guard):
    see(guard)
    assert call(guard, "browser_click", {"ref": "@e4"}, task="other") is None
    see(guard, snapshot='- link "Inbox" [ref=e4]')
    assert call(guard, "browser_click", {"ref": "@e4"}) is None


def test_unknown_ref_fails_open(guard):
    assert call(guard, "browser_click", {"ref": "@e99"}) is None


def test_type_into_message_box_is_blocked(guard):
    see(guard)
    assert blocked(call(guard, "browser_type", {"ref": "@e7", "text": "hi"}))


def test_type_with_write_verb_is_blocked_but_search_is_allowed(guard):
    see(guard)
    assert blocked(call(guard, "browser_type", {"ref": "@e8", "text": "please Forward this"}))
    assert call(guard, "browser_type", {"ref": "@e8", "text": "calculus week 3"}) is None


@pytest.mark.parametrize("key", ["Control+Enter", "Delete", "e", "Alt+S", "Backspace"])
def test_non_navigation_keys_are_blocked(guard, key):
    assert blocked(call(guard, "browser_press", {"key": key}))


@pytest.mark.parametrize("key", ["Enter", "Tab", "Shift+Tab", "Escape", "PageDown"])
def test_navigation_keys_are_allowed(guard, key):
    assert call(guard, "browser_press", {"key": key}) is None


def test_js_eval_and_raw_control_are_blocked(guard):
    assert blocked(call(guard, "browser_console", {"expression": "document.title"}))
    assert blocked(call(guard, "browser_cdp", {"method": "Runtime.evaluate", "params": {}}))
    assert blocked(call(guard, "browser_exec", {"code": "print(1)"}))


@pytest.mark.parametrize("tool,args", [
    ("browser_navigate", {"url": "https://outlook.office.com/mail/inbox"}),
    ("browser_snapshot", {"full": True}),
    ("browser_scroll", {"direction": "down"}),
    ("browser_back", {}),
    ("browser_console", {"clear": False}),
    ("browser_vision", {"question": "What is due?"}),
    ("web_search", {"query": "send help"}),
])
def test_reading_is_allowed(guard, tool, args):
    assert call(guard, tool, args) is None


def test_register_wires_both_hooks(guard):
    hooks = {}

    class Ctx:
        def register_hook(self, name, cb):
            hooks[name] = cb

    guard.register(Ctx())
    assert hooks == {"pre_tool_call": guard.pre_tool_call, "post_tool_call": guard.post_tool_call}
