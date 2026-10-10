"""Which text of a page the model gets: the content, not the navigation around it.

The script that takes a page's text runs inside the page, so a fake cannot test it; these
tests give a real Chromium small HTML documents (no network) and check what comes back.
They are skipped on a machine where Chromium is not installed.

Measured on real pages with the plain `document.body.innerText`: the first 4,000 characters of
a Wikipedia article and of the Python docs were menus and language lists, and the weather page
began with a site menu instead of the temperature. Reading the main content instead starts at
the article, the docs text and "Now | 30 C | Sunny".

Rules pinned here:

**Navigation, scripts and hidden things are left out**, and the main content is preferred.
**Nothing is lost on a page built differently:** several articles without a `<main>` are all
kept, a page wrapped in a form still has its text, and when the main content turns out tiny the
whole page is used instead.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from playwright.sync_api import sync_playwright

from pli.web import _BOXES_JS, _LINKS_JS, _TEXT_JS

LONG = " ".join(f"sentence{n} about the topic." for n in range(30))  # well over 200 characters


@pytest.fixture(scope="module")
def page() -> Iterator[Any]:
    playwright = sync_playwright().start()
    try:
        browser = playwright.chromium.launch(headless=True)
    except Exception as exc:  # the browser binary is not downloaded
        playwright.stop()
        pytest.skip(f"Chromium is not available: {str(exc).splitlines()[0]}")
    opened = browser.new_page()
    yield opened
    browser.close()
    playwright.stop()


def _text(page: Any, html: str) -> str:
    page.set_content(html)
    return page.evaluate(_TEXT_JS)


def test_navigation_and_footers_are_left_out_and_the_main_content_is_kept(page: Any) -> None:
    text = _text(
        page,
        f"""<body><nav>Home About Contact MENUWORD</nav><header>SITE BANNER</header>
        <main><h1>Title</h1><p>{LONG}</p></main><aside>RELATED LINKS</aside>
        <footer>COPYRIGHT FOOTER</footer></body>""",
    )

    assert "sentence0" in text and "sentence29" in text
    for noise in ("MENUWORD", "SITE BANNER", "RELATED LINKS", "COPYRIGHT FOOTER"):
        assert noise not in text


def test_a_div_marked_as_the_main_content_counts_too(page: Any) -> None:
    text = _text(
        page,
        f'<body><div class="related">index modules next</div><div role="main">{LONG}</div></body>',
    )

    assert "sentence5" in text and "index modules" not in text


def test_scripts_styles_and_hidden_elements_are_never_text(page: Any) -> None:
    text = _text(
        page,
        f"""<body><main><script>var SECRETSCRIPT = 1;</script><style>.x{{color:red}}</style>
        <div hidden>HIDDENTEXT</div><div aria-hidden="true">ARIAHIDDEN</div>
        <noscript>NOSCRIPTTEXT</noscript><p>{LONG}</p></main></body>""",
    )

    assert "sentence1" in text
    for noise in ("SECRETSCRIPT", "color:red", "HIDDENTEXT", "ARIAHIDDEN", "NOSCRIPTTEXT"):
        assert noise not in text


def test_a_page_of_several_articles_without_a_main_keeps_every_article(page: Any) -> None:
    articles = "".join(f"<article><p>Story {n}: {LONG}</p></article>" for n in range(3))

    text = _text(page, f"<body><nav>MENUWORD</nav>{articles}</body>")

    assert all(f"Story {n}" in text for n in range(3)) and "MENUWORD" not in text


def test_a_page_with_neither_main_nor_article_still_loses_its_navigation(page: Any) -> None:
    text = _text(
        page,
        f"<body><header>SITEHEADER</header><nav>MENUWORD</nav><div><p>{LONG}</p></div>"
        "<footer>FOOT</footer></body>",
    )

    assert "sentence3" in text
    for noise in ("MENUWORD", "FOOT", "SITEHEADER"):
        assert noise not in text


def test_a_page_wrapped_in_one_big_form_keeps_its_text(page: Any) -> None:
    """Some sites put the whole page inside a <form>; stripping forms would empty it."""
    text = _text(page, f"<body><form><div><p>{LONG}</p></div></form></body>")

    assert "sentence7" in text


def test_navigation_inside_a_page_wide_form_is_still_left_out(page: Any) -> None:
    text = _text(page, f"<body><form><nav>MENUWORD</nav><main><p>{LONG}</p></main></form></body>")

    assert "sentence2" in text and "MENUWORD" not in text


def test_a_tiny_main_does_not_hide_the_rest_of_the_page(page: Any) -> None:
    text = _text(
        page,
        f"<body><main>Tiny</main><div><p>{LONG}</p></div></body>",
    )

    assert "sentence10" in text


def test_role_navigation_and_other_landmarks_are_left_out_too(page: Any) -> None:
    """No <main> here, so the whole body is the fallback: whatever is not removed leaks in."""
    text = _text(
        page,
        f"""<body><div role="navigation">NAVWORD</div><div role="banner">BANNERWORD</div>
        <div role="search">SEARCHWORD</div><div><p>{LONG}</p></div>
        <div role="contentinfo">INFOWORD</div></body>""",
    )

    assert "sentence1" in text
    for noise in ("NAVWORD", "BANNERWORD", "SEARCHWORD", "INFOWORD"):
        assert noise not in text


def test_a_byline_inside_an_article_is_kept_but_the_site_header_is_not(page: Any) -> None:
    text = _text(
        page,
        f"""<body><header>SITEHEADER</header><article><header>By Ada, 9 October 2026</header>
        <p>{LONG}</p></article></body>""",
    )

    assert "By Ada, 9 October 2026" in text and "SITEHEADER" not in text


def test_an_article_inside_an_article_is_not_read_twice(page: Any) -> None:
    text = _text(
        page,
        f"<body><article><p>OUTER {LONG}</p><article><p>INNER once</p></article></article></body>",
    )

    assert text.count("INNER once") == 1


def test_when_stripping_leaves_too_little_the_whole_page_is_used_instead(page: Any) -> None:
    """A short status page whose only text sits in a <header> must not come back empty."""
    text = _text(page, "<body><header>Status: down</header><p>Back soon.</p></body>")

    assert "Status: down" in text and "Back soon." in text


def test_a_short_page_is_returned_whole(page: Any) -> None:
    text = _text(page, "<body><p>This domain is for use in documentation examples.</p></body>")

    assert "documentation examples" in text


def test_an_empty_document_gives_an_empty_string(page: Any) -> None:
    assert _text(page, "") == ""


# --- the links a page offers ------------------------------------------------------------------


def _links(page: Any, html: str) -> list[list[str]]:
    page.set_content(html, wait_until="domcontentloaded")
    return page.evaluate(_LINKS_JS)


def test_links_come_with_their_text_and_address_main_content_first_and_navigation_too(
    page: Any,
) -> None:
    """Navigation is where a site's other sections are, so its links are offered too - after the
    links inside the article, which are what the page is about. (`_TEXT_JS` removes navigation
    from the text, so the links are taken first.)"""
    found = _links(
        page,
        """<body><nav><a href="https://example.org/about">About us</a></nav>
        <main><p>See <a href="https://example.org/guide">the guide</a>.</p></main></body>""",
    )

    assert found == [
        ["the guide", "https://example.org/guide"],
        ["About us", "https://example.org/about"],
    ]


def test_links_with_no_text_and_hidden_links_are_not_offered(page: Any) -> None:
    found = _links(
        page,
        """<body><a href="https://a.example/img"><img src="x.png"></a>
        <a href="https://a.example/hidden" style="display:none">Hidden</a>
        <a href="https://a.example/shown">Shown</a>
        <a href="https://a.example/labelled" aria-label="Labelled only"><svg></svg></a></body>""",
    )

    assert [text for text, _ in found] == ["Shown", "Labelled only"]


def test_a_link_is_listed_once_even_when_the_page_repeats_it(page: Any) -> None:
    found = _links(
        page,
        """<body><main><a href="https://a.example/x">First</a></main>
        <nav><a href="https://a.example/x">Again</a><a href="https://a.example/y">Other</a></nav>
        </body>""",
    )

    assert [url for _, url in found] == ["https://a.example/x", "https://a.example/y"]


def test_a_page_with_a_thousand_links_hands_over_a_bounded_number(page: Any) -> None:
    anchors = "".join(f'<a href="https://a.example/{n}">Link {n}</a>' for n in range(1_000))

    assert len(_links(page, f"<body>{anchors}</body>")) <= 200


# --- the search boxes a page offers -------------------------------------------------------------
# Typing is the one thing besides opening addresses that the agent does on a page, so what it may
# type into is narrow: a plain text or search box that submits as a GET (a search, not a purchase
# or a sign-in), never one that looks like it holds a secret.


def _boxes(page: Any, html: str) -> list[str]:
    page.set_content(html, wait_until="domcontentloaded")
    return page.evaluate(_BOXES_JS)


def test_a_search_box_is_offered_with_its_label(page: Any) -> None:
    found = _boxes(
        page,
        '<body><form action="/s"><input type="search" placeholder="Search the library"></form>',
    )

    assert found == ["Search the library"]


def test_a_text_box_that_looks_like_a_search_is_offered_too(page: Any) -> None:
    found = _boxes(
        page,
        """<body><form><input name="q" aria-label="Find a course"></form>
        <div role="search"><input type="text" placeholder="Jump to"></div>
        <form><input type="text" name="keyword" title="Keywords"></form></body>""",
    )

    assert found == ["Find a course", "Jump to", "Keywords"]


def test_a_form_that_does_not_say_post_counts_as_get_and_one_that_says_post_does_not(
    page: Any,
) -> None:
    found = _boxes(
        page,
        """<body><form><input type="search" placeholder="No method"></form>
        <form method="GET"><input type="search" placeholder="Get"></form>
        <form method="post"><input type="search" placeholder="Posted"></form>
        <form method="POST" action="/buy">
        <input type="search" placeholder="Also posted"></form></body>""",
    )

    assert found == ["No method", "Get"]


@pytest.mark.parametrize(
    "box",
    [
        '<input type="password" name="search">',
        '<input type="email" name="q">',
        '<input type="tel" name="q">',
        '<input type="number" name="q">',
        '<input type="file" name="q">',
        '<input type="hidden" name="q" value="x">',
        '<input type="search" disabled>',
        '<input type="search" readonly>',
        '<input type="search" style="display:none">',
        '<input type="search" style="visibility:hidden">',
        '<input type="search" style="opacity:0">',
        '<input type="search" style="width:0;height:0;padding:0;border:0">',
        '<input type="search" style="position:absolute;left:-9999px">',
        '<input type="text" name="card_number" placeholder="Search">',
        '<input type="search" autocomplete="cc-number">',
        '<input type="search" autocomplete="current-password">',
        '<input type="search" autocomplete="new-password">',
        '<input type="search" placeholder="Enter your password">',
        '<input type="search" name="password_confirm">',
        '<input type="search" name="password1">',
        '<input type="search" name="search_password1">',
        '<input type="search" name="pwd">',
        '<input type="search" name="passcode">',
        '<input type="search" name="pin">',
        '<input type="search" name="otp">',
        '<input type="search" name="ssn">',
        '<input type="text" name="q" placeholder="Mot de passe">',
        '<input type="text" name="q" placeholder="Contrase\u00f1a">',
        '<input type="text" name="q" placeholder="M\u1eadt kh\u1ea9u">',
        '<input type="text" name="q" placeholder="Passwort">',
        '<input type="text" name="q" placeholder="Social security number">',
        '<input type="text" name="q" placeholder="Date of birth">',
        '<input type="text" name="q" placeholder="Enter your 6-digit code">',
        '<input type="text" name="q" placeholder="Your e-mail">',
        '<input type="text" name="username">',
        '<input type="search" name="login">',
        '<input type="search" name="user">',
        '<input type="search" name="username">',
        '<input type="search" name="secret_answer">',
        '<input type="search" name="api_token">',
        '<input type="search" name="cvv">',
        '<input type="search" name="cvc">',
        '<input type="search" name="creditno">',
        '<input type="search" name="dob">',
        '<input type="search" name="signin">',
        '<input type="search" name="sign-in">',
        '<input type="search" name="iban">',
        '<input type="search" name="sign_in_code">',
        '<input type="search" name="mypin">',
        '<input type="search" name="gmail">',
        '<input type="search" name="postcode">',
        '<input type="search" aria-label="Your password">',
        '<input type="search" autocomplete="one-time-code">',
        '<input type="text" name="comment">',
        '<textarea name="q"></textarea>',
    ],
)
def test_a_box_that_could_hold_a_secret_or_is_not_a_search_is_never_offered(
    page: Any, box: str
) -> None:
    assert _boxes(page, f"<body><form>{box}</form></body>") == []


@pytest.mark.parametrize(
    "action", ["/login", "/signin", "/account/pay", "/checkout", "/cart/add", "/register"]
)
def test_a_get_form_that_goes_to_a_login_or_payment_page_is_not_a_search(
    page: Any, action: str
) -> None:
    html = f'<body><form action="{action}"><input type="search" name="q"></form></body>'

    assert _boxes(page, html) == []


@pytest.mark.parametrize(
    "label",
    [
        "Search the footprint archive",
        "Search cardiology papers",
        "Search mailing lists",
        "Search users",
    ],
)
def test_words_that_merely_contain_a_secretive_one_do_not_hide_a_search_box(
    page: Any, label: str
) -> None:
    """`otp` in foOTPrint, `card` in CARDiology, `mail` in MAILing, `user` in USERs."""
    assert _boxes(
        page, f'<body><form><input type="search" placeholder="{label}"></form></body>'
    ) == [label]


def test_a_box_below_the_fold_is_still_offered(page: Any) -> None:
    html = (
        '<body><div style="height:5000px"></div>'
        '<form><input type="search" placeholder="Down here"></form></body>'
    )

    assert _boxes(page, html) == ["Down here"]


def test_markers_a_page_set_itself_are_cleared_so_only_the_offered_boxes_are_tagged(
    page: Any,
) -> None:
    """A page can pre-tag its own field; the text must go to the box that was offered."""
    html = """<body><form method="post"><input type="password" data-pli-box="0" name="pw"></form>
        <form><input type="search" placeholder="The real box"></form></body>"""

    found = _boxes(page, html)

    assert found == ["The real box"]
    tagged = page.eval_on_selector_all("[data-pli-box]", "els => els.map(e => e.type)")
    assert tagged == ["search"]  # one tag, on the offered box - none on the password field


def test_at_most_three_boxes_are_offered_and_each_can_be_found_again_by_its_number(
    page: Any,
) -> None:
    boxes = "".join(f'<form><input type="search" placeholder="Box {n}"></form>' for n in range(6))

    found = _boxes(page, f"<body>{boxes}</body>")

    assert found == ["Box 0", "Box 1", "Box 2"]
    assert page.eval_on_selector('[data-pli-box="1"]', "e => e.placeholder") == "Box 1"
    assert page.query_selector('[data-pli-box="3"]') is None
