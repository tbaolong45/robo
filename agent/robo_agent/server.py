"""robo-agent serve: the HTTP API the app's Brain.swift talks to, on 127.0.0.1 only.

POST /v1/runs {input, session_id} -> {run_id}
GET  /v1/runs/{id}/events          SSE; `id:` = the event's number, Last-Event-ID replays after it
POST /v1/runs/{id}/stop
POST /v1/runs/{id}/approval {choice: once|session|deny, request_id?} (none: the oldest ask)
GET  /health                       no key needed
Everything else needs `Authorization: Bearer <R/server_key>`. Errors are {"error": {"message"}}.
"""

from __future__ import annotations

import asyncio
import hmac
import json

from aiohttp import web

from . import harness
from .config import Config

KEEP_RUNS = 50
PING_S = 15  # Brain.swift gives up on a silent stream after 120 s
CHOICES = {"once", "session", "deny"}


def error(status: int, message: str) -> web.Response:
    return web.json_response({"error": {"message": message}}, status=status)


def make_app(cfg: Config, store, connect=None) -> web.Application:
    """`store()` gives the memory for one run (its keys are read again each run)."""
    runs: dict[str, harness.Run] = {}  # in start order
    previous: dict[str, str] = {}  # session -> last reply, for learning from corrections

    @web.middleware
    async def auth(request, handler):
        if request.path == "/health":
            return await handler(request)
        key = cfg.key("server_key", "ROBO_SERVER_KEY")
        given = request.headers.get("Authorization", "")
        if not key or not hmac.compare_digest(given.encode(), f"Bearer {key}".encode()):
            return error(401, "missing or wrong server key")
        return await handler(request)

    def find(request) -> harness.Run:
        run = runs.get(request.match_info["id"])
        if run is None:
            raise web.HTTPNotFound(text=json.dumps({"error": {"message": "no such run"}}),
                                   content_type="application/json")
        return run

    async def health(request):
        return web.json_response({"status": "ok"})

    async def start(request):
        try:
            body = await request.json()
        except ValueError:
            return error(400, "the body must be JSON")
        text, session = body.get("input"), body.get("session_id")
        if not isinstance(text, str) or not text.strip() or not isinstance(session, str):
            return error(400, "input and session_id are required strings")
        run = harness.Run(text, session)
        runs[run.id] = run
        for old in [r for r in runs.values() if r.done][: max(0, len(runs) - KEEP_RUNS)]:
            del runs[old.id]  # the oldest finished ones; a live run is never dropped
        run.task = asyncio.create_task(harness.execute(run, cfg, store(), connect, previous))
        return web.json_response({"run_id": run.id})

    async def events(request):
        run = find(request)
        try:
            seen = int(request.headers.get("Last-Event-ID", "0"))
        except ValueError:
            seen = 0
        response = web.StreamResponse(headers={"Content-Type": "text/event-stream",
                                               "Cache-Control": "no-cache"})
        await response.prepare(request)
        while True:
            while seen < len(run.events):
                event = run.events[seen]
                seen += 1
                await response.write(f"id: {seen}\ndata: {json.dumps(event)}\n\n".encode())
                if event["event"] in harness.TERMINAL:
                    return response
            before = len(run.events)
            await run.wait(seen, PING_S)
            if len(run.events) == before:
                await response.write(b": ping\n\n")

    async def stop(request):
        run = find(request)
        if run.task and not run.task.done():
            run.task.cancel()
        run.emit("run.cancelled")
        return web.json_response({"status": "stopping"})

    async def approval(request):
        run = find(request)
        try:
            body = await request.json()
        except ValueError:
            return error(400, "the body must be JSON")
        if body.get("choice") not in CHOICES:
            return error(400, "choice must be once, session or deny")
        if not run.answer(body["choice"], body.get("request_id")):
            return error(404, "no pending approval")
        return web.json_response({"status": "ok"})

    app = web.Application(middlewares=[auth])
    app.router.add_get("/health", health)
    app.router.add_post("/v1/runs", start)
    app.router.add_get("/v1/runs/{id}/events", events)
    app.router.add_post("/v1/runs/{id}/stop", stop)
    app.router.add_post("/v1/runs/{id}/approval", approval)
    return app


def serve(cfg: Config) -> None:
    from .memory import Store

    cfg.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    cfg.root.chmod(0o700)
    def store():
        return Store(cfg.root, cfg.key("supermemory_key", "SUPERMEMORY_API_KEY") or None)

    web.run_app(make_app(cfg, store), host="127.0.0.1", port=cfg.port, print=None)
