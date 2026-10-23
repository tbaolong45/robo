import stat
import subprocess
import sys
from pathlib import Path

import pytest

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


def test_pids_matches_chromium_rewritten_cmdline(tmp_path):
    d = tmp_path / "b"
    (tmp_path / "proc" / "7").mkdir(parents=True)  # Chromium joins argv with spaces in place
    (tmp_path / "proc" / "7" / "cmdline").write_text(f"brave --user-data-dir={d} --x=1\0\0\0")
    (tmp_path / "proc" / "8").mkdir(parents=True)
    (tmp_path / "proc" / "8" / "cmdline").write_text(f"brave --user-data-dir={d}-other --x\0")
    assert browser.pids(d, proc=tmp_path / "proc") == [7]


def test_find_brave_on_path_else_where_the_installer_puts_it():
    on_path = {"brave-browser": "/usr/bin/brave-browser"}
    assert browser.find_brave("linux", on_path.get) == "/usr/bin/brave-browser"
    assert browser.find_brave("darwin", {}.get) == browser.MAC_BRAVE
    assert browser.MAC_BRAVE == "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    assert browser.find_brave("linux", {}.get) == "brave-browser"


APP = "/Applications/Brave Browser.app/Contents"
PS = """\
  101 {app}/MacOS/Brave Browser --user-data-dir={d} --headless=new
  102 {app}/Frameworks/Brave Helper --type=renderer --user-data-dir={d}
  103 {app}/MacOS/Brave Browser --user-data-dir={d}2
  104 /bin/zsh -l
"""


def test_pids_without_proc_reads_ps_even_with_a_space_in_home(tmp_path):
    d = tmp_path / "Jane Doe" / "brave"
    ps = PS.format(app=APP, d=d)
    assert browser.pids(d, proc=tmp_path / "no-proc", ps=lambda: ps) == [101, 102]


def test_pids_without_proc_survive_a_failing_ps(tmp_path):
    def boom():
        raise OSError("no ps")

    assert browser.pids(tmp_path, proc=tmp_path / "no-proc", ps=boom) == []


def test_pids_find_a_real_process_through_ps_and_proc(tmp_path):
    d = tmp_path / "brave"
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                          f"--user-data-dir={d}"])
    try:
        assert p.pid in browser.pids(d, proc=tmp_path / "no-proc")  # real ps
        if Path("/proc").is_dir():
            assert p.pid in browser.pids(d)  # real /proc
    finally:
        p.kill()
        p.wait()


def test_a_missing_brave_is_a_browser_error_not_a_crash(tmp_path):
    def spawn(argv):
        raise FileNotFoundError(2, "No such file or directory", argv[0])

    with pytest.raises(browser.BrowserError, match="Brave"):
        browser.ensure(tmp_path / "b", up=lambda: False, spawn=spawn)


def test_downloads_go_to_the_folder_and_pdfs_are_downloaded_not_viewed(tmp_path):
    import json
    seen = {}
    answers = iter([False, True])
    browser.ensure(tmp_path / "b", downloads=tmp_path / "dl", up=lambda: next(answers),
                   spawn=lambda argv: seen.update(json.loads(
                       (tmp_path / "b/Default/Preferences").read_text())),
                   sleep=lambda s: None)
    assert seen["download"] == {"default_directory": str(tmp_path / "dl"),
                                "prompt_for_download": False}  # written BEFORE the start
    assert seen["plugins"]["always_open_pdf_externally"] is True and (tmp_path / "dl").is_dir()


def test_the_other_preferences_are_kept_and_an_unreadable_file_is_left_alone(tmp_path):
    import json
    file = tmp_path / "b/Default/Preferences"
    file.parent.mkdir(parents=True)
    file.write_text('{"profile": {"name": "Robo"}, "download": {"extensions_to_open": "pdf"}}')
    browser.allow_downloads(tmp_path / "b", tmp_path / "dl")
    prefs = json.loads(file.read_text())
    assert prefs["profile"] == {"name": "Robo"} and prefs["download"]["extensions_to_open"] == "pdf"
    assert prefs["download"]["default_directory"] == str(tmp_path / "dl")
    file.write_text("not json")
    browser.allow_downloads(tmp_path / "b", tmp_path / "dl")
    assert file.read_text() == "not json"


def test_without_a_folder_the_profile_is_not_touched(tmp_path):
    answers = iter([False, True])
    browser.ensure(tmp_path / "b", up=lambda: next(answers), spawn=lambda a: None,
                   sleep=lambda s: None)
    assert not (tmp_path / "b/Default/Preferences").exists()
