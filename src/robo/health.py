"""Is the Hermes gateway answering? One tiny GET now and then, reported as ok / warn / bad."""

import contextlib
import threading
from collections.abc import Callable

import httpx


class HealthPoller:
    """Polls `<gateway>/health` on a daemon thread and calls `on_state("ok" | "warn" | "bad")` from
    that thread (the app must route it through its Qt bridge). The first failure is "warn", the
    second in a row "bad"; failures re-poll after `retry` seconds, a good poll waits `every`."""

    def __init__(self, url: str, on_state: Callable[[str], None], get=httpx.get,
                 every: float = 20.0, retry: float = 5.0):
        self.health = url.split("/p/")[0] + "/health"  # as setup._wait_healthy; no key needed
        self.on_state, self.get, self.every, self.retry = on_state, get, every, retry
        self._poke, self._stop = threading.Event(), threading.Event()
        self._thread = threading.Thread(target=self._run, name="robo-health", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def poke(self) -> None:
        """Poll right now (a run just failed: don't wait out the interval)."""
        self._poke.set()

    def stop(self) -> None:
        self._stop.set()
        self._poke.set()  # wakes the wait; the thread is a daemon, so closing never blocks on it

    def _up(self) -> bool:
        try:
            return self.get(self.health, timeout=1.5, trust_env=False).status_code == 200
        except Exception:  # any failure to ask is "not up"; the poller must outlive it
            return False

    def _run(self) -> None:
        fails = 0
        while not self._stop.is_set():
            fails = 0 if self._up() else fails + 1
            if self._stop.is_set():  # the window closed during the GET
                return
            with contextlib.suppress(Exception):  # a broken listener must not end the polling
                self.on_state("ok" if not fails else "warn" if fails == 1 else "bad")
            self._poke.wait(self.retry if fails else self.every)
            self._poke.clear()
