#!/usr/bin/env python3
# noqa: SIZE_OK - one full-tree policy recognizer; required in-module AST fixtures make its adapters and mutation contract indivisible.
"""Reject direct Spack installation surfaces outside versioned release internals."""

from __future__ import annotations

import ast
import hashlib
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tokenize
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from typing import Final, assert_never

sys.dont_write_bytecode = True
from no_direct_install_inputs import (  # noqa: E402 - suppress product-tree pycache before local import.
    AuditInputError,
    BINARY_PATH,
    load_documents,
    parse_file_list,
    parse_file_names,
    parse_stage_zero_index,
)


AUDIT_PATH: Final = PurePosixPath("ci/tests/no-direct-install-surface-test.py")
RELEASE_PATHS: Final = frozenset(
    {PurePosixPath("envs/hpcsim/release.sh"), PurePosixPath("envs/vlad/release.sh")}
)
POLICY_PATHS: Final = frozenset(
    {
        PurePosixPath("AGENTS.md"),
        PurePosixPath("agents/skills/chapar-release-helper/SKILL.md"),
        PurePosixPath("agents/skills/chapar-spack-env-change/SKILL.md"),
        PurePosixPath("docs/ci-github-actions.md"),
    }
)
POLICY_TOKENS: Final = ("never", "do not", "forbidden", "must not")
SHELL_SUFFIXES: Final = frozenset({".sh", ".bash", ".zsh"})
MARKDOWN_SUFFIXES: Final = frozenset({".md", ".markdown"})
SHELL_FENCES: Final = frozenset({"bash", "sh", "shell", "zsh", ""})
COMMAND_SEPARATORS: Final = frozenset({";", "&&", "||", "|", "&", "(", ")", "\n"})
SELF_TEST_FIXTURES: dict[str, str] = {
    "prerequisite": 'spack -C "${scope_dir}" install "$@" "${spec}"',
    "cuda-dependencies": 'spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete "${install_args_ref[@]}" --only dependencies "${spec_hash}"',
    "cuda-package": 'spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete --dirty "${install_args_ref[@]}" --only package "${spec_hash}"',
    "environment": 'spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"',
    "policy-never": "NEVER run `spack install example` directly.",
    "policy-do-not": "Do NOT run `spack install example` directly.",
    "policy-forbidden": "A direct `spack install example` is forbidden.",
    "policy-must-not": "Operators must not run `spack install example` directly.",
    "rogue": "spack install rogue-package",
}


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


@dataclass(frozen=True, slots=True)
class InputSelfTestResult:
    failures: tuple[str, ...]
    messages: tuple[str, ...]
    accepted: int
    rejected: int


@dataclass(frozen=True, slots=True)
class RepositoryFixture:
    root: Path
    selected: bytes


@dataclass(frozen=True, slots=True)
class RejectedRepository:
    name: str
    fixture: RepositoryFixture
    status: int
    reason: str


@dataclass(frozen=True, slots=True)
class CliArguments:
    root: str
    file_list: str | None
    self_test: bool


def lex_shell(source: str) -> tuple[str, ...]:
    source = source.replace("\\\r\n", "").replace("\\\n", "")
    lexer = shlex.shlex(source, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = "#"
    try:
        return tuple(lexer)
    except ValueError as error:
        raise AuditInputError(f"malformed shell syntax: {error}") from error


def logical_shell_lines(text: str) -> Iterator[tuple[int, str]]:
    pending = ""
    start_line = 1
    heredoc: tuple[str, bool] | None = None
    for line_number, line in enumerate(text.splitlines(), 1):
        if heredoc is not None:
            delimiter, strips_tabs = heredoc
            candidate = line.lstrip("\t") if strips_tabs else line
            if candidate == delimiter:
                heredoc = None
            continue
        if not pending:
            start_line = line_number
        trailing_slashes = len(line) - len(line.rstrip("\\"))
        if not line.lstrip().startswith("#") and trailing_slashes % 2 == 1:
            pending += line[:-1] + " "
            continue
        pending += line
        heredoc_match = re.search(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line)
        if heredoc_match is not None:
            heredoc = (heredoc_match.group(3), heredoc_match.group(1) == "-")
        try:
            shell_tokens = lex_shell(pending)
        except AuditInputError:
            pending += "\n"
        else:
            substitution_depth = 0
            previous_character = ""
            for token in shell_tokens:
                for character in token:
                    if character == "(" and (substitution_depth or previous_character == "$"):
                        substitution_depth += 1
                    elif character == ")" and substitution_depth:
                        substitution_depth -= 1
                    previous_character = character
            if substitution_depth:
                pending += "\n"
                continue
            try:
                legacy_backtick_payloads(pending)
            except AuditInputError:
                pending += "\n"
                continue
            yield start_line, pending
            pending = ""
    if heredoc is not None:
        raise AuditInputError(f"unterminated heredoc at line {start_line}")
    if pending:
        lex_shell(pending)
        legacy_backtick_payloads(pending)
        raise AuditInputError(f"unterminated command substitution at line {start_line}")


def legacy_backtick_payloads(source: str) -> tuple[str, ...]:
    payloads: list[str] = []
    payload: list[str] | None = None
    single_quoted = False
    double_quoted = False
    escaped = False
    for index, character in enumerate(source):
        marker_run = character == "`" and (
            (index > 0 and source[index - 1] == "`") or (index + 1 < len(source) and source[index + 1] == "`")
        )
        if escaped:
            if payload is not None:
                payload.append(character)
            escaped = False
            continue
        if character == "\\":
            if payload is not None:
                payload.append(character)
            escaped = True
            continue
        if payload is not None:
            if character == "`" and not marker_run:
                payloads.append("".join(payload))
                payload = None
            else:
                payload.append(character)
            continue
        if character == "'" and not double_quoted:
            single_quoted = not single_quoted
        elif character == '"' and not single_quoted:
            double_quoted = not double_quoted
        elif character == "#" and not single_quoted and not double_quoted and (index == 0 or source[index - 1] in " \t\r\n;&|()"):
            break
        elif character == "`" and not single_quoted and not marker_run:
            payload = []
    if payload is not None:
        raise AuditInputError("unterminated legacy command substitution")
    return tuple(payloads)


def direct_install_segment(source: str, *, shell_syntax: bool = False) -> tuple[str, ...] | None:
    normalized = source.replace("\\\r\n", "").replace("\\\n", "")
    if re.search(r"\bspack\b", normalized) is None or re.search(r"\binstall\b", normalized) is None:
        return None
    if shell_syntax:
        for payload in legacy_backtick_payloads(normalized):
            if direct_install_segment(payload, shell_syntax=True) is not None:
                return lex_shell(normalized)
    tokens = lex_shell(normalized)
    for index, token in enumerate(tokens):
        if token != "spack":
            continue
        for following in tokens[index + 1 :]:
            if following in COMMAND_SEPARATORS:
                break
            if following == "install":
                return tokens
    for index, token in enumerate(tokens):
        executable = PurePosixPath(token).name
        payload: str | None = None
        if executable in {"bash", "dash", "ksh", "sh", "zsh"}:
            for option_index in range(index + 1, len(tokens)):
                option = tokens[option_index]
                if option.startswith("-") and not option.startswith("--") and "c" in option[1:]:
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
        elif executable == "env":
            for option_index in range(index + 1, len(tokens)):
                option = tokens[option_index]
                if option == "-S":
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
                if option.startswith("-S") and len(option) > 2:
                    payload = option[2:]
                    break
                if option.startswith("--split-string="):
                    payload = option.partition("=")[2]
                    break
                if option == "--split-string":
                    payload = tokens[option_index + 1] if option_index + 1 < len(tokens) else None
                    break
        if payload is not None and direct_install_segment(payload, shell_syntax=True) is not None:
            return tokens
        if "$(" in token and token != normalized and direct_install_segment(token, shell_syntax=shell_syntax) is not None:
            return tokens
    return None


def shell_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    function: str | None = None
    controls: list[str] = []
    declaration = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
    for line_number, line in logical_shell_lines(text):
        match = declaration.match(line)
        if match is not None:
            function = match.group(1)
            controls = []
            continue
        stripped = line.strip()
        if function is not None and stripped == "}" and not controls:
            function = None
            continue
        tokens = direct_install_segment(line.lstrip("\t"), shell_syntax=True)
        if tokens is not None:
            yield Candidate(path=path, line=line_number, tokens=tokens, function=function, controls=tuple(controls))
        if re.match(r"^(?:(?:fi|done|esac)\b|[})])", stripped) and controls:
            controls.pop()
        opener = re.match(r"^(if|for|while|until|case|select)\b", stripped)
        if opener is not None:
            controls.append(opener.group(1))
        elif stripped == "{" or stripped == "(":
            controls.append(stripped)
        elif re.search(r"\$\(\s*$", stripped):
            controls.append("$(")


def markdown_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    fence_marker: str | None = None
    fence_length = 0
    shell_fence = False
    fence_line = 0
    fence_content: list[str] = []
    shell_blocks: list[tuple[int, str]] = []
    prose: list[tuple[int, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        opening = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", line)
        if fence_marker is None and opening is not None:
            marker, info = opening.groups()
            if marker[0] == "`" and "`" in info:
                prose.append((line_number, line))
                continue
            language = info.strip().split(maxsplit=1)[0].lower() if info.strip() else ""
            fence_marker = marker[0]
            fence_length = len(marker)
            shell_fence = language in SHELL_FENCES
            fence_line = line_number
            fence_content = []
            continue
        if fence_marker is not None:
            closing = re.fullmatch(rf" {{0,3}}{re.escape(fence_marker)}{{{fence_length},}}[ \t]*", line)
            if closing is not None:
                if shell_fence:
                    shell_blocks.append((fence_line, "\n".join(fence_content)))
                fence_marker = None
                fence_content = []
                continue
            fence_content.append(line)
            continue
        prose.append((line_number, line))
    if fence_marker is not None and shell_fence:
        shell_blocks.append((fence_line, "\n".join(fence_content)))
    for opening_line, content in shell_blocks:
        for candidate in shell_candidates(path, content):
            yield Candidate(path=path, line=opening_line + candidate.line, tokens=candidate.tokens)
    block: list[tuple[int, str]] = []
    for line_number, line in prose + [(0, "")]:
        starts_item = re.match(r"\s*(?:[-*+] |\d+\. )", line) is not None
        if block and (not line.strip() or starts_item):
            normalized = " ".join(part.strip() for _, part in block)
            for sentence in re.split(r"(?<=[.!?])\s+", normalized):
                policy_words = sentence.lower()
                policy_language = any(token in policy_words for token in POLICY_TOKENS)
                if path not in POLICY_PATHS and not policy_language and not block[0][1].lstrip().startswith(("-", "*", "+")):
                    continue
                commands = tuple(filter(None, (direct_install_segment(inline) for inline in re.findall(r"`([^`]+)`", sentence))))
                negative = len(commands) == 1 and policy_language
                for tokens in commands:
                    yield Candidate(path=path, line=block[0][0], tokens=tokens, negative_policy=negative)
            block = []
        if line.strip():
            block.append((line_number, line))


def json_strings(value: str | int | float | bool | None | list[json_value] | dict[str, json_value]) -> Iterator[str]:
    match value:
        case str() as text:
            yield text
        case list() as items:
            for item in items:
                yield from json_strings(item)
        case dict() as entries:
            for item in entries.values():
                yield from json_strings(item)
        case int() | float() | bool() | None:
            return
        case unreachable:
            assert_never(unreachable)


type json_value = str | int | float | bool | None | list[json_value] | dict[str, json_value]


def json_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    try:
        document: json_value = json.loads(text)
    except json.JSONDecodeError as error:
        raise AuditInputError(f"malformed JSON: {error.msg} at line {error.lineno}") from error
    for value in json_strings(document):
        tokens = direct_install_segment(value)
        if tokens is not None:
            line = text.count("\n", 0, text.find(value)) + 1
            yield Candidate(path=path, line=line, tokens=tokens)


def fixture_nodes(tree: ast.Module) -> frozenset[int]:
    for statement in tree.body:
        match statement:  # noqa: MATCH_OK - AST visitors intentionally select relevant node shapes.
            case ast.AnnAssign(
                target=ast.Name(id="SELF_TEST_FIXTURES"),
                annotation=annotation,
                value=ast.Dict(values=values),
            ) if ast.unparse(annotation) == "dict[str, str]":
                if all(isinstance(value, ast.Constant) and isinstance(value.value, str) for value in values):
                    return frozenset(id(value) for value in values)
            case _:
                continue
    return frozenset()


def static_string(node: ast.expr) -> str | None:
    match node:  # noqa: MATCH_OK - dynamic string expressions are intentionally rejected.
        case ast.Constant(value=str() as value):
            return value
        case ast.BinOp(left=left, op=ast.Add(), right=right):
            left_value = static_string(left)
            right_value = static_string(right)
            if left_value is not None and right_value is not None:
                return left_value + right_value
            return None
        case _:
            return None


def python_candidates(path: PurePosixPath, text: str) -> Iterator[Candidate]:
    try:
        tree = ast.parse(text)
    except SyntaxError as error:
        raise AuditInputError(f"malformed Python at line {error.lineno}: {error.msg}") from error
    fixtures = fixture_nodes(tree) if path == AUDIT_PATH else frozenset()
    child_nodes = {id(child) for node in ast.walk(tree) if isinstance(node, ast.BinOp) for child in (node.left, node.right)}
    for node in ast.walk(tree):
        if not isinstance(node, ast.expr) or id(node) in child_nodes:
            continue
        value = static_string(node)
        if value is None:
            continue
        tokens = direct_install_segment(value)
        if tokens is not None:
            yield Candidate(
                path=path,
                line=node.lineno,
                tokens=tokens,
                fixture_value=id(node) in fixtures,
            )
    try:
        comments = tokenize.generate_tokens(io.StringIO(text).readline)
        for token in comments:
            if token.type != tokenize.COMMENT:
                continue
            tokens = direct_install_segment(token.string.removeprefix("#"))
            if tokens is not None:
                yield Candidate(path=path, line=token.start[0], tokens=tokens)
    except (IndentationError, tokenize.TokenError) as error:
        raise AuditInputError(f"malformed Python token stream: {error}") from error


def candidates_for(path: PurePosixPath, text: str) -> tuple[Candidate, ...]:
    if path.name == "Makefile" or path.suffix in SHELL_SUFFIXES:
        return tuple(shell_candidates(path, text))
    if path.suffix in MARKDOWN_SUFFIXES:
        return tuple(markdown_candidates(path, text))
    if path.suffix == ".json":
        return tuple(json_candidates(path, text))
    if path.suffix == ".py":
        return tuple(python_candidates(path, text))
    candidates: list[Candidate] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        tokens = direct_install_segment(line)
        if tokens is not None:
            candidates.append(Candidate(path=path, line=line_number, tokens=tokens))
    return tuple(candidates)


def is_internal_release(candidate: Candidate) -> bool:
    if candidate.path not in RELEASE_PATHS:
        return False
    tokens = candidate.tokens
    if candidate.function == "install_release_prerequisite":
        return not candidate.controls and tokens == ("spack", "-C", "${scope_dir}", "install", "$@", "${spec}")
    if candidate.function == "cmd_build":
        return not candidate.controls and tokens == (
            "spack", "-e", "${ENV_PATH}", "-C", "${scope_dir}", "install",
            "--only-concrete", "${install_args[@]}",
        )
    if candidate.function != "install_cuda_libfabric_specs":
        return False
    accepted = {
        (
            "spack", "-e", "${ENV_PATH}", "-C", "${BUILD_SCOPE_DIR}", "install",
            "--only-concrete", "${install_args_ref[@]}", "--only", "dependencies", "${spec_hash}",
        ),
        (
            "spack", "-e", "${ENV_PATH}", "-C", "${BUILD_SCOPE_DIR}", "install",
            "--only-concrete", "--dirty", "${install_args_ref[@]}", "--only", "package", "${spec_hash}",
        ),
    }
    return candidate.controls == ("for",) and tokens in accepted


def audit_documents(documents: Mapping[PurePosixPath, str]) -> AuditResult:
    violations: list[Candidate] = []
    internal_release = 0
    negative_policy = 0
    self_fixtures = 0
    for path, text in documents.items():
        try:
            candidates = candidates_for(path, text)
        except AuditInputError as error:
            raise AuditInputError(f"{path}: {error}") from error
        for candidate in candidates:
            if is_internal_release(candidate):
                internal_release += 1
            elif candidate.path in POLICY_PATHS and candidate.negative_policy:
                negative_policy += 1
            elif candidate.path == AUDIT_PATH and candidate.fixture_value:
                self_fixtures += 1
            else:
                violations.append(candidate)
    return AuditResult(tuple(violations), internal_release, negative_policy, self_fixtures)


def _selected(repository: Path) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repository), "ls-files", "-z"],
        check=True,
        capture_output=True,
    ).stdout


def _prepare(root: Path, name: str, contents: Mapping[PurePosixPath, bytes]) -> RepositoryFixture:
    repository = root / name
    repository.mkdir()
    subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
    for fixture_path, fixture_payload in contents.items():
        absolute_fixture = repository / fixture_path
        absolute_fixture.parent.mkdir(parents=True, exist_ok=True)
        absolute_fixture.write_bytes(fixture_payload)
    subprocess.run(["git", "-C", str(repository), "add", "--all"], check=True)
    return RepositoryFixture(repository, _selected(repository))


def _audit_child(scanner: Path, fixture: RepositoryFixture) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(scanner), "--file-list", "-", str(fixture.root)],
        check=False,
        input=fixture.selected,
        capture_output=True,
        env=os.environ | {"PYTHONDONTWRITEBYTECODE": "1"},
    )


def run_input_self_test(scanner: Path, rogue_payload: bytes) -> InputSelfTestResult:  # noqa: SIZE_OK
    failures: list[str] = []
    messages: list[str] = []
    valid = b"README.md\0envs/vlad/release.sh\0"
    if parse_file_list(valid) != (PurePosixPath("README.md"), PurePosixPath("envs/vlad/release.sh")):
        failures.append("valid NUL file list changed")
    else:
        messages.append("SELF-TEST accepted file-list-nul")
    invalid_lists = {
        "file-list-termination": b"README.md\n",
        "file-list-duplicate": b"README.md\0README.md\0",
        "file-list-alias": b"./README.md\0",
        "file-list-trailing-slash": b"README.md/\0",
        "file-list-double-slash": b"docs//README.md\0",
        "file-list-backslash": b".\\README.md\0",
        "file-list-drive-alias": b"C:/README.md\0",
        "file-list-absolute": b"/README.md\0",
        "file-list-parent": b"../README.md\0",
    }
    for name, payload in invalid_lists.items():
        try:
            parse_file_list(payload)
        except AuditInputError:
            messages.append(f"SELF-TEST rejected {name}")
        else:
            failures.append(f"invalid file list accepted: {name}")
    invalid_indexes = {
        "index-path-alias": b"100644 0000000000000000000000000000000000000000 0\t./README.md\0",
    }
    for name, payload in invalid_indexes.items():
        try:
            parse_stage_zero_index(payload)
        except AuditInputError:
            messages.append(f"SELF-TEST rejected {name}")
        else:
            failures.append(f"invalid stage-0 index accepted: {name}")

    with TemporaryDirectory(prefix="chapar-direct-install-") as temporary:
        root = Path(temporary)
        exact = _prepare(root, "exact", {PurePosixPath("tracked.sh"): b"safe\n"})
        if _audit_child(scanner, exact).returncode == 0:
            messages.append("SELF-TEST accepted repository-exact-universe")
        else:
            failures.append("exact stage-0 repository universe was rejected")

        binary_source = scanner.parents[2] / BINARY_PATH
        classified = _prepare(
            root,
            "classified",
            {
                BINARY_PATH: binary_source.read_bytes(),
                PurePosixPath("agents/skills/fixture.txt"): b"safe\n",
                PurePosixPath("validation/analyze/fixture.txt"): b"safe\n",
            },
        )
        (classified.root / ".claude").mkdir()
        (classified.root / ".claude/skills").symlink_to("../agents/skills")
        (classified.root / "validation/vlad").mkdir(parents=True)
        (classified.root / "validation/vlad/analyze").symlink_to("../analyze")
        subprocess.run(
            ["git", "-C", str(classified.root), "add", ".claude/skills", "validation/vlad/analyze"],
            check=True,
        )
        classified = RepositoryFixture(classified.root, _selected(classified.root))
        classified_process = _audit_child(scanner, classified)
        if (
            classified_process.returncode == 0
            and b"INPUT_CLASSES regular=2 symlinks=2 binaries=1" in classified_process.stdout
        ):
            messages.append("SELF-TEST accepted repository-classified-inputs")
        else:
            failures.append("exact classified repository inputs were rejected or miscounted")

        universe = _prepare(
            root,
            "universe",
            {PurePosixPath("one.sh"): b"safe\n", PurePosixPath("two.sh"): b"safe\n"},
        )
        rejected: list[RejectedRepository] = [
            RejectedRepository("repository-universe-missing", RepositoryFixture(universe.root, b"one.sh\0"), 2, "--file-list does not exactly match the tracked Git universe"),
            RejectedRepository("repository-universe-added", RepositoryFixture(universe.root, universe.selected + b"untracked.sh\0"), 2, "--file-list does not exactly match the tracked Git universe"),
            RejectedRepository("repository-universe-order", RepositoryFixture(universe.root, b"two.sh\0one.sh\0"), 2, "--file-list does not exactly match the tracked Git universe"),
            RejectedRepository("repository-universe-alias", RepositoryFixture(universe.root, b"./one.sh\0two.sh\0"), 2, "invalid tracked path: ./one.sh"),
            RejectedRepository("repository-universe-trailing-alias", RepositoryFixture(universe.root, b"one.sh/\0two.sh\0"), 2, "invalid tracked path: one.sh/"),
            RejectedRepository("repository-universe-backslash-alias", RepositoryFixture(universe.root, b".\\one.sh\0two.sh\0"), 2, "invalid tracked path: .\\one.sh"),
            RejectedRepository("repository-universe-duplicate", RepositoryFixture(universe.root, b"one.sh\0one.sh\0two.sh\0"), 2, "file list contains duplicate paths"),
            RejectedRepository("repository-file-list-non-utf8", RepositoryFixture(universe.root, b"\xff\0"), 2, "file list contains a non-UTF-8 path"),
        ]

        missing = _prepare(root, "missing", {PurePosixPath("tracked.sh"): b"safe\n"})
        (missing.root / "tracked.sh").unlink()
        directory = _prepare(root, "directory", {PurePosixPath("tracked.sh"): b"safe\n"})
        (directory.root / "tracked.sh").unlink()
        (directory.root / "tracked.sh").mkdir()
        unreadable = _prepare(root, "unreadable", {PurePosixPath("tracked.sh"): b"safe\n"})
        (unreadable.root / "tracked.sh").chmod(0)
        mode = _prepare(root, "mode", {PurePosixPath("tracked.sh"): b"safe\n"})
        (mode.root / "tracked.sh").chmod(0o755)
        intermediate = _prepare(
            root,
            "intermediate",
            {PurePosixPath("nested/tracked.sh"): b"indexed\n"},
        )
        external_directory = root / "intermediate-external"
        external_directory.mkdir()
        (external_directory / "tracked.sh").write_bytes(b"external\n")
        (intermediate.root / "nested").rename(root / "intermediate-indexed")
        (intermediate.root / "nested").symlink_to("../intermediate-external")
        rejected.extend(
            (
                RejectedRepository("repository-missing-path", missing, 2, "selected path is unavailable: tracked.sh"),
                RejectedRepository("repository-directory-drift", directory, 2, "selected path is not a regular file: tracked.sh"),
                RejectedRepository("repository-unreadable-path", unreadable, 2, "selected path is unreadable: tracked.sh"),
                RejectedRepository("repository-mode-drift", mode, 2, "regular selected path mode drift: tracked.sh"),
                RejectedRepository(
                    "repository-intermediate-symlink",
                    intermediate,
                    2,
                    "selected path has symlinked intermediate component: nested/tracked.sh",
                ),
                RejectedRepository("repository-nul-content", _prepare(root, "nul", {PurePosixPath("tracked.sh"): b"safe\0hidden\n"}), 2, "unexpected NUL content in selected text path: tracked.sh"),
                RejectedRepository("repository-non-utf8-content", _prepare(root, "non-utf8", {PurePosixPath("tracked.sh"): b"\xffhidden\n"}), 2, "selected text path is not UTF-8: tracked.sh"),
                RejectedRepository("repository-ascii-binary", _prepare(root, "binary", {PurePosixPath("artifact.pdf"): b"%PDF-1.7\nASCII\n%%EOF\n"}), 2, "selected path is an unclassified binary: artifact.pdf"),
                RejectedRepository("repository-binary-digest-drift", _prepare(root, "digest", {BINARY_PATH: b"%PDF-1.7\nchanged\n%%EOF\n"}), 2, "classified binary digest changed: docs/presentation.pdf"),
                RejectedRepository("repository-direct-install-bypass", _prepare(root, "bypass", {PurePosixPath("rogue.toml"): rogue_payload + b"\n"}), 1, "rogue.toml:1: unsupported direct install:"),
            )
        )

        unclassified = _prepare(root, "unclassified", {PurePosixPath("target.sh"): b"safe\n"})
        (unclassified.root / "rogue-link").symlink_to("target.sh")
        subprocess.run(["git", "-C", str(unclassified.root), "add", "rogue-link"], check=True)
        rejected.append(
            RejectedRepository(
                "repository-unclassified-symlink",
                RepositoryFixture(unclassified.root, _selected(unclassified.root)),
                2,
                "selected path is an unclassified symlink: rogue-link",
            )
        )

        def classified_symlink(name: str, target: str) -> RepositoryFixture:
            fixture = _prepare(root, name, {})
            (fixture.root / ".claude").mkdir()
            (fixture.root / ".claude/skills").symlink_to(target)
            subprocess.run(["git", "-C", str(fixture.root), "add", ".claude/skills"], check=True)
            return RepositoryFixture(fixture.root, _selected(fixture.root))

        wrong_target = classified_symlink("wrong-target", "../agents/other")
        (wrong_target.root / "agents/other").mkdir(parents=True)
        target_type = _prepare(root, "target-type", {PurePosixPath("agents/skills"): b"file\n"})
        (target_type.root / ".claude").mkdir()
        (target_type.root / ".claude/skills").symlink_to("../agents/skills")
        subprocess.run(["git", "-C", str(target_type.root), "add", ".claude/skills"], check=True)
        target_type = RepositoryFixture(target_type.root, _selected(target_type.root))
        changed_type = _prepare(root, "changed-type", {PurePosixPath("agents/skills/fixture"): b"safe\n"})
        (changed_type.root / ".claude").mkdir()
        changed_link = changed_type.root / ".claude/skills"
        changed_link.symlink_to("../agents/skills")
        subprocess.run(["git", "-C", str(changed_type.root), "add", ".claude/skills"], check=True)
        changed_type = RepositoryFixture(changed_type.root, _selected(changed_type.root))
        changed_link.unlink()
        changed_link.write_text("../agents/skills", encoding="utf-8")
        escape = classified_symlink("escape", "../agents/skills")
        (escape.root / "agents").mkdir()
        (escape.root / "agents/skills").symlink_to(root)
        missing_target = classified_symlink("missing-target", "../agents/skills")
        wrong_mode = _prepare(root, "wrong-mode", {PurePosixPath("agents/skills/fixture"): b"safe\n"})
        (wrong_mode.root / ".claude").mkdir()
        (wrong_mode.root / ".claude/skills").symlink_to("../agents/skills")
        blob = subprocess.run(
            ["git", "-C", str(wrong_mode.root), "hash-object", "-w", "--stdin"],
            check=True,
            input=b"../agents/skills",
            capture_output=True,
        ).stdout.decode("ascii").strip()
        subprocess.run(
            [
                "git",
                "-C",
                str(wrong_mode.root),
                "update-index",
                "--add",
                "--cacheinfo",
                f"100644,{blob},.claude/skills",
            ],
            check=True,
        )
        wrong_mode = RepositoryFixture(wrong_mode.root, _selected(wrong_mode.root))
        rejected.extend(
            (
                RejectedRepository("repository-classified-symlink-target-drift", wrong_target, 2, "classified symlink target changed: .claude/skills"),
                RejectedRepository("repository-classified-symlink-target-type", target_type, 2, "classified symlink target changed file type: .claude/skills"),
                RejectedRepository("repository-classified-symlink-type-drift", changed_type, 2, "classified symlink changed file type: .claude/skills"),
                RejectedRepository("repository-classified-symlink-mode-drift", wrong_mode, 2, "classified symlink has wrong Git mode: .claude/skills"),
                RejectedRepository("repository-classified-symlink-escape", escape, 2, "classified symlink target escapes repository: .claude/skills"),
                RejectedRepository("repository-classified-symlink-missing-target", missing_target, 2, "classified symlink target is missing: .claude/skills"),
            )
        )

        unmerged = _prepare(root, "unmerged", {})
        object_ids = tuple(
            subprocess.run(
                ["git", "-C", str(unmerged.root), "hash-object", "-w", "--stdin"],
                check=True,
                input=payload,
                capture_output=True,
            ).stdout.decode("ascii").strip()
            for payload in (b"base\n", b"ours\n", b"theirs\n")
        )
        subprocess.run(
            ["git", "-C", str(unmerged.root), "update-index", "--index-info"],
            check=True,
            input="".join(
                f"100644 {object_id} {stage}\ttracked.sh\n"
                for stage, object_id in enumerate(object_ids, 1)
            ).encode(),
        )
        rejected.append(
            RejectedRepository(
                "repository-unmerged-index",
                RepositoryFixture(unmerged.root, b""),
                2,
                "tracked path has unresolved index stage",
            )
        )

        for case in rejected:
            process = _audit_child(scanner, case.fixture)
            stderr = process.stderr.decode("utf-8", errors="replace")
            if process.returncode != case.status or case.reason not in stderr:
                failures.append(
                    f"repository boundary mismatch: {case.name}: "
                    f"status={process.returncode} stderr={stderr.strip()!r}"
                )
            else:
                messages.append(
                    f"SELF-TEST rejected {case.name} "
                    f"status={case.status} reason={case.reason}"
                )
        (unreadable.root / "tracked.sh").chmod(0o600)

    return InputSelfTestResult(
        tuple(failures),
        tuple(messages),
        accepted=3,
        rejected=len(invalid_lists) + len(invalid_indexes) + len(rejected),
    )


def synthetic_python(mapping_name: str, annotation: str, expression: str, *, nested: bool = False) -> str:
    assignment = f"{mapping_name}: {annotation} = {{'case': {expression}}}\n"
    return f"def holder():\n    {assignment}" if nested else assignment


def run_self_test() -> int:
    internal_path = PurePosixPath("envs/vlad/release.sh")
    accepted_cases: tuple[tuple[str, PurePosixPath, str], ...] = (
        ("internal-prerequisite", internal_path, f"install_release_prerequisite() {{\n  {SELF_TEST_FIXTURES['prerequisite']}\n}}\n"),
        ("internal-hpcsim-path", PurePosixPath("envs/hpcsim/release.sh"), f"install_release_prerequisite() {{\n  {SELF_TEST_FIXTURES['prerequisite']}\n}}\n"),
        ("internal-cuda-dependencies", internal_path, f"install_cuda_libfabric_specs() {{\nfor spec in one; do\n  {SELF_TEST_FIXTURES['cuda-dependencies']}\ndone\n}}\n"),
        ("internal-cuda-package", internal_path, f"install_cuda_libfabric_specs() {{\nfor spec in one; do\n  {SELF_TEST_FIXTURES['cuda-package']}\ndone\n}}\n"),
        ("internal-environment", internal_path, f"cmd_build() {{\n  {SELF_TEST_FIXTURES['environment']}\n}}\n"),
        ("policy-never", PurePosixPath("AGENTS.md"), SELF_TEST_FIXTURES["policy-never"]),
        ("policy-do-not", PurePosixPath("agents/skills/chapar-release-helper/SKILL.md"), SELF_TEST_FIXTURES["policy-do-not"]),
        ("policy-forbidden", PurePosixPath("agents/skills/chapar-spack-env-change/SKILL.md"), SELF_TEST_FIXTURES["policy-forbidden"]),
        ("policy-must-not", PurePosixPath("docs/ci-github-actions.md"), SELF_TEST_FIXTURES["policy-must-not"]),
        ("policy-multiline", PurePosixPath("docs/ci-github-actions.md"), "Operators must not\n  `spack install example` directly.\n"),
        ("fixture-ast", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", repr(SELF_TEST_FIXTURES["rogue"]))),
        ("shell-comment", PurePosixPath("rogue.sh"), f"# {SELF_TEST_FIXTURES['rogue']}\n"),
        ("backtick-escaped", PurePosixPath("rogue.sh"), "echo \\`spack install inert\\`\n"),
        ("backtick-escaped-quoted", PurePosixPath("rogue.sh"), 'echo "\\`spack install inert\\`"\n'),
        ("backtick-single-quoted", PurePosixPath("rogue.sh"), "printf '%s' '`spack install inert`'\n"),
        ("backtick-heredoc", PurePosixPath("rogue.sh"), "cat <<'DATA'\n`spack install inert`\nDATA\n"),
    )
    rogue = SELF_TEST_FIXTURES["rogue"]
    rejected_cases: tuple[tuple[str, PurePosixPath, str], ...] = (
        ("internal-path", PurePosixPath("envs/other/release.sh"), accepted_cases[0][2]),
        ("internal-function", internal_path, accepted_cases[0][2].replace("install_release_prerequisite", "other_function")),
        ("internal-token", internal_path, accepted_cases[0][2].replace("${scope_dir}", "${other_scope}")),
        ("internal-argv-order", internal_path, accepted_cases[3][2].replace('--dirty "${install_args_ref[@]}"', '"${install_args_ref[@]}" --dirty')),
        ("internal-argv-extra", internal_path, accepted_cases[4][2].replace("--only-concrete", "--only-concrete --reuse")),
        ("policy-path", PurePosixPath("README.md"), SELF_TEST_FIXTURES["policy-never"]),
        ("policy-token", PurePosixPath("AGENTS.md"), "- " + SELF_TEST_FIXTURES["policy-never"].replace("NEVER", "Avoid")),
        ("fixture-file", PurePosixPath("ci/tests/other.py"), accepted_cases[10][2]),
        ("fixture-name", AUDIT_PATH, synthetic_python("OTHER_FIXTURES", "dict[str, str]", repr(rogue))),
        ("fixture-annotation", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "Mapping[str, str]", repr(rogue))),
        ("fixture-nested", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", repr(rogue), nested=True)),
        ("fixture-computed", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", f"{repr('spack ')} + {repr('install rogue-package')}")),
        ("fixture-comment", AUDIT_PATH, f"# {rogue}\nSELF_TEST_FIXTURES: dict[str, str] = {{}}\n"),
        ("shell-multiline", PurePosixPath("rogue.sh"), "spack " + chr(92) + "\n  install rogue-package\n"),
        ("shell-env-prefix", PurePosixPath("rogue.sh"), f"env MODE=x {rogue}\n"),
        ("shell-malformed-quote", PurePosixPath("rogue.sh"), rogue.replace("rogue-package", chr(34) + "rogue-package")),
        ("shell-substitution", PurePosixPath("rogue.sh"), f"$({rogue})\n"),
        ("shell-separator", PurePosixPath("rogue.sh"), f"true; {rogue}\n"),
        ("internal-env-prefix", internal_path, accepted_cases[0][2].replace("  spack", "  env MODE=x spack")),
        ("internal-substitution", internal_path, accepted_cases[0][2].replace("  spack", "  $(spack").replace("\n}\n", ")\n}\n")),
        ("internal-separator", internal_path, accepted_cases[0][2].replace("  spack", "  true; spack")),
        ("markdown-multiline", PurePosixPath("README.md"), "```bash\nspack " + chr(92) + "\n install rogue-package\n```\n"),
        ("python-malformed", PurePosixPath("rogue.py"), "command = " + chr(34) + rogue + "\n"),
        ("json-malformed", PurePosixPath("rogue.json"), "{" + chr(34) + "command" + chr(34) + ": " + chr(34) + rogue),
        ("string-newline-separator", PurePosixPath("rogue.py"), f"command = {repr('echo ok' + chr(10) + rogue)}\n"),
        *((f"wrapper-{name}", PurePosixPath("rogue.sh"), f"{prefix} {rogue}\n") for name, prefix in (("sudo", "sudo"), ("sudo-option", "sudo -u root"), ("command", "command"), ("command-option", "command --"), ("nice", "nice"), ("nice-option", "nice -n 10"), ("timeout", "timeout 60"), ("timeout-option", "timeout --signal KILL 60"), ("nohup", "nohup"), ("nohup-option", "nohup --"), ("env-i", "env -i"), ("env-i-option", "env -i MODE=x"), ("env-ignore", "env --ignore-environment"), ("env-ignore-option", "env --ignore-environment MODE=x"))),
        *((f"control-{name}", internal_path, f"install_release_prerequisite() {{\n{body}\n}}\n") for name, body in (("if", f"if true; then\n {SELF_TEST_FIXTURES['prerequisite']}\nfi"), ("for", f"for item in one; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("while", f"while true; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("until", f"until false; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("case", f"case x in x)\n {SELF_TEST_FIXTURES['prerequisite']}\n;; esac"), ("select", f"select item in one; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("group", f"{{\n {SELF_TEST_FIXTURES['prerequisite']}\n}}"), ("subshell", f"(\n {SELF_TEST_FIXTURES['prerequisite']}\n)"), ("substitution-multiline", f"value=\"$(\n {SELF_TEST_FIXTURES['prerequisite']}\n)\""))),
        *((f"separator-{name}", PurePosixPath("rogue.sh"), f"{prefix} {rogue}\n") for name, prefix in (("and", "true &&"), ("or", "false ||"), ("pipe", "printf x |"))),
        ("internal-cuda-extra-control", internal_path, accepted_cases[2][2].replace("for spec in one; do", "for spec in one; do\nif true; then").replace("done\n}", "fi\ndone\n}")),
        ("policy-multiline-path", PurePosixPath("README.md"), "Operators must not\n `spack install example` directly.\n"),
        ("policy-multiline-token", PurePosixPath("AGENTS.md"), "- Operators should avoid\n `spack install example` directly.\n"),
        ("policy-mixed-positive", PurePosixPath("AGENTS.md"), "NEVER run `spack install blocked`; the positive example is `spack install allowed`.\n"),
        ("policy-fence", PurePosixPath("AGENTS.md"), f"```bash\n# NEVER\n{rogue}\n```\n"),
        ("payload-bash-clustered", PurePosixPath("rogue.sh"), f"bash -xc {repr(rogue)}\n"),
        ("payload-bash-prefixed-clustered", PurePosixPath("rogue.sh"), f"bash --noprofile -xc {repr(rogue)}\n"),
        ("payload-sh-clustered", PurePosixPath("rogue.sh"), f"sh -ec {repr(rogue)}\n"),
        ("payload-env-s", PurePosixPath("rogue.sh"), f"env -S {repr(rogue)}\n"),
        ("payload-env-s-clustered", PurePosixPath("rogue.sh"), f"env -S{repr(rogue)}\n"),
        ("payload-env-s-long", PurePosixPath("rogue.sh"), f"env --split-string={repr(rogue)}\n"),
        ("payload-env-s-long-separate", PurePosixPath("rogue.sh"), f"env --split-string {repr(rogue)}\n"),
        ("substitution-quoted", PurePosixPath("rogue.sh"), f'echo "$({rogue})"\n'),
        ("substitution-inline-approved", internal_path, accepted_cases[0][2].replace("  spack", '  value="$(printf x; spack').replace("\n}\n", ')"\n}\n')),
        ("substitution-prefixed-multiline", internal_path, accepted_cases[0][2].replace("  spack", '  value="$(printf x;\n  spack').replace("\n}\n", '\n)"\n}\n')),
        ("substitution-unquoted-multiline", internal_path, accepted_cases[0][2].replace("  spack", "  value=$(printf x;\n  spack").replace("\n}\n", "\n)\n}\n")),
        ("fence-info-string", PurePosixPath("AGENTS.md"), f"```bash title=blocked\n{rogue}\n```\n"),
        ("fence-tilde", PurePosixPath("AGENTS.md"), f"~~~bash\n{rogue}\n~~~\n"),
        ("fence-four-backticks", PurePosixPath("AGENTS.md"), f"````bash\n{rogue}\n````\n"),
        ("fence-unterminated", PurePosixPath("AGENTS.md"), f"```bash\n{rogue}\n"),
        ("policy-positive-sentence", PurePosixPath("AGENTS.md"), "NEVER run blocked. Run `spack install allowed` for setup.\n"),
        ("policy-positive-only", PurePosixPath("AGENTS.md"), "Run `spack install allowed` for setup.\n"),
        ("backtick-beginning", PurePosixPath("rogue.sh"), f"`{rogue}`\n"),
        ("backtick-middle", PurePosixPath("rogue.sh"), f"echo before `{rogue}` after\n"),
        ("backtick-double-quoted", PurePosixPath("rogue.sh"), f'echo "`{rogue}`"\n'),
        ("backtick-internal", internal_path, f"install_release_prerequisite() {{\n  value=`{SELF_TEST_FIXTURES['prerequisite']}`\n}}\n"),
        ("backtick-shell-payload", PurePosixPath("rogue.sh"), f"bash -c {repr(f'echo `{rogue}`')}\n"),
        ("backtick-internal-multiline", internal_path, f"install_release_prerequisite() {{\n  value=`printf x\n  {SELF_TEST_FIXTURES['prerequisite']}\n  `\n}}\n"),
        ("backtick-unterminated", PurePosixPath("rogue.sh"), f"echo `{rogue}\n"),
    )
    failures: list[str] = []
    input_error_cases = frozenset({"shell-malformed-quote", "python-malformed", "json-malformed", "backtick-unterminated"})
    own_source = Path(__file__).read_text(encoding="utf-8")
    own_result = audit_documents({AUDIT_PATH: own_source})
    expected_fixture_candidates = sum(
        direct_install_segment(value) is not None for value in SELF_TEST_FIXTURES.values()
    )
    if own_result.violations or own_result.self_fixtures != expected_fixture_candidates:
        failures.append("annotated module-level fixture mapping was not bounded exactly")
    print(f"SELF-TEST accepted fixture-source-span count={own_result.self_fixtures}")
    for name, path, text in accepted_cases:
        result = audit_documents({path: text})
        if result.violations:
            failures.append(f"accepted case rejected: {name}")
        if name == "policy-multiline" and result.negative_policy != 1:
            failures.append("accepted multiline policy was not classified")
        print(f"SELF-TEST accepted {name}")
    for name, path, text in rejected_cases:
        try:
            result = audit_documents({path: text})
        except AuditInputError:
            result = None
        if name in input_error_cases:
            if result is not None:
                failures.append(f"malformed case did not fail input parsing: {name}")
        elif result is None:
            failures.append(f"valid rogue case failed input parsing: {name}")
        elif not result.violations:
            failures.append(f"rogue case accepted: {name}")
        print(f"SELF-TEST rejected {name}")
    input_result = run_input_self_test(Path(__file__).resolve(), rogue.encode("utf-8"))
    failures.extend(input_result.failures)
    for message in input_result.messages:
        print(message)
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1
    accepted_count = len(accepted_cases) + 1 + input_result.accepted
    rejected_count = len(rejected_cases) + input_result.rejected
    print(f"SELF-TEST PASS: accepted={accepted_count} rejected={rejected_count}")
    return 0


def audit_repository(root: Path, file_list: str | None) -> int:
    process = subprocess.run(["git", "-C", str(root), "ls-files", "--stage", "-z"], check=False, capture_output=True)
    if process.returncode != 0:
        reason = process.stderr.decode("utf-8", errors="replace").strip()
        raise AuditInputError(f"git ls-files failed: {reason}")
    expected, index_modes, expected_payload = parse_stage_zero_index(process.stdout)
    if file_list is None:
        selected = expected
    else:
        payload = sys.stdin.buffer.read() if file_list == "-" else Path(file_list).read_bytes()
        selected_names = parse_file_names(payload)
        if payload != expected_payload:
            raise AuditInputError("--file-list does not exactly match the tracked Git universe")
        selected = tuple(PurePosixPath(name) for name in selected_names)
    loaded = load_documents(root, selected, index_modes)
    result = audit_documents(loaded.documents)
    digest = hashlib.sha256(b"".join(f"{path}\0".encode() for path in selected)).hexdigest()
    print(f"TRACKED_UNIVERSE count={len(selected)} sha256={digest}")
    print(
        "INPUT_CLASSES "
        f"regular={loaded.regular_files} "
        f"symlinks={loaded.symlinks} "
        f"binaries={loaded.binaries}"
    )
    print(
        "EXCEPTIONS "
        f"internal-release={result.internal_release} "
        f"negative-policy={result.negative_policy} "
        f"self-test-fixtures={result.self_fixtures}"
    )
    if result.violations:
        for violation in result.violations:
            command = " ".join(violation.tokens)
            print(f"ERROR: {violation.path}:{violation.line}: unsupported direct install: {command}", file=sys.stderr)
        return 1
    print("PASS: no unsupported direct-install surfaces")
    return 0


def parse_cli(arguments: Sequence[str]) -> CliArguments:
    root = "."
    file_list: str | None = None
    self_test = False
    position = 0
    while position < len(arguments):
        argument = arguments[position]
        match argument:  # noqa: MATCH_OK - the final capture handles every remaining string.
            case "--self-test":
                self_test = True
            case "--file-list":
                next_position = position + 1
                if next_position < len(arguments) and not arguments[next_position].startswith("--"):
                    file_list = arguments[next_position]
                    position = next_position
                else:
                    file_list = "-"
            case value if value.startswith("--"):
                raise AuditInputError(f"unknown option: {value}")
            case value if root == ".":
                root = value
            case value:
                raise AuditInputError(f"unexpected argument: {value}")
        position += 1
    return CliArguments(root=root, file_list=file_list, self_test=self_test)


def main() -> int:
    try:
        arguments = parse_cli(sys.argv[1:])
        if arguments.self_test:
            return run_self_test()
        return audit_repository(Path(arguments.root).resolve(), arguments.file_list)
    except (AuditInputError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
