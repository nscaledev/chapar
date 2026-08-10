"""The light documentation linter.

Three rules keep the docs honest without turning them into compliance
fixtures (the old documentation-contract tests enforced boilerplate and even
capped README at one bash fence — deliberately not reproduced here):

1. Doc bash fences never instruct a direct `spack install` — delivery goes
   through release.sh.
2. Backtick-quoted repo paths must exist — the rule that catches stale docs.
3. Every `chapar ...` command line in a fence names a real registered
   subcommand, checked against the argparse tree itself.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT

DOC_FILES: tuple[Path, ...] = tuple(
    sorted(
        {
            REPO_ROOT / "README.md",
            REPO_ROOT / "AGENTS.md",
            REPO_ROOT / "etc/README.md",
            REPO_ROOT / "containers/README.md",
            REPO_ROOT / "envs/software/README.md",
            REPO_ROOT / "spack_repo/README.md",
            REPO_ROOT / "validation/README.md",
            REPO_ROOT / "validation/ARCHITECTURE.md",
            *(REPO_ROOT / "docs").glob("*.md"),
        }
    )
)

REPO_PATH_TOKEN = re.compile(
    r"^(?:\.agents|\.githooks|ci|containers|docs|envs|etc|src|tests|validation|spack_repo)/[A-Za-z0-9._/\-]*[A-Za-z0-9_\-]$"
)
TOP_LEVEL_FILES = {"Makefile", "README.md", "AGENTS.md", "CLAUDE.md", "TODO.md", "pyproject.toml", "opencode.json"}
# Referenced by design but absent from a fresh checkout.
UNTRACKED_ALLOWED = {"etc/chapar-site.env", "etc/user/compilers.yaml", "etc/user/packages.yaml"}
DIRECT_INSTALL = re.compile(r"\bspack\s+(?:buildcache\s+)?install\b")


def fences(text: str) -> list[str]:
    lines: list[str] = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            lines.append(line)
    return lines


def backtick_tokens(text: str) -> list[str]:
    return re.findall(r"`([^`\n]+)`", text)


@pytest.mark.parametrize("doc", DOC_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_no_direct_install_instructions(doc: Path) -> None:
    offenders = [line for line in fences(doc.read_text(encoding="utf-8")) if DIRECT_INSTALL.search(line)]
    assert not offenders, f"direct-install instruction in {doc.name}: {offenders}"


@pytest.mark.parametrize("doc", DOC_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_no_dead_repo_paths(doc: Path) -> None:
    missing: list[str] = []
    for token in backtick_tokens(doc.read_text(encoding="utf-8")):
        candidate = token.strip().rstrip(":").rstrip("/")
        if any(marker in candidate for marker in ("<", ">", "*", "{", "$", " ", "|")):
            continue
        if candidate in UNTRACKED_ALLOWED:
            continue
        is_repo_path = bool(REPO_PATH_TOKEN.match(candidate)) or candidate in TOP_LEVEL_FILES
        if is_repo_path and not (REPO_ROOT / candidate).exists():
            missing.append(candidate)
    assert not missing, f"{doc} references paths that do not exist: {sorted(set(missing))}"


def chapar_commands() -> dict[str, set[str]]:
    """group -> subcommands, walked from the real parser."""
    import argparse

    from chapar.cli import build_parser

    tree: dict[str, set[str]] = {}
    parser = build_parser()
    for action in parser._subparsers._group_actions:
        if not isinstance(action, argparse._SubParsersAction):
            continue
        for group_name, group_parser in action.choices.items():
            commands: set[str] = set()
            if group_parser._subparsers is not None:
                for sub_action in group_parser._subparsers._group_actions:
                    if isinstance(sub_action, argparse._SubParsersAction):
                        commands.update(sub_action.choices)
            tree[group_name] = commands
    return tree


CHAPAR_LINE = re.compile(r"(?:uv run\s+|python3 -m\s+)?\bchapar\s+([a-z][a-z-]*)(?:\s+([a-z][a-z-]*))?")


@pytest.mark.parametrize("doc", DOC_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_chapar_commands_are_real(doc: Path) -> None:
    tree = chapar_commands()
    bad: list[str] = []
    for line in fences(doc.read_text(encoding="utf-8")):
        match = CHAPAR_LINE.search(line)
        if not match:
            continue
        group, command = match.group(1), match.group(2)
        if group in {"error"}:  # error-message examples
            continue
        if group not in tree:
            bad.append(line.strip())
            continue
        if command and tree[group] and command not in tree[group] and not command.startswith("-"):
            bad.append(line.strip())
    assert not bad, f"{doc} references chapar commands that do not exist: {bad}"
