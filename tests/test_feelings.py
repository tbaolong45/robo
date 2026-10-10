from robo.events import Delta, Feeling
from robo.feelings import FeelingFilter, strip_tags


def run(*deltas: str) -> list:
    f = FeelingFilter()
    out = [e for d in deltas for e in f.feed(d)]
    return out + f.finish()


def text(events: list) -> str:
    return "".join(e.text for e in events if isinstance(e, Delta))


def feelings(events: list) -> list[str]:
    return [e.emotion for e in events if isinstance(e, Feeling)]


def test_whole_tag_then_text():
    assert run("[[feel:curious]] Hi there") == [Feeling("curious"), Delta("Hi there")]


def test_tag_split_across_deltas():
    f = FeelingFilter()
    assert f.feed("[[fe") == []
    assert f.feed("el:hap") == []
    assert f.feed("py]] Hi") == [Feeling("happy"), Delta("Hi")]
    assert f.feed(" you") == [Delta(" you")]
    assert f.finish() == []


def test_space_after_tag_in_next_delta_is_stripped_once():
    ev = run("[[feel:calm]]", "\n", "\nok")
    assert ev == [Feeling("calm"), Delta("\nok")]


def test_leading_whitespace_before_tag():
    assert run("  ", "\n[[feel:sad]]Oh") == [Feeling("sad"), Delta("Oh")]


def test_unknown_emotion_is_neutral():
    assert run("[[feel:Ecstatic]] Yo") == [Feeling("neutral"), Delta("Yo")]


def test_uppercase_known_emotion():
    assert feelings(run("[[feel:Happy]] Yo")) == ["happy"]


def test_no_tag_passes_through_immediately():
    f = FeelingFilter()
    assert f.feed("Hello") == [Feeling("neutral"), Delta("Hello")]
    assert f.feed(" world") == [Delta(" world")]
    assert f.finish() == []


def test_bracket_start_that_is_not_a_tag():
    f = FeelingFilter()
    assert f.feed("[") == []
    assert f.feed("1] item") == [Feeling("neutral"), Delta("[1] item")]


def test_incomplete_tag_flushed_as_text_on_finish():
    f = FeelingFilter()
    assert f.feed("[[feel:hap") == []
    assert f.finish() == [Feeling("neutral"), Delta("[[feel:hap")]


def test_overlong_prefix_stops_buffering():
    long = "[[feel:" + "x" * 50
    ev = run(long)
    assert ev == [Feeling("neutral"), Delta(long)]


def test_empty_reply_still_gets_one_feeling():
    assert run() == [Feeling("neutral")]


def test_later_tag_is_stripped_and_shifts_mood():
    ev = run("[[feel:happy]] Great. [[feel:concerned]]But wait.")
    assert feelings(ev) == ["happy", "concerned"]
    assert text(ev) == "Great. But wait."
    assert ev.index(Feeling("concerned")) > ev.index(Delta("Great. "))


def test_later_tag_split_across_deltas():
    f = FeelingFilter()
    out = f.feed("[[feel:happy]] A [[fe")
    assert out == [Feeling("happy"), Delta("A ")]
    assert f.feed("el:sad]] B") == [Feeling("sad"), Delta(" B")]


def test_later_unknown_tag_stripped_without_feeling():
    ev = run("Hi [[feel:weird]]there")
    assert feelings(ev) == ["neutral"]
    assert text(ev) == "Hi there"


def test_repeated_leading_tag():
    ev = run("[[feel:happy]] [[feel:happy]] Hi")
    assert text(ev) == " Hi"
    assert feelings(ev) == ["happy"]  # a repeat is not a mood shift


def test_plain_brackets_mid_text_not_held():
    f = FeelingFilter()
    f.feed("Hi ")
    assert f.feed("a[1] b") == [Delta("a[1] b")]
    assert f.feed("x [") == [Delta("x ")]
    assert f.feed("y") == [Delta("[y")]


def test_one_leading_feeling_before_any_delta():
    for chunks in (["[[feel:proud]]x"], ["x"], ["[", "["], [" "]):
        ev = run(*chunks)
        assert isinstance(ev[0], Feeling)
        assert sum(isinstance(e, Feeling) for e in ev) == 1


def test_every_split_point_gives_same_result():
    s = "[[feel:playful]] Hey [[feel:sad]]oh no [x] [[feel"
    whole = run(s)
    for i in range(len(s) + 1):
        for j in range(i, len(s) + 1):
            ev = run(s[:i], s[i:j], s[j:])
            assert feelings(ev) == feelings(whole)
            assert text(ev) == text(whole) == "Hey oh no [x] [[feel"


def test_strip_tags():
    assert strip_tags("[[feel:happy]] Hi [[feel:sad]]there\n") == "Hi there"
    assert strip_tags("plain [x]") == "plain [x]"


def test_padded_leading_tag_still_parses_when_streamed():
    f = FeelingFilter()
    text = "[[feel:" + " " * 35 + "happy]] Hi"
    out = [e for i in range(len(text)) for e in f.feed(text[i])] + f.finish()
    assert out[0] == Feeling("happy")
    assert "".join(e.text for e in out if isinstance(e, Delta)) == "Hi"
