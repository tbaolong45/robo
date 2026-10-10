import stat

from robo import browser


class Proc:
    def __init__(self, argv):
        self.argv = argv


def test_running_browser_is_reused(tmp_path):
    started = []
    assert browser.ensure(tmp_path / "b", up=lambda: True, spawn=started.append) is False
    assert started == []


def test_starts_headless_brave_with_private_dir_and_waits(tmp_path):
    started, answers = [], iter([False, False, True])
    d = tmp_path / "b"
    assert browser.ensure(d, up=lambda: next(answers), spawn=started.append,
                          sleep=lambda s: None) is True
    argv = started[0]
    assert argv[0] == browser.BINARY
    assert f"--remote-debugging-port={browser.PORT}" in argv
    assert "--remote-debugging-address=127.0.0.1" in argv
    assert f"--user-data-dir={d}" in argv and "--headless=new" in argv
    assert stat.S_IMODE(d.stat().st_mode) == 0o700


def test_signin_is_visible(tmp_path):
    started = []
    browser.ensure(tmp_path / "b", headless=False, up=iter([False, True]).__next__,
                   spawn=started.append, sleep=lambda s: None, url="https://x")
    assert "--headless=new" not in started[0] and started[0][-1] == "https://x"


def test_gives_up_when_port_never_opens(tmp_path):
    try:
        browser.ensure(tmp_path / "b", up=lambda: False, spawn=lambda a: None,
                       sleep=lambda s: None)
    except browser.BrowserError as e:
        assert "Brave" in str(e)
    else:
        raise AssertionError("expected BrowserError")


def test_pids_finds_only_our_data_dir(tmp_path):
    d = tmp_path / "b"
    procs = {
        "1": f"brave\0--user-data-dir={d}\0",
        "2": f"brave\0--user-data-dir={d}-other\0",
        "3": "brave\0",
    }
    for pid, cmd in procs.items():
        (tmp_path / "proc" / pid).mkdir(parents=True)
        (tmp_path / "proc" / pid / "cmdline").write_text(cmd)
    assert browser.pids(d, proc=tmp_path / "proc") == [1]
