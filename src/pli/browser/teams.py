"""Teams channel posts, read from the web client the user is already signed in to.

This module is the reason the project left Graph behind. `ChannelMessage.Read.All`
needs tenant admin consent, which a student cannot grant, so the API route to the
one place a lecturer announces that a deadline moved was closed. The browser is
not: the user can see their channels, so the browser can read them.

Everything below follows from that. A page that a person is looking at is not an
API, so the rules are:

**Read only what is already visible to the user.** Every channel reached here is
one the sidebar already lists. Nothing searches, joins, or enumerates a channel
the user is not in, and nothing is ever written: there is no `send_message`.
Opening a channel and scrolling it is the whole footprint.

**One bad channel must not lose the others.** A channel that fails to load is
logged and skipped, exactly as `pli.sources.base.iter_all` isolates a failing
source. The one exception is a message list that cannot be read *at all* - that
raises, because returning `[]` would claim "this channel has no messages", which
is a statement about the user's courses that a broken selector must never make.
The evidence for the raise is a screenshot and a DOM dump on disk, named in the
error, so a selector mismatch can be diagnosed without a live browser.

**The model reads, code computes, and nothing is paraphrased.** The judge decides
which captured text is a channel post, whether a post is about assessment at all,
which course it belongs to, and what date words it uses. It is never asked what
datetime something is, and it never writes a message body: bodies are sliced
verbatim out of the text the page rendered, and a post whose body cannot be cut
out cleanly is dropped rather than summarised. A paraphrase of "quiz moved to
Friday" that silently loses the Friday is worse than no message at all.

**Every probability stays raw.** This reader does not decide what is important.
It returns every post it can see and leaves P(deadline) and P(course) for the
caller via `last_judgements`, because what counts as certain enough to influence
a study plan is a policy the caller owns.

`external_id` is `teams:` plus the first 32 hex characters of a SHA-256 over
team, channel, author, timestamp and body. The timestamp is the page's own
rendered stamp resolved to UTC, and the body is verbatim page text, so a repeat
read of the same post produces the same id and the `messages` table upserts
instead of duplicating. The body is deliberately part of the hash: hashing
without it would collapse two posts an author made in the same minute, silently
losing one, whereas an edited post merely gets a second row.
"""

from __future__ import annotations

import hashlib
import logging
import re
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from typing import TYPE_CHECKING, Any
from zoneinfo import ZoneInfo

from pli.browser import BrowserError, SessionError
from pli.config import Settings
from pli.judge import (
    MAX_OPTIONS,
    MAX_QUESTIONS_PER_CALL,
    Candidate,
    Judge,
    Judgements,
    label_candidates,
    parse_clock,
)
from pli.models import ChannelMessage

if TYPE_CHECKING:  # pragma: no cover - the browser is never needed to import this
    from playwright.sync_api import Page

__all__ = [
    "DateParts",
    "PostJudgement",
    "TeamChannel",
    "clear_judgements",
    "last_judgements",
    "list_channels",
    "parse_posted_at",
    "read_channel",
    "read_messages",
    "resolve_relative_date",
]

log = logging.getLogger(__name__)

SOURCE = "teams"

#: How many of the page's text fragments to consider at once.
MESSAGE_CANDIDATES = 400
#: P(a captured fragment is a channel post). Deliberately low: this question
#: sorts posts from furniture (nav labels, reaction counts, "See more"), and
#: carrying a fragment that turns out to be furniture costs one extra question,
#: while dropping a real post loses a deadline announcement.
MESSAGE_FLOOR = 0.5
#: The option that lets the judge say a post has no course here, so a message is
#: never forced onto a course that does not own it.
NONE_LABEL = "none"
#: P(the judge named a month/day/course). Anything below this counts as "did not
#: say", so a half-remembered date never becomes a resolved one.
ANSWER_FLOOR = 0.5
#: A post's author and posted time sit above its body by at most this much.
HEADER_LOOKBACK_PX = 180.0
#: File-looking text in a post's own block is an attachment it names.
ATTACHMENT_RE = re.compile(
    r"[\w][\w .()\-]{0,80}\.(?:pdf|docx?|pptx?|xlsx?|zip|csv|txt|md|ipynb|py|png|jpe?g)\s*$",
    re.IGNORECASE,
)
#: Give up on scrolling after this many passes. A channel a user has never read
#: deepens without limit; the run has to end.
MAX_SCROLLS = 40
SCROLL_DELTA_PX = 900
SETTLE_MS = 700
#: Two passes that produce nothing new in a row mean the list has stopped
#: yielding older posts.
STALL_LIMIT = 2
#: How far into the past a month/day with no year may land before the year rolls
#: forward. A post read just after a date it names is far more likely to be
#: describing that date than one eleven months past.
PAST_GRACE_DAYS = 7

MONTHS: dict[str, int] = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}
WEEKDAYS: dict[str, int] = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}
#: Relative words the judge may name, and how many days each is from the anchor.
RELATIVE_DAYS = {"today": 0, "tomorrow": 1, "yesterday": -1, "next_weekday": None}


@dataclass(frozen=True)
class TeamChannel:
    """One channel the user can see, as the sidebar groups it."""

    team: str
    channel: str


@dataclass(frozen=True)
class DateParts:
    """What a post says about a date, before Python turns it into one.

    Only the parts the text actually names: which month, which day number, which
    weekday, and whether the wording was relative. The model reports these; it
    never reports a date, because that would be arithmetic it cannot do
    reliably, cannot be asked about DST, and whose mistakes are invisible.
    """

    stated: bool = False
    month: int | None = None
    day: int | None = None
    weekday: str | None = None
    relative: str | None = None


@dataclass(frozen=True)
class PostJudgement:
    """The model's opinion of one post, kept out of the frozen message model.

    `ChannelMessage` has nowhere to put a probability, and inventing a field on
    a contract every other module codes against would be worse than handing the
    numbers back beside it. The reader applies no thresholds to any of these.
    """

    external_id: str
    #: P(this post announces, changes or reminds about a deadline or assessment).
    deadline: float
    #: The channel's own team when the post belongs to that course, else None.
    course: str | None
    course_confidence: float
    #: The date the post names, resolved in Python against the post's own
    #: timestamp. None when it names no day.
    due_at: datetime | None


@dataclass(frozen=True)
class _Block:
    """One message element's structured header, read from the DOM.

    Heads are read from the DOM rather than judged because they are the one part
    of a Teams post that is genuinely structured; the body still comes from the
    captured text so that nothing the model touched can reach `body`.
    """

    box: tuple[float, float, float, float] | None
    author: str = ""
    time_text: str = ""


@dataclass(frozen=True)
class _Post:
    """A post before and after judging: the page's text plus code's reading."""

    candidate: Candidate
    author: str
    time_text: str
    posted_at: datetime
    #: False when the page's stamp could not be read and the read clock stood in.
    timestamp_read: bool
    body: str
    attachments: tuple[str, ...] = ()

    def external_id(self, team: str, channel: str) -> str:
        stamp = self.posted_at.isoformat() if self.timestamp_read else self.time_text
        return _external_id(team, channel, self.author, stamp, self.body)


@dataclass
class _Collection:
    """Posts gathered from one channel, in the order they first appeared."""

    posts: list[_Post] = field(default_factory=list)
    since_covered: bool = False


#: The judgements from the most recent top-level read, keyed by `external_id`.
_JUDGEMENTS: dict[str, PostJudgement] = {}


def last_judgements() -> dict[str, PostJudgement]:
    """What the judge said about the messages the last read returned.

    The caller applies its own thresholds to `PostJudgement.deadline` and picks
    a course from `PostJudgement.course`; this reader filters on neither, so a
    post that says nothing about assessment is still returned, with a low
    probability, rather than being silently dropped here.
    """
    return dict(_JUDGEMENTS)


def clear_judgements() -> None:
    _JUDGEMENTS.clear()


# --- thin wrappers over the modules another agent owns ------------------------
# Imported lazily so this module imports while its neighbours are still being
# written, and so tests can replace each seam with a small fake instead of a
# browser.


def _selectors(path: Path | None = None) -> Any:
    from pli.browser.selectors import load

    return load(path)


@contextmanager
def _session(settings: Settings) -> Iterator[Page]:
    from pli.browser.session import session

    with session(settings) as page:
        yield page


def _capture_candidates(page: Page, *, selectors: Any, limit: int) -> list[Candidate]:
    from pli.browser.capture import capture_candidates

    return capture_candidates(page, selectors=selectors, limit=limit)


def _diagnostics(page: Page, settings: Settings, *, label: str) -> Path:
    from pli.browser.capture import diagnostics

    return diagnostics(page, settings, label=label)


def _choice(instructions: str, criteria: dict[str, str | None]) -> Any:
    from typesafe_sdk import Choice

    return Choice(instructions=instructions, criteria=criteria)


def _noul(instructions: str) -> Any:
    from typesafe_sdk import Noul

    return Noul(instructions=instructions)


def _now() -> datetime:
    return datetime.now(UTC)


# --- the sidebar --------------------------------------------------------------


def list_channels(page: Page, *, settings: Settings | None = None) -> list[TeamChannel]:
    """Every (team, channel) the user can see, from the Teams sidebar.

    The sidebar shows one team's channels at a time, so this walks the teams
    already in the rail and reads whatever channels appear under each. It only
    ever clicks entries the rail already offers: a team the user is not a member
    of is not in the rail, and nothing here searches for one.

    The page must already be showing Teams - `read_messages` navigates there, and
    a caller driving its own page navigates it itself. Pass `settings` and a
    sidebar that yields nothing is captured to diagnostics before it raises;
    without them the message says the page could not be saved.

    An empty sidebar is **not** evidence of a signed-out profile. `read_messages`
    checks the session the moment Teams is open - see `_open_teams` - so by the
    time this runs the session is known to be good, and the only thing left that
    can empty the rail is the query for it. Asserting otherwise here, as this
    used to, is how a restyled sidebar sends someone to sign in again when what
    they needed was a line in config/browser.toml.
    """
    selectors = _selectors()
    found: dict[tuple[str, str], TeamChannel] = {}
    teams = _team_elements(page, selectors)
    for element in teams:
        team = _label(element)
        if not team:
            continue
        try:
            element.click()
            page.wait_for_timeout(SETTLE_MS)
        except Exception as exc:  # noqa: BLE001 - one unreachable team must not lose the rest
            log.warning("teams: could not open the %r team (%s: %s)", team, type(exc).__name__, exc)
            continue
        for item in _channel_items(page, selectors):
            channel = _label(item)
            # The channel list also carries thread and meeting entries. A blank
            # label is not a channel, and a repeat is the same channel revisited.
            if channel:
                found.setdefault((team, channel), TeamChannel(team=team, channel=channel))

    if not teams and not found:
        reason = (
            f"The Teams sidebar offered no teams at {selectors.teams_app_bar!r} and no "
            f"channels at {selectors.teams_channel_item!r}, so there is nothing to read. "
            f"The saved profile was signed in, or the page would have been refused as a "
            f"sign-in screen before this point - so the sidebar query is what stopped "
            f"matching, most likely because Teams was restyled."
        )
        if settings is None:
            raise BrowserError(f"{reason} The page was not captured for this failure.")
        _fail(page, settings, label="teams-sidebar", reason=reason)
    return list(found.values())


def _team_elements(page: Page, selectors: Any) -> list[Any]:
    return list(page.query_selector_all(selectors.teams_app_bar))


def _channel_items(page: Page, selectors: Any) -> list[Any]:
    container = page.query_selector(selectors.teams_channel_list)
    if container is None:
        return list(page.query_selector_all(selectors.teams_channel_item))
    return list(container.query_selector_all(selectors.teams_channel_item))


def _label(element: Any) -> str:
    """A sidebar entry's name.

    `aria-label` first: it is the name without the unread badge Teams appends to
    the visible text, and reading "General 3" as the channel would mean the
    channel is never recognised on the next run.
    """
    for attribute in ("aria-label", "title"):
        try:
            value = element.get_attribute(attribute)
        except Exception:  # noqa: BLE001 - an attribute probe must never abort a read
            value = None
        if value and value.strip():
            return value.strip()
    try:
        text = element.inner_text() or ""
    except Exception:  # noqa: BLE001
        return ""
    return text.strip().splitlines()[0].strip() if text.strip() else ""


# --- opening one channel ------------------------------------------------------


def _open_teams(page: Page, settings: Settings, selectors: Any) -> None:
    """Open Teams, and say so plainly when the session has expired.

    The check has to happen here, before anything is looked for. A signed-out
    profile does not fail the navigation: Teams serves a sign-in page, the
    sidebar is empty, and "no teams in the sidebar" is then indistinguishable
    from a restyled channel list. Only one of those is fixed by signing in, and
    guessing wrong sends the user to edit a selector that was never broken.
    """
    from pli.browser.session import require_signed_in

    page.goto(settings.teams_url)
    page.wait_for_timeout(SETTLE_MS)
    require_signed_in(page)


def _open_channel(
    page: Page, settings: Settings, selectors: Any, *, team: str, channel: str
) -> None:
    """Click the channel in the sidebar, never searching for it.

    Membership is the access control: if the rail does not offer the channel, it
    is not read. Reading whatever happened to be on screen instead would attach
    another channel's posts to the team the caller asked for.
    """
    if not _team_elements(page, selectors) and not _channel_items(page, selectors):
        _open_teams(page, settings, selectors)

    for element in _team_elements(page, selectors):
        if _label(element) == team:
            element.click()
            page.wait_for_timeout(SETTLE_MS)
            break

    for item in _channel_items(page, selectors):
        if _label(item) == channel:
            item.click()
            page.wait_for_timeout(SETTLE_MS)
            return

    raise BrowserError(
        f"the Teams sidebar does not list the channel {channel!r} under {team!r}. "
        "This reader only reads channels the user is already a member of; if the "
        "channel exists, check config/browser.toml against the page."
    )


# --- scrolling older posts into view ------------------------------------------


def _scroll_top(container: Any) -> float | None:
    try:
        return float(container.evaluate("el => el.scrollTop") or 0)
    except Exception:  # noqa: BLE001 - a container we cannot scroll is a stall, not a crash
        return None


def _scroll_up(page: Page, container: Any, *, delta: int = SCROLL_DELTA_PX) -> bool:
    """Ask the message list for older posts. True when anything moved."""
    if container is None:
        page.mouse.wheel(0, -delta)
        return True
    before = _scroll_top(container)
    if before is None:
        return False
    container.evaluate("(el, d) => { el.scrollTop = Math.max(0, el.scrollTop - d); }", delta)
    after = _scroll_top(container)
    return after is not None and after < before


def _click_more_messages(page: Page, selectors: Any) -> bool:
    """Some views put an explicit "older messages" control at the top."""
    button = page.query_selector(selectors.teams_more_messages)
    if button is None:
        return False
    try:
        button.click()
    except Exception:  # noqa: BLE001
        return False
    page.wait_for_timeout(SETTLE_MS)
    return True


def _should_stop(
    *,
    found: int,
    new: int,
    max_messages: int,
    stalls: int,
    since_covered: bool,
) -> bool:
    """Whether to stop pulling older posts into view.

    Loading older posts is the one expensive thing this reader does, so the
    stopping rule is explicit rather than implied by the scroll position: stop
    when enough posts are in hand, when the list has twice in a row produced
    nothing older, or when what is in hand already predates `since`, because
    there is nothing further back that could be wanted.
    """
    if found >= max_messages:
        return True
    if since_covered:
        return True
    return stalls >= STALL_LIMIT


def _readability(container: Any, candidates: Sequence[Candidate], blocks: Sequence[_Block]) -> str:
    """Whether the message list was read: "ok", "empty", or "broken".

    An empty channel and a channel whose posts did not parse look identical from
    the outside, and must not: "no messages" is a claim about the user's
    courses. It is only made when the message list itself was found and holds
    nothing.
    """
    if candidates or blocks:
        return "ok"
    return "empty" if container is not None else "broken"


def _fail(page: Page, settings: Settings, *, label: str, reason: str) -> None:
    """Save the evidence, then raise naming it.

    The screenshot and DOM dump are the only way to tell a redesign from an
    expired session after the fact, so the path goes in the message.
    """
    path = _diagnostics(page, settings, label=label)
    raise BrowserError(f"{reason} Diagnostics saved to {path}.")


# --- turning captured text into posts -----------------------------------------


def _selection_candidates(candidates: Sequence[Candidate]) -> list[Candidate]:
    """The subsets of the page worth offering to the post-selection question.

    A Jev Choice takes at most MAX_OPTIONS options, so an oversized capture is
    trimmed by text length: a channel post is longer than a nav label, a reaction
    count or a timestamp, which is exactly the furniture being sorted out. Page
    order is restored afterwards, because the geometry below depends on it.
    """
    if len(candidates) <= MAX_OPTIONS:
        return list(candidates)
    longest = sorted(candidates, key=lambda c: (-len(c.text), c.id))[:MAX_OPTIONS]
    keep = {c.id for c in longest}
    return [c for c in candidates if c.id in keep]


def _post_block(candidate: Candidate, blocks: Sequence[_Block]) -> _Block | None:
    """The message element this candidate was captured from, if any.

    Matched by geometry: the element whose box contains the candidate. The join
    is needed because the body must come from the captured text while the header
    comes from the DOM.
    """
    cx = candidate.x + candidate.width / 2
    cy = candidate.y + candidate.height / 2
    for block in blocks:
        if block.box is None:
            continue
        bx, by, bw, bh = block.box
        if bx <= cx <= bx + bw and by <= cy <= by + bh:
            return block
    return None


def _header(candidate: Candidate, others: Sequence[Candidate], *, now: datetime, tz: ZoneInfo):
    """The author and posted time of a post, from the candidates around it.

    Teams stacks a post as a header row (sender and time) with the body beneath,
    so the header is the nearest candidate above the body that is not itself a
    timestamp. Used when the message element could not be matched.
    """
    above = [
        c
        for c in others
        if c.id != candidate.id
        and 0 <= candidate.y - c.y <= HEADER_LOOKBACK_PX
        and c.row < candidate.row
    ]
    above.sort(key=lambda c: (candidate.y - c.y, c.x))
    time_text = ""
    author = ""
    for other in above:
        text = other.text.strip()
        if not time_text and parse_posted_at(text, now=now, tz=tz) is not None:
            time_text = text
            continue
        if not author:
            author = text
    return author, time_text


def _slice_body(text: str, author: str, time_text: str) -> str | None:
    """The post's body, cut out of the captured text verbatim.

    Nothing is generated here. A capture that returned the whole post removes the
    header strings by literal match - the first occurrence, which is the header -
    and what is left is the page's own words; a capture that returned the body
    alone leaves it untouched. Either way `body` is a substring of what the page
    showed. A cut that leaves nothing is not readable verbatim, and a post with
    no readable body is dropped rather than summarised.
    """
    body = text
    for known in (author, time_text):
        if known and known in body:
            body = body.replace(known, "", 1)
    body = body.strip()
    return body or None


def _attachments(candidates: Sequence[Candidate], *, top: float, bottom: float) -> tuple[str, ...]:
    """Files named inside one post's own block."""
    names: list[str] = []
    for candidate in candidates:
        if not (top <= candidate.y < bottom):
            continue
        text = candidate.text.strip()
        if ATTACHMENT_RE.search(text) and text not in names:
            names.append(text)
    return tuple(names)


def _extract_posts(
    candidates: Sequence[Candidate],
    blocks: Sequence[_Block],
    *,
    others: Sequence[Candidate] | None = None,
    now: datetime,
    tz: ZoneInfo,
) -> list[_Post]:
    """Turn captured text into posts. No model is involved.

    `candidates` are the fragments the judge selected as channel posts, in page
    order; `blocks` are the message elements found by selector. Each selected
    fragment becomes a post with its header read from its own message element, or
    from the fragments above it when no element could be matched.

    `others` is every fragment on the page. It is used to find the files a post
    names and to read a header when no element matched, and in both cases the
    selected fragments are the wrong set to look in: a file name and an author
    line are each usually their own short fragment, and a fragment that is not a
    post is not offered to the selection question in the first place.
    """
    ordered = sorted(candidates, key=lambda c: (c.y, c.x))
    page_fragments = list(others) if others is not None else ordered
    posts: list[_Post] = []
    for index, candidate in enumerate(ordered):
        block = _post_block(candidate, blocks)
        if block is not None:
            author, time_text = block.author, block.time_text
        else:
            author, time_text = _header(candidate, page_fragments, now=now, tz=tz)
        body = _slice_body(candidate.text, author, time_text)
        if body is None:
            log.debug("teams: dropping a fragment with no readable body: %r", candidate.text[:60])
            continue
        stamp = parse_posted_at(time_text, now=now, tz=tz)
        following = ordered[index + 1].y if index + 1 < len(ordered) else float("inf")
        attachments = _attachments(
            page_fragments, top=candidate.y + candidate.height, bottom=following
        )
        posts.append(
            _Post(
                candidate=candidate,
                author=author,
                time_text=time_text,
                posted_at=stamp or now,
                timestamp_read=stamp is not None,
                body=body,
                attachments=attachments,
            )
        )
    return posts


def _external_id(team: str, channel: str, author: str, stamp: str, body: str) -> str:
    """A stable id for one post, derived only from what the page showed.

    Deterministic on purpose: the same post read twice must upsert rather than
    duplicate in the `messages` table.
    """
    material = "\x1f".join((team, channel, author, stamp, body))
    return f"{SOURCE}:{hashlib.sha256(material.encode('utf-8')).hexdigest()[:32]}"


# --- reading one channel ------------------------------------------------------


def read_channel(
    settings: Settings,
    judge: Judge,
    *,
    team: str,
    channel: str,
    page: Page | None = None,
    max_messages: int = 100,
) -> list[ChannelMessage]:
    """The most recent posts in one channel the user is a member of, newest last.

    A `page` is taken when the caller already has a signed-in one - reading many
    channels through one session is the normal case - and opened here otherwise.
    """
    _JUDGEMENTS.clear()
    if page is not None:
        return _read_channel(
            settings, judge, team=team, channel=channel, page=page, max_messages=max_messages
        )
    with _session(settings) as owned:
        return _read_channel(
            settings, judge, team=team, channel=channel, page=owned, max_messages=max_messages
        )


def read_messages(
    settings: Settings,
    judge: Judge,
    *,
    since: datetime,
    teams: Sequence[str] | None = None,
    max_per_channel: int = 100,
) -> list[ChannelMessage]:
    """Every post newer than `since`, across every channel the user can see.

    One broken channel does not stop the others, mirroring `iter_all`: the
    failure is logged with the channel that caused it and the read continues, so
    a single redesign cannot cost the announcements in the other nine channels.
    """
    if since.tzinfo is None or since.tzinfo.utcoffset(since) is None:
        raise ValueError("`since` must be timezone-aware")
    since = since.astimezone(UTC)
    _JUDGEMENTS.clear()
    wanted = set(teams) if teams is not None else None

    found: list[ChannelMessage] = []
    with _session(settings) as page:
        _open_teams(page, settings, _selectors())
        for target in list_channels(page, settings=settings):
            if wanted is not None and target.team not in wanted:
                continue
            try:
                messages = _read_channel(
                    settings,
                    judge,
                    team=target.team,
                    channel=target.channel,
                    page=page,
                    max_messages=max_per_channel,
                    since=since,
                )
            except SessionError:
                # Not a channel that broke - a profile that is no longer signed
                # in, which every channel after this one fails the same way. It
                # goes up instead of being skipped like one: returning the posts
                # read before it would hand the caller a half-read channel list
                # that looks finished, and the cursor would move past the
                # announcements nobody looked at. `pli sync` turns a
                # `SessionError` into "not read", which is what this is.
                raise
            except Exception as exc:  # noqa: BLE001 - deliberate per-channel isolation
                log.warning(
                    "teams: skipping %s / %s (%s: %s)",
                    target.team,
                    target.channel,
                    type(exc).__name__,
                    exc,
                )
                continue
            # A post older than `since` is not stored. The reader itself does not
            # know the window, so the cut happens here, where it was asked for.
            found.extend(message for message in messages if message.posted_at >= since)
    return found


def _read_channel(
    settings: Settings,
    judge: Judge,
    *,
    team: str,
    channel: str,
    page: Page,
    max_messages: int,
    since: datetime | None = None,
) -> list[ChannelMessage]:
    selectors = _selectors()
    _open_channel(page, settings, selectors, team=team, channel=channel)
    tz = settings.timezone()
    label = f"teams-{_slug(team)}-{_slug(channel)}"

    collection = _collect(
        settings,
        judge,
        page=page,
        selectors=selectors,
        team=team,
        channel=channel,
        tz=tz,
        max_messages=max_messages,
        since=since,
        label=label,
    )
    if not collection.posts:
        return []

    posts = collection.posts[:max_messages]
    _JUDGEMENTS.update(_judge_posts(judge, posts, team=team, channel=channel, tz=tz))
    return [
        ChannelMessage(
            source=SOURCE,
            external_id=post.external_id(team, channel),
            team=team,
            channel=channel,
            author=post.author,
            posted_at=post.posted_at,
            body=post.body,
            attachments=list(post.attachments),
        )
        for post in posts
    ]


def _collect(
    settings: Settings,
    judge: Judge,
    *,
    page: Page,
    selectors: Any,
    team: str,
    channel: str,
    tz: ZoneInfo,
    max_messages: int,
    since: datetime | None,
    label: str,
) -> _Collection:
    """Scroll the channel until the stopping rule fires, judging as it goes.

    Which captured fragments are posts is asked once per pass, because that
    question is about the fragments currently on screen. The questions about
    meaning are asked once, over everything gathered, since those are about
    posts and not about the viewport.
    """
    collection = _Collection()
    seen: set[str] = set()
    stalls = 0
    first = True
    for _ in range(MAX_SCROLLS):
        container = page.query_selector(selectors.teams_message_list)
        raw = list(_capture_candidates(page, selectors=selectors, limit=MESSAGE_CANDIDATES))
        blocks = _message_blocks(page, selectors)
        if first:
            state = _readability(container, raw, blocks)
            if state == "broken":
                _fail(
                    page,
                    settings,
                    label=label,
                    reason=(
                        "the Teams message list could not be read, so this channel's posts are "
                        "unknown rather than empty."
                    ),
                )
            first = False

        now = _now()
        fresh = 0
        for post in _selected_posts(judge, raw, blocks, now=now, tz=tz):
            key = post.external_id(team, channel)
            if key in seen:
                continue
            seen.add(key)
            collection.posts.append(post)
            fresh += 1
            # Only a stamp the page actually showed can say the window is
            # covered; one that fell back to the read clock says nothing.
            if since is not None and post.timestamp_read and post.posted_at < since:
                collection.since_covered = True

        if _should_stop(
            found=len(collection.posts),
            new=fresh,
            max_messages=max_messages,
            stalls=stalls,
            since_covered=collection.since_covered,
        ):
            break
        stalls = 0 if fresh else stalls + 1
        moved = _scroll_up(page, container)
        if not moved and not _click_more_messages(page, selectors):
            page.wait_for_timeout(SETTLE_MS)
    return collection


def _selected_posts(
    judge: Judge,
    candidates: Sequence[Candidate],
    blocks: Sequence[_Block],
    *,
    now: datetime,
    tz: ZoneInfo,
) -> list[_Post]:
    """Ask which fragments are posts, then read the selected ones."""
    offered = _selection_candidates(candidates)
    if not offered:
        return []
    answers = _ask_batched(
        judge,
        label_candidates(offered),
        {"is_post": _choice(_SELECT_INSTRUCTIONS, {c.id: None for c in offered})},
    )
    by_id = {c.id: c for c in offered}
    ranked = answers.ranked("is_post", minimum=MESSAGE_FLOOR)
    chosen = [by_id[cid] for cid, _ in ranked if cid in by_id]
    # `others` is everything captured, not `offered`: an author line or a file
    # name is short, so the trim above is exactly what would drop them.
    return _extract_posts(chosen, blocks, others=candidates, now=now, tz=tz)


def _message_blocks(page: Page, selectors: Any) -> list[_Block]:
    """The message elements on screen, with their headers read from the DOM."""
    blocks: list[_Block] = []
    for element in page.query_selector_all(selectors.teams_message):
        box = None
        raw_box = element.bounding_box()
        if raw_box:
            box = (
                float(raw_box.get("x", 0.0)),
                float(raw_box.get("y", 0.0)),
                float(raw_box.get("width", 0.0)),
                float(raw_box.get("height", 0.0)),
            )
        blocks.append(
            _Block(
                box=box,
                author=_child_text(element, selectors.teams_message_author),
                time_text=_child_text(element, selectors.teams_message_time),
            )
        )
    return blocks


def _child_text(element: Any, selector: str) -> str:
    if not selector:
        return ""
    try:
        child = element.query_selector(selector)
    except Exception:  # noqa: BLE001
        return ""
    if child is None:
        return ""
    try:
        return (child.inner_text() or "").strip()
    except Exception:  # noqa: BLE001
        return ""


def _slug(text: str) -> str:
    """A label safe to put in a diagnostics file name."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("_")[:60] or "channel"


# --- asking the judge about posts ---------------------------------------------

_SELECT_INSTRUCTIONS = (
    "Each option is one piece of text captured from a Microsoft Teams channel view, "
    "shown as `id|text`. Select EVERY option that is the text of a whole channel post - "
    "a message a person wrote in the channel conversation. Do not select navigation "
    "labels, team or channel names, toolbar buttons, reaction counts, a bare timestamp, "
    "'See more' links, or the text of the channel header. More than one option may "
    "qualify, and more than one should be selected when several posts are on screen."
)
_DEADLINE_INSTRUCTIONS = (
    "This is one post from a university course channel. Does it announce, change or "
    "remind about a deadline, an assessment or required work - an exam, quiz, "
    "assignment, submission, presentation, lab or similar? Answer yes only if a person "
    "reading the post would learn that something is due, or that something they must do "
    "has changed."
)
_STATED_INSTRUCTIONS = (
    "Does this post name a specific calendar day for that work - a date, a weekday, "
    "'tomorrow', 'next Monday' or similar? Answer no if it names no day at all, or only "
    "a time of day."
)
_MONTH_INSTRUCTIONS = (
    "Which month does this post name as the day the work is due? Choose the month only "
    f"if the post names one; otherwise choose {NONE_LABEL!r}."
)
_DAY_INSTRUCTIONS = (
    "Which day number of the month does this post name as the day the work is due? "
    f"Choose a number only if the post names one; otherwise choose {NONE_LABEL!r}."
)
_WEEKDAY_INSTRUCTIONS = (
    "Which weekday does this post name as the day the work is due? Choose a weekday "
    f"only if the post names one; otherwise choose {NONE_LABEL!r}."
)
_RELATIVE_INSTRUCTIONS = (
    "How does this post express the day the work is due? Choose 'today' or 'tomorrow' if "
    "it says so, 'next_weekday' if it says something like 'next Thursday', and "
    f"{NONE_LABEL!r} if it uses no relative wording."
)


def _questions_for(index: int, *, team: str) -> dict[str, Any]:
    month_criteria = {name.title(): None for name in MONTHS}
    month_criteria[NONE_LABEL] = None
    day_criteria = {str(day): None for day in range(1, 32)}
    day_criteria[NONE_LABEL] = None
    weekday_criteria = {name.title(): None for name in WEEKDAYS}
    weekday_criteria[NONE_LABEL] = None
    relative_criteria = {key: None for key in RELATIVE_DAYS}
    relative_criteria[NONE_LABEL] = None
    # The known course set is the channel's own team: this is a channel-scoped
    # read, so the real question is whether the post belongs to this course or is
    # unrelated chatter, and `none` is what keeps a course from being forced on.
    course_criteria = {team: None, NONE_LABEL: None}

    return {
        f"p{index}.deadline": _noul(_DEADLINE_INSTRUCTIONS),
        f"p{index}.course": _choice(
            f"Which course is this post about? Choose {team!r} only if it concerns that "
            f"course's work; choose {NONE_LABEL!r} for anything else.",
            course_criteria,
        ),
        f"p{index}.date_stated": _noul(_STATED_INSTRUCTIONS),
        f"p{index}.month": _choice(_MONTH_INSTRUCTIONS, month_criteria),
        f"p{index}.day": _choice(_DAY_INSTRUCTIONS, day_criteria),
        f"p{index}.weekday": _choice(_WEEKDAY_INSTRUCTIONS, weekday_criteria),
        f"p{index}.relative": _choice(_RELATIVE_INSTRUCTIONS, relative_criteria),
    }


def _ask_batched(judge: Judge, state: Any, questions: dict[str, Any]) -> Judgements:
    """One request per MAX_QUESTIONS_PER_CALL questions, merged.

    A hundred posts is seven hundred questions, and an oversized batch fails the
    whole read rather than the questions that overflowed. `Judge.ask` splits at
    the same limit as a transport concern; this split is the reader's own, so
    that the number of questions sent is a property of this module and stays
    true of any judge it is handed.
    """
    merged = Judgements()
    items = list(questions.items())
    for start in range(0, len(items), MAX_QUESTIONS_PER_CALL):
        chunk = dict(items[start : start + MAX_QUESTIONS_PER_CALL])
        answers = judge.ask(state, chunk)
        merged.choices.update(answers.choices)
        merged.nouls.update(answers.nouls)
    return merged


def _judge_posts(
    judge: Judge, posts: Sequence[_Post], *, team: str, channel: str, tz: ZoneInfo
) -> dict[str, PostJudgement]:
    """Everything the model is asked about the collected posts, in one batch.

    The state is the bodies alone, labelled with the same ids the question names
    use, so the model reads exactly the text a person would.
    """
    if not posts:
        return {}
    labelled = [Candidate(id=f"p{index}", text=post.body) for index, post in enumerate(posts)]
    questions: dict[str, Any] = {}
    for index in range(len(posts)):
        questions.update(_questions_for(index, team=team))
    answers = _ask_batched(judge, label_candidates(labelled), questions)

    judged: dict[str, PostJudgement] = {}
    for index, post in enumerate(posts):
        parts = _date_parts(answers, index)
        # Relative words are relative to when the post was written, so the post's
        # own stamp is the anchor: "due tomorrow" means the next day, whatever
        # the day this read happens to run on.
        due_at = resolve_relative_date(parts, now=post.posted_at, tz=tz)
        chosen = answers.choice(f"p{index}.course", minimum_confidence=ANSWER_FLOOR)
        external_id = post.external_id(team, channel)
        judged[external_id] = PostJudgement(
            external_id=external_id,
            deadline=answers.yes(f"p{index}.deadline"),
            course=None if chosen in (None, NONE_LABEL) else chosen,
            course_confidence=(answers.probability(f"p{index}.course", chosen) if chosen else 0.0),
            due_at=due_at,
        )
    return judged


def _date_parts(answers: Judgements, index: int) -> DateParts:
    stated = answers.is_yes(f"p{index}.date_stated", minimum=ANSWER_FLOOR)
    month = _month_number(answers.choice(f"p{index}.month", minimum_confidence=ANSWER_FLOOR))
    day = _day_number(answers.choice(f"p{index}.day", minimum_confidence=ANSWER_FLOOR))
    weekday = _weekday_name(answers.choice(f"p{index}.weekday", minimum_confidence=ANSWER_FLOOR))
    relative = answers.choice(f"p{index}.relative", minimum_confidence=ANSWER_FLOOR)
    return DateParts(
        stated=stated,
        month=month,
        day=day,
        weekday=weekday,
        relative=relative if relative in RELATIVE_DAYS else None,
    )


def _month_number(name: str | None) -> int | None:
    return MONTHS.get((name or "").strip().lower())


def _weekday_name(name: str | None) -> str | None:
    key = (name or "").strip().lower()
    return key if key in WEEKDAYS else None


def _day_number(name: str | None) -> int | None:
    if name and name.strip().isdigit() and 1 <= int(name) <= 31:
        return int(name)
    return None


# --- dates: the model reads the words, Python does the arithmetic -------------


def resolve_relative_date(
    parts: DateParts,
    *,
    now: datetime,
    tz: ZoneInfo,
    at: time | None = None,
) -> datetime | None:
    """The absolute, UTC datetime a post's date words point at.

    Everything the model reported is already in `parts`; the arithmetic is here
    because it is testable, because DST is real, and because a model asked for a
    datetime will confidently return the wrong year.

    The anchor is `now`, converted into `tz`, and the result is local midnight on
    the named day unless `at` names a clock time. Local midnight is chosen so the
    answer is a day boundary on the user's calendar; a spring-forward day that
    has no midnight in `tz` resolves to the instant the clocks jumped, which is
    the closest thing to that day's start that exists.
    """
    if now.tzinfo is None or now.tzinfo.utcoffset(now) is None:
        raise ValueError("`now` must be timezone-aware")
    local_now = now.astimezone(tz)
    today = local_now.date()

    if not parts.stated:
        return None

    day: date | None = None
    if parts.relative in ("today", "tomorrow", "yesterday"):
        day = today + timedelta(days=RELATIVE_DAYS[parts.relative] or 0)
    elif parts.weekday:
        target = WEEKDAYS[parts.weekday]
        forward = (target - today.weekday()) % 7
        if parts.relative == "next_weekday":
            forward = forward or 7
        day = today + timedelta(days=forward)
    elif parts.month and parts.day:
        day = _dated(parts.month, parts.day, today)
    elif parts.day:
        day = _day_only(parts.day, today)

    if day is None:
        return None
    return datetime.combine(day, at or time.min, tzinfo=tz).astimezone(UTC)


def _dated(month: int, day: int, today: date) -> date | None:
    """A month and day with no year: this year, or next if it has just passed."""
    for year in (today.year, today.year + 1):
        try:
            candidate = date(year, month, day)
        except ValueError:
            return None
        if candidate >= today - timedelta(days=PAST_GRACE_DAYS):
            return candidate
    return None


def _day_only(day: int, today: date) -> date | None:
    """A bare day number: the next month that actually has that day."""
    for offset in range(3):
        month = today.month + offset
        year = today.year + (month - 1) // 12
        month = (month - 1) % 12 + 1
        try:
            candidate = date(year, month, day)
        except ValueError:
            continue
        if candidate >= today:
            return candidate
    return None


_MONTH_NAMES = "|".join(MONTHS)
_WEEKDAY_NAMES = "|".join(WEEKDAYS)
_ISO_DATE_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")
_DAY_MONTH_RE = re.compile(rf"\b(\d{{1,2}})\s+({_MONTH_NAMES})\b\.?\s*(\d{{4}})?", re.IGNORECASE)
_MONTH_DAY_RE = re.compile(
    rf"\b({_MONTH_NAMES})\b\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?,?\s*(\d{{4}})?",
    re.IGNORECASE,
)
_SLASH_DATE_RE = re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b")
_WEEKDAY_RE = re.compile(rf"\b({_WEEKDAY_NAMES})\b", re.IGNORECASE)
_AGO_RE = re.compile(r"\b(\d{1,3})\s*(minute|min|hour|hr|day)s?\s+ago\b", re.IGNORECASE)
_JUST_NOW_RE = re.compile(r"\bjust now\b", re.IGNORECASE)
_AGO_UNITS = {"minute": "minutes", "min": "minutes", "hour": "hours", "hr": "hours", "day": "days"}


def parse_posted_at(text: str, *, now: datetime, tz: ZoneInfo | None = None) -> datetime | None:
    """The page's own rendered timestamp, as a UTC datetime, or None.

    Teams prints a post's stamp in whatever form the locale and the post's age
    call for - "Just now", "12 minutes ago", "Yesterday 14:32", "Monday 09:15",
    "12 September 2026 10:03" - so this reads the forms it can and refuses the
    rest. Refusing is important: a stamp guessed wrong silently moves a post out
    of the `since` window, so the caller stamps it with the read clock instead
    and is told the timestamp was not read.
    """
    if not text or not text.strip():
        return None
    zone = tz or UTC
    local_now = now.astimezone(zone)
    body = text.strip()

    if _JUST_NOW_RE.search(body):
        return local_now.astimezone(UTC)

    ago = _AGO_RE.search(body)
    if ago:
        amount = int(ago.group(1))
        unit = _AGO_UNITS[ago.group(2).lower()]
        delta = timedelta(**{unit: amount})
        return (local_now - delta).astimezone(UTC)

    clock = parse_clock(body)
    at = time(clock[0], clock[1]) if clock else None

    day = _parse_calendar_day(body, local_now)
    if day is None and at is None:
        return None
    if day is None:
        day = local_now.date()
        # A bare time that has not happened yet is the previous day's post - a
        # message cannot be stamped in the future.
        if at is not None and datetime.combine(day, at, tzinfo=zone) > local_now + timedelta(
            hours=1
        ):
            day = day - timedelta(days=1)
    if at is None:
        at = time.min
    return datetime.combine(day, at, tzinfo=zone).astimezone(UTC)


def _parse_calendar_day(body: str, local_now: datetime) -> date | None:
    today = local_now.date()
    lowered = body.lower()
    if "yesterday" in lowered:
        return today - timedelta(days=1)
    if "today" in lowered:
        return today

    iso = _ISO_DATE_RE.search(body)
    if iso:
        return _safe_date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)))

    for pattern, order in ((_DAY_MONTH_RE, "dm"), (_MONTH_DAY_RE, "md")):
        match = pattern.search(body)
        if match:
            first, second, year = match.group(1), match.group(2), match.group(3)
            day, month_name = (first, second) if order == "dm" else (second, first)
            month = MONTHS.get(month_name.lower())
            if month and day.isdigit():
                resolved = _safe_date(int(year) if year else today.year, month, int(day))
                if resolved and not year and resolved < today - timedelta(days=PAST_GRACE_DAYS):
                    resolved = _safe_date(today.year + 1, month, int(day))
                return resolved

    slash = _SLASH_DATE_RE.search(body)
    if slash:
        first, second, year = (int(part) for part in slash.groups())
        # 3/12/2026 is day-first in most of the world and month-first in the US,
        # and the page does not say which. Only the unambiguous day wins.
        if first > 12:
            return _safe_date(year, second, first)
        if second > 12:
            return _safe_date(year, first, second)
        return None

    weekday = _WEEKDAY_RE.search(body)
    if weekday:
        target = WEEKDAYS[weekday.group(1).lower()]
        back = (today.weekday() - target) % 7
        candidate = today - timedelta(days=back)
        clock = parse_clock(body)
        if clock:
            at = time(clock[0], clock[1])
            if datetime.combine(candidate, at, tzinfo=local_now.tzinfo) > local_now:
                candidate -= timedelta(days=7)
        return candidate
    return None


def _safe_date(year: int, month: int, day: int) -> date | None:
    try:
        return date(year, month, day)
    except ValueError:
        return None
