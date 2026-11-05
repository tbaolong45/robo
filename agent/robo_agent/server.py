"""robo-agent serve: the HTTP API the app's Brain.swift talks to, on 127.0.0.1 only.

POST /v1/runs {input, session_id} -> {run_id}
GET  /v1/runs/{id}/events          SSE; `id:` = the event's number, Last-Event-ID replays after it
POST /v1/runs/{id}/stop
GET  /health                       no key needed
Everything else needs `Authorization: Bearer <R/server_key>`. Errors are {"error": {"message"}}.
"""

from __future__ import annotations

import asyncio
import hmac
import json

from aiohttp import web

from . import chat
from .config import Config

KEEP_RUNS = 50
PING_S = 15  # Brain.swift gives up on a silent stream after 120 s


def error(status: int, message: str) -> web.Response:
    return web.json_response({"error": {"message": message}}, status=status)


def make_app(cfg: Config) -> web.Application:
    runs: dict[str, chat.Run] = {}  # in start order
    histories: dict[str, list[dict]] = {}  # session -> its messages so far

    @web.middleware
    async def auth(request, handler):
        if request.path == "/health":
            return await handler(request)
        key = cfg.key("server_key", "ROBO_SERVER_KEY")
        given = request.headers.get("Authorization", "")
        if not key or not hmac.compare_digest(given.encode(), f"Bearer {key}".encode()):
            return error(401, "missing or wrong server key")
        return await handler(request)

    def find(request) -> chat.Run:
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
        run = chat.Run(text, session)
        runs[run.id] = run
        for old in [r for r in runs.values() if r.done][: max(0, len(runs) - KEEP_RUNS)]:
            del runs[old.id]  # the oldest finished ones; a live run is never dropped
        run.task = asyncio.create_task(chat.execute(run, cfg, histories))
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
                if event["event"] in chat.TERMINAL:
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

    app = web.Application(middlewares=[auth])
    app.router.add_get("/health", health)
    app.router.add_post("/v1/runs", start)
    app.router.add_get("/v1/runs/{id}/events", events)
    app.router.add_post("/v1/runs/{id}/stop", stop)
    return app


def serve(cfg: Config) -> None:
    cfg.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    cfg.root.chmod(0o700)
    web.run_app(make_app(cfg), host="127.0.0.1", port=cfg.port, print=None)
