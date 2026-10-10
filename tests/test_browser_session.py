"""The browser session: one profile, one owner, no real browser in the tests.

Two rules in this module are load-bearing and neither is visible from a passing
run, so they are pinned here:

* **The profile is created private, every time.** It holds live session cookies
  for a university account. `mkdir(mode=0o700)` does nothing to a directory that
  already exists, so the chmod is the only thing that tightens a profile created
  by an older build - and a test that only checks a fresh directory would pass
  while every real upgrade stayed world-readable.
* **"Not signed in" is not "the page changed".** Both arrive as a failure to read
  a calendar, and they need opposite responses. `SessionError` means the saved
  session expired and has to be re-established; anything else means the page
  moved.

No browser is launched and no network is touched: Playwright is replaced at its
import seam with a hand-written fake, which is also the only way to observe what
`launch_persistent_context` was actually asked to do.
"""

from __future__ import annotations

import importlib
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from pli.browser import SessionError
from pli.browser import session as session_module
from pli.browser.session import (
    _is_app_url,
    _looks_like_sign_in,
    login,
    logout,
    profile_is_ready,
    require_signed_in,
    session,
    status,
)
from pli.config import REPO_ROOT, Settings

# --- fakes --------------------------------------------------------------------------


class _FakePage:
    """Enough of a Playwright Page to drive `login` and detect a sign-in wall."""

    def __init__(
        self,
        *,
        url: str = "about:blank",
        url_after_goto: str | None = None,
        identity: object = "Ada Lovelace",
        fail_wait: bool = False,
    ) -> None:
        self._url = url
        self.url_after_goto = url_after_goto
        self.identity = identity
        self.fail_wait = fail_wait
        self.goto_calls: list[str] = []
        self.evaluate_calls: list[object] = []
        self.wait_calls: list[float] = []

    @property
    def url(self) -> str:
        return self._url

    def goto(self, url: str, **kwargs: object) -> None:
        self.goto_calls.append(url)
        if self.url_after_goto is not None:
            self._url = self.url_after_goto

    def wait_for_url(self, predicate, *, timeout: float) -> None:
        self.wait_calls.append(timeout)
        if self.fail_wait or not predicate(self._url):
            raise RuntimeError(f"Timeout {timeout}ms exceeded.")

    def evaluate(self, script: object, *args: object) -> object:
        self.evaluate_calls.append(script)
        return self.identity


class _FakeContext:
    """A persistent context: a list of pages that closes exactly once."""

    def __init__(self, pages: list[_FakePage] | None = None) -> None:
        self.pages = pages if pages is not None else [_FakePage()]
        self.closed = False
        self.opened = 0

    def new_page(self) -> _FakePage:
        self.opened += 1
        page = _FakePage()
        self.pages.append(page)
        return page

    def close(self) -> None:
        self.closed = True


class _FakeChromium:
    """Records the launch arguments, so the profile and flags can be asserted."""

    def __init__(self, context: _FakeContext | None = None, error: Exception | None = None):
        self.context = context if context is not None else _FakeContext()
        self.error = error
        self.launches: list[dict] = []

    def launch_persistent_context(self, **kwargs: object) -> _FakeContext:
        self.launches.append(kwargs)
        if self.error is not None:
            raise self.error
        return self.context

    @property
    def last_launch(self) -> dict:
        assert self.launches, "launch_persistent_context was never called"
        return self.launches[-1]


class _FakePlaywright:
    def __init__(self, chromium: _FakeChromium) -> None:
        self.chromium = chromium
        self.stopped = False

    def stop(self) -> None:
        self.stopped = True


class _FakeStarter:
    """Stands in for the object `sync_playwright()` returns, before `.start()`."""

    def __init__(self, handle: _FakePlaywright) -> None:
        self._handle = handle

    def start(self) -> _FakePlaywright:
        return self._handle


def _install(monkeypatch, chromium: _FakeChromium) -> _FakePlaywright:
    """Point the module's import seam at a fake driver. Returns the handle."""
    handle = _FakePlaywright(chromium)
    monkeypatch.setattr(
        session_module, "_import_sync_playwright", lambda: lambda: _FakeStarter(handle)
    )
    return handle


def _settings(tmp_path: Path, **kwargs: object) -> Settings:
    return Settings(
        _env_file=None, browser_profile=tmp_path / "profile", pli_home=tmp_path, **kwargs
    )


def _signed_in_page(**kwargs: object) -> _FakePage:
    """A page that has already arrived at Outlook by the time `login` waits."""
    kwargs.setdefault("url_after_goto", "https://outlook.office.com/mail/inbox")
    return _FakePage(**kwargs)


# --- URL classification --------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=abc",
        "https://login.microsoftonline.com/common/SAS/ProcessAuth",
        "https://login.microsoftonline.com/common/pickaccount?username=student",
        "https://login.microsoftonline.com/kmsi",
        "https://login.live.com/oauth20_authorize.srf?client_id=abc",
        "https://login.microsoft.com/common/login",
        "https://adfs.uni.example/adfs/ls/?SAMLRequest=x",
    ],
)
def test_a_sign_in_wall_is_recognised(url):
    assert _looks_like_sign_in(url)


@pytest.mark.parametrize(
    "url",
    [
        "https://outlook.office.com/calendar/view/week",
        "https://outlook.office.com/mail/inbox",
        "https://outlook.office365.com/owa/",
        "https://teams.microsoft.com/v2/?ctx=channels",
        "https://login.microsoftonline.com.evil.example/steal",  # not actually Microsoft
        "",
        "about:blank",
    ],
)
def test_an_application_page_is_not_mistaken_for_a_sign_in_wall(url):
    assert not _looks_like_sign_in(url)


def test_an_ordinary_query_string_does_not_look_like_a_login():
    """`login_hint` is on half of Microsoft's own app URLs; the host is what counts."""
    assert not _looks_like_sign_in("https://outlook.office.com/calendar/view/week?login_hint=a@b.c")


def test_the_app_url_check_is_stricter_than_the_sign_in_check():
    """`login` must not return while the user is still on their university's SSO page."""
    assert not _is_app_url("https://adfs.uni.example/adfs/ls/")
    assert not _is_app_url("about:blank")
    assert _is_app_url("https://outlook.office.com/mail/inbox")


def test_a_check_that_finds_a_wall_explains_how_to_sign_in():
    with pytest.raises(SessionError, match="BROWSER_HEADLESS=false"):
        require_signed_in(_FakePage(url="https://login.microsoftonline.com/common/oauth2/v2.0"))


def test_the_sign_in_message_names_the_host_and_not_the_oauth_query():
    """A live run printed the whole authorize URL: a screen and a half of
    client_id, nonce and code_challenge that buried the one sentence the user
    needed. The host is the entire diagnosis, so the query string is dropped."""
    wall = (
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        "?client_id=9199bf20&scope=https%3A%2F%2Foutlook.office.com&nonce=01a0e8a9"
        "&code_challenge=R9MAWe1fTBklOWN1&response_type=code"
    )

    with pytest.raises(SessionError) as raised:
        require_signed_in(_FakePage(url=wall))

    message = str(raised.value)
    assert "https://login.microsoftonline.com/common/oauth2/v2.0/authorize" in message
    assert "client_id" not in message
    assert "code_challenge" not in message
    assert "?" not in message


def test_a_signed_in_page_passes_the_check():
    require_signed_in(_FakePage(url="https://outlook.office.com/calendar/view/week"))


# --- session() ------------------------------------------------------------------------


def test_session_yields_the_contexts_page(monkeypatch, tmp_path):
    context = _FakeContext([_FakePage(url="https://outlook.office.com/mail/inbox")])
    _install(monkeypatch, _FakeChromium(context))

    with session(_settings(tmp_path)) as page:
        assert page is context.pages[0]


def test_session_closes_the_context_and_stops_the_driver(monkeypatch, tmp_path):
    context = _FakeContext()
    handle = _install(monkeypatch, _FakeChromium(context))

    with session(_settings(tmp_path)):
        pass

    assert context.closed
    assert handle.stopped


def test_session_closes_the_context_when_the_body_raises(monkeypatch, tmp_path):
    """A crashed read must still flush cookies to the profile."""
    context = _FakeContext()
    handle = _install(monkeypatch, _FakeChromium(context))

    with pytest.raises(ValueError, match="body exploded"), session(_settings(tmp_path)):
        raise ValueError("body exploded")

    assert context.closed
    assert handle.stopped


def test_session_closes_the_context_when_the_page_is_a_wall(monkeypatch, tmp_path):
    context = _FakeContext([_FakePage(url="https://login.microsoftonline.com/common/login")])
    _install(monkeypatch, _FakeChromium(context))

    with pytest.raises(SessionError, match="BROWSER_HEADLESS=false"), session(_settings(tmp_path)):
        raise AssertionError("the body must not run on a sign-in wall")

    assert context.closed


def test_session_opens_a_page_when_the_profile_restored_none(monkeypatch, tmp_path):
    """A reused profile can come up with no tabs at all."""
    context = _FakeContext([])
    _install(monkeypatch, _FakeChromium(context))

    with session(_settings(tmp_path)) as page:
        assert page in context.pages

    assert context.opened == 1


def test_session_is_headless_by_default(monkeypatch, tmp_path):
    chromium = _FakeChromium()
    _install(monkeypatch, chromium)

    with session(_settings(tmp_path, browser_headless=True)):
        pass

    assert chromium.last_launch["headless"] is True


def test_the_headless_argument_beats_the_setting(monkeypatch, tmp_path):
    chromium = _FakeChromium()
    _install(monkeypatch, chromium)

    with session(_settings(tmp_path, browser_headless=True), headless=False):
        pass

    assert chromium.last_launch["headless"] is False


def test_the_launch_gets_the_profile_the_user_agent_and_the_slowdown(monkeypatch, tmp_path):
    chromium = _FakeChromium()
    _install(monkeypatch, chromium)
    settings = _settings(tmp_path, browser_headless=True, browser_slow_mo_ms=250)

    with session(settings):
        pass

    launch = chromium.last_launch
    assert launch["user_data_dir"] == str(settings.profile_dir)
    assert launch["slow_mo"] == 250
    assert "HeadlessChrome" not in launch["user_agent"]
    # A narrow window gets the collapsed mobile layout, and every selector in
    # browser.toml misses.
    assert launch["viewport"]["width"] >= 1280


def test_a_context_that_will_not_start_is_a_session_error(monkeypatch, tmp_path):
    _install(monkeypatch, _FakeChromium(error=RuntimeError("Target page closed")))

    with (
        pytest.raises(SessionError, match="could not open the profile"),
        session(_settings(tmp_path)),
    ):
        pass


def test_a_missing_chromium_binary_names_the_install_command(monkeypatch, tmp_path):
    """The most likely first failure on a new machine needs the exact fix."""
    missing = RuntimeError("Executable doesn't exist at /root/.cache/ms-playwright/chromium/chrome")
    _install(monkeypatch, _FakeChromium(error=missing))

    with (
        pytest.raises(SessionError, match="uv run playwright install chromium"),
        session(_settings(tmp_path)),
    ):
        pass


def test_a_missing_playwright_is_a_session_error_not_an_import_crash(monkeypatch, tmp_path):
    monkeypatch.setitem(sys.modules, "playwright.sync_api", None)

    with (
        pytest.raises(SessionError, match="playwright install chromium"),
        session(_settings(tmp_path)),
    ):
        pass


def test_the_module_imports_on_a_box_without_playwright(monkeypatch):
    """`pli status` and the whole test suite must run with no browser installed."""
    import builtins

    real_import = builtins.__import__

    def blocked(name, *args, **kwargs):
        if name.split(".")[0] == "playwright":
            raise ImportError("no playwright here")
        return real_import(name, *args, **kwargs)

    original = sys.modules.get("pli.browser.session")
    monkeypatch.setattr(builtins, "__import__", blocked)
    monkeypatch.delitem(sys.modules, "pli.browser.session", raising=False)
    try:
        reimported = importlib.import_module("pli.browser.session")
    finally:
        monkeypatch.setitem(sys.modules, "pli.browser.session", original)

    assert callable(reimported.login)


# --- the profile directory --------------------------------------------------------------


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def test_a_fresh_profile_directory_is_private(monkeypatch, tmp_path):
    settings = _settings(tmp_path)
    _install(monkeypatch, _FakeChromium())

    with session(settings):
        pass

    assert _mode(settings.profile_dir) == 0o700


def test_an_existing_profile_directory_is_tightened_on_every_launch(monkeypatch, tmp_path):
    """`mkdir(mode=...)` cannot fix a directory that already exists."""
    settings = _settings(tmp_path)
    settings.profile_dir.mkdir(parents=True, exist_ok=True)
    settings.profile_dir.chmod(0o755)
    _install(monkeypatch, _FakeChromium())

    with session(settings):
        pass

    assert _mode(settings.profile_dir) == 0o700


def test_a_profile_that_cannot_be_secured_is_a_session_error(monkeypatch, tmp_path):
    settings = _settings(tmp_path)
    _install(monkeypatch, _FakeChromium())

    def refuse(self, mode=None):
        raise OSError("operation not permitted")

    monkeypatch.setattr(Path, "chmod", refuse)

    with pytest.raises(SessionError, match="(?i)could not create or secure"), session(settings):
        pass


# --- the profile must never be committed -------------------------------------------------


def _default_profile_dir() -> Path:
    """The profile path a fresh checkout gets, whatever this shell has exported.

    Read from the field default rather than from a built `Settings`, so a
    developer who has `BROWSER_PROFILE` exported still tests the path every
    other checkout will use - the one `.gitignore` has to cover.
    """
    declared = Settings.model_fields["browser_profile"].default
    return declared if declared.is_absolute() else REPO_ROOT / declared


def test_gitignore_names_the_browser_profile():
    """A committed profile is a handed-over university account.

    It holds LIVE session cookies, so this is checked against the file itself and
    not through `git check-ignore`, which the `/data/` blanket above it would
    answer on its own: the profile is named again precisely so the rule survives
    a change to that one, and a test that only asked git would pass with the line
    deleted - which is exactly how it was found missing.
    """
    ignored = {
        # The surrounding slashes are how a pattern is anchored, not part of the
        # path it names, so `/data/browser/` and `data/browser` are one rule.
        line.strip().strip("/")
        for line in (REPO_ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }

    assert str(_default_profile_dir().relative_to(REPO_ROOT)) in ignored


def test_git_refuses_to_track_the_browser_profile():
    """The end-to-end half: git itself will not stage the profile directory."""
    profile = _default_profile_dir()

    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "check-ignore", "-q", "--no-index", str(profile)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, f"git would track the profile at {profile}: {result.stderr}"


@pytest.mark.parametrize("secret", [".env", "msal_cache.json", "microsoft.token_cache.json"])
def test_git_refuses_to_track_a_file_of_secrets(secret):
    """The `.gitignore` that protects the profile protects the keys with it.

    `.env` holds the LLM and TypeSafe API keys and the token caches hold OAuth
    refresh tokens, so a committed copy of either is a live credential in
    someone else's hands. Asked through git rather than by reading the file:
    unlike the profile, no blanket ignore happens to cover these, which makes
    `check-ignore` the honest question for them.
    """
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "check-ignore", "-q", "--no-index", str(REPO_ROOT / secret)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, f"git would track {secret}, which holds a credential"


# --- profile_is_ready -------------------------------------------------------------------


def test_a_profile_that_was_never_created_is_not_ready(tmp_path):
    assert not profile_is_ready(_settings(tmp_path))


def test_a_profile_with_an_empty_cookie_jar_is_not_ready(tmp_path):
    """A directory exists as soon as the browser opens; only signing in fills it."""
    settings = _settings(tmp_path)
    (settings.profile_dir / "Default").mkdir(parents=True)
    (settings.profile_dir / "Default" / "Cookies").write_bytes(b"")

    assert not profile_is_ready(settings)


def test_a_profile_with_cookies_is_ready(tmp_path):
    settings = _settings(tmp_path)
    (settings.profile_dir / "Default" / "Network").mkdir(parents=True)
    (settings.profile_dir / "Default" / "Network" / "Cookies").write_bytes(b"SQLite format 3\0")

    assert profile_is_ready(settings)


def test_the_older_cookie_location_also_counts(tmp_path):
    """Which path Chromium uses depends on the bundled version, not on us."""
    settings = _settings(tmp_path)
    (settings.profile_dir / "Default").mkdir(parents=True)
    (settings.profile_dir / "Default" / "Cookies").write_bytes(b"SQLite format 3\0")

    assert profile_is_ready(settings)


# --- login / logout ----------------------------------------------------------------------


def test_login_reports_the_name_the_app_bar_shows(monkeypatch, tmp_path):
    page = _signed_in_page(identity="Ada Lovelace")
    _install(monkeypatch, _FakeChromium(_FakeContext([page])))

    assert login(_settings(tmp_path)) == "signed in as Ada Lovelace"
    assert page.goto_calls == [_settings(tmp_path).outlook_url]


def test_login_always_opens_a_window(monkeypatch, tmp_path):
    """MFA needs a person; a window that never appears is indistinguishable from a hang."""
    chromium = _FakeChromium(_FakeContext([_signed_in_page()]))
    _install(monkeypatch, chromium)

    login(_settings(tmp_path, browser_headless=True))

    assert chromium.last_launch["headless"] is False


def test_login_closes_the_context_so_the_cookies_reach_disk(monkeypatch, tmp_path):
    """The next run may be a headless cron job minutes later."""
    context = _FakeContext([_signed_in_page()])
    handle = _install(monkeypatch, _FakeChromium(context))

    login(_settings(tmp_path))

    assert context.closed
    assert handle.stopped


def test_login_gives_up_with_an_actionable_message(monkeypatch, tmp_path):
    page = _FakePage(fail_wait=True)
    _install(monkeypatch, _FakeChromium(_FakeContext([page])))

    with pytest.raises(SessionError, match="Timed out waiting for sign-in"):
        login(_settings(tmp_path))


def test_login_survives_an_account_name_it_cannot_read(monkeypatch, tmp_path):
    """The sign-in worked; only the label did not. Reporting failure would be a lie."""
    page = _signed_in_page(identity=None)
    _install(monkeypatch, _FakeChromium(_FakeContext([page])))

    assert login(_settings(tmp_path)) == "signed in (the account button did not expose a name)"


def test_logout_deletes_the_profile(tmp_path):
    settings = _settings(tmp_path)
    (settings.profile_dir / "Default").mkdir(parents=True)
    (settings.profile_dir / "Default" / "Cookies").write_bytes(b"SQLite format 3\0")

    logout(settings)

    assert not settings.profile_dir.exists()


def test_logout_on_a_missing_profile_is_not_an_error(tmp_path):
    logout(_settings(tmp_path))


# --- status -------------------------------------------------------------------------------


def test_status_says_not_signed_in_when_there_is_no_profile(tmp_path):
    line = status(_settings(tmp_path))
    assert "not signed in" in line
    # The status line has to name a way out, and the only one that exists is
    # opening a window to sign in; naming a command that does not exist would
    # send the user looking for it.
    assert "BROWSER_HEADLESS=false" in line


def test_status_does_not_claim_a_sign_in_it_cannot_prove(tmp_path):
    """A cookie jar is not a session, and an expired one looks identical on disk.

    `profile_is_ready` is an explicit heuristic - non-empty cookie jar, so that
    `pli status` stays instant instead of opening Chromium. Wording it "signed
    in" made the heuristic a verdict, and it was wrong in the one case that
    matters: an expired session leaves a cookie jar behind, so the user facing a
    sign-in wall was told they were fine. The line names the file it found and
    says the claim is unproven.
    """
    settings = _settings(tmp_path)
    (settings.profile_dir / "Default").mkdir(parents=True)
    (settings.profile_dir / "Default" / "Cookies").write_bytes(b"SQLite format 3\0")

    line = status(settings)

    assert line.startswith("not verified")
    assert str(settings.profile_dir) in line
    assert "signed in" not in line, "a cookie jar is not proof of a session"


def test_status_mentions_playwright_when_it_is_not_installed(monkeypatch, tmp_path):
    monkeypatch.setitem(sys.modules, "playwright.sync_api", None)

    line = status(_settings(tmp_path))

    assert "playwright" in line
    assert isinstance(line, str)


def test_status_never_raises_even_on_a_broken_profile(monkeypatch, tmp_path):
    """`pli status` is the command a user runs *because* something is wrong."""

    def explode(settings):
        raise OSError("no such file or directory")

    monkeypatch.setattr(session_module, "profile_is_ready", explode)

    line = status(_settings(tmp_path))

    assert isinstance(line, str)
    assert "unavailable" in line
