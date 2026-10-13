import os
import subprocess
import sys
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPoint, Qt  # noqa: E402
from PySide6.QtGui import QColor, QImage, QRegion, QTextCharFormat, QTextDocument  # noqa: E402
from PySide6.QtWidgets import QApplication, QWidget  # noqa: E402

from robo import hud, widgets  # noqa: E402
from robo.theme import CYAN, THEMES, accent  # noqa: E402

QAPP = QApplication.instance() or QApplication([])


def styled(markdown: str) -> QTextDocument:
    doc = QTextDocument()
    doc.setMarkdown(markdown)
    widgets.style_markdown(doc)
    return doc


def blocks(doc: QTextDocument):
    block = doc.begin()
    while block.isValid():
        yield block
        block = block.next()


def fragments(block):
    it = block.begin()
    while not it.atEnd():
        yield it.fragment()
        it += 1


def test_paragraphs_have_a_gap_below_and_the_last_block_leaves_no_band():
    doc = styled("one\n\ntwo")  # the blocks must not outlive their document
    first, last = list(blocks(doc))
    assert first.blockFormat().bottomMargin() == widgets.GAP
    assert last.blockFormat().bottomMargin() == 0


def test_a_list_is_tight_inside_and_gapped_from_the_paragraph_after_it():
    doc = styled("- a\n- b\n\nafter")
    a, b, after = list(blocks(doc))
    assert a.blockFormat().bottomMargin() == widgets.LIST_GAP
    assert b.blockFormat().bottomMargin() == widgets.GAP  # the list's end
    assert after.blockFormat().topMargin() == 0 and after.text() == "after"


def test_a_heading_sits_close_to_what_it_introduces():
    doc = styled("## Today\n\nthings")
    heading, body = list(blocks(doc))
    assert heading.blockFormat().headingLevel() == 2
    assert heading.blockFormat().bottomMargin() == widgets.HEADING_GAP


def test_code_lines_form_a_dark_monospace_box():
    doc = styled("before\n\n```python\ndef f():\n    return 1\n```\n\nafter")
    before, one, two, after = list(blocks(doc))
    for line in (one, two):
        fmt, char = line.blockFormat(), next(fragments(line)).charFormat()
        assert fmt.background().color() == QColor("#070b14")
        assert fmt.textIndent() == 8  # padding at the left of the box
        assert char.fontFamilies() == widgets.MONO and char.fontPointSize() == 0
        assert char.property(char.Property.FontPixelSize) == 12
        assert char.foreground().color() != QColor("#d8e6ff")  # not the text colour
    assert one.blockFormat().bottomMargin() == 0  # the lines touch: one box
    assert two.blockFormat().bottomMargin() == widgets.GAP
    assert before.blockFormat().background().style() == after.blockFormat().background().style()


def test_long_code_lines_wrap_instead_of_forcing_a_scrollbar():
    doc = styled("```\n" + "find . -name '*.plist' | xargs ls -la " * 5 + "\n```")
    doc.setTextWidth(300)  # the bubble's text column
    assert doc.idealWidth() <= 300  # nothing sticks out to the right


def test_inline_code_and_links_are_readable_on_the_dark_panel():
    doc = styled("run `ls -l` or see [the notes](https://example.com) now")
    frags = {f.text(): f.charFormat() for f in fragments(next(blocks(doc)))}
    assert frags["ls -l"].background().color() == QColor("#1b2640")
    assert frags["ls -l"].fontFamilies() == widgets.MONO
    assert frags["the notes"].foreground().color() == QColor("#7fb2ff")
    assert frags["the notes"].fontUnderline()
    assert frags["run "].background().style() == Qt.BrushStyle.NoBrush  # plain text untouched


def test_styling_twice_changes_nothing():
    md = "# T\n\npara `c` [l](https://x.y)\n\n- a\n  - b\n- c\n\n```\nx\ny\n```\n\nend"
    doc = styled(md)
    once = doc.toHtml()
    widgets.style_markdown(doc)
    assert doc.toHtml() == once


def test_table_cells_are_left_alone():
    doc = styled("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter")
    cells = [b for b in blocks(doc) if b.text() in ("a", "b", "1", "2")]
    assert len(cells) == 4 and all(b.blockFormat().bottomMargin() == 0 for b in cells)


def test_a_reply_is_styled_in_a_couple_of_milliseconds():
    reply = ("**This week**\n\n- *Linear Algebra* set - due Thursday\n- Physics lab report\n\n"
             "The chain rule: `d/dx f(g(x))`.\n\n```python\ndef chain(f, g, x):\n"
             "    return f(g(x))\n```\n\nSee [the notes](https://example.com/notes).\n\n") * 7
    assert 1400 < len(reply) < 1700
    doc, best = QTextDocument(), 1.0
    for _ in range(10):
        doc.setMarkdown(reply)
        t = time.perf_counter()
        widgets.style_markdown(doc)
        best = min(best, time.perf_counter() - t)
    assert best < 0.02  # about 0.4 ms on an M-series Mac; the slack is for a busy CI box


# --- themed looks, fonts and the typing dots ---------------------------------------------------

ALL = list(THEMES.values())
KEYS = list(THEMES)
SAMPLE = ("# Title\n\npara `code` [link](https://x.y) **bold**\n\n- a\n  - b\n- c\n\n"
          "```python\nx = 1\ny = 2\n```\n\nend")


def themed(md: str, t) -> QTextDocument:
    doc = QTextDocument()
    doc.setMarkdown(md)
    widgets.style_markdown(doc, hud.md_look(t))
    return doc


def test_the_default_look_is_what_the_bubble_always_had():
    doc = styled("# T\n\npara\n\n```\nx\n```")
    assert doc.documentMargin() == 4  # Qt's own: the default look does not touch it
    head, para, code = list(blocks(doc))
    for block in (head, para, code):
        assert block.blockFormat().lineHeight() == 0
    assert next(fragments(head)).charFormat().foreground().style() == Qt.BrushStyle.NoBrush
    assert widgets.DEFAULT is widgets.default_look()


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_a_themed_look_dresses_headings_code_and_links_in_the_themes_colours(t):
    doc = themed(SAMPLE, t)
    head, para, a, b, c, one, two, end = list(blocks(doc))
    h = next(fragments(head)).charFormat()
    assert h.foreground().color() == QColor(t.head) and h.fontWeight() == 700
    assert h.property(h.Property.FontPixelSize) == widgets.HEAD_PX[1]
    frags = {f.text(): f.charFormat() for f in fragments(para)}
    assert frags["code"].background().color() == QColor(t.inline_bg)
    assert frags["code"].fontFamilies() == widgets.MONO
    assert frags["link"].foreground().color() == QColor(t.link) and frags["link"].fontUnderline()
    for line in (one, two):
        fmt, char = line.blockFormat(), next(fragments(line)).charFormat()
        assert fmt.background().color() == QColor(t.code_bg)
        assert char.foreground().color() == QColor(t.code_fg)
    assert doc.documentMargin() == 0
    assert doc.indentWidth() == widgets.INDENT + (6 if t.body_mono else 0)
    fmt = para.blockFormat()
    assert fmt.lineHeight() == t.line_h
    assert fmt.lineHeightType() == fmt.LineHeightTypes.ProportionalHeight.value
    assert one.blockFormat().lineHeight() == t.line_h - 12  # 12 px code in a tighter line


def test_headings_come_out_larger_than_the_body():
    """The importer gives a heading FontSizeAdjustment, which overrides any pixel size while the
    property exists, and a merge cannot remove it: only replacing the format sets the size."""
    doc = themed("# One\n\n## Two\n\n### Three\n\nbody", CYAN)
    sizes = [next(fragments(block)).charFormat().font().pixelSize() for block in blocks(doc)]
    assert sizes[:3] == [widgets.HEAD_PX[1], widgets.HEAD_PX[2], widgets.HEAD_PX[3]]
    assert sizes[3] != sizes[0]  # and the body keeps its own size


def test_headings_get_a_size_per_level_and_stay_below_qts_own():
    doc = themed("# one\n\n## two\n\n### three\n\n#### four", CYAN)
    sizes = [next(fragments(b)).charFormat().property(QTextCharFormat.Property.FontPixelSize)
             for b in blocks(doc)]
    assert sizes == [17, 16, 15, 14]


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_styling_a_themed_document_twice_changes_nothing(t):
    doc = themed(SAMPLE, t)
    once = doc.toHtml()
    widgets.style_markdown(doc, hud.md_look(t))
    assert doc.toHtml() == once


def test_a_document_restyled_for_another_theme_equals_one_styled_for_it_from_scratch():
    for src, dst in (("cyan", "matrix"), ("aurora", "daylight"), ("matrix", "cyan")):
        doc = themed(SAMPLE, THEMES[src])
        widgets.style_markdown(doc, hud.md_look(THEMES[dst]))
        assert doc.toHtml() == themed(SAMPLE, THEMES[dst]).toHtml(), (src, dst)


def test_a_themed_look_leaves_table_cells_alone_too():
    doc = themed("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter", CYAN)
    cells = [b for b in blocks(doc) if b.text() in ("a", "b", "1", "2")]
    assert len(cells) == 4 and all(b.blockFormat().lineHeight() == 0 for b in cells)


def test_a_themed_reply_is_still_styled_in_a_couple_of_milliseconds():
    reply = ("## This week\n\n- *Linear Algebra* set - due Thursday\n- Physics lab report\n\n"
             "The chain rule: `d/dx f(g(x))`.\n\n```python\ndef chain(f, g, x):\n"
             "    return f(g(x))\n```\n\nSee [the notes](https://example.com/notes).\n\n") * 7
    look, doc, best = hud.md_look(THEMES["matrix"]), QTextDocument(), 1.0
    for _ in range(10):
        doc.setMarkdown(reply)
        t = time.perf_counter()
        widgets.style_markdown(doc, look)
        best = min(best, time.perf_counter() - t)
    assert best < 0.02


def test_the_monospace_family_is_the_first_installed_one_and_is_resolved_once():
    from PySide6.QtGui import QFontDatabase

    have = set(QFontDatabase.families())
    first = next((f for f in widgets.MONO_STACK if f in have), widgets.MONO_STACK[-1])
    assert widgets.mono_family() == first
    assert [first, "monospace"] == widgets.MONO
    assert widgets.MONO_STACK[0] == "SF Mono"  # preferred where it exists
    assert widgets._installed_mono.cache_info().misses == 1  # the database is read once


def test_importing_the_module_and_asking_for_its_fonts_needs_no_application():
    # QFontDatabase aborts the process before a QGuiApplication exists, and robo.app imports
    # `STYLE` from here at import time.
    code = ("from robo.widgets import STYLE, MONO, DEFAULT, mono_family\n"
            "assert STYLE and MONO[-1] == 'monospace' and DEFAULT.code\n"
            "print(mono_family())")
    run = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60,
                         env={**os.environ, "QT_QPA_PLATFORM": "offscreen"})
    assert run.returncode == 0, run.stderr
    assert run.stdout.strip() == "Menlo"  # the stand-in until the font database can be read


def test_the_old_module_attributes_are_still_there():
    assert hud.qss(CYAN) == widgets.STYLE
    assert widgets.BUBBLE_W == 340 and widgets.TEXT_W == 302
    with pytest.raises(AttributeError):
        widgets.NOPE  # noqa: B018


def shot(w: QWidget) -> QImage:
    """What `w` paints on a transparent ground (no window colour behind it)."""
    img = QImage(w.size(), QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(Qt.GlobalColor.transparent)
    w.render(img, QPoint(), QRegion(), QWidget.RenderFlag.DrawChildren)
    return img


def test_the_typing_dots_hop_in_the_accent_colour_without_a_pill():
    dots = widgets.TypingDots()
    assert (dots.width(), dots.height()) == (32, 16)
    img = shot(dots)
    assert img.pixelColor(31, 8).alpha() == 0 and img.pixelColor(0, 15).alpha() == 0  # no pill
    first = img.pixelColor(5, 8)  # the first dot's column: always inside its dot
    want = accent(CYAN, CYAN.hue)
    assert first.alpha() > 100 and first.blue() > first.red()
    assert abs(first.green() - want[1]) < 40


@pytest.mark.parametrize("t", ALL, ids=KEYS)
def test_the_dots_take_the_theme_and_the_live_hue(t):
    dots = widgets.TypingDots(theme=t)
    dots.restyle(t, 356.0)  # an error: red whatever the theme
    px = shot(dots).pixelColor(5, 8)
    assert px.red() > px.green() and px.red() > px.blue()
    dots.restyle(t, t.hue)
    assert dots.theme is t and dots.hue == t.hue


def test_the_dots_keep_their_wave():
    a, b = widgets.TypingDots.offsets(0.0), widgets.TypingDots.offsets(0.2)
    assert len(a) == 3 and a != b and max(map(abs, a + b)) <= widgets.TypingDots.HOP
