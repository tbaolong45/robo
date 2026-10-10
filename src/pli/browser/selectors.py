"""Where every query against Microsoft's markup lives, so nothing else has to know.

This whole approach to reading Outlook and Teams is a bet: the pages are
undocumented and restyled without notice, but a redesign costs a config edit
instead of a release. That bet only pays if the queries are in one place and
nowhere else, because a stray `page.click("[data-tid='foo']")` buried in a
reader is invisible when the rename happens - it just starts returning nothing,
and "the week is empty" is the one wrong answer this tool must never give.

So: **queries are data.** `config/browser.toml` carries them, the dataclass
below carries the fallback used when that file is missing or incomplete, and a
reader that needs a new element adds a key rather than a string literal.

Two rules for the values themselves:

* Prefer the accessible name. A `role=button[name="New event"]` query survives a
  restyle because a screen reader still has to announce it; `data-tid` is an
  internal id Microsoft renames whenever it feels like it, and is the fallback,
  not the first choice.
* A value is a Playwright selector, not a plain CSS selector. That is what lets
  the accessible-name form above live in a string.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, fields
from pathlib import Path

from pli.browser import BrowserError
from pli.config import REPO_ROOT

__all__ = ["DEFAULT_PATH", "Selectors", "load"]

#: The file `pli` reads at runtime. Kept next to study.toml because it is
#: user-editable config, not packaging.
DEFAULT_PATH = REPO_ROOT / "config" / "browser.toml"


@dataclass(frozen=True)
class Selectors:
    """One query per element the readers touch, with a working default each.

    Every field has a default so a partial - or absent - TOML still leaves a
    usable object: a missing key must never be the reason a read fails, because
    the failure would look like an empty calendar rather than a config mistake.

    Frozen because this is read-only state shared across a run; a reader that
    could mutate it could change what a later reader sees.
    """

    # --- Outlook calendar ---------------------------------------------------------

    #: The week board itself. The only place an event can be found, so a read
    #: that scopes to it cannot pick up a reminder from somewhere else on screen.
    outlook_week_grid: str = "[data-automationid='CalendarGrid'], [role='grid']"
    #: One event chip inside the week board.
    outlook_event: str = (
        "[data-automationid='CalendarItem'], [role='button'][aria-label*='Calendar item']"
    )
    #: The subject line inside an opened event.
    outlook_event_subject: str = (
        "[data-automationid='subject'], [role='textbox'][aria-label*='title' i]"
    )
    #: The start/end line inside an opened event.
    outlook_event_time: str = "[data-automationid='time'], [data-automationid='timePrefix']"
    outlook_new_event_button: str = "role=button[name='New event']"
    outlook_title_field: str = "role=textbox[name='Add a title']"
    outlook_start_field: str = "role=textbox[name='Start time']"
    outlook_end_field: str = "role=textbox[name='End time']"
    #: The calendar dropdown. Checked before any write, so a plan can never be
    #: committed to the user's real timetable.
    outlook_calendar_picker: str = "role=combobox[name='Calendar']"
    outlook_save_button: str = "role=button[name='Save']"
    outlook_delete_button: str = "role=button[name='Delete']"

    # --- Outlook mail -------------------------------------------------------------

    #: One row of the message list. Matched by `role=option` plus `data-convid`,
    #: the conversation id Outlook puts on every row; the class names on the row
    #: are generated and change per build, so none of them appear here. The row's
    #: accessible name (`aria-label`) is the text the reader takes.
    outlook_mail_row: str = "[role='option'][data-convid]"

    # --- Teams --------------------------------------------------------------------

    teams_app_bar: str = "[data-tid='app-bar'], [data-tid='titlebar']"
    teams_channel_list: str = "[data-tid='channel-list'], [data-tid='channel-list-pane']"
    #: A single channel in the sidebar of a team.
    teams_channel_item: str = "[data-tid='channel-list-item'], [role='treeitem']"
    teams_message_list: str = "[data-tid='message-list'], [role='list'][aria-label*='message' i]"
    teams_message: str = "[data-tid='chat-pane-message'], [data-tid='message-body']"
    teams_message_author: str = "[data-tid='message-author-name'], [data-tid='message-author']"
    teams_message_time: str = "[data-tid='message-timestamp'], [data-tid='message-time']"
    teams_message_body: str = "[data-tid='message-body-content'], [data-tid='message-body']"
    #: Whatever the app calls "scroll up for older posts" this week.
    teams_more_messages: str = "button[aria-label*='Load more' i], [data-tid='load-more-messages']"


def load(path: Path | None = None) -> Selectors:
    """Read the overrides from `config/browser.toml`, falling back per key.

    Tolerant by design: no file, an empty file, or a file that names only the
    two selectors the user just fixed all produce a complete `Selectors`. Keys
    this dataclass does not know are ignored, so a stale line left over from an
    older version cannot break a read.

    A file that will not parse is the one exception, and it raises. The user
    edited that file seconds ago; silently reading the built-in defaults would
    report "no events" against the queries that just stopped working, which is
    exactly the misreading this module exists to prevent.
    """
    target = path or DEFAULT_PATH
    if not target.exists():
        return Selectors()
    try:
        with target.open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise BrowserError(f"config/browser.toml could not be read: {exc}") from exc

    known = {field.name for field in fields(Selectors)}
    merged: dict[str, str] = {}
    for key, value in _flatten(data).items():
        # Non-strings are ignored rather than coerced: a value that is not a
        # selector would reach Playwright and fail there, far from the edit.
        if key in known and isinstance(value, str) and value.strip():
            _check(key, value)
            merged[key] = value
    return Selectors(**merged)


#: Playwright's non-CSS selector engines, spelled as they start a value. The
#: distinction matters because a value beginning with one of these is *not* CSS,
#: and a comma in it is parsed by that engine rather than as a CSS list.
_ENGINES = (
    "role=",
    "text=",
    "label=",
    "placeholder=",
    "alt=",
    "title=",
    "testid=",
    "xpath=",
    "id=",
    "data-testid=",
    "nth=",
    "react=",
    "aria-ref=",
)


def _check(key: str, value: str) -> None:
    """Refuse a selector Playwright would reject when the page is already open.

    The hazard is specific and the reason this exists is that it happened: a
    value like `role=button[name*='more' i], [data-tid='load-more']` reads like a
    CSS list of two alternatives, but the `role=` engine consumes the whole
    string and fails on the comma - `InvalidSelectorError`, raised from inside a
    read, halfway through a channel, with the browser already open. The same
    mistake at load time is one sentence naming the line to fix.

    Only this one mistake is checked. It is not a validator: a selector that
    parses but matches nothing is a live-page question no offline check can
    answer, and pretending otherwise would be worse than saying nothing.
    """
    prefix = next((engine for engine in _ENGINES if value.lower().startswith(engine)), None)
    if prefix and "," in value:
        raise BrowserError(
            f"config/browser.toml: {key} starts with the Playwright `{prefix}` engine and "
            f"also contains a comma, which Playwright rejects - a comma is only a list "
            f"separator in a plain CSS selector, never inside an engine. Write it as two "
            f"CSS alternatives (for example `button[aria-label*='Load more' i], "
            f"[data-tid='...']`), or keep the engine and drop to a single query."
        )


def _flatten(data: dict) -> dict[str, object]:
    """Top-level keys, plus the keys of any top-level table.

    Grouping the queries under `[outlook]` and `[teams]` reads better in the
    file, and so does a flat list; supporting both costs one function and means
    the layout in `config/browser.toml` never has to be explained.
    """
    flat: dict[str, object] = {}
    for key, value in data.items():
        if isinstance(value, dict):
            flat.update(value)
        else:
            flat[key] = value
    return flat
