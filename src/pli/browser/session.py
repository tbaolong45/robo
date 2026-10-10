"""The one module that owns the browser and the Chromium profile.

Everything else in `pli.browser` is handed an already-signed-in `Page` by
`session()` and never touches the profile, the credentials, or Playwright's
lifecycle. There is one reason for that concentration: the profile directory
holds live session cookies for the user's university account, and every extra
code path that could create, copy, or widen it is another place to leak it.

Three rules:

1. **Nothing is stored but cookies.** The user types their password and their MFA
   code into the real Microsoft page. There is no credential argument anywhere in
   this module, so there is nothing here to log, print, or commit.
2. **The profile is private by construction.** It is created 0700 and re-chmodded
   0700 before every launch, so a Chromium update that recreates the directory
   cannot quietly widen it.
3. **"Not signed in" stays a distinct failure.** `SessionError` means the fix is
   a headed run; a page-level failure means the page changed. Collapsing the two
   would send the user hunting for a selector bug when the real answer is that
   the session expired overnight.

Importing this module must never require Playwright. A box without it still has
to run `pli status`, `pli plan` and the whole test suite, so the import happens
inside the functions and an ImportError becomes a `SessionError` that names the
command to run.
"""

from __future__ import annotations

import contextlib
import shutil
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import TYPE_CHECKING, Any
from urllib.parse import urlsplit

from pli.browser import SessionError
from pli.config import Settings

if TYPE_CHECKING:  # pragma: no cover - Playwright is imported lazily at runtime
    from playwright.sync_api import BrowserContext, Page

__all__ = [
    "login",
    "logout",
    "profile_is_ready",
    "require_signed_in",
    "session",
    "start_playwright",
    "status",
]

#: Where Chromium keeps the cookie jar inside a profile. Modern Chromium moved
#: it under Default/Network; older builds put it directly under Default. Both
#: are checked because which one appears depends on the bundled Chromium version.
_COOKIE_FILES = ("Default/Network/Cookies", "Default/Cookies")

#: A desktop user agent. Headless Chromium announces itself as "HeadlessChrome",
#: which both web apps answer with a "use a supported browser" wall - so the
#: string is set explicitly rather than left to the engine. It is a constant
#: rather than a computed value on purpose: a profile that suddenly changes its
#: UA is a better signal than one that silently drifts with the Chromium build.
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/141.0.0.0 Safari/537.36"
)

#: A normal laptop window. Outlook's week grid and the Teams channel pane only
#: render their desktop layouts above roughly 1200px wide; a smaller viewport
#: gets the collapsed mobile layout and the selectors in browser.toml miss.
VIEWPORT = {"width": 1600, "height": 1000}

#: How long `login` waits for the user to finish MFA before giving up. Long
#: enough for a phone that has to be found, short enough that a forgotten window
#: does not hold the terminal forever.
LOGIN_TIMEOUT_MS = 300_000

#: How a user gets back from an expired session. Signing in is deliberately not a
#: command: the profile is a real Chromium profile, so a headed run opens a window
#: where the sign-in can be completed once, and the session survives afterwards.
#: Every message that needs to say "you are signed out" points here, so the advice
#: cannot drift into naming a command that does not exist.
SIGN_IN = "run with BROWSER_HEADLESS=false to sign in once"

#: Hosts that exist only to ask a human who they are. A page on one of these is
#: a sign-in wall, not a calendar.
_SIGN_IN_HOSTS = (
    "login.microsoftonline.com",
    "login.live.com",
    "login.microsoft.com",
    "login.windows.net",
)

#: Path fragments that only ever appear on a sign-in flow, for the cases where
#: the wall is served from a host we do not list - a university ADFS or a
#: branded federated login, for instance.
_SIGN_IN_PATHS = (
    "oauth2/authorize",
    "oauth20_authorize",
    "account_picker",
    "adfs/ls",
    "login.srf",
    "kmsi",
)

#: Path segments that mean "sign in" on their own. Matched as whole segments, so
#: a legitimately named path like /calendar/view/week is never caught by them.
_SIGN_IN_SEGMENTS = frozenset({"login", "signin", "auth", "authorize", "sso"})

#: Hosts that mean the browser actually arrived at the app. Used by `login` to
#: decide the user is finished, because "no longer on a sign-in page" is not
#: enough: the university's own single-sign-on page is not a Microsoft login
#: host either, and waiting for it to *not* be a sign-in page would return while
#: the user is still typing.
_APP_HOSTS = (
    "outlook.office.com",
    "outlook.office365.com",
    "outlook.live.com",
    "teams.microsoft.com",
    "teams.cloud.microsoft",
    "microsoft365.com",
)

#: Elements that carry the signed-in user's own name. Read off the account button
#: in the app bar; there is no API for "who is this profile" without a request.
_IDENTITY_JS = """
() => {
  const nodes = document.querySelectorAll(
    '[data-automationid="AccountManagerButton"], [data-tid="me-control-avatar"],'
    + '[aria-label*="Account manager" i], button[aria-label*="account" i]'
  );
  for (const node of nodes) {
    const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
    if (label) return label;
  }
  return '';
}
"""


# --- the public surface ---------------------------------------------------------


@contextmanager
def session(settings: Settings, *, headless: bool | None = None) -> Iterator[Page]:
    """Yield a signed-in Page. Caller navigates. Raises SessionError.

    `headless` defaults to `settings.browser_headless`; pass False to watch a
    read happen, which is the only way to see what a selector is actually
    matching when a page has changed.

    The context is closed on the way out even when the body raises - not for
    tidiness, but because Chromium flushes cookies to the profile on close, and
    a run that crashed after a successful re-auth must not lose the new session.
    """
    effective_headless = settings.browser_headless if headless is None else headless
    playwright = start_playwright()
    context: BrowserContext | None = None
    try:
        context = _launch(playwright, settings, headless=effective_headless)
        page = _first_page(context)
        # A profile that is signed out normally shows up as a redirect after the
        # caller navigates, which `require_signed_in` catches. Checking here too
        # costs nothing and covers a context that restored a stale sign-in tab.
        require_signed_in(page)
        yield page
    finally:
        if context is not None:
            # Closing is best-effort: a crash inside the body must not be
            # replaced by a crash while cleaning up after it.
            with contextlib.suppress(Exception):
                context.close()
        with contextlib.suppress(Exception):
            playwright.stop()


def login(settings: Settings) -> str:
    """Open a HEADED browser so the user can sign in interactively (MFA).

    Wait until signed in, then return a human-readable "signed in as X".

    Headed is forced regardless of `browser_headless`: MFA needs a person, and a
    window that never appears is indistinguishable from a hang. The context is
    closed before returning so the cookies are on disk by the time this call
    ends - the next `session()` may be a headless cron run minutes later.
    """
    playwright = start_playwright()
    context: BrowserContext | None = None
    try:
        context = _launch(playwright, settings, headless=False)
        page = _first_page(context)
        try:
            page.goto(settings.outlook_url, wait_until="domcontentloaded")
            _wait_for_app(page)
        except SessionError:
            raise
        except Exception as exc:
            raise SessionError(
                "Timed out waiting for sign-in to finish. If the browser window is still "
                "open, complete the sign-in there; if it closed, "
                "check that this machine can reach login.microsoftonline.com."
                f"\nDetails: {type(exc).__name__}: {exc}"
            ) from exc
        who = _signed_in_identity(page)
        if who:
            return f"signed in as {who}"
        return "signed in (the account button did not expose a name)"
    finally:
        if context is not None:
            with contextlib.suppress(Exception):
                context.close()
        with contextlib.suppress(Exception):
            playwright.stop()


def logout(settings: Settings) -> None:
    """Delete the stored profile.

    Deleting the directory is the whole logout: there is no token cache to clear
    and no credential to revoke, because none of that was ever stored here.
    """
    profile = settings.profile_dir
    if not profile.exists():
        return
    try:
        shutil.rmtree(profile)
    except OSError as exc:
        raise SessionError(
            f"Could not delete the browser profile at {profile}: {exc}. "
            "Close any Chromium window that is still using it and try again."
        ) from exc


def profile_is_ready(settings: Settings) -> bool:
    """True when a profile directory exists and looks signed in.

    A heuristic, and deliberately so: the alternative is launching Chromium to
    ask, which turns `pli status` into a five-second command that opens a
    browser. Presence of a non-empty cookie jar is the strongest signal
    available without doing that - a profile that was created but never signed
    in has an empty one. Only a real navigation proves the session still works.
    """
    profile = settings.profile_dir
    if not profile.is_dir():
        return False
    for relative in _COOKIE_FILES:
        try:
            cookies = profile / relative
            if cookies.is_file() and cookies.stat().st_size > 0:
                return True
        except OSError:
            continue
    return False


def status(settings: Settings) -> str:
    """One human-readable line for `pli status`. Must NEVER raise.

    Plain text, no Rich markup: `pli status` is not the only caller, and a
    coloured string that reaches a log file or a plain `print` is noise. The
    caller decides how to colour it.
    """
    try:
        profile = settings.profile_dir
        if not _playwright_installed():
            return "unavailable - playwright is not installed (run `uv sync`)"
        if profile_is_ready(settings):
            # "signed in" is a verdict this cannot give. `profile_is_ready` is a
            # cookie jar on disk, and an *expired* session leaves exactly that
            # behind - so the one person who most needs the truth here is the one
            # this line used to mislead. It claims what was observed, and says
            # plainly that the claim is unproven.
            return (
                f"not verified - profile at {profile} has a cookie jar; "
                f"only a read proves it still works"
            )
        if profile.exists():
            return f"not signed in - profile at {profile} has no session; {SIGN_IN}"
        return f"not signed in - {SIGN_IN}"
    except Exception as exc:  # noqa: BLE001 - `pli status` must never crash
        return f"unavailable ({type(exc).__name__}: {exc})"


def require_signed_in(page: Page) -> None:
    """Raise `SessionError` when `page` has landed on a Microsoft sign-in page.

    Callers navigate after `session()` yields, so this is the check they run
    before reading anything: a signed-out profile does not fail the navigation,
    it silently serves the login page, and a reader that treats that as "no
    events this week" would hand the planner an empty calendar to fill.
    """
    url = str(getattr(page, "url", "") or "")
    if _looks_like_sign_in(url):
        raise SessionError(
            f"The page redirected to a Microsoft sign-in screen at "
            f"{_address(url) or 'an unknown address'}, so the saved profile is no "
            "longer signed in. Run with BROWSER_HEADLESS=false to sign in once; the "
            "profile keeps the session afterwards."
        )


def _address(url: str) -> str:
    """Just the host and path of a URL, for a message a person has to read.

    A sign-in redirect is an OAuth authorize URL, and its query string is a
    screen and a half of client_id, nonce and code_challenge - machinery that
    says nothing to the user and buries the one sentence that matters. The host
    and path are the whole diagnosis: which wall the browser hit.
    """
    parts = urlsplit(url)
    if not parts.netloc:
        return url.split("?", 1)[0]
    return f"{parts.scheme}://{parts.netloc}{parts.path}"


# --- Playwright plumbing --------------------------------------------------------


def _import_sync_playwright() -> Any:
    """The one place Playwright is imported, so its absence stays survivable.

    Returns the `sync_playwright` factory rather than starting it, which keeps
    "the package is missing" and "the browser will not start" as separate,
    separately-worded failures.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise SessionError(
            "Playwright is not installed, so the browser cannot be started. Install it "
            "with `uv sync`, then run `uv run playwright install chromium` to fetch the "
            "browser binary itself."
        ) from exc
    return sync_playwright


def start_playwright() -> Any:
    """Start the Playwright driver process."""
    sync_playwright = _import_sync_playwright()
    try:
        return sync_playwright().start()
    except Exception as exc:
        raise SessionError(_start_hint(exc)) from exc


#: Fragments Playwright uses when the browser binary is simply not downloaded.
#: Matching on the message is unpleasant but it is the only signal available:
#: the exception type is a `playwright.Error`, which cannot be named here
#: without importing the package this module must survive without.
_MISSING_BROWSER_MARKERS = ("Executable doesn't exist", "playwright install")


def _needs_browser_install(message: str) -> bool:
    return any(marker in message for marker in _MISSING_BROWSER_MARKERS)


def _install_hint(message: str) -> str:
    return (
        "Chromium is not installed for Playwright, so no page can be opened. Run "
        f"`uv run playwright install chromium`.\nDetails: {message}"
    )


def _start_hint(exc: Exception) -> str:
    message = str(exc)
    if _needs_browser_install(message):
        return _install_hint(message)
    return f"Playwright could not start: {message}"


def _launch_hint(exc: Exception, profile: Path) -> str:
    message = str(exc)
    if _needs_browser_install(message):
        return _install_hint(message)
    return (
        f"Chromium could not open the profile at {profile}: {type(exc).__name__}: {message}. "
        "A profile left locked by a crashed run clears when that process exits; "
        "deleting the profile directory clears it, at the cost of one sign-in."
    )


def _launch(playwright: Any, settings: Settings, *, headless: bool) -> BrowserContext:
    """Start a persistent Chromium context on the profile directory."""
    profile = _prepare_profile_dir(settings)
    try:
        return playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=headless,
            slow_mo=settings.browser_slow_mo_ms,
            viewport=dict(VIEWPORT),
            user_agent=USER_AGENT,
            # locale is deliberately not set: the language a mailbox or channel
            # renders in comes from the account settings on the server, and
            # forcing one here would only make the page disagree with what the
            # user sees in their own browser.
        )
    except SessionError:
        raise
    except Exception as exc:
        raise SessionError(_launch_hint(exc, profile)) from exc


def _prepare_profile_dir(settings: Settings) -> Path:
    """Create the profile directory if needed and make it private.

    `mkdir(mode=0o700)` does not touch a directory that already exists, and the
    directory does exist on every run after the first - so the chmod is not
    redundant bookkeeping, it is the only thing that tightens permissions on a
    profile created before this rule existed, or by a Chromium build that
    recreated the directory itself.
    """
    profile = settings.profile_dir
    try:
        profile.mkdir(mode=0o700, parents=True, exist_ok=True)
        profile.chmod(0o700)
    except OSError as exc:
        raise SessionError(
            f"Could not create or secure the browser profile at {profile}: {exc}. "
            "It holds live session cookies, so it is only used if it can be made "
            "readable by this user alone."
        ) from exc
    return profile


def _first_page(context: BrowserContext) -> Page:
    """The page to hand the caller.

    A fresh context opens with one blank page; a reused profile may have none or
    several depending on what Chromium restored. The first is used rather than
    closing the others, because a page the caller did not ask about is not this
    module's to close.
    """
    pages = list(getattr(context, "pages", None) or [])
    if pages:
        return pages[0]
    return context.new_page()


def _wait_for_app(page: Page) -> None:
    """Block until the page has landed on Microsoft 365 rather than a login host."""
    page.wait_for_url(lambda url: _is_app_url(str(url)), timeout=LOGIN_TIMEOUT_MS)


def _signed_in_identity(page: Page) -> str:
    """The user's own name as the app bar shows it, or "" when it cannot be read.

    Best-effort by design: the returned string is what a headed run reports, and a
    missing name must not fail a sign-in that actually worked.
    """
    try:
        raw = page.evaluate(_IDENTITY_JS)
    except Exception:  # noqa: BLE001 - the sign-in succeeded; the label did not
        return ""
    if not isinstance(raw, str):
        return ""
    return " ".join(raw.split())[:120]


# --- URL classification ---------------------------------------------------------


def _looks_like_sign_in(url: str) -> bool:
    """True when `url` is a Microsoft sign-in wall rather than an application.

    Matched on the URL and not on the page's content, because this has to be
    answerable before anything is read: a wrong "yes" costs one re-sign-in, and
    a wrong "no" means a login page is parsed as a calendar.
    """
    text = (url or "").strip().lower()
    if not text:
        return False
    parts = urlsplit(text)
    host = parts.netloc.rsplit("@", 1)[-1].split(":")[0]
    path = parts.path if host else text
    if any(host == wall or host.endswith("." + wall) for wall in _SIGN_IN_HOSTS):
        return True
    if any(fragment in path for fragment in _SIGN_IN_PATHS):
        return True
    return any(segment in _SIGN_IN_SEGMENTS for segment in path.split("/"))


def _is_app_url(url: str) -> bool:
    """True when the URL is one of the apps this tool reads, on a real host.

    Used only to decide that `login` is finished. The bar is deliberately higher
    than `not _looks_like_sign_in`: a university's federated login page is not a
    Microsoft host either, so "no longer a Microsoft login" would return while
    the user is still typing their password and store a half-finished session.
    """
    text = (url or "").strip().lower()
    if not text or _looks_like_sign_in(text):
        return False
    host = urlsplit(text).netloc.rsplit("@", 1)[-1].split(":")[0]
    return any(host == app or host.endswith("." + app) for app in _APP_HOSTS)


def _playwright_installed() -> bool:
    try:
        _import_sync_playwright()
    except SessionError:
        return False
    return True
