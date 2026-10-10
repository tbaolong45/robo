"""Characters that are never wanted in text taken from a page.

Shared by the inbox reader and the web reader, because both turn what a stranger wrote
into text that is shown in a terminal and put in a prompt.
"""

from __future__ import annotations

__all__ = ["INVISIBLE"]

#: Characters Outlook pads a row's accessible name with so it reads aloud well, plus the
#: ones an author could use on purpose: Unicode "tag" characters (invisible, yet able to spell
#: a hidden instruction) and bidi controls (they reorder what a person sees). Invisible, so
#: they would otherwise reach the models unseen. For `str.translate`.
INVISIBLE = dict.fromkeys(
    [
        *range(0x200B, 0x2010),  # zero-width spaces and marks
        *range(0x202A, 0x202F),  # bidi embeddings and overrides
        *range(0x2060, 0x2070),  # word joiner, invisible operators, bidi isolates
        *range(0xE0000, 0xE0080),  # tag characters
        0x00AD,
        0x034F,
        0x115F,
        0x3164,
        0xFEFF,
    ]  # fmt: skip
)
