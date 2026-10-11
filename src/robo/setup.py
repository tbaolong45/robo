"""`robo setup`: give Hermes a `robo` profile served by the host gateway at /p/robo/.

Hermes runs one host gateway for every profile; a profile's API is the host's API server under
`/p/<profile>/`, authenticated with that profile's OWN key. So setup turns on the host API server
(loopback only), gives robo its own key, installs the persona/skills/guard and sets robo's config.
"""

from __future__ import annotations

import hashlib
import os
import re
import secrets
import subprocess
import time
from collections.abc import Callable
from pathlib import Path
from urllib.parse import urlsplit

import httpx

from robo.browser import CDP_URL

PROFILE = "robo"
TEMPLATES = Path(__file__).resolve().parents[2] / "hermes"
INSTALLED = ("SOUL.md", "skills", "plugins")  # what of TEMPLATES lands in the profile


class SetupError(RuntimeError):
    pass


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def profile_dir() -> Path:
    return hermes_home() / "profiles" / PROFILE


def persona_stamp() -> str:
    """Short hash of the installed SOUL.md and skills.

    Hermes builds a session's system prompt once, so robo starts a new session whenever this
    changes; otherwise a running day's chat would never see an updated persona or skill.
    """
    h = hashlib.sha256()
    root = profile_dir()
    for f in sorted([root / "SOUL.md", *(root / "skills").rglob("*.md")]):
        if f.is_file():
            h.update(str(f.relative_to(root)).encode() + b"\0" + f.read_bytes() + b"\0")
    return h.hexdigest()[:8]


def brave_dir() -> Path:
    """Robo's Brave profile (school logins), inside the 0700 Hermes home."""
    return profile_dir() / "brave"


def read_env(path: Path) -> dict[str, str]:
    """KEY=VALUE lines of a dotenv file (comments and bare words skipped, one level of quotes)."""
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.strip().partition("=")
        if sep and key and not key.startswith("#"):
            out[key.strip()] = value.strip().strip("'\"")
    return out


def set_env(path: Path, values: dict[str, str]) -> bool:
    """Set keys in a dotenv file in place (other lines untouched), mode 0600. True if it changed."""
    lines = path.read_text().splitlines() if path.exists() else []
    todo = dict(values)
    new = []
    for line in lines:
        key = line.partition("=")[0].strip()
        new.append(f"{key}={todo.pop(key)}" if key in todo else line)
    new += [f"{k}={v}" for k, v in todo.items()]
    text = "\n".join(new) + "\n"
    if path.exists() and path.read_text() == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.chmod(0o600)
    os.replace(tmp, path)
    return True


def connection() -> tuple[str, str]:
    """(base URL, robo key) for HermesClient; ROBO_HERMES_URL overrides the URL."""
    key = read_env(profile_dir() / ".env").get("API_SERVER_KEY")
    if not key:
        raise SetupError("Hermes has no robo profile key yet: run `robo setup` first.")
    port = read_env(hermes_home() / ".env").get("API_SERVER_PORT", "8642")
    return os.environ.get("ROBO_HERMES_URL", f"http://127.0.0.1:{port}/p/{PROFILE}"), key


def _copy_tree(src: Path, dst: Path, fill: dict[str, str]) -> bool:
    """Copy template files over the profile's, filling {{KEY}}s; True if any file changed."""
    changed = False
    files = [p for p in src.rglob("*") if p.is_file() and "__pycache__" not in p.parts
             and p.relative_to(src).parts[0] in INSTALLED]
    for f in sorted(files):
        data = f.read_bytes()
        for key, value in fill.items():
            data = data.replace(f"{{{{{key}}}}}".encode(), value.encode())
        target = dst / f.relative_to(src)
        if not target.exists() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            changed = True
    return changed


def _moodle_url(url: str) -> str:
    """The Moodle base URL, normalised; robo's browser may open only https sites."""
    parts = urlsplit(url.strip())
    if parts.scheme != "https" or not parts.hostname:
        raise SetupError(f"The Moodle address must look like https://moodle.your-school.edu, "
                         f"not {url!r}.")
    path = re.sub(r"/(?:my|login|course|calendar|mod)(?:/.*)?$", "", parts.path)  # a pasted page
    return f"https://{parts.netloc}{path}".rstrip("/")


def _run(cmd: list[str]) -> None:
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if done.returncode:
        raise SetupError(f"`{' '.join(cmd[:5])}` failed: {(done.stderr or done.stdout).strip()}")


def _wait_healthy(timeout: float = 90) -> bool:
    url, _ = connection()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            health = url.split("/p/")[0] + "/health"
            if httpx.get(health, timeout=3, trust_env=False).status_code == 200:
                return True
        except httpx.HTTPError:
            pass
        time.sleep(2)
    return False


def setup(
    templates: Path = TEMPLATES,
    config: dict[str, str] | None = None,
    run: Callable[[list[str]], None] = _run,
    wait: Callable[[], bool] = _wait_healthy,
    moodle: str | None = None,
) -> list[str]:
    """Idempotent; returns what it did. Restarts the host gateway only when something changed."""
    moodle = _moodle_url(moodle) if moodle is not None else None
    done = []
    host_env = hermes_home() / ".env"
    host = read_env(host_env)
    host_key = host.get("API_SERVER_KEY") or secrets.token_urlsafe(32)
    if set_env(host_env, {"API_SERVER_ENABLED": "true", "API_SERVER_KEY": host_key}):
        done.append("enabled the host API server on 127.0.0.1 (default profile .env)")
    created = not profile_dir().exists()
    if created:
        run(["hermes", "profile", "create", PROFILE, "--no-alias",
             "--description", "Robo desktop study buddy (robot face app)"])
        done.append("created the robo Hermes profile")
    robo_env = profile_dir() / ".env"
    if not read_env(robo_env).get("API_SERVER_KEY"):
        set_env(robo_env, {"API_SERVER_KEY": secrets.token_urlsafe(32)})
        done.append("gave robo its own API key")
    if moodle and set_env(robo_env, {"MOODLE_BASE_URL": moodle}):
        done.append(f"set your Moodle address to {moodle}")
    fill = {"MOODLE_BASE_URL": read_env(robo_env).get("MOODLE_BASE_URL") or "not set"}
    if _copy_tree(templates, profile_dir(), fill):
        done.append("installed the persona, skills and guard")
    cfg = profile_dir() / "config.yaml"
    before = cfg.read_bytes() if cfg.exists() else b""
    for key, value in (config if config is not None else CONFIG).items():
        run(["hermes", "-p", PROFILE, "config", "set", key, value])
    if (cfg.read_bytes() if cfg.exists() else b"") != before:
        done.append("updated robo's Hermes config")
    if done:
        run(["hermes", "gateway", "restart"])
        if not wait():
            raise SetupError("The Hermes gateway did not come back: check `hermes gateway status`.")
        done.append("restarted the Hermes gateway")
    return done


# robo's profile config, applied with `hermes -p robo config set` (which refuses unknown keys).
CONFIG: dict[str, str] = {
    "model.provider": "anthropic",
    "model.default": "claude-sonnet-5.5",
    # Runs arriving at /p/robo/v1/runs resolve their tools as platform "api_server": no terminal,
    # no file writes, no code execution, no page fetching outside the guarded browser ("search",
    # not "web": web_extract could post school content to any URL).
    "platform_toolsets.api_server": '["browser", "search", "skills"]',
    # Nothing a page says (e.g. a malicious email) may persist into later sessions: no memory,
    # no self-written or self-edited skills, no curator archiving robo's skills.
    "memory.memory_enabled": "false",
    "memory.user_profile_enabled": "false",
    "auxiliary.background_review.enabled": "false",
    "curator.enabled": "false",
    # "off" keeps the built-in browser_* tools that robo-guard can judge; unset would pick the
    # Browser Use `browser_exec` tool, which is hidden without the terminal toolset.
    "browser.backend": "off",
    # Robo's own Brave (robo.browser), signed in to school sites only. The user's everyday Brave
    # locks its login databases while open, so Hermes cannot borrow that profile.
    "browser.use_real_profile": "false",
    "browser.cdp_url": CDP_URL,
    "plugins.enabled": '["robo-guard"]',
}
