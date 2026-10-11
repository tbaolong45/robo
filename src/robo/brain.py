"""Talk to Hermes Agent over its HTTP API server (`/v1/runs` + SSE events)."""

from __future__ import annotations

import contextlib
import json
from collections.abc import Callable, Iterable, Iterator
from dataclasses import replace

import httpx

from robo.events import (
    ApprovalNeeded,
    Delta,
    Event,
    RunEnded,
    ToolCompleted,
    ToolStarted,
)
from robo.feelings import FeelingFilter, strip_tags

_TIMEOUT = httpx.Timeout(15.0, connect=3.0)
# Hermes sends a `: keepalive` comment every 10 s, so a silent 120 s means the stream is dead.
_STREAM_TIMEOUT = httpx.Timeout(15.0, connect=3.0, read=120.0)
_TERMINAL = ("run.completed", "run.failed", "run.cancelled", "run.interrupted")


class BrainError(Exception):
    """A Hermes request failed; the message is safe to show the user."""


class HermesClient:
    """Minimal client for one Hermes API server."""

    def __init__(self, base_url: str, key: str, client: httpx.Client | None = None) -> None:
        self._base = base_url.rstrip("/")
        self._auth = {"Authorization": f"Bearer {key}"}
        # trust_env=False: a proxy from the environment must never see the key
        self._http = client or httpx.Client(timeout=_TIMEOUT, trust_env=False)
        self.run_id: str | None = None  # the latest run started by `ask`, for stop/approve

    def start_run(self, text: str, session_id: str) -> str:
        body = {"input": text, "session_id": session_id}
        return self._request("POST", "/v1/runs", body).json()["run_id"]

    def stop(self, run_id: str) -> None:
        self._request("POST", f"/v1/runs/{run_id}/stop")

    def approve(self, run_id: str, choice: str) -> None:
        """Answer a pending approval: "once", "session" (the same action, rest of the session)
        or "deny". Never "always": that would allowlist the action for every future session."""
        if choice not in ("once", "session", "deny"):
            raise ValueError(f"unsupported approval choice {choice!r}")
        self._request("POST", f"/v1/runs/{run_id}/approval", {"choice": choice})

    def events(self, run_id: str) -> Iterator[Event]:
        """Yield the run's events; always ends with exactly one `RunEnded`.

        A dropped stream is resumed once from the last event id (Hermes replays the rest). If
        that fails too the run is stopped, so it never keeps going with nobody watching.
        """
        url = f"{self._base}/v1/runs/{run_id}/events"
        last: str | None = None
        for _ in range(2):
            headers = {**self._auth, **({"Last-Event-ID": last} if last else {})}
            try:
                with self._http.stream("GET", url, headers=headers, timeout=_STREAM_TIMEOUT) as r:
                    _check(r)
                    for seq, data in _sse(r.iter_lines()):
                        event = _parse(json.loads(data))
                        last = seq or last
                        if event is not None:
                            yield event
                        if isinstance(event, RunEnded):
                            return
                error = "Hermes stream ended without a result"
            except BrainError as e:  # an error response: retrying would get the same
                yield RunEnded("failed", error=str(e))
                return
            except (httpx.HTTPError, ValueError) as e:
                error = _describe(e)
        with contextlib.suppress(BrainError):
            self.stop(run_id)
        yield RunEnded("failed", error=error)

    def ask(self, text: str, session_id: str,
            started: Callable[[str], None] | None = None) -> Iterator[Event]:
        """Start a run and yield its events with feel tags split into `Feeling`s.

        `started(run_id)` is called as soon as the run exists, before any event arrives.
        """
        self.run_id = None
        self.run_id = self.start_run(text, session_id)
        if started:
            started(self.run_id)
        feel = FeelingFilter()
        for event in self.events(self.run_id):
            if isinstance(event, Delta):
                yield from feel.feed(event.text)
            elif isinstance(event, RunEnded):
                yield from feel.finish()
                yield replace(event, output=strip_tags(event.output))
            else:
                yield event

    def _request(self, method: str, path: str, body: dict | None = None) -> httpx.Response:
        try:
            r = self._http.request(method, self._base + path, headers=self._auth, json=body)
        except httpx.HTTPError as e:
            raise BrainError(_describe(e)) from None
        _check(r)
        return r


def _describe(e: Exception) -> str:
    if isinstance(e, httpx.ConnectError):
        return "Hermes is not running (connection refused)"
    if isinstance(e, httpx.TimeoutException):
        return "Hermes timed out"
    if isinstance(e, ValueError):
        return "Hermes sent malformed data"
    return f"Hermes connection failed ({type(e).__name__})"


def _check(r: httpx.Response) -> None:
    """Raise `BrainError` for an error response."""
    if r.status_code == 401:
        raise BrainError("Hermes rejected the API key (401)")
    if r.is_error:
        r.read()
        try:
            detail = r.json()["error"]["message"]
        except (ValueError, KeyError, TypeError):
            detail = r.reason_phrase
        raise BrainError(f"Hermes error {r.status_code}: {detail}")


def _sse(lines: Iterable[str]) -> Iterator[tuple[str | None, str]]:
    """Yield (id, data) for each complete SSE event; comments are skipped."""
    seq: str | None = None
    data: list[str] = []
    for line in lines:
        if not line:
            if data:
                yield seq, "\n".join(data)
            seq, data = None, []
        elif line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
        elif line.startswith("id:"):
            seq = line[3:].strip()


def _parse(d: dict) -> Event | None:
    """Map one Hermes run event to a robo event (None for ones robo ignores)."""
    match name := d.get("event"):
        case "message.delta":
            return Delta(d.get("delta") or "")
        case "tool.started":
            return ToolStarted(d.get("tool") or "")
        case "tool.completed":
            return ToolCompleted(d.get("tool") or "", bool(d.get("error")))
        case "approval.request":
            return ApprovalNeeded(d.get("description") or d.get("command") or "")
        case _ if name in _TERMINAL:
            return RunEnded(name.removeprefix("run."), output=d.get("output") or "",
                            error=d.get("error") or "")
    return None
