"""Turning a page into candidates: geometry, ordering, and the failure path.

The rules pinned here are the ones a passing run hides. A candidate list is
*consumed* as a claim about a page: the judge picks one of the ids, and code
reads the value back out of `text`. So a list that is misordered, that offers
the same element twice, or that quietly comes back empty for a page that failed
to be read does not look like a bug - it looks like an answer.

Two halves get their own tests:

* The parsing half, against canned `evaluate` results. The JS runs in a browser
  and cannot be unit tested, so everything it might return - garbage, `None`, a
  dict, a list of strings, an entry without coordinates - is fed in by hand.
* The diagnostics half, which is the failure path. It is called from an `except`
  block, so a page that dies mid-dump must cost the dump and nothing else.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pli.browser import BrowserError
from pli.browser.capture import (
    MAX_TEXT,
    capture_candidates,
    diagnostics,
    visible_text,
)
from pli.browser.selectors import Selectors
from pli.config import Settings
from pli.judge import MAX_OPTIONS

# --- fakes --------------------------------------------------------------------------


class _FakePage:
    """A Page that answers from a canned `evaluate` result and records the calls."""

    def __init__(
        self,
        result: object = None,
        *,
        html: str = "<html><body>hi</body></html>",
        error: Exception | None = None,
        html_error: Exception | None = None,
        screenshot_error: Exception | None = None,
    ) -> None:
        self.result = result
        self.html = html
        self.error = error
        self.html_error = html_error
        self.screenshot_error = screenshot_error
        self.evaluations: list[tuple[object, tuple[object, ...]]] = []
        self.screenshots: list[dict] = []
        self.url = "https://outlook.office.com/calendar/view/week"

    def evaluate(self, script: object, *args: object) -> object:
        self.evaluations.append((script, args))
        if self.error is not None:
            raise self.error
        return self.result

    def content(self) -> str:
        if self.html_error is not None:
            raise self.html_error
        return self.html

    def screenshot(self, **kwargs: object) -> None:
        self.screenshots.append(kwargs)
        if self.screenshot_error is not None:
            raise self.screenshot_error
        Path(str(kwargs["path"])).write_bytes(b"\x89PNG\r\n\x1a\n")


def _item(text: str, *, x=10.0, y=20.0, width=100.0, height=16.0, depth=1, **extra) -> dict:
    """One measurement as the page script would have produced it."""
    payload = {"text": text, "x": x, "y": y, "width": width, "height": height, "depth": depth}
    payload.update(extra)
    return payload


def _settings(tmp_path: Path, **kwargs: object) -> Settings:
    return Settings(_env_file=None, pli_home=tmp_path, **kwargs)


def _texts(candidates) -> list[str]:
    return [candidate.text for candidate in candidates]


# --- the page call --------------------------------------------------------------------


def test_the_whole_page_is_measured_in_one_round_trip():
    """A round trip per element is tens of seconds on a real week grid."""
    page = _FakePage([_item("Algorithms")])

    capture_candidates(page)

    assert len(page.evaluations) == 1
    script, _args = page.evaluations[0]
    assert isinstance(script, str)
    assert "getBoundingClientRect" in script


def test_capture_scopes_the_walk_to_the_payload_container_when_asked():
    page = _FakePage([_item("Algorithms")])
    selectors = Selectors(outlook_week_grid="[data-automationid='CalendarGrid']")

    capture_candidates(page, selectors=selectors)

    _script, args = page.evaluations[0]
    assert selectors.outlook_week_grid in args[0]


def test_capture_without_selectors_walks_whatever_is_there():
    page = _FakePage([_item("Algorithms")])

    capture_candidates(page)

    _script, args = page.evaluations[0]
    assert args[0] == ""


def test_a_page_that_cannot_be_read_raises_rather_than_returning_nothing():
    """An empty list is a claim that the week is free, and the planner believes it."""
    page = _FakePage(error=RuntimeError("Execution context was destroyed"))

    with pytest.raises(BrowserError, match="could not be read"):
        capture_candidates(page)


@pytest.mark.parametrize(
    "garbage",
    [
        None,
        "a string",
        42,
        {"text": "Algorithms"},
        [],
        [None, 7, "Algorithms"],
        [{"x": 1, "y": 2}],  # no text at all
        [{"text": 7, "x": 1}],  # text that is not text
    ],
)
def test_a_garbage_evaluate_result_is_no_candidates(garbage):
    assert capture_candidates(_FakePage(garbage)) == []


def test_an_entry_without_coordinates_is_still_offered():
    """Missing geometry is a zero box, not a reason to drop a readable label."""
    page = _FakePage([{"text": "Algorithms", "width": 40, "height": 12}])

    (candidate,) = capture_candidates(page)

    assert (candidate.x, candidate.y, candidate.width, candidate.height) == (0.0, 0.0, 40, 12)


def test_geometry_that_is_not_a_number_is_treated_as_missing():
    page = _FakePage([_item("Algorithms", x="left", y=None, width=40, height=12)])

    (candidate,) = capture_candidates(page)

    assert candidate.x == 0.0 and candidate.y == 0.0


# --- what is dropped ---------------------------------------------------------------------


def test_blank_text_is_not_a_candidate():
    page = _FakePage([_item("   \n\t "), _item("Algorithms")])

    assert _texts(capture_candidates(page)) == ["Algorithms"]


def test_an_element_with_no_area_is_not_something_a_person_can_point_at():
    page = _FakePage([_item("hidden", width=0), _item("Algorithms")])

    assert _texts(capture_candidates(page)) == ["Algorithms"]


def test_an_element_the_page_marked_invisible_is_dropped():
    page = _FakePage([_item("ghost", visible=False), _item("Algorithms")])

    assert _texts(capture_candidates(page)) == ["Algorithms"]


def test_a_paragraph_is_truncated_not_dropped():
    """The first 300 characters still say which deadline the paragraph is about."""
    page = _FakePage([_item("x" * 900)])

    (candidate,) = capture_candidates(page)

    assert len(candidate.text) == MAX_TEXT


def test_whitespace_inside_a_label_is_collapsed():
    """`label_candidates` is line-based: an embedded newline would forge a label."""
    page = _FakePage([_item("Quiz 3\n   moved   to\n Friday")])

    (candidate,) = capture_candidates(page)

    assert candidate.text == "Quiz 3 moved to Friday"
    assert "\n" not in candidate.text


# --- deduplication --------------------------------------------------------------------------


def test_a_wrapper_holding_its_child_text_is_dropped():
    page = _FakePage(
        [
            _item("Algorithms", x=0, y=0, width=200, height=40, depth=1),
            _item("Algorithms", x=36, y=10, width=100, height=16, depth=3),
        ]
    )

    (candidate,) = capture_candidates(page)

    assert (candidate.x, candidate.y) == (36.0, 10.0)


def test_the_same_text_in_two_places_is_two_candidates():
    """Two columns both headed "Mon" are two facts about two columns."""
    page = _FakePage([_item("Mon", x=10, depth=2), _item("Mon", x=300, depth=2)])

    assert len(capture_candidates(page)) == 2


def test_an_inner_copy_is_not_dropped_when_the_boxes_do_not_nest():
    """Depth alone is not containment: a sibling inside a padded wrapper is its own."""
    page = _FakePage(
        [
            _item("Mon", x=0, y=0, width=40, height=16, depth=1),
            _item("Mon", x=200, y=0, width=40, height=16, depth=3),
        ]
    )

    assert len(capture_candidates(page)) == 2


# --- ordering and ids ------------------------------------------------------------------------


def test_candidates_come_back_in_reading_order():
    page = _FakePage(
        [
            _item("third", x=10, y=200),
            _item("first", x=10, y=10),
            _item("second", x=10, y=100),
        ]
    )

    assert _texts(capture_candidates(page)) == ["first", "second", "third"]


def test_items_on_one_visual_line_keep_their_x_order():
    """A cell 2px lower than its neighbour is the normal state of a week grid."""
    page = _FakePage(
        [
            _item("09:00", x=120, y=102),
            _item("Algorithms", x=20, y=100),
        ]
    )

    assert _texts(capture_candidates(page)) == ["Algorithms", "09:00"]


def test_a_new_line_is_a_new_line():
    page = _FakePage(
        [
            _item("Tuesday", x=20, y=100),
            _item("Monday", x=20, y=60),
        ]
    )

    assert _texts(capture_candidates(page)) == ["Monday", "Tuesday"]


def test_ids_are_assigned_after_ordering():
    page = _FakePage([_item("third", x=10, y=200), _item("first", x=10, y=10)])

    candidates = capture_candidates(page)

    assert [(c.id, c.text) for c in candidates] == [("C000", "first"), ("C001", "third")]


def test_ids_are_three_digits_so_they_sort_as_text():
    page = _FakePage([_item(f"label {i}", y=float(i)) for i in range(12)])

    ids = [candidate.id for candidate in capture_candidates(page)]

    assert ids[:3] == ["C000", "C001", "C002"]
    assert sorted(ids) == ids


def test_the_limit_caps_the_list_from_the_top():
    page = _FakePage([_item(f"label {i}", y=float(i)) for i in range(20)])

    candidates = capture_candidates(page, limit=5)

    assert _texts(candidates) == ["label 0", "label 1", "label 2", "label 3", "label 4"]


def test_the_default_limit_leaves_room_for_a_caller_to_slice():
    """The judge refuses more than 255 options, so the caller narrows; capture must not."""
    page = _FakePage([_item(f"label {i}", y=float(i)) for i in range(300)])

    candidates = capture_candidates(page)

    assert len(candidates) > MAX_OPTIONS
    assert len(candidates) == 300


def test_an_empty_page_yields_no_candidates():
    assert capture_candidates(_FakePage([])) == []


# --- visible_text -------------------------------------------------------------------------------


def test_visible_text_returns_what_the_page_showed():
    page = _FakePage("Monday\n09:00 Algorithms")

    assert visible_text(page) == "Monday\n09:00 Algorithms"


def test_visible_text_is_truncated():
    page = _FakePage("x" * 5000)

    assert len(visible_text(page, limit=100)) == 100


def test_visible_text_of_a_page_that_answers_with_something_else_is_empty():
    assert visible_text(_FakePage(None)) == ""
    assert visible_text(_FakePage(["a"])) == ""


# --- diagnostics ----------------------------------------------------------------------------------


def test_diagnostics_writes_html_a_screenshot_and_the_text(tmp_path):
    settings = _settings(tmp_path)
    page = _FakePage("Monday\n09:00 Algorithms")

    directory = diagnostics(page, settings, label="outlook-week")

    assert directory == settings.home / "diagnostics"
    written = sorted(path.suffix for path in directory.iterdir())
    assert written == [".html", ".png", ".txt", ".url"]
    assert (directory / Path(next(directory.glob("*.txt"))).name).read_text() == (
        "Monday\n09:00 Algorithms"
    )
    assert page.screenshots[0]["full_page"] is True


def test_diagnostics_records_which_page_the_browser_was_actually_on(tmp_path):
    """The fact a dump is read to find, and the one it used to leave out.

    A reader that stopped matching has two causes - the page was restyled, or the
    page is not the page we asked for - and the HTML cannot always tell them
    apart, because a sign-in wall and a redesigned calendar both simply fail to
    match. The URL settles it. Kept whole, query string included: the parameters
    are the evidence for whoever has to fix the reader.
    """
    settings = _settings(tmp_path)
    page = _FakePage("Monday")
    page.url = "https://login.microsoftonline.com/common/oauth2/authorize?client_id=abc123"

    directory = diagnostics(page, settings, label="outlook-week")

    [url_file] = directory.glob("*.url")
    assert url_file.read_text() == (
        "https://login.microsoftonline.com/common/oauth2/authorize?client_id=abc123"
    )


def test_a_page_that_cannot_report_its_url_still_dumps_the_rest(tmp_path):
    """Reads through the page object, not the browser, and it is still the failure
    path: the dump has to cost the dump, never the report of what went wrong."""
    settings = _settings(tmp_path)
    page = _FakePage("Monday")
    del page.url  # a closed target answers no attribute at all

    directory = diagnostics(page, settings, label="dead")

    assert sorted(path.suffix for path in directory.iterdir()) == [".html", ".png", ".txt"]


def test_a_page_with_no_url_gets_no_url_file(tmp_path):
    """An empty `.url` would read as "the browser was at no address" - a small
    lie of exactly the kind this dump exists to prevent, and the reason the
    check is for a *truthy* url rather than for a string."""
    settings = _settings(tmp_path)
    page = _FakePage("Monday")
    page.url = ""

    directory = diagnostics(page, settings, label="unaddressed")

    assert sorted(path.suffix for path in directory.iterdir()) == [".html", ".png", ".txt"]


def test_diagnostics_timestamps_the_files_so_two_dumps_do_not_collide(tmp_path):
    settings = _settings(tmp_path)
    page = _FakePage("Monday")

    diagnostics(page, settings, label="calendar")
    diagnostics(page, settings, label="calendar")

    assert len(list((settings.home / "diagnostics").glob("*.html"))) == 2


def test_diagnostics_never_raises_when_the_page_dies_mid_dump(tmp_path):
    """It is called from an `except` block: it must cost the dump, not the report."""
    settings = _settings(tmp_path)
    page = _FakePage(
        "Monday",
        html_error=RuntimeError("Target closed"),
        screenshot_error=RuntimeError("Target closed"),
    )

    directory = diagnostics(page, settings, label="broken")

    assert directory.exists()
    assert sorted(path.suffix for path in directory.iterdir()) == [".txt", ".url"]


def test_diagnostics_still_captures_the_html_when_only_the_screenshot_fails(tmp_path):
    settings = _settings(tmp_path)
    page = _FakePage("Monday", screenshot_error=RuntimeError("page too tall to rasterise"))

    directory = diagnostics(page, settings, label="tall")

    assert sorted(path.suffix for path in directory.iterdir()) == [".html", ".txt", ".url"]


def test_a_label_cannot_escape_the_diagnostics_directory(tmp_path):
    settings = _settings(tmp_path)

    directory = diagnostics(_FakePage("x"), settings, label="../../etc/passwd")

    assert directory == settings.home / "diagnostics"
    for path in directory.iterdir():
        assert path.parent == directory
        assert "/" not in path.name


def test_diagnostics_works_when_the_label_is_empty(tmp_path):
    settings = _settings(tmp_path)

    directory = diagnostics(_FakePage("x"), settings, label="")

    assert any(path.name.endswith("-page.html") for path in directory.iterdir())


def test_a_failed_screenshot_leaves_no_half_written_file(tmp_path):
    """Half a png looks like evidence, which is worse than none."""
    settings = _settings(tmp_path)
    page = _FakePage("x", screenshot_error=RuntimeError("Target closed"))

    directory = diagnostics(page, settings, label="torn")

    assert not list(directory.glob("*.png"))


def test_the_dump_is_readable_json_free_html(tmp_path):
    """The user sends these back; the html has to be the page's own."""
    settings = _settings(tmp_path)
    page = _FakePage("x", html="<html><body><div data-tid='calendar'></div></body></html>")

    directory = diagnostics(page, settings, label="markup")

    html = directory / next(directory.glob("*.html")).name
    assert "data-tid='calendar'" in html.read_text()
    assert json.loads(json.dumps(page.html)) == page.html
