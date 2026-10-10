"""Configuration: secrets from .env, study preferences from config/study.toml."""

from __future__ import annotations

import tomllib
from functools import lru_cache
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_STUDY_CONFIG = REPO_ROOT / "config" / "study.toml"


class ConfigError(Exception):
    """A configuration file the user can fix, described in one sentence.

    Raised instead of letting pydantic's `ValidationError` reach the top of a
    command: `pli status` is what a user runs when something is wrong, so it is
    the last command that may die with a traceback.
    """


class Settings(BaseSettings):
    """Secrets and machine-local paths. Read from the environment / .env."""

    model_config = SettingsConfigDict(
        env_file=REPO_ROOT / ".env", env_file_encoding="utf-8", extra="ignore"
    )

    # LLM - any OpenAI-compatible endpoint (GLM, DeepSeek, ...).
    llm_api_key: str = ""
    llm_base_url: str = "https://api.deepseek.com"
    llm_model: str = "deepseek-chat"

    # TypeSafe - the judgement layer over captured page content.
    typesafe_api_key: str = ""
    typesafe_model: str = "jev-latest"
    typesafe_timeout: float = 60.0

    # Speech-to-text for `pli agent --voice`. Runs on this machine: the audio is
    # never sent anywhere. A faster-whisper model name; `base.en` is ~145 MB.
    stt_model: str = "base.en"

    # The browser that reaches Microsoft 365 and Moodle.
    #: Where the signed-in Chromium profile lives. This holds live session
    #: cookies for the user's university account, so it is gitignored and
    #: created 0700.
    browser_profile: Path = Path("data/browser")
    #: False shows the window, which is the only way to sign in or to watch a
    #: read happen. True is for the scheduled run.
    browser_headless: bool = True
    #: Slow every browser action down by this many ms. A little delay makes
    #: automation look like a person to the web app and avoids races where the
    #: page has not finished rendering an event.
    browser_slow_mo_ms: int = 0
    outlook_url: str = "https://outlook.office.com/calendar/view/week"
    teams_url: str = "https://teams.microsoft.com/"

    # Moodle (Phase 2).
    moodle_base_url: str = ""
    moodle_token: str = ""

    # Local activity watching (`pli watch`). Counts only: no titles, URLs, file names,
    # commit messages or shell commands are ever stored.
    #: Folders searched for git repositories and edited files, comma separated.
    activity_roots: str = "~/logrian"
    #: The only websites whose visits are counted (subdomains included); anything else
    #: in the browser history is never stored. Comma separated.
    activity_domains: str = (
        "github.com,docs.python.org,stackoverflow.com,"
        "outlook.office.com,teams.microsoft.com,learn.chatgpt.com"
    )
    #: Days of activity kept; older rows are deleted every cycle.
    activity_retention_days: int = 30
    #: A Chromium/Brave `History` file. Empty = look for Brave's default profile.
    activity_history_path: str = ""

    #: Lets `pli agent` look things up on the web (a question that needs live information, or
    #: "search the web for ..."): the typed question goes to a search engine and public pages
    #: are read in a fresh browser. False removes the tool.
    web_enabled: bool = True

    #: The sender name the LMS's deadline notices come from, exactly as the inbox shows it.
    #: Notices from anyone else are not tracked.
    deadline_sender: str = "LMS"

    pli_timezone: str = ""
    pli_home: Path = Path("data")

    @property
    def profile_dir(self) -> Path:
        p = self.browser_profile
        return p if p.is_absolute() else REPO_ROOT / p

    @property
    def home(self) -> Path:
        p = self.pli_home
        return p if p.is_absolute() else REPO_ROOT / p

    @property
    def db_path(self) -> Path:
        return self.home / "state.db"

    @property
    def materials_dir(self) -> Path:
        return self.home / "materials"

    @property
    def deadlines_db_path(self) -> Path:
        """Deadlines found in LMS mail notices, kept apart from the planner's own table."""
        return self.home / "deadlines.db"

    @property
    def activity_db_path(self) -> Path:
        return self.home / "activity.db"

    @property
    def activity_pause_path(self) -> Path:
        """Its existence means `pli watch` is paused and collects nothing."""
        return self.home / "activity.paused"

    @property
    def activity_root_paths(self) -> list[Path]:
        return [Path(r.strip()).expanduser() for r in self.activity_roots.split(",") if r.strip()]

    @property
    def activity_domain_list(self) -> list[str]:
        return [d.strip().lower() for d in self.activity_domains.split(",") if d.strip()]

    @field_validator("pli_timezone")
    @classmethod
    def _known_zone(cls, value: str) -> str:
        if value:
            try:
                ZoneInfo(value)
            except (ZoneInfoNotFoundError, ValueError) as exc:
                raise ValueError(f"'{value}' is not a time zone name such as Asia/Dubai") from exc
        return value

    def timezone(self) -> ZoneInfo:
        return ZoneInfo(self.pli_timezone or system_timezone_name())


def system_timezone_name() -> str:
    """Best-effort IANA zone from the OS. Ubuntu keeps it in /etc/timezone."""
    etc = Path("/etc/timezone")
    try:
        if etc.exists() and (name := etc.read_text().strip()):
            return name
    except OSError:
        pass
    localtime = Path("/etc/localtime")
    try:
        target = localtime.resolve()
        if "zoneinfo" in target.parts:
            return "/".join(target.parts[target.parts.index("zoneinfo") + 1 :])
    except OSError:
        pass
    return "UTC"


# --- study.toml -----------------------------------------------------------------


#: `study.toml` is hand-edited, so every study model rejects unknown keys. The
#: default is to ignore them, which turns a typo into a silent no-op: the tool
#: plans with the defaults while its owner believes the file applied. `Settings`
#: deliberately does the opposite - it reads the whole environment, which is full
#: of keys that are none of its business.
_STRICT = ConfigDict(extra="forbid")


class HorizonCfg(BaseModel):
    model_config = _STRICT

    days: int = 7


class StudyCfg(BaseModel):
    model_config = _STRICT

    session_min_minutes: int = 45
    session_max_minutes: int = 120
    break_minutes: int = 15
    daily_cap_minutes: int = 300
    # Ceiling per course per day, so one subject cannot eat the whole evening.
    course_daily_cap_minutes: int = 180
    earliest_hour: int = 8
    latest_hour: int = 22
    weekdays_allowed: list[int] = Field(default_factory=lambda: list(range(7)))
    weekend_daily_cap_minutes: int = 240


class DeepWorkCfg(BaseModel):
    model_config = _STRICT

    prefer_before_hour: int = 14


class DeadlineCfg(BaseModel):
    model_config = _STRICT

    urgent_within_days: int = 3


class StudyConfig(BaseModel):
    model_config = _STRICT

    horizon: HorizonCfg = Field(default_factory=HorizonCfg)
    study: StudyCfg = Field(default_factory=StudyCfg)
    deep_work: DeepWorkCfg = Field(default_factory=DeepWorkCfg)
    deadlines: DeadlineCfg = Field(default_factory=DeadlineCfg)
    weights: dict[str, float] = Field(default_factory=dict)

    def weight_for(self, course: str) -> float:
        """Per-course multiplier. Matches on the full name or the short code."""
        return float(self.weights.get(course, 1.0))


def _first_problem(exc: ValidationError, *, as_env_var: bool = False) -> str:
    """`field.path: what is wrong with it`, for the first thing pydantic found.

    Every problem in the file is a fix the user has to make, but one sentence
    naming the first is what they can act on; a wall of pydantic output is not.

    `as_env_var` upper-cases the field name, because the user typed
    `BROWSER_HEADLESS` into `.env` and pydantic reports `browser_headless` - a
    name that appears nowhere in the file they have to go and edit.
    """
    error = exc.errors()[0]
    where = ".".join(str(part) for part in error["loc"]) or "config"
    if as_env_var:
        where = where.upper()
    return f"{where}: {error['msg']}"


@lru_cache(maxsize=1)
def load_study_config(path: Path | None = None) -> StudyConfig:
    target = path or DEFAULT_STUDY_CONFIG
    if not target.exists():
        return StudyConfig()
    try:
        with target.open("rb") as fh:
            return StudyConfig.model_validate(tomllib.load(fh))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{target}: not valid TOML ({exc})") from exc
    except ValidationError as exc:
        raise ConfigError(f"{target}: {_first_problem(exc)}") from exc


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    try:
        return Settings()
    except ValidationError as exc:
        raise ConfigError(f"{REPO_ROOT / '.env'}: {_first_problem(exc, as_env_var=True)}") from exc
