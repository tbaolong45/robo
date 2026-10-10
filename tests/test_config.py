"""Configuration: where the credentials live, and what a typo in study.toml does.

Two things here are worth more than the rest, and neither is visible from a run
that works:

* **`profile_dir` decides which Chromium profile the browser opens.** Resolve it
  against the process's working directory instead of the repo and `pli` run from
  anywhere but the repo root opens an empty profile - which reads exactly like an
  expired session, so the user is told to sign in again, signs in, and the next
  run fails the same way. The wrong answer here is indistinguishable from the
  problem the whole design is built around.

* **A config key that did not apply must not look like one that did.** `study.toml`
  is the file the user is invited to edit, and pydantic's default is to *ignore*
  keys it does not recognise: a misspelled `dayz = 3` left the horizon at 7 with
  no warning at all, so the tool planned a week while its owner believed it had
  planned three days. The same silence the Teams reader refuses to produce.
"""

from __future__ import annotations

from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from pydantic import ValidationError

from pli.config import (
    REPO_ROOT,
    ConfigError,
    Settings,
    StudyConfig,
    get_settings,
    load_study_config,
    system_timezone_name,
)


@pytest.fixture(autouse=True)
def _fresh_caches():
    """`load_study_config` and `get_settings` are `lru_cache`d, and every test
    below changes the thing they cache on."""
    load_study_config.cache_clear()
    get_settings.cache_clear()
    yield
    load_study_config.cache_clear()
    get_settings.cache_clear()


def _settings(**kwargs: object) -> Settings:
    kwargs.setdefault("_env_file", None)
    return Settings(**kwargs)


# --- where the profile and the ledger live ----------------------------------------


def test_a_relative_home_resolves_against_the_repo_not_the_working_directory(monkeypatch, tmp_path):
    """The regression this file exists for.

    `pli` is run from a cron entry, from `~`, from anywhere. A relative
    `PLI_HOME=data` has to mean the repo's `data/` in all of them: the ledger,
    the materials and the browser profile that holds the session.
    """
    monkeypatch.chdir(tmp_path)

    settings = _settings(pli_home=Path("data"))

    assert settings.home == REPO_ROOT / "data"
    assert settings.home != tmp_path / "data"


def test_a_relative_profile_resolves_against_the_repo(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)

    settings = _settings(browser_profile=Path("data/browser"))

    assert settings.profile_dir == REPO_ROOT / "data" / "browser"


def test_an_absolute_profile_is_used_as_given(monkeypatch, tmp_path):
    """The user put the profile somewhere on purpose - often outside the repo so
    a `git clean` cannot take their session with it."""
    monkeypatch.chdir(tmp_path)
    elsewhere = tmp_path / "elsewhere" / "browser"

    settings = _settings(browser_profile=elsewhere)

    assert settings.profile_dir == elsewhere


def test_the_ledger_and_the_materials_hang_off_the_home(tmp_path):
    settings = _settings(pli_home=tmp_path / "home")

    assert settings.db_path == tmp_path / "home" / "state.db"
    assert settings.materials_dir == tmp_path / "home" / "materials"


def test_the_env_file_is_the_repos_not_the_working_directorys(monkeypatch, tmp_path):
    """Reading `.env` from the CWD would mean the key is found when the user
    happens to be in the repo and mysteriously missing when they are not - a
    failure that appears and disappears with `cd`."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text("LLM_API_KEY=decoy-from-the-working-directory\n")

    settings = Settings()

    assert settings.llm_api_key != "decoy-from-the-working-directory"


# --- study.toml -------------------------------------------------------------------


def test_the_shipped_config_is_valid():
    """It is also the guard on `extra="forbid"` below: the file in the repo has
    to be one the models accept, key for key, or every command fails at startup."""
    cfg = load_study_config()

    assert cfg.horizon.days == 7
    assert cfg.study.earliest_hour < cfg.study.latest_hour


def test_a_missing_config_file_falls_back_to_the_defaults(tmp_path):
    """A first checkout with no `study.toml` is not an error - the defaults are
    the documented behaviour and the file is an override."""
    cfg = load_study_config(tmp_path / "absent.toml")

    assert cfg == StudyConfig()


def test_a_misspelled_key_is_an_error_and_not_a_silent_default(tmp_path):
    """The failure nobody notices: the user edits the file they were told to
    edit, makes a typo, and the tool plans with the defaults while reporting
    nothing. A wrong horizon is a wrong week."""
    path = tmp_path / "study.toml"
    path.write_text("[horizon]\ndayz = 3\n")

    with pytest.raises(ConfigError) as raised:
        load_study_config(path)

    assert "dayz" in str(raised.value), "the message has to name the key that was ignored"


def test_a_misspelled_section_is_an_error_too(tmp_path):
    path = tmp_path / "study.toml"
    path.write_text("[studies]\nearliest_hour = 9\n")

    with pytest.raises(ConfigError) as raised:
        load_study_config(path)

    assert "studies" in str(raised.value)


def test_a_wrong_type_is_a_sentence_and_not_a_traceback(tmp_path):
    """`pli status` is the command a user runs *when something is wrong*. It must
    not be the command that dies with a pydantic traceback."""
    path = tmp_path / "study.toml"
    path.write_text('[study]\nearliest_hour = "nine"\n')

    with pytest.raises(ConfigError) as raised:
        load_study_config(path)

    message = str(raised.value)
    assert "earliest_hour" in message
    assert "Traceback" not in message


def test_the_error_names_the_file_it_read(tmp_path):
    """There is more than one config file in this project; the message has to
    say which one is broken."""
    path = tmp_path / "study.toml"
    path.write_text("[horizon]\ndayz = 3\n")

    with pytest.raises(ConfigError) as raised:
        load_study_config(path)

    assert str(path) in str(raised.value)


# --- the timezone ------------------------------------------------------------------


def test_a_configured_timezone_is_used():
    assert _settings(pli_timezone="Asia/Dubai").timezone() == ZoneInfo("Asia/Dubai")


def test_an_unset_timezone_falls_back_to_a_usable_zone():
    """Whatever the fallback is, it has to be a zone the rest of the tool can
    call `astimezone` with - every renderer depends on it."""
    assert _settings(pli_timezone="").timezone() == ZoneInfo(system_timezone_name())


def test_the_system_timezone_name_is_stripped():
    """/etc/timezone ends in a newline, and `ZoneInfo("Asia/Dubai\\n")` raises -
    a crash in every renderer, from a file the user never touched."""
    assert system_timezone_name() == system_timezone_name().strip()
    ZoneInfo(system_timezone_name())  # would raise if the name were unusable


def test_a_bad_timezone_name_is_not_silently_swallowed():
    """An unknown zone is a typo in `.env`, and swallowing it would plan the week
    in a timezone the user did not ask for. It is refused when the settings load."""
    with pytest.raises(ValidationError, match="Mars/Olympus_Mons"):
        _settings(pli_timezone="Mars/Olympus_Mons")


# --- per-course weights ------------------------------------------------------------


def test_a_configured_weight_is_used():
    cfg = StudyConfig(weights={"CS301": 1.5})

    assert cfg.weight_for("CS301") == 1.5


def test_an_unlisted_course_keeps_its_full_weight():
    """The default has to be neutral. A `0.0` here would silently rank every
    course the user did not list below every course they did."""
    cfg = StudyConfig()

    assert cfg.weight_for("GEN101") == 1.0


def test_a_bad_env_value_names_the_variable_the_user_typed(monkeypatch):
    """pydantic reports the *field* - `browser_headless` - and that string is
    nowhere in the `.env` the user has to go and fix."""
    monkeypatch.setenv("BROWSER_HEADLESS", "maybe")

    with pytest.raises(ConfigError) as raised:
        get_settings()

    assert "BROWSER_HEADLESS" in str(raised.value)


def test_a_bad_env_value_names_the_env_file(monkeypatch):
    monkeypatch.setenv("BROWSER_SLOW_MO_MS", "fast")

    with pytest.raises(ConfigError) as raised:
        get_settings()

    assert ".env" in str(raised.value)


def test_a_mistyped_timezone_is_a_settings_error_not_a_traceback_in_every_command(monkeypatch):
    """`Asia/Dubay` would otherwise surface as ZoneInfoNotFoundError from whichever command
    first asked for the zone, and `pli watch` would report it every minute forever."""
    monkeypatch.setenv("PLI_TIMEZONE", "Asia/Dubay")

    with pytest.raises(ConfigError) as raised:
        get_settings()

    assert "PLI_TIMEZONE" in str(raised.value) and "Asia/Dubay" in str(raised.value)


def test_a_real_timezone_and_an_empty_one_are_both_accepted(monkeypatch):
    monkeypatch.setenv("PLI_TIMEZONE", "Asia/Dubai")
    assert get_settings().timezone().key == "Asia/Dubai"

    get_settings.cache_clear()
    monkeypatch.setenv("PLI_TIMEZONE", "")
    assert get_settings().pli_timezone == ""
