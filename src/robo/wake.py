"""First-wake-of-the-day trigger: a persisted digest date, a resume watcher (login1 on Linux, a
clock gap elsewhere), a net wait."""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Protocol

log = logging.getLogger(__name__)


class DigestClock:
    """Remembers the local date of the last digest in a 0600 JSON file."""

    def __init__(self, path: Path):
        self.path = Path(path)

    def due(self, today: date) -> bool:
        try:
            return date.fromisoformat(json.loads(self.path.read_text())["last_digest"]) != today
        except (OSError, ValueError, KeyError, TypeError):
            return True

    def mark(self, today: date) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".digest-")  # mkstemp: 0600
        try:
            with os.fdopen(fd, "w") as f:
                json.dump({"last_digest": today.isoformat()}, f)
            os.replace(tmp, self.path)
        except BaseException:
            os.unlink(tmp)
            raise


class SleepSource(Protocol):
    def recv(self, timeout: float) -> bool | None: ...  # PrepareForSleep flag, None on timeout
    def close(self) -> None: ...


class Login1:
    """PrepareForSleep(b) from org.freedesktop.login1 on the system bus (jeepney, blocking)."""

    def __init__(self):
        from jeepney import MatchRule, message_bus
        from jeepney.io.blocking import open_dbus_connection
        from jeepney.wrappers import unwrap_msg

        rule = MatchRule(type="signal", interface="org.freedesktop.login1.Manager",
                         member="PrepareForSleep", path="/org/freedesktop/login1")
        self.conn = open_dbus_connection(bus="SYSTEM")
        try:
            unwrap_msg(self.conn.send_and_get_reply(message_bus.AddMatch(rule), timeout=5))
        except BaseException:
            self.conn.close()
            raise
        self.handle = self.conn.filter(rule, bufsize=8)

    def recv(self, timeout: float) -> bool | None:
        try:
            return bool(self.conn.recv_until_filtered(self.handle.queue, timeout=timeout).body[0])
        except TimeoutError:
            return None

    def close(self) -> None:
        self.conn.close()


GAP_S = 60  # wall time this far ahead of awake time: the machine slept


class ClockGap:
    """A SleepSource for any OS: monotonic time stops while the machine sleeps, wall time
    does not, so a jump between them after a short wait is a resume."""

    def __init__(self, wall: Callable[[], float] = time.time,
                 awake: Callable[[], float] = time.monotonic,
                 wait: Callable[[float], None] = time.sleep):
        self.wall, self.awake, self.wait = wall, awake, wait
        self._last = (wall(), awake())

    def recv(self, timeout: float) -> bool | None:
        self.wait(timeout)
        now = (self.wall(), self.awake())
        slept = (now[0] - self._last[0]) - (now[1] - self._last[1])
        self._last = now
        return False if slept > GAP_S else None

    def close(self) -> None:
        pass


class WakeWatcher:
    """Calls `on_resume()` from a daemon thread each time the machine wakes from sleep."""

    def __init__(self, on_resume: Callable[[], None],
                 connect: Callable[[], SleepSource] | None = None, poll: float = 0.5,
                 retry: float = 10.0):
        self.on_resume, self.poll, self.retry = on_resume, poll, retry
        self.connect = connect or (Login1 if sys.platform == "linux" else ClockGap)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        """Subscribe; False (logged at info) when the system bus is unavailable."""
        try:
            src = self.connect()
        except Exception as e:  # no system bus, no login1, sandbox…
            log.info("resume watcher off: %s", e)
            return False
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, args=(src,), daemon=True,
                                        name="robo-wake")
        self._thread.start()
        return True

    def _run(self, src: SleepSource | None) -> None:
        while not self._stop.is_set():
            try:
                src = src or self.connect()
                if src.recv(self.poll) is False:  # False = resumed
                    try:
                        self.on_resume()
                    except Exception:
                        log.exception("on_resume failed")
            except Exception as e:  # the bus went away: reconnect after a pause
                log.info("resume watcher lost the bus, retrying: %s", e)
                if src:
                    src.close()
                src = None
                self._stop.wait(self.retry)
        if src:
            src.close()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(self.poll + 2)


def wait_for_network(probe: Callable[[], bool], timeout: float = 60, interval: float = 2,
                     sleep: Callable[[float], None] = time.sleep) -> bool:
    """Probe every `interval` s until it returns True (True) or `timeout` s pass (False)."""
    waited = 0.0
    while True:
        try:
            if probe():
                return True
        except Exception:
            pass
        if waited >= timeout:
            return False
        sleep(interval)
        waited += interval
