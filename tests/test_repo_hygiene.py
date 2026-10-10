"""What must never be committed.

The browser profile holds live session cookies for a university account; `.env`
holds an API key and a Moodle token. Both are excluded by `.gitignore`, and
nothing else stands between them and a `git add -A` - so the exclusion is worth
a test.

These ask **git** rather than reading the file. A `.gitignore` line can be
present and still not match: a leading slash anchors it to the repo root, a
trailing slash only matches directories, and a typo in a path is invisible to
`assert ".env" in text`. `git check-ignore` is the only thing that answers the
question actually being asked - "would this file be committed?".
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

#: Paths that must never be tracked, with what each one would leak.
SECRETS = {
    ".env": "the API key and the Moodle token",
    "data/state.db": "the local ledger",
    "data/browser/Default/Cookies": "live session cookies for the university account",
    "data/browser/Default/Network/Cookies": "live session cookies for the university account",
    "outlook.token_cache.json": "a Microsoft Graph token",
    "msal_cache.json": "an MSAL token cache",
}


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, check=False)


@pytest.mark.parametrize("path,leaks", sorted(SECRETS.items()))
def test_a_secret_path_is_ignored_by_git(path, leaks):
    """`git check-ignore` exits 0 when the path is ignored, 1 when it is not."""
    result = _git("check-ignore", "--quiet", path)

    assert result.returncode == 0, (
        f"{path} would be committed; it holds {leaks}. Add it to .gitignore."
    )


def test_no_secret_is_already_tracked():
    """The ignore rules do nothing for a file git already knows about: an ignore
    entry cannot untrack anything. This is the check that catches a secret added
    before the rule existed."""
    tracked = set(_git("ls-files").stdout.splitlines())

    leaked = sorted(tracked & set(SECRETS))
    assert not leaked, f"already tracked in git: {leaked}"


def test_the_ignore_rules_are_actually_in_the_repository():
    """A working `check-ignore` could come from a global or system exclude, which
    would protect this machine and no one else's. The rules have to be in the
    repo's own file."""
    ignored = _git("check-ignore", "--verbose", "--no-index", ".env").stdout

    assert ".gitignore" in ignored
