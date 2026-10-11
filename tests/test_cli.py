from datetime import date

from robo import activity, cli, plan


def test_activity_prints_the_summary(monkeypatch, capsys):
    seen = {}

    def fake_summary(store, day=None, days=1):
        seen.update(day=day, days=days)
        return "Active 42 min"

    monkeypatch.setattr(activity, "summary", fake_summary)
    monkeypatch.setattr(activity, "ActivityStore", lambda *a, **k: object())
    assert cli.main(["activity", "--days", "3", "--day", "2026-10-11"]) == 0
    assert capsys.readouterr().out.strip() == "Active 42 min"
    assert seen == {"day": date(2026, 10, 11), "days": 3}


def test_plan_hands_its_arguments_to_the_planner(monkeypatch):
    got = []
    monkeypatch.setattr(plan, "main", lambda argv: got.append(argv) or 0)
    assert cli.main(["plan", "--tasks", "t.json", "--busy", "-"]) == 0
    assert got == [["--tasks", "t.json", "--busy", "-"]]


def test_xwayland_only_on_linux():
    env = {"DISPLAY": ":0"}
    cli._use_xwayland(env, "linux")
    assert env["QT_QPA_PLATFORM"] == "xcb;wayland"
    mac = {"DISPLAY": "/private/tmp/com.apple.launchd.x/org.xquartz:0"}  # XQuartz sets DISPLAY
    cli._use_xwayland(mac, "darwin")
    assert "QT_QPA_PLATFORM" not in mac
    own = {"DISPLAY": ":0", "QT_QPA_PLATFORM": "wayland"}
    cli._use_xwayland(own, "linux")
    assert own["QT_QPA_PLATFORM"] == "wayland"  # the user's choice wins


def test_robo_floats_on_xwayland_and_macos():
    assert set(cli.FLOATING) == {"xcb", "cocoa"}
