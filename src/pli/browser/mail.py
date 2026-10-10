"""Reading the Outlook inbox list - and only reading it.

**The reader never opens a message.** Outlook marks a mail read the moment it is
selected, so a click is not a read: it is a write to the user's inbox. Everything
here comes from the message *list*, where each row's accessible name already
carries sender, subject, time and the start of the body. A digest built from that
is shallower than one built from full bodies, and that is the price of leaving
the user's unread badge alone. Reading bodies needs Outlook's "mark as read"
setting turned to Never first - a decision for the user, not for this module.

**An empty read is an error.** A list that failed to render looks exactly like an
inbox with nothing in it, and only the second should ever be reported as "no
mail". So a list that never appears raises `BrowserError`; it is never returned
as `[]`.

**A failed read saves nothing.** The calendar reader dumps the page for the user
to send back when a selector goes stale. A mail page is private correspondence,
so no diagnostics are written here: the error names the config key to fix.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING
from urllib.parse import urljoin

from pli.browser import BrowserError
from pli.browser.text import INVISIBLE
from pli.config import Settings

if TYPE_CHECKING:
    from playwright.sync_api import Page

    from pli.browser.selectors import Selectors

__all__ = ["MAX_ROW_CHARS", "MailItem", "parse_row", "read_inbox"]

#: How long the message list may take to render. A cold first load of Outlook was
#: measured at 76 s and a warm one at 5 s, so the ceiling is generous on purpose:
#: a read that gives up at 30 s would call a slow morning an empty inbox.
LIST_TIMEOUT_MS = 120_000
#: Pause after a scroll, so the virtualised list can render the next rows.
SCROLL_PAUSE_MS = 1_500
#: How far one mouse-wheel step moves the list. Measured on a real inbox: Outlook
#: draws only about ten rows (~76 px each) at a time, so a 900 px step is taller
#: than the drawn window and skips rows. 600 px leaves the windows overlapping.
SCROLL_STEP_PX = 600
#: Most scrolls one read will make. Bounds the work if the list never runs out.
MAX_SCROLLS = 12
#: Two windows in a row with nothing new means the end of the list.
STALLS_TO_STOP = 2

#: The longest row kept. Real rows are under 450 characters (the longest measured was 431),
#: so this never cuts one; it bounds what a hostile mail can make every later step process.
MAX_ROW_CHARS = 1_000
#: Words a row's accessible name starts with when the flag is set.
_UNREAD = "Unread"
_ATTACHMENTS = "Has attachments"

#: Runs in the page: one round trip for every rendered row, as [id, label] pairs.
_COLLECT = (
    "els => els.map(e => [e.getAttribute('data-convid') || '', "
    "e.getAttribute('aria-label') || e.innerText || ''])"
)


@dataclass(frozen=True)
class MailItem:
    """One inbox row, as the list shows it.

    `text` is verbatim from the row - sender, subject, time and the start of the
    body, in the order Outlook announces them - because which words are the
    sender and which are the subject is a judgement, and the judge reads the
    whole row rather than a split code guessed at.
    """

    id: str
    unread: bool
    attachments: bool
    text: str


def parse_row(convid: str, label: str) -> MailItem | None:
    """A row's accessible name as a `MailItem`, or None when there is no text."""
    text = " ".join(label.translate(INVISIBLE).split())
    unread = attachments = False
    while True:
        if text == _UNREAD or text.startswith(_UNREAD + " "):
            unread, text = True, text[len(_UNREAD) :].lstrip()
        elif text == _ATTACHMENTS or text.startswith(_ATTACHMENTS + " "):
            attachments, text = True, text[len(_ATTACHMENTS) :].lstrip()
        else:
            break
    text = text[:MAX_ROW_CHARS].rstrip()
    if not text:
        return None
    return MailItem(id=convid or text, unread=unread, attachments=attachments, text=text)


def read_inbox(
    settings: Settings,
    *,
    limit: int = 10,
    page: Page | None = None,
    selectors: Selectors | None = None,
) -> list[MailItem]:
    """The newest `limit` inbox rows, newest first. Opens nothing, changes nothing.

    Pass `page` to drive an existing session; otherwise a fresh signed-in one is
    opened. Raises `SessionError` when the profile is signed out and
    `BrowserError` when the list never renders.
    """
    if limit < 1:
        raise ValueError("limit must be at least 1")
    queries = selectors if selectors is not None else _load_selectors()
    if page is not None:
        return _read(page, settings, queries, limit)
    from pli.browser.session import session

    with session(settings) as opened:
        return _read(opened, settings, queries, limit)


def _load_selectors() -> Selectors:
    from pli.browser.selectors import load

    return load()


def _read(page: Page, settings: Settings, selectors: Selectors, limit: int) -> list[MailItem]:
    from pli.browser.session import require_signed_in

    url = urljoin(settings.outlook_url, "/mail/")
    page.goto(url, wait_until="domcontentloaded", timeout=60_000)
    require_signed_in(page)

    rows = page.locator(selectors.outlook_mail_row)
    try:
        rows.first.wait_for(state="visible", timeout=LIST_TIMEOUT_MS)
    except Exception as exc:
        # A redirect to sign-in can land after `goto` returns; that is a different
        # fix from a restyled page, so it must be reported as one.
        require_signed_in(page)
        raise BrowserError(
            f"The Outlook message list never appeared at {url}, so there is nothing to read - "
            "and a list that did not render is not reported as an empty inbox. If the page was "
            "restyled, the fix is outlook_mail_row in config/browser.toml. No snapshot of the "
            "page is taken, because it would hold your private mail."
        ) from exc

    seen: dict[str, MailItem] = {}
    previous: set[str] = set()
    stalls = 0
    hovered = False
    for _ in range(MAX_SCROLLS + 1):
        before = len(seen)
        window: set[str] = set()
        for convid, label in rows.evaluate_all(_COLLECT):
            item = parse_row(convid, label)
            if item is None:
                continue
            window.add(item.id)
            seen.setdefault(item.id, item)
        if previous and window and not previous & window:
            # Nothing in common with the last window: rows between them were never
            # drawn. Returning what we have would drop mail without saying so.
            raise BrowserError(
                "Scrolling the Outlook message list skipped rows, so the inbox read would be "
                "missing messages. Lower SCROLL_STEP_PX in pli/browser/mail.py."
            )
        previous = window
        if len(seen) >= limit:
            break
        stalls = stalls + 1 if len(seen) == before else 0
        if stalls >= STALLS_TO_STOP:
            break
        if not hovered:
            # The wheel scrolls whatever is under the pointer. Moving it onto a row
            # selects nothing; a click would, and Outlook marks a selected mail read.
            rows.first.hover(timeout=5_000)
            hovered = True
        page.mouse.wheel(0, SCROLL_STEP_PX)
        page.wait_for_timeout(SCROLL_PAUSE_MS)
    return list(seen.values())[:limit]
