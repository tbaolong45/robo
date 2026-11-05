"""One reply: the session's history and the new text go to DeepSeek, and the answer comes back as
run events. This is the whole brain for now, and the place a harness plugs in later: anything that
emits `message.delta` and ends a run the same way works with the app, unchanged.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import uuid

import anthropic

from .config import API_BASE, Config, soul

TERMINAL = {"run.completed", "run.failed", "run.cancelled"}
MAX_TOKENS = 8192
# ponytail: history lives in memory and is cut at this length; a harness owns real memory.
MAX_MESSAGES = 100


class Run:
    """One request's events, replayed to any reader."""

    def __init__(self, text: str, session_id: str):
        self.id = "run_" + uuid.uuid4().hex
        self.input, self.session_id = text, session_id
        self.events: list[dict] = []
        self.task: asyncio.Task | None = None
        self._tick = asyncio.Event()

    @property
    def done(self) -> bool:
        return bool(self.events) and self.events[-1]["event"] in TERMINAL

    def emit(self, event: str, **fields) -> None:
        if self.done:
            return
        self.events.append({"event": event, "run_id": self.id, **fields})
        self._tick.set()
        self._tick = asyncio.Event()

    async def wait(self, seen: int, timeout: float) -> None:
        """Until there are more than `seen` events, or `timeout` seconds."""
        tick = self._tick
        if len(self.events) <= seen:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(tick.wait(), timeout)


def client(key: str) -> anthropic.AsyncAnthropic:
    """DeepSeek's Anthropic-format API. ANTHROPIC_BASE_URL reroutes it, for tests. Both credentials
    are set, or the client fills the missing one from a real Anthropic key in the environment."""
    return anthropic.AsyncAnthropic(api_key=key, auth_token=key,
                                    base_url=os.environ.get("ANTHROPIC_BASE_URL") or API_BASE)


async def execute(run: Run, cfg: Config, histories: dict[str, list[dict]]) -> None:
    """Run one request to its end event. The turn joins the history only when it completes."""
    key = cfg.key("api_key", "DEEPSEEK_API_KEY")
    if not key:
        run.emit("run.failed", error="no DeepSeek API key: run `robo key set deepseek` in "
                 "Terminal and ask again.")
        return
    history = histories.setdefault(run.session_id, [])
    turn = {"role": "user", "content": run.input}
    reply = ""
    try:
        async with client(key).messages.stream(
                model=cfg.model, max_tokens=MAX_TOKENS, system=soul(), messages=[*history, turn],
                thinking={"type": "disabled"}) as stream:
            async for text in stream.text_stream:
                reply += text
                run.emit("message.delta", delta=text)
            # a dropped connection can end the stream quietly: only a whole reply has a stop reason
            if reply and not (await stream.get_final_message()).stop_reason:
                raise ConnectionError("the reply was cut off")
    except asyncio.CancelledError:
        run.emit("run.cancelled")
        raise
    except Exception as e:
        run.emit("run.failed", error=f"DeepSeek failed: {e}")
        return
    if not reply.strip():  # kept, it would be an empty message on every later turn of the session
        run.emit("run.failed", error="DeepSeek sent an empty reply. Try asking again.")
        return
    history += [turn, {"role": "assistant", "content": reply}]
    del history[:-MAX_MESSAGES]
    run.emit("run.completed", output=reply)
