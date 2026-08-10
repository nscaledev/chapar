from __future__ import annotations

import hashlib
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path, PurePosixPath

from .documents import candidates_for
from .model import (
    AUDIT_PATH,
    MALFORMED_FIXTURE_PATHS,
    POLICY_PATHS,
    RELEASE_PATHS,
    AuditInputError,
    AuditResult,
    Candidate,
    CliArguments,
)


def is_internal_release(candidate: Candidate) -> bool:
    if candidate.path not in RELEASE_PATHS:
        return False
    tokens = candidate.tokens
    if candidate.function == "bootstrap_install":
        return candidate.controls == ("if",) and tokens == ("spack", "-C", "${BUILD_SCOPE_DIR}", "install", "$@")
    if candidate.function == "install_staged_roots":
        return candidate.controls == ("for",) and tokens == (
            "spack", "-e", "${RELEASE_STAGING}", "-C", "${BUILD_SCOPE_DIR}", "install", "--only-concrete", "/${hash}",
        )
    if candidate.function == "cmd_build":
        return not candidate.controls and tokens == (
            "spack", "-e", "${RELEASE_STAGING}", "-C", "${BUILD_SCOPE_DIR}", "install", "--only-concrete",
        )
    return False


def audit_documents(documents: Mapping[PurePosixPath, str]) -> AuditResult:
    violations: list[Candidate] = []
    internal_release = negative_policy = self_fixtures = 0
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


def parse_file_list(payload: bytes) -> tuple[PurePosixPath, ...]:
    if payload and not payload.endswith(b"\0"):
        raise AuditInputError("file list must be NUL terminated")
    entries = payload.removesuffix(b"\0").split(b"\0") if payload else []
    paths: list[PurePosixPath] = []
    for entry in entries:
        try:
            text = entry.decode("utf-8")
        except UnicodeDecodeError as error:
            raise AuditInputError("file list contains a non-UTF-8 path") from error
        path = PurePosixPath(text)
        if path.is_absolute() or ".." in path.parts or text in {"", "."}:
            raise AuditInputError(f"invalid tracked path: {text}")
        paths.append(path)
    if len(paths) != len(set(paths)):
        raise AuditInputError("file list contains duplicate paths")
    return tuple(paths)


def load_documents(root: Path, paths: Iterable[PurePosixPath]) -> dict[PurePosixPath, str]:
    documents: dict[PurePosixPath, str] = {}
    for path in paths:
        if path in MALFORMED_FIXTURE_PATHS:
            continue
        absolute_path = root / path
        if not absolute_path.is_file():
            continue
        payload = absolute_path.read_bytes()
        if b"\0" in payload:
            continue
        try:
            documents[path] = payload.decode("utf-8")
        except UnicodeDecodeError:
            continue
    return documents


def audit_repository(root: Path, file_list: str | None) -> int:
    process = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=False, capture_output=True)
    if process.returncode != 0:
        reason = process.stderr.decode("utf-8", errors="replace").strip()
        raise AuditInputError(f"git ls-files failed: {reason}")
    expected = parse_file_list(process.stdout)
    if file_list is None:
        selected = expected
    else:
        payload = sys.stdin.buffer.read() if file_list == "-" else Path(file_list).read_bytes()
        selected = parse_file_list(payload)
        if selected != expected:
            raise AuditInputError("--file-list does not exactly match the tracked Git universe")
    result = audit_documents(load_documents(root, selected))
    digest = hashlib.sha256(b"".join(f"{path}\0".encode() for path in selected)).hexdigest()
    print(f"TRACKED_UNIVERSE count={len(selected)} sha256={digest}")
    print(f"EXCEPTIONS internal-release={result.internal_release} negative-policy={result.negative_policy} self-test-fixtures={result.self_fixtures}")
    if result.violations:
        for violation in result.violations:
            print(f"ERROR: {violation.path}:{violation.line}: unsupported direct install: {' '.join(violation.tokens)}", file=sys.stderr)
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
