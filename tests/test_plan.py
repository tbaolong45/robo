"""Today's plan: the pure placement rules, then the JSON CLI Hermes runs from the terminal."""

import io
import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from robo.plan import Busy, Task, free_slots, main, plan_day, unscheduled

DXB = ZoneInfo("Asia/Dubai")


def at(hm: str, day: int = 12) -> datetime:
    h, m = map(int, hm.split(":"))
    return datetime(2026, 10, day, h, m, tzinfo=DXB)


def busy(*spans: str) -> list[Busy]:
    return [Busy(at(a), at(b)) for a, b in (s.split("-") for s in spans)]


def task(id: str, minutes: int = 60, deadline: str | None = None, priority: float = 0.5) -> Task:
    return Task(id, id.title(), minutes, at(deadline) if deadline else None, priority)


def plan(tasks, spans=(), now="07:00", **kw):
    return plan_day(tasks, busy(*spans), day_start=at("08:00"), day_end=at("22:00"),
                    now=at(now), **kw)


def mins(b) -> int:
    return (b.end - b.start) // timedelta(minutes=1)


def left(tasks, blocks) -> list[tuple[str, int]]:
    return [(t.id, m) for t, m in unscheduled(tasks, blocks)]


# --- free_slots -------------------------------------------------------------------------------


def test_free_slots_subtracts_busy_and_clips_to_the_day():
    spans = ("07:00-08:30", "10:00-11:00", "10:30-12:00", "12:00-12:30", "13:00-13:00",
             "21:00-23:00")  # straddles the start, overlaps, abuts, zero-width, straddles the end
    got = free_slots(busy(*spans), at("08:00"), at("22:00"))
    assert got == [(at("08:30"), at("10:00")), (at("12:30"), at("21:00"))]


def test_free_slots_keeps_gaps_of_exactly_the_minimum_and_drops_shorter():
    got = free_slots(busy("08:20-09:00", "09:25-22:00"), at("08:00"), at("22:00"), min_minutes=25)
    assert got == [(at("09:00"), at("09:25"))]


def test_free_slots_empty_calendar_and_empty_window():
    assert free_slots([], at("08:00"), at("22:00")) == [(at("08:00"), at("22:00"))]
    assert free_slots([], at("22:00"), at("08:00")) == []


def test_naive_datetimes_are_rejected():
    with pytest.raises(ValueError, match="timezone"):
        free_slots([], datetime(2026, 10, 12, 8), datetime(2026, 10, 12, 22))
    with pytest.raises(ValueError, match="timezone"):
        Busy(datetime(2026, 10, 12, 8), at("09:00"))


@pytest.mark.parametrize("kw", [{"minutes": 0}, {"minutes": 1.5}, {"priority": 1.5},
                                {"deadline": datetime(2026, 10, 12, 12)}])
def test_task_rejects_bad_fields(kw):
    with pytest.raises(ValueError):
        Task(**{"id": "a", "title": "A", "minutes": 30, **kw})


# --- plan_day ---------------------------------------------------------------------------------


def test_blocks_never_overlap_busy_time_or_each_other():
    spans = ("09:00-10:30", "12:00-13:00", "13:00-14:00", "15:00-15:30", "15:15-16:00",
             "18:40-19:10")
    tasks = [task("a", 200, priority=0.9), task("b", 60), task("c", 45, priority=0.2),
             task("d", 120), task("e", 300, priority=0.1)]
    blocks = plan(tasks, spans)
    assert len(blocks) >= 6
    for b in blocks:
        assert at("08:00") <= b.start < b.end <= at("22:00")
        for x in busy(*spans):
            assert b.end <= x.start or b.start >= x.end, (b, x)
    assert all(p.end <= n.start for p, n in zip(blocks, blocks[1:], strict=False))


def test_nothing_is_scheduled_after_its_deadline():
    tasks = [task("essay", 90, deadline="12:00", priority=0.9), task("quiz", 30, deadline="11:45"),
             task("late", 30, deadline="06:00"), task("open", 60, priority=0.1)]
    blocks = plan(tasks, ["08:00-11:00"])
    due = {t.id: t.deadline for t in tasks}
    assert all(due[b.task_id] is None or b.end <= due[b.task_id] for b in blocks)
    assert [b.task_id for b in blocks] == ["quiz", "open"]
    assert left(tasks, blocks) == [("essay", 90), ("late", 30)]


def test_partial_fit_reports_the_exact_minutes_left_over():
    tasks = [task("a", 200, deadline="11:30")]
    blocks = plan(tasks)
    assert [mins(b) for b in blocks] == [67, 67]
    assert left(tasks, blocks) == [("a", 66)]


def test_long_tasks_split_into_capped_blocks_with_breaks_between():
    blocks = plan([task("a", 200), task("b", 30)])
    assert blocks[0].start == at("08:00")
    assert [mins(b) for b in blocks if b.task_id == "a"] == [67, 67, 66]
    assert all(n.start - p.end >= timedelta(minutes=10)
               for p, n in zip(blocks, blocks[1:], strict=False))
    tuned = plan([task("a", 100)], max_block=50, break_min=15)
    assert [mins(b) for b in tuned] == [50, 50]
    assert tuned[1].start - tuned[0].end >= timedelta(minutes=15)


def test_nothing_starts_before_now_and_starts_land_on_five_minutes():
    blocks = plan([task("a", 30), task("b", 30)], now="10:03")
    assert blocks[0].start == at("10:05")
    assert all(b.start >= at("10:03") and b.start.minute % 5 == 0 for b in blocks)


def test_priority_then_nearest_deadline_wins_the_scarce_window():
    one_hour = ["09:00-22:00"]
    assert plan([task("low", priority=0.2), task("high", priority=0.9)], one_hour)[0].task_id \
        == "high"
    assert plan([task("later", deadline="20:00"), task("sooner", deadline="18:00")],
                one_hour)[0].task_id == "sooner"
    assert plan([task("open"), task("dated", deadline="20:00")], one_hour)[0].task_id == "dated"


def test_same_input_in_any_order_gives_the_same_plan():
    spans = ["09:00-10:30", "13:00-14:00"]
    tasks = [task("a", 120, priority=0.7), task("b", 60, priority=0.7),
             task("c", 90, deadline="20:00")]
    first = plan(tasks, spans)
    assert plan(tasks[::-1], spans[::-1]) == first == plan(tasks, spans)


# --- CLI --------------------------------------------------------------------------------------

NOW = at("07:00")
GOOD = '[{"id": "a", "title": "A", "minutes": 30}]'


def write(tmp_path, name: str, data) -> str:
    p = tmp_path / name
    p.write_text(data if isinstance(data, str) else json.dumps(data))
    return str(p)


def run(argv, capsys):
    rc = main(argv, now=NOW)
    out, err = capsys.readouterr()
    return rc, out, err


def test_cli_prints_blocks_and_unscheduled_as_json(tmp_path, capsys):
    tasks = write(tmp_path, "t.json", [
        {"id": "r", "title": "Read ch.3", "minutes": 60, "priority": 0.8},
        {"id": "e", "title": "Essay", "minutes": 90, "deadline": "2026-10-12T10:00:00+04:00"},
    ])
    # UTC "Z" and a naive time read in --tz: 08:00-09:00 Dubai.
    busy_ = write(tmp_path, "b.json",
                  [{"start": "2026-10-12T04:00:00Z", "end": "2026-10-12T09:00"}])
    rc, out, err = run(["--tasks", tasks, "--busy", busy_, "--start", "08:00", "--end", "12:00"],
                       capsys)
    assert (rc, err) == (0, "")
    assert json.loads(out) == {
        "blocks": [{"title": "Read ch.3", "start": "2026-10-12T09:00+04:00",
                    "end": "2026-10-12T10:00+04:00"}],
        "unscheduled": [{"id": "e", "title": "Essay", "minutes": 90}],
    }


def test_cli_reads_tasks_from_stdin_and_busy_is_optional(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(GOOD))
    rc, out, _ = run(["--tasks", "-", "--day", "2026-10-13", "--tz", "UTC"], capsys)
    assert rc == 0
    assert json.loads(out)["blocks"] == [
        {"title": "A", "start": "2026-10-13T08:00+00:00", "end": "2026-10-13T08:30+00:00"}]


def assert_one_line_error(rc, out, err, says):
    assert (rc, out) == (2, "")
    assert err.startswith("robo plan: ") and err.count("\n") == 1 and says in err, err


@pytest.mark.parametrize("tasks, extra, says", [
    (None, [], "cannot read"),
    ("{oops", [], "invalid JSON"),
    ('{"id": "a"}', [], "list of objects"),
    ('[{"id": "a", "title": "A"}]', [], "tasks[0]: missing 'minutes'"),
    ('[{"id": "a", "title": "A", "minutes": 0}]', [], "tasks[0]: minutes"),
    ('[{"id": "a", "title": "A", "minutes": 30, "deadline": "tomorrow"}]', [], "tasks[0].deadline"),
    ('[{"id": "a", "title": "A", "minutes": 30, "priority": 2}]', [], "priority"),
    (GOOD[:-1] + ', {"id": "a", "title": "B", "minutes": 5}]', [], "duplicate id 'a'"),
    (GOOD, ["--busy", "BAD_BUSY"], "busy[0].end"),
    (GOOD, ["--tz", "Mars/Base"], "--tz"),
    (GOOD, ["--day", "12/10/2026"], "--day"),
    (GOOD, ["--start", "22:00", "--end", "08:00"], "--end"),
])
def test_cli_bad_input_is_exit_2_with_one_line(tmp_path, capsys, tasks, extra, says):
    path = write(tmp_path, "t.json", tasks) if tasks is not None else str(tmp_path / "none.json")
    bad_busy = write(tmp_path, "b.json", '[{"start": "2026-10-12T09:00", "end": "soon"}]')
    extra = [bad_busy if a == "BAD_BUSY" else a for a in extra]
    assert_one_line_error(*run(["--tasks", path, *extra], capsys), says)


@pytest.mark.parametrize("argv, says",
                         [([], "--tasks"), (["--tasks", "-", "--busy", "-"], "stdin")])
def test_cli_usage_errors_are_exit_2_with_one_line(capsys, argv, says):
    assert_one_line_error(*run(argv, capsys), says)
