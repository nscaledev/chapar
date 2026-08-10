from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Final

AUDIT_PATH: Final = PurePosixPath("ci/tests/no-direct-install-surface-test.py")
RELEASE_PATHS: Final = frozenset({PurePosixPath("envs/software/release.sh")})
POLICY_PATHS: Final = frozenset(
    {
        PurePosixPath("AGENTS.md"),
        PurePosixPath(".agents/skills/chapar-release-helper/SKILL.md"),
        PurePosixPath(".agents/skills/chapar-spack-env-change/SKILL.md"),
    }
)
#: Tracked fixtures that are deliberately malformed inputs for their own
#: parsers; the audit must not treat unparseable-by-design bytes as findings.
MALFORMED_FIXTURE_PATHS: Final = frozenset(
    {
        PurePosixPath("envs/software/tests/fixtures/malformed.json"),
    }
)
POLICY_TOKENS: Final = ("never", "do not", "forbidden", "must not")
SHELL_SUFFIXES: Final = frozenset({".sh", ".bash", ".zsh"})
MARKDOWN_SUFFIXES: Final = frozenset({".md", ".markdown"})
SHELL_FENCES: Final = frozenset({"bash", "sh", "shell", "zsh", ""})
COMMAND_SEPARATORS: Final = frozenset({";", "&&", "||", "|", "&", "(", ")", "\n"})


@dataclass(frozen=True, slots=True)
class Candidate:
    path: PurePosixPath
    line: int
    tokens: tuple[str, ...]
    function: str | None = None
    controls: tuple[str, ...] = ()
    fixture_value: bool = False
    negative_policy: bool = False


@dataclass(frozen=True, slots=True)
class AuditResult:
    violations: tuple[Candidate, ...]
    internal_release: int
    negative_policy: int
    self_fixtures: int


class AuditInputError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class CliArguments:
    root: str
    file_list: str | None
    self_test: bool
