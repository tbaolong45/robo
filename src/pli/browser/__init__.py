"""Reaching Microsoft 365 and Moodle by driving the browser a person would use.

This replaces the Graph API entirely. It is a deliberate trade: Graph was
exact, documented and immune to a redesign, but it needed an app registration
in a tenant the user does not administer, and it could not read Teams channel
messages at all without tenant admin consent - which is where a lecturer
announces that a deadline moved. The browser can read everything the user can
see. What it cannot do is promise the page will look the same next term.

Three rules make that survivable:

1. **One place holds the session.** `pli.browser.session` owns the Chromium
   profile. Everything else receives an already-signed-in context and never
   touches credentials.
2. **Selectors are configuration.** `pli.browser.selectors` loads the CSS and
   accessibility queries from `config/browser.toml`, so a redesign is a config
   edit rather than a code change.
3. **Text is judged, not pattern-matched.** Anything that requires understanding
   what the page *means* goes through `pli.judge`. Geometry and arithmetic stay
   in Python.
"""

from __future__ import annotations

__all__ = ["CALENDAR_NAME", "STUDY_MARKER", "BrowserError", "SessionError"]

#: The dedicated calendar every study block is written to. The tool must never
#: address any other calendar, so this name is the only one it looks for.
CALENDAR_NAME = "Study Plan"

#: Prefix of the marker this tool embeds in the events it creates, so it can
#: recognise its own work in a UI with no custom-property support.
STUDY_MARKER = "[pli:"


class BrowserError(RuntimeError):
    """The page could not be read or driven; the message says what to do."""


class SessionError(BrowserError):
    """Not signed in, or the browser could not be started.

    Kept distinct from a page-level failure because the fix is different: this
    one means "the saved session expired", not "the calendar page changed".
    """
