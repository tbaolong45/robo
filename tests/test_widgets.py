import os
import time

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import Qt  # noqa: E402
from PySide6.QtGui import QColor, QTextDocument  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from robo import widgets  # noqa: E402

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
