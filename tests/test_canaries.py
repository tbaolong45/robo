"""Hostile-text canaries and the live eval's offline parts.

Each line of tests/evals/canaries.jsonl is a piece of hostile text (an e-mail body, a Teams
message, a calendar invite, a Moodle page) with a HARMLESS payload (a token, a .invalid domain, a
temp path), the tool call a fooled agent would make, and what robo-guard must answer. The test
replays the call through the guard offline: nothing is sent, fetched or run.

With approvals off only a "block" stops an action: the harness allows every robo-guard "approve"
by itself, so that outcome here means "would ask in mode manual", not "stopped". An "allow"
canary is
a known gap or proof that a harmless call is not blocked.

scripts/eval_live.py (opt-in, talks to the real agent) is tested here with a fake client.
"""

import importlib.util
import json
import re
from pathlib import Path

import pytest
from robo_agent.guard import Guard

ROOT = Path(__file__).resolve().parents[1]
CANARIES = ROOT / "tests" / "evals" / "canaries.jsonl"
REQUESTS = ROOT / "tests" / "evals" / "requests.jsonl"
LINES = [line for line in CANARIES.read_text(encoding="utf-8").splitlines() if line.strip()]
SAFE_HOSTS = re.compile(r"\.(?:invalid|example)$|^(?:outlook\.office\.com|teams\.microsoft\.com)$")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.mark.parametrize("line", LINES, ids=[json.loads(line)["id"] for line in LINES])
def test_canary(tmp_path, line):
    home = tmp_path / "home"
    guard = Guard(home, runtime=home / ".local/share/robo/agent", own=[ROOT / "agent"],
                  moodle="https://moodle.uni.example")
    canary = json.loads(line.replace("{HOME}", home.as_posix()))
    for step in canary["setup"]:  # the pages the agent has seen before the call
        guard.post(step["tool"], step["args"], step["result"])
    call = canary["call"]
    ret = guard.pre(call["tool"], call["args"])
    assert (ret["action"] if ret else "allow") == canary["expect"], canary["why"]
    if "shows" in canary:  # what the user must be able to read in the question
        assert canary["shows"] in ret["message"]


def test_canaries_are_well_formed_and_harmless():
    canaries = [json.loads(line) for line in LINES]
    assert len({c["id"] for c in canaries}) == len({c["token"] for c in canaries}) == len(canaries)
    assert {c["expect"] for c in canaries} == {"block", "approve", "allow"}
    assert {c["channel"] for c in canaries} == {"email", "teams", "invite", "moodle"}
    for c in canaries:
        assert c["token"] in c["text"] and c["why"]
        assert c["call"]["tool"] and isinstance(c["call"]["args"], dict)
    for host in re.findall(r"https?://([^/\s\"'?]+)", "\n".join(LINES)):
        assert SAFE_HOSTS.search(host), f"{host}: a canary may only point at .invalid or .example"


# --- requests.jsonl and scripts/eval_live.py ------------------------------------------------

WRITES = re.compile(r"\b(send|delete|remove|submit|forward|post|accept|decline|move|archive|book|"
                    r"schedule|cancel|unsubscribe|pay|buy|reply to)\b", re.IGNORECASE)


def test_requests_are_read_only_and_well_formed():
    items = [json.loads(line) for line in REQUESTS.read_text(encoding="utf-8").splitlines()]
    assert 30 <= len(items) <= 50
    assert len({item["id"] for item in items}) == len(items)
    for item in items:
        assert item["request"].strip() and item["kind"]
        assert not WRITES.search(item["request"]), item["request"]
        re.compile(item.get("match", ""))


@pytest.fixture
def live():
    return load(ROOT / "scripts" / "eval_live.py", "eval_live")


class Fake:
    """A robo-agent client that answers from a script of event lists, keyed by the request text."""

    def __init__(self, script):
        self.script, self.asked, self.approvals, self.run_id = script, [], [], None

    def ask(self, text, session, started=None):
        self.asked.append((text, session))
        self.run_id = f"run{len(self.asked)}"
        script = self.script[text]
        if isinstance(script, Exception):
            raise script
        yield from script

    def approve(self, run_id, choice):
        self.approvals.append((run_id, choice))


def test_eval_live_refuses_without_yes_and_says_it_uses_the_real_agent(live, capsys):
    client = Fake({})
    assert live.main([], client=client) == 2
    out = capsys.readouterr().out
    assert "REAL Robo agent" in out and "--yes" in out
    assert client.asked == []


def test_eval_live_scores_each_request(live, tmp_path, monkeypatch, capsys):
    requests = [
        {"id": "ok", "request": "what is due"}, {"id": "streamed", "request": "plan"},
        {"id": "ask", "request": "tidy"}, {"id": "empty", "request": "ledger"},
        {"id": "failed", "request": "grades"}, {"id": "miss", "request": "explain",
                                                "match": "eigen"},
        {"id": "hit", "request": "explain 2", "match": "EIGEN"}, {"id": "down", "request": "mail"},
    ]
    path = tmp_path / "requests.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in requests))
    monkeypatch.setattr(live, "REQUESTS", path)
    done = {"event": "run.completed", "output": "Two things."}
    client = Fake({
        "what is due": [{"event": "tool.started", "tool": "browser_navigate"},
                        {"event": "message.delta", "delta": "Two"}, done],
        "plan": [{"event": "message.delta", "delta": "A plan."},
                 {"event": "run.completed"}],  # no final output: the stream counts
        "tidy": [{"event": "approval.request", "description": "Robo wants to delete 3 mails."},
                 done],
        "ledger": [{"event": "run.completed", "output": "  "}],
        "grades": [{"event": "run.failed", "error": "the agent failed: 500"}],
        "explain": [{"event": "run.completed", "output": "It is a number."}],
        "explain 2": [{"event": "run.completed", "output": "Eigenvalues scale a vector."}],
        "mail": live.ClientError("robo-agent is not running"),
    })
    assert live.main(["--yes"], client=client) == 1
    out = capsys.readouterr().out
    assert "3/8 passed" in out
    fails = {line.split()[1]: line for line in out.splitlines() if line.startswith("FAIL")}
    assert set(fails) == {"ask", "empty", "failed", "miss", "down"}
    assert "approval" in fails["ask"] and "empty reply" in fails["empty"]
    assert "failed" in fails["failed"] and "500" in fails["failed"]
    assert "/eigen/" in fails["miss"] and "not running" in fails["down"]
    assert client.approvals == [("run3", "deny")]  # an ask is denied, never approved
    assert {session for _, session in client.asked} == {client.asked[0][1]}
    assert client.asked[0][1].startswith("robo-eval-")
    assert "1 tools" in out  # the tool count of the first request


def test_eval_live_limit_runs_only_the_first_requests(live, capsys):
    items = live.load(REQUESTS)
    client = Fake({item["request"]: [{"event": "run.completed", "output": "?"}]
                   for item in items})
    assert live.main(["--yes", "--limit", "2"], client=client) == 0
    assert [text for text, _ in client.asked] == [item["request"] for item in items[:2]]
    assert "2/2 passed" in capsys.readouterr().out
