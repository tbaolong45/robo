"""Does the real agent answer a student's read-only requests without asking to change anything?

  uv run python scripts/eval_live.py --yes [--limit N]

Run it by hand, never from CI. It SENDS the requests in tests/evals/requests.jsonl to your REAL
agent (robo-agent serve, its own session robo-eval-<time>), which reads your mail, Teams, Moodle
and calendar to answer, on your Anthropic API key; a digest takes minutes. The requests change
nothing on purpose, and an approval the agent asks for is denied (it only asks in approvals
"manual"). A request passes when the run completes with a reply, the agent asked for no approval,
and the reply matches the item's optional `match` pattern. Prints a line per request, then the
score and the failures. It does not judge the quality of an answer: read the replies.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUESTS = ROOT / "tests" / "evals" / "requests.jsonl"


class ClientError(Exception):
    pass


class Client:
    """A small client of robo-agent serve (the same API as the app's Brain.swift)."""

    def __init__(self, base: str, key: str):
        self.base, self.key, self.run_id = base, key, None

    def _open(self, method: str, path: str, body: dict | None = None, timeout: float = 15):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as e:
            raise ClientError(f"robo-agent error {e.code}") from e
        except OSError as e:
            raise ClientError(f"robo-agent is not running ({e})") from e

    def ask(self, text: str, session: str):
        """The events of one run, as dicts."""
        with self._open("POST", "/v1/runs", {"input": text, "session_id": session}) as r:
            self.run_id = json.load(r)["run_id"]
        with self._open("GET", f"/v1/runs/{self.run_id}/events", timeout=600) as stream:
            for line in stream:
                if line.startswith(b"data: "):
                    event = json.loads(line[6:])
                    yield event
                    if event["event"] in ("run.completed", "run.failed", "run.cancelled"):
                        return

    def approve(self, run_id: str, choice: str) -> None:
        self._open("POST", f"/v1/runs/{run_id}/approval", {"choice": choice}).close()


def connect() -> Client:
    sys.path.insert(0, str(ROOT / "agent"))
    from robo_agent import config

    cfg = config.load()
    key = cfg.key("server_key", "ROBO_SERVER_KEY")
    if not key:
        raise ClientError("no server key: start Robo once so it writes one")
    return Client(f"http://127.0.0.1:{cfg.port}", key)


def load(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def run_one(client, text: str, session: str) -> list[dict]:
    """The events of one run; an approval request is denied, so the agent changes nothing."""
    events = []
    for event in client.ask(text, session):
        events.append(event)
        if event["event"] == "approval.request":
            client.approve(client.run_id, "deny")
    return events


def grade(item: dict, events: list[dict]) -> tuple[str, str]:
    """(reply, why it failed): the reason is empty when the request passed."""
    ended = next((e for e in reversed(events) if e["event"].startswith("run.")), None)
    streamed = "".join(e.get("delta", "") for e in events if e["event"] == "message.delta")
    reply = ((ended and ended.get("output")) or streamed).strip()
    if ended is None or ended["event"] != "run.completed":
        if ended is None:
            return reply, "run lost"
        return reply, f"run {ended['event'][4:]} {ended.get('error', '')}".strip()
    if any(e["event"] == "approval.request" for e in events):
        return reply, "asked for approval on a read-only request"
    if not reply:
        return reply, "empty reply"
    if item.get("match") and not re.search(item["match"], reply, re.IGNORECASE):
        return reply, f"reply does not match /{item['match']}/"
    return reply, ""


def main(argv: list[str] | None = None, client=None) -> int:
    parser = argparse.ArgumentParser(description="Send tests/evals/requests.jsonl to the agent.")
    parser.add_argument("--yes", action="store_true", help="really send them to the live agent")
    parser.add_argument("--limit", type=int, help="only the first N requests")
    args = parser.parse_args(argv)
    items = load(REQUESTS)[: args.limit]
    if not args.yes:
        print(f"This sends {len(items)} requests to your REAL Robo agent, which reads your mail, "
              "Teams, Moodle and calendar to answer them, on your Anthropic API key. Nothing is "
              "changed on purpose, but it is the live agent. Run again with --yes to go ahead.")
        return 2
    try:
        client = client or connect()
    except ClientError as e:
        print(f"robo: {e}", file=sys.stderr)
        return 1
    session = time.strftime("robo-eval-%Y%m%d-%H%M%S")
    print(f"sending {len(items)} requests to the live agent as session {session}")
    failed = []
    for item in items:
        start = time.monotonic()
        try:
            events = run_one(client, item["request"], session)
            reply, why = grade(item, events)
        except ClientError as e:
            events, reply, why = [], "", f"error: {e}"
        tools = sum(e["event"] == "tool.started" for e in events)
        shown = " ".join(reply.split())[:80]
        note = f"  <- {why}" if why else ""
        print(f"{'BAD' if why else 'ok '} {item['id']:16} {time.monotonic() - start:5.1f}s "
              f"{tools:2d} tools | {item['request']!r} -> {shown!r}{note}")
        if why:
            failed.append((item["id"], why))
    print(f"\n{len(items) - len(failed)}/{len(items)} passed")
    for name, why in failed:
        print(f"FAIL {name:16} {why}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
