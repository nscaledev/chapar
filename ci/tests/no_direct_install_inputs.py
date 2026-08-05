"""Fail-closed parsing and loading for the tracked scanner input universe."""

from __future__ import annotations

import hashlib
import os
import stat
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final


BINARY_PATH: Final = PurePosixPath("docs/presentation.pdf")
BINARY_SHA256: Final = "87957322337491eae10c545c43e594941524c8a18d0412f8549c02bb7f053e16"
BINARY_SUFFIXES: Final = frozenset(
    {".7z", ".bin", ".bz2", ".elf", ".gif", ".gz", ".jpeg", ".jpg", ".pdf", ".png", ".sqsh", ".xz", ".zip"}
)
BINARY_MAGIC_PREFIXES: Final = (
    b"%PDF-",
    b"\x7fELF",
    b"\x89PNG\r\n\x1a\n",
    b"GIF87a",
    b"GIF89a",
    b"PK\x03\x04",
    b"\x1f\x8b",
)
CLASSIFIED_SYMLINKS: Final = (
    (PurePosixPath(".claude/skills"), "../agents/skills"),
    (PurePosixPath("validation/vlad/analyze"), "../analyze"),
)
GIT_SYMLINK_MODE: Final = "120000"
GIT_REGULAR_MODES: Final = frozenset({"100644", "100755"})


@dataclass(frozen=True, slots=True)
class LoadedInputs:
    documents: Mapping[PurePosixPath, str]
    regular_files: int
    symlinks: int
    binaries: int


class AuditInputError(Exception):
    """The tracked input universe or one selected path failed closed."""


def parse_file_names(payload: bytes) -> tuple[str, ...]:
    if payload and not payload.endswith(b"\0"):
        raise AuditInputError("file list must be NUL terminated")
    entries = payload.removesuffix(b"\0").split(b"\0") if payload else []
    names: list[str] = []
    for entry in entries:
        try:
            text = entry.decode("utf-8")
        except UnicodeDecodeError as error:
            raise AuditInputError("file list contains a non-UTF-8 path") from error
        components = text.split("/")
        drive_alias = len(text) >= 2 and text[0].isalpha() and text[1] == ":"
        if "\\" in text or drive_alias or any(component in {"", ".", ".."} for component in components):
            raise AuditInputError(f"invalid tracked path: {text}")
        names.append(text)
    if len(names) != len(set(names)):
        raise AuditInputError("file list contains duplicate paths")
    return tuple(names)


def parse_file_list(payload: bytes) -> tuple[PurePosixPath, ...]:
    return tuple(PurePosixPath(name) for name in parse_file_names(payload))


def parse_stage_zero_index(
    payload: bytes,
) -> tuple[tuple[PurePosixPath, ...], Mapping[PurePosixPath, str], bytes]:
    modes: dict[PurePosixPath, str] = {}
    entries: list[bytes] = []
    for entry in payload.removesuffix(b"\0").split(b"\0") if payload else ():
        try:
            metadata, raw_path = entry.split(b"\t", 1)
            mode, _object_id, stage = metadata.decode("ascii").split()
        except (UnicodeDecodeError, ValueError) as error:
            raise AuditInputError("git ls-files --stage returned malformed metadata") from error
        if stage != "0":
            raise AuditInputError(f"tracked path has unresolved index stage: {raw_path!r}: {stage}")
        path = parse_file_list(raw_path + b"\0")[0]
        modes[path] = mode
        entries.append(raw_path)
    raw_file_list = b"\0".join(entries) + (b"\0" if entries else b"")
    paths = parse_file_list(raw_file_list)
    return paths, modes, raw_file_list


def load_documents(
    root: Path,
    paths: Iterable[PurePosixPath],
    index_modes: Mapping[PurePosixPath, str] | None = None,
) -> LoadedInputs:
    documents: dict[PurePosixPath, str] = {}
    repository_root = root.resolve()
    symlink_count = 0
    binary_count = 0
    try:
        repository_descriptor = os.open(repository_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise AuditInputError(f"repository root is unavailable: {error.strerror}") from error
    try:
        for path in paths:
            absolute_path = root / path
            parent_descriptor = os.dup(repository_descriptor)
            try:
                for component in path.parts[:-1]:
                    try:
                        component_metadata = os.stat(component, dir_fd=parent_descriptor, follow_symlinks=False)
                    except OSError as error:
                        raise AuditInputError(
                            f"selected path has unavailable intermediate component: {path}: {component}"
                        ) from error
                    if stat.S_ISLNK(component_metadata.st_mode):
                        raise AuditInputError(f"selected path has symlinked intermediate component: {path}")
                    if not stat.S_ISDIR(component_metadata.st_mode):
                        raise AuditInputError(f"selected path has non-directory intermediate component: {path}")
                    try:
                        child_descriptor = os.open(
                            component,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent_descriptor,
                        )
                    except OSError as error:
                        raise AuditInputError(f"selected path intermediate identity drift: {path}") from error
                    child_metadata = os.fstat(child_descriptor)
                    if not os.path.samestat(component_metadata, child_metadata):
                        os.close(child_descriptor)
                        raise AuditInputError(f"selected path intermediate identity drift: {path}")
                    os.close(parent_descriptor)
                    parent_descriptor = child_descriptor
                leaf = path.name
                try:
                    metadata = os.stat(leaf, dir_fd=parent_descriptor, follow_symlinks=False)
                except OSError as error:
                    raise AuditInputError(f"selected path is unavailable: {path}: {error.strerror}") from error
                expected_target = next((target for classified_path, target in CLASSIFIED_SYMLINKS if classified_path == path), None)
                index_mode = index_modes.get(path) if index_modes is not None else None
                if expected_target is not None:
                    if index_mode is not None and index_mode != GIT_SYMLINK_MODE:
                        raise AuditInputError(f"classified symlink has wrong Git mode: {path}: {index_mode}")
                    if not stat.S_ISLNK(metadata.st_mode):
                        raise AuditInputError(f"classified symlink changed file type: {path}")
                    try:
                        target = os.readlink(leaf, dir_fd=parent_descriptor)
                    except OSError as error:
                        raise AuditInputError(f"classified symlink is unreadable: {path}: {error.strerror}") from error
                    target_path = PurePosixPath(target)
                    if target_path.is_absolute():
                        raise AuditInputError(f"classified symlink target is absolute: {path}: {target}")
                    if target_path.as_posix() != target or "//" in target or "/./" in f"/{target}/":
                        raise AuditInputError(f"classified symlink target is not canonical: {path}: {target}")
                    resolved_target = (absolute_path.parent / target).resolve()
                    if not resolved_target.is_relative_to(repository_root):
                        raise AuditInputError(f"classified symlink target escapes repository: {path}: {target}")
                    if target != expected_target:
                        raise AuditInputError(f"classified symlink target changed: {path}: {target}")
                    if not resolved_target.exists():
                        raise AuditInputError(f"classified symlink target is missing: {path}: {target}")
                    if not resolved_target.is_dir():
                        raise AuditInputError(f"classified symlink target changed file type: {path}: {target}")
                    symlink_count += 1
                    continue
                if stat.S_ISLNK(metadata.st_mode):
                    raise AuditInputError(f"selected path is an unclassified symlink: {path}")
                if not stat.S_ISREG(metadata.st_mode):
                    raise AuditInputError(f"selected path is not a regular file: {path}")
                if index_mode is not None and index_mode not in GIT_REGULAR_MODES:
                    raise AuditInputError(f"regular selected path has unexpected Git mode: {path}: {index_mode}")
                try:
                    descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_descriptor)
                    with os.fdopen(descriptor, "rb") as stream:
                        opened_metadata = os.fstat(stream.fileno())
                        if not os.path.samestat(metadata, opened_metadata):
                            raise AuditInputError(f"selected path changed while opening: {path}")
                        if not stat.S_ISREG(opened_metadata.st_mode):
                            raise AuditInputError(f"selected path is not a regular file: {path}")
                        if index_mode is not None:
                            expected_executable = index_mode == "100755"
                            actual_executable = bool(stat.S_IMODE(opened_metadata.st_mode) & 0o111)
                            if actual_executable != expected_executable:
                                raise AuditInputError(
                                    f"regular selected path mode drift: {path}: "
                                    f"Git={index_mode} filesystem={stat.S_IMODE(opened_metadata.st_mode):04o}"
                                )
                        payload = stream.read()
                except OSError as error:
                    raise AuditInputError(f"selected path is unreadable: {path}: {error.strerror}") from error
            finally:
                os.close(parent_descriptor)
            if path == BINARY_PATH:
                digest = hashlib.sha256(payload).hexdigest()
                if digest != BINARY_SHA256:
                    raise AuditInputError(f"classified binary digest changed: {path}: {digest}")
                binary_count += 1
                continue
            if path.suffix.lower() in BINARY_SUFFIXES or payload.startswith(BINARY_MAGIC_PREFIXES):
                raise AuditInputError(f"selected path is an unclassified binary: {path}")
            if b"\0" in payload:
                raise AuditInputError(f"unexpected NUL content in selected text path: {path}")
            try:
                documents[path] = payload.decode("utf-8")
            except UnicodeDecodeError as error:
                raise AuditInputError(f"selected text path is not UTF-8: {path}") from error
    finally:
        os.close(repository_descriptor)
    return LoadedInputs(documents, len(documents), symlink_count, binary_count)
