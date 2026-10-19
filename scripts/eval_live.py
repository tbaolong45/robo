"""Does the real agent answer a student's read-only requests without asking to change anything?

  uv run python scripts/eval_live.py --yes [--limit N]

Run it by hand, never from CI. It SENDS the requests in tests/evals/requests.jsonl to your REAL
Hermes agent (its own session, robo-eval-<time>), which reads your mail, Teams, Moodle and
calendar to answer; a digest takes minutes. The requests change nothing on purpose (plan and
digest ones may write a Plans note into your vault, as they always do), and an approval the agent
asks for is denied. A request passes when the run completes with a reply, the agent asked for no
approval, and the reply matches the item's optional `match` pattern. Prints a line per request,
then the score and the failures. It does not judge the quality of an answer: read the replies.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

from robo import setup
from robo.brain import BrainError, HermesClient
from robo.events import ApprovalNeeded, Delta, RunEnded, ToolStarted

REQUESTS = Path(__file__).resolve().parents[1] / "tests" / "evals" / "requests.jsonl"


def load(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def run_one(client, text: str, session: str) -> list:
    """The events of one run; an approval request is denied, so the agent changes nothing."""
    events = []
    for event in client.ask(text, session):
        events.append(event)
        if isinstance(event, ApprovalNeeded):
            client.approve(client.run_id, "deny")
    return events


def grade(item: dict, events: list) -> tuple[str, str]:
    """(reply, why it failed): the reason is empty when the request passed."""
    ended = next((e for e in reversed(events) if isinstance(e, RunEnded)), None)
    streamed = "".join(e.text for e in events if isinstance(e, Delta))
    reply = ((ended and ended.output) or streamed).strip()
    if ended is None or ended.status != "completed":
        return reply, f"run {ended.status} {ended.error}".strip() if ended else "run lost"
    if any(isinstance(e, ApprovalNeeded) for e in events):
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
        print(f"This sends {len(items)} requests to your REAL Hermes agent, which reads your mail, "
              "Teams, Moodle and calendar to answer them. Nothing is changed on purpose, but it is "
              "the live agent. Run again with --yes to go ahead.")
        return 2
    try:
        client = client or HermesClient(*setup.connection())
    except setup.SetupError as e:
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
        except BrainError as e:
            events, reply, why = [], "", f"error: {e}"
        tools = sum(isinstance(e, ToolStarted) for e in events)
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
