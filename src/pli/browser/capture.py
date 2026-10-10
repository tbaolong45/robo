"""Turn a rendered page into Candidates the judge can point at.

This is the bridge between two very different readers. Above it, `pli.judge`
answers questions about meaning and is indifferent to markup. Below it, Outlook
and Teams render whatever they like. What crosses the bridge is a flat list of
verbatim text fragments with their screen geometry, in reading order, with ids
that stay stable for the length of one call.

Four rules, each of which exists because of a specific way this goes wrong:

1. **One round trip, not one per element.** The whole document is measured in a
   single `page.evaluate`. Asking Playwright for elements one at a time costs a
   protocol round trip each; on a real week grid that is tens of seconds for a
   list that one script produces in one. The script only *measures* - every
   policy decision below is made in Python, where it is testable without a page.
2. **Reading order, because the judge sees a list.** The model gets a list of
   candidates and no screenshot, so "the second entry under Tuesday" only means
   anything if the order matches what a person would read: down the page, then
   across. A tolerance keeps two items on one visual line in x order rather than
   sorting them by a y difference of half a pixel.
3. **The innermost wins.** A week grid is containers all the way down, and a
   parent and its child routinely carry byte-identical text. Keeping both spends
   two of the judge's 255 options on one fact and makes the model choose between
   two ids that mean the same thing.
4. **A failed read raises.** An empty candidate list is a *claim*: it says the
   calendar is empty. Returning it after a broken evaluate would tell the planner
   the week is free and fill it with study blocks over real classes, so a page
   that cannot be read says so, and the caller dumps diagnostics instead.
"""

from __future__ import annotations

import contextlib
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

from pli.browser import BrowserError
from pli.browser.selectors import Selectors
from pli.config import Settings
from pli.judge import Candidate

if TYPE_CHECKING:  # pragma: no cover - Playwright is imported lazily by session.py
    from playwright.sync_api import Page

__all__ = ["MAX_TEXT", "capture_candidates", "diagnostics", "visible_text"]

#: Longer than this and the fragment is a paragraph, not a label - a lecture
#: description, a mail body, a whole channel. It is truncated rather than
#: dropped: the first 300 characters are still the evidence for what it is.
MAX_TEXT = 300

#: Two items whose top edges differ by less than this are on the same visual
#: line. Text in one row is often not perfectly baseline-aligned, and sorting
#: strictly by y would put "09:00" after "Algorithms" because it sits 2px lower.
LINE_TOLERANCE_PX = 6.0

#: Slack when asking whether one box contains another. Layout rounding puts a
#: child's rect a fraction of a pixel outside its parent's.
BOX_TOLERANCE_PX = 1.5

#: Kept in sync with `visible_text`'s default: the same text, in the same order,
#: goes into the diagnostics dump as goes to any reader that asks for it.
DEFAULT_TEXT_LIMIT = 20_000

#: Containers whose contents are the page's payload rather than its chrome.
#: Scoping a capture to one of them is what keeps the id list short enough to
#: hand a judge; see `capture_candidates`.
_ROOT_FIELDS = (
    "outlook_week_grid",
    "teams_message_list",
    "teams_channel_list",
)

#: Measures the document. Emits every visible element's own rendered text with
#: its box in *document* coordinates (scroll offset added), so the reading order
#: does not change when the page happens to be scrolled.
_CAPTURE_JS = """
(rootSelector) => {
  const round = (value) => Math.round(value * 100) / 100;
  const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'TITLE']);
  let roots = [];
  if (rootSelector) {
    roots = Array.from(document.querySelectorAll(rootSelector));
  }
  if (!roots.length && document.body) {
    roots = [document.body];
  }
  const found = [];
  const walk = (element, depth) => {
    for (const child of element.children) {
      if (skip.has(child.tagName)) continue;
      const style = window.getComputedStyle(child);
      const hidden =
        style.display === 'none' ||
        style.visibility === 'hidden' ||
        style.opacity === '0' ||
        child.getClientRects().length === 0;
      if (hidden) continue;
      const text = (child.innerText || '').trim();
      const rect = child.getBoundingClientRect();
      if (text) {
        found.push({
          text: text,
          visible: true,
          depth: depth,
          x: round(rect.left + window.scrollX),
          y: round(rect.top + window.scrollY),
          width: round(rect.width),
          height: round(rect.height),
        });
      }
      walk(child, depth + 1);
    }
  };
  for (const root of roots) walk(root, 0);
  return found;
}
"""

#: What a person can read off the page, which is exactly what `innerText` means:
#: it already excludes `display:none` subtrees and folded text.
_VISIBLE_TEXT_JS = "() => (document.body ? document.body.innerText : '')"

#: `innerText` collapses whitespace per line but keeps paragraphs. That is right
#: for the diagnostics dump and wrong for a Candidate: see `_normalise`.
_WHITESPACE_RE = re.compile(r"\s+")

#: Labels are file names in the diagnostics dump, so anything that could escape
#: the directory - or mean something to a shell - is replaced.
_UNSAFE_LABEL_RE = re.compile(r"[^A-Za-z0-9._-]+")

#: The three artefacts one dump writes. Kept together so a stem is only reused
#: when none of them is taken - a half-overwritten dump is worse than two.
_SUFFIXES = (".html", ".png", ".txt")


def capture_candidates(
    page: Page,
    *,
    selectors: Selectors | None = None,
    limit: int = 400,
) -> list[Candidate]:
    """Every visible piece of text on `page`, in reading order, as Candidates.

    Ids are `C000`, `C001`, ... assigned after ordering, so `C042` is the same
    element for every question asked about this capture.

    `selectors` scopes the walk to the page's payload container (Outlook's week
    grid, Teams' message list) when one is present on the page, and leaves it
    unscoped otherwise. Narrowing is not an optimisation: `pli.judge` refuses
    more than `judge.MAX_OPTIONS` (255) candidates in one question, and an
    unscoped week grid plus app chrome comfortably exceeds that.

    `limit` caps the returned list, and the default deliberately sits above
    `judge.MAX_OPTIONS`: a caller with a page it understands - one day column,
    one channel - wants the surplus to slice itself, not to be silently dropped
    before it can. A caller that hands the whole list to `Judge.locate` must
    slice to 255 first or the judge raises.
    """
    root = _root_selector(selectors)
    raw = _evaluate(page, _CAPTURE_JS, root)
    items = [item for item in _coerce_items(raw) if _is_usable(item)]
    items = _drop_outer_duplicates(items)
    ordered = _reading_order(items)
    chosen = ordered[: max(limit, 0)]
    return [
        Candidate(
            id=f"C{index:03d}",
            text=item["text"],
            x=item["x"],
            y=item["y"],
            width=item["width"],
            height=item["height"],
        )
        for index, item in enumerate(chosen)
    ]


def visible_text(page: Page, *, limit: int = DEFAULT_TEXT_LIMIT) -> str:
    """What a person could read off `page`, as one string.

    Used for the diagnostics dump and by readers that want a whole message body
    as prose rather than as candidates. Truncated at `limit` so a runaway page
    cannot write a 50 MB text file into the user's data directory.
    """
    raw = _evaluate(page, _VISIBLE_TEXT_JS)
    if not isinstance(raw, str):
        return ""
    return raw[: max(limit, 0)]


def diagnostics(page: Page, settings: Settings, *, label: str) -> Path:
    """Dump the page so the user can send back what a broken selector saw.

    Writes `data/diagnostics/<UTC timestamp>-<label>.html`, `.png` (full page),
    `.txt` and `.url` into the diagnostics directory and returns that directory.

    The `.url` is not decoration. A reader that stopped matching has two very
    different causes - the page was restyled, or the page is not the page we
    asked for - and the HTML alone often cannot tell them apart, because a
    sign-in wall and a redesigned calendar both just fail to match. Which URL
    the browser actually landed on is the first question anyone reading one of
    these dumps asks, and it was the one thing these dumps did not record.

    Never raises. This is the failure path - it is called from the `except` block
    of a read that has already gone wrong - so a page that closes mid-dump must
    cost the dump, not the report of what happened. Each artefact is written
    independently for the same reason: a screenshot that fails on a page taller
    than the GPU limit still leaves the HTML and the text, which are usually
    enough to find the new attribute.
    """
    directory = settings.home / "diagnostics"
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    with contextlib.suppress(OSError):
        directory.mkdir(parents=True, exist_ok=True)
    stem = _free_stem(directory, f"{stamp}-{_safe_label(label)}")
    _write_text(directory / f"{stem}.html", _page_html(page))
    _write_screenshot(page, directory / f"{stem}.png")
    _write_text(directory / f"{stem}.txt", _page_text(page))
    _write_text(directory / f"{stem}.url", _page_url(page))
    return directory


# --- page calls -----------------------------------------------------------------


def _evaluate(page: Page, script: str, argument: Any = None) -> Any:
    """Run one script in the page.

    A failure here is raised rather than swallowed, because the empty result it
    would otherwise become is indistinguishable from "this page has no events".
    """
    try:
        return page.evaluate(script, argument)
    except BrowserError:
        raise
    except Exception as exc:
        raise BrowserError(
            f"The page could not be read ({type(exc).__name__}: {exc}). It may have "
            "navigated mid-read; retry, and dump the page with a diagnostics capture "
            "if it keeps happening."
        ) from exc


def _page_html(page: Page) -> str | None:
    try:
        html = page.content()
    except Exception:  # noqa: BLE001 - the failure path must not fail
        return None
    return html if isinstance(html, str) else None


def _page_text(page: Page) -> str | None:
    try:
        return visible_text(page)
    except Exception:  # noqa: BLE001 - the failure path must not fail
        return None


def _page_url(page: Page) -> str | None:
    """The address the browser is actually on, query string and all.

    Kept whole rather than trimmed to host and path the way the user-facing
    messages trim it: those are read by the person who has to fix their session,
    and an OAuth query string tells them nothing. This is read by whoever has to
    fix the *reader*, and there the parameters are the evidence - which tenant,
    which flow, which wall.
    """
    try:
        url = page.url
    except Exception:  # noqa: BLE001 - the failure path must not fail
        return None
    return url if isinstance(url, str) and url else None


def _write_text(path: Path, content: str | None) -> None:
    if content is None:
        return
    with contextlib.suppress(OSError):
        path.write_text(content, encoding="utf-8")


def _write_screenshot(page: Page, path: Path) -> None:
    try:
        page.screenshot(path=str(path), full_page=True)
    except Exception:  # noqa: BLE001 - the failure path must not fail
        # A half-written png is worse than none: it looks like evidence.
        with contextlib.suppress(OSError):
            path.unlink(missing_ok=True)


# --- measurement -> candidates --------------------------------------------------


def _root_selector(selectors: Selectors | None) -> str:
    """The payload containers to scope the walk to, as one selector."""
    if selectors is None:
        return ""
    return ", ".join(getattr(selectors, name) for name in _ROOT_FIELDS)


def _coerce_items(raw: Any) -> list[dict[str, Any]]:
    """Whatever `page.evaluate` returned, turned into usable measurements.

    Defensive on purpose: the value crossed a language boundary, so `None`, a
    dict, a list of strings, or an entry missing its coordinates are all
    possible and none of them is a reason to fail a read that mostly worked.
    """
    if not isinstance(raw, list):
        return []
    items: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        text = entry.get("text")
        if not isinstance(text, str):
            continue
        normalised = _normalise(text)
        if not normalised:
            continue
        items.append(
            {
                # Truncated, not dropped: a 300-character preface still says
                # which deadline the paragraph is about.
                "text": normalised[:MAX_TEXT],
                "visible": entry.get("visible", True) is not False,
                "depth": int(_number(entry.get("depth"))),
                "x": _number(entry.get("x")),
                "y": _number(entry.get("y")),
                "width": _number(entry.get("width")),
                "height": _number(entry.get("height")),
            }
        )
    return items


def _normalise(text: str) -> str:
    """Collapse every run of whitespace to one space.

    `Candidate.text` is otherwise verbatim, and this is the one exception. The
    reason is `judge.label_candidates`, which renders candidates as
    `id|text` joined by newlines: an embedded newline would produce a line that
    looks exactly like another labelled candidate, and the model could then
    answer with a fragment of one element's own text as though it were a
    different element's id.
    """
    return _WHITESPACE_RE.sub(" ", text).strip()


def _number(value: Any) -> float:
    """A finite float from whatever JSON produced, or 0.0.

    `bool` is excluded deliberately - `True` is an `int` in Python, and a stray
    boolean geometry would silently become a one-pixel box.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")):
        return 0.0
    return number


def _is_usable(item: dict[str, Any]) -> bool:
    """Whether this measurement can be a choice for the judge.

    Blank text is already gone. What remains is: it has to occupy space on the
    screen. A zero-width or zero-height element is not something a person can
    point at, and offering it to the model would let an answer land on a hidden
    duplicate of the real element.
    """
    if not item["visible"]:
        return False
    return item["width"] > 0 and item["height"] > 0


def _drop_outer_duplicates(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Of several elements carrying the same text, keep the innermost.

    Only nested copies are collapsed. Two cells showing "Mon" side by side are
    two facts about two columns and both stay; a `div` wrapping a `span` with
    identical text is one fact, and the span is the one that says where it is -
    the outer element's box is the container's, which is the one piece of
    geometry that is useless when the judge is asked which cell this is.
    """
    groups: dict[str, list[dict[str, Any]]] = {}
    for item in items:
        groups.setdefault(item["text"], []).append(item)
    kept: list[dict[str, Any]] = []
    for group in groups.values():
        if len(group) == 1:
            kept.append(group[0])
            continue
        for item in group:
            if any(_wraps(item, other) for other in group if other is not item):
                continue
            kept.append(item)
    return kept


def _wraps(outer: dict[str, Any], inner: dict[str, Any]) -> bool:
    """Whether `outer` is an ancestor of `inner`, by depth and box."""
    if outer["depth"] >= inner["depth"]:
        return False
    tolerance = BOX_TOLERANCE_PX
    return (
        outer["x"] - tolerance <= inner["x"]
        and outer["y"] - tolerance <= inner["y"]
        and outer["x"] + outer["width"] + tolerance >= inner["x"] + inner["width"]
        and outer["y"] + outer["height"] + tolerance >= inner["y"] + inner["height"]
    )


def _reading_order(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Sort down the page and across each line.

    Items are banded into lines by their top edge, and each band is then sorted
    by x. Sorting on y alone would reorder a row whose cells are a couple of
    pixels out of alignment, which is the normal state of a rendered week grid.
    """
    ordered: list[dict[str, Any]] = []
    band: list[dict[str, Any]] = []
    previous_y: float | None = None
    for item in sorted(items, key=lambda entry: (entry["y"], entry["x"])):
        if previous_y is None or abs(item["y"] - previous_y) <= LINE_TOLERANCE_PX:
            band.append(item)
        else:
            ordered.extend(sorted(band, key=lambda entry: entry["x"]))
            band = [item]
        # The band's own top edge, so a line of text that drifts downwards as it
        # wraps does not start a new line on every item.
        previous_y = band[0]["y"]
    ordered.extend(sorted(band, key=lambda entry: entry["x"]))
    return ordered


def _safe_label(label: str) -> str:
    """A file-name-safe form of the caller's label."""
    cleaned = _UNSAFE_LABEL_RE.sub("_", str(label or "")).strip("._-")
    return cleaned[:60] or "page"


def _free_stem(directory: Path, stem: str) -> str:
    """A stem no earlier dump is already using.

    Two dumps inside one second is the normal case, not the rare one: a read
    fails, the user retries, and the second failure lands in the same second as
    the first. Overwriting would delete the evidence for the failure that made
    them retry, so a suffix is added instead.
    """
    candidate = stem
    suffix = 2
    while any((directory / f"{candidate}{extension}").exists() for extension in _SUFFIXES):
        candidate = f"{stem}-{suffix}"
        suffix += 1
    return candidate
