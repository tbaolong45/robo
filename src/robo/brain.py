"""Talk to Hermes Agent over its HTTP API server (`/v1/runs` + SSE events)."""

from __future__ import annotations

import json
from collections.abc import Iterable, Iterator
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
        self._http = client or httpx.Client(timeout=_TIMEOUT)
        self.run_id: str | None = None  # the latest run started by `ask`, for stop/approve

    def health(self) -> bool:
        try:
            return self._request("GET", "/health").status_code == 200
        except BrainError:
            return False

    def start_run(self, text: str, session_id: str) -> str:
        body = {"input": text, "session_id": session_id}
        return self._request("POST", "/v1/runs", body).json()["run_id"]

    def stop(self, run_id: str) -> None:
        self._request("POST", f"/v1/runs/{run_id}/stop")

    def approve(self, run_id: str, allow: bool) -> None:
        self._request("POST", f"/v1/runs/{run_id}/approval",
                          {"choice": "once" if allow else "deny"})

    def events(self, run_id: str) -> Iterator[Event]:
        """Yield the run's events; always ends with exactly one `RunEnded`."""
        url = f"{self._base}/v1/runs/{run_id}/events"
        try:
            with self._http.stream("GET", url, headers=self._auth, timeout=_STREAM_TIMEOUT) as r:
                _check(r)
                for data in _sse_data(r.iter_lines()):
                    event = _parse(json.loads(data))
                    if event is not None:
                        yield event
                    if isinstance(event, RunEnded):
                        return
        except BrainError as e:
            yield RunEnded("failed", error=str(e))
            return
        except (httpx.HTTPError, ValueError) as e:
            yield RunEnded("failed", error=_describe(e))
            return
        yield RunEnded("failed", error="Hermes stream ended without a result")

    def ask(self, text: str, session_id: str) -> Iterator[Event]:
        """Start a run and yield its events with feel tags split into `Feeling`s."""
        self.run_id = self.start_run(text, session_id)
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


def _sse_data(lines: Iterable[str]) -> Iterator[str]:
    """Yield each complete SSE event's data; comments and `id:` lines are skipped."""
    data: list[str] = []
    for line in lines:
        if not line:
            if data:
                yield "\n".join(data)
                data = []
        elif line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))


def _parse(d: dict) -> Event | None:
    """Map one Hermes run event to a robo event (None for ones robo ignores)."""
    match name := d.get("event"):
        case "message.delta":
            return Delta(d.get("delta") or "")
        case "tool.started":
            return ToolStarted(d.get("tool") or "", d.get("preview") or "")
        case "tool.completed":
            return ToolCompleted(d.get("tool") or "", float(d.get("duration") or 0),
                                 bool(d.get("error")))
        case "approval.request":
            return ApprovalNeeded(d.get("description") or d.get("command") or "")
        case _ if name in _TERMINAL:
            return RunEnded(name.removeprefix("run."), output=d.get("output") or "",
                            error=d.get("error") or "")
    return None
