"""Anonymous, no-clobber publication for validated SQSH images."""

from __future__ import annotations

import errno
import hashlib
import os
import re
import stat
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum, unique
from typing import Callable, Final, Iterator, assert_never


HEX64: Final = re.compile(r"[0-9a-f]{64}")
CHUNK: Final = 1024 * 1024
READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
DIR_FLAGS: Final = READ_FLAGS | os.O_DIRECTORY
CRASH_STATUS: Final = 97
O_TMPFILE: Final = getattr(os, "O_TMPFILE", 0)
UNSUPPORTED_TMPFILE_ERRNOS: Final = frozenset(
    {errno.EINVAL, errno.EISDIR, errno.ENOENT, errno.ENOSYS, errno.EOPNOTSUPP, errno.EPERM}
)


@unique
class CrashPoint(StrEnum):
    INCOMPLETE = "incomplete"
    VERIFIED = "verified"
    LINKED = "linked"
    FINAL = "final"


@unique
class BackendKind(StrEnum):
    LINUX_ANONYMOUS = "linux-anonymous"
    DARWIN_FIXTURE = "darwin-fixture"


@dataclass(frozen=True, slots=True)
class InstallRequest:
    source: str
    destination_directory: str
    destination_name: str
    expected_sha256: str
    expected_size: int


@dataclass(frozen=True, slots=True)
class InstallTestHooks:
    before_publish: Callable[[int, str], None] | None = None
    after_stream: Callable[[], None] | None = None
    backend: BackendKind = BackendKind.DARWIN_FIXTURE
    unsupported_tmpfile: bool = False
    unsupported_linkat: bool = False


@dataclass(frozen=True, slots=True)
class _OpenAnonymousRequest:
    directory_fd: int
    destination_directory: str
    backend: BackendKind
    unsupported_tmpfile: bool


@dataclass(frozen=True, slots=True)
class _DescriptorPublication:
    staging_fd: int
    directory_fd: int
    destination_name: str
    backend: BackendKind
    unsupported_linkat: bool


class InstallError(Exception):
    """Reject an input or unsupported publication setup."""


class DurabilityError(Exception):
    """Report a linked final whose directory durability is uncertain."""


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise InstallError(detail)


def required(value: str | None, label: str) -> str:
    require(value is not None and value != "", f"{label} is required")
    return value


def required_size(value: int | None) -> int:
    require(type(value) is int and value > 0, "expected size is required and must be positive")
    return value


def canonical_absolute(raw: str, label: str) -> str:
    require(raw.startswith("/") and os.path.normpath(raw) == raw, f"{label} must be canonical absolute path")
    parts = raw.split("/")[1:]
    require(parts and all(part not in ("", ".", "..") for part in parts), f"{label} has invalid components")
    return raw


def simple_name(raw: str) -> str:
    require(raw not in ("", ".", "..") and "/" not in raw, "destination name must be one component")
    return raw


@contextmanager
def opened(raw: str, directory: bool) -> Iterator[int]:
    absolute = canonical_absolute(raw, "path")
    parts = absolute.split("/")[1:]
    fd = os.open("/", DIR_FLAGS)
    try:
        for index, part in enumerate(parts):
            flags = DIR_FLAGS if index < len(parts) - 1 or directory else READ_FLAGS
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        info = os.fstat(fd)
        require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), "path has wrong file type")
        yield fd
    finally:
        os.close(fd)


def stable_identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def inode_identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def _open_anonymous_file(request: _OpenAnonymousRequest) -> int:
    if request.unsupported_tmpfile:
        raise InstallError("setup unsupported: anonymous destination inode unavailable (injected)")
    match request.backend:
        case BackendKind.LINUX_ANONYMOUS:
            require(sys.platform.startswith("linux"), "setup unsupported: anonymous destination inode requires Linux")
            require(O_TMPFILE != 0, "setup unsupported: O_TMPFILE is unavailable")
            try:
                return os.open(
                    ".",
                    O_TMPFILE | os.O_RDWR | os.O_CLOEXEC,
                    0o600,
                    dir_fd=request.directory_fd,
                )
            except OSError as error:
                if error.errno in UNSUPPORTED_TMPFILE_ERRNOS:
                    raise InstallError(
                        f"setup unsupported: anonymous destination inode unavailable (errno {error.errno})"
                    ) from None
                raise
        case BackendKind.DARWIN_FIXTURE:
            require(sys.platform == "darwin", "portable fixture backend is Darwin-only")
            with tempfile.TemporaryFile(mode="w+b", dir=request.destination_directory) as fixture:
                staging_fd = os.dup(fixture.fileno())
            os.set_inheritable(staging_fd, False)
            return staging_fd
        case unreachable:
            assert_never(unreachable)


def _copy_and_hash(source_fd: int, destination_fd: int, point: CrashPoint | None) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    first = True
    while chunk := os.read(source_fd, CHUNK):
        view = memoryview(chunk)
        while view:
            written = os.write(destination_fd, view)
            view = view[written:]
        digest.update(chunk)
        size += len(chunk)
        if first:
            first = False
            _crash(point, CrashPoint.INCOMPLETE)
    if first:
        _crash(point, CrashPoint.INCOMPLETE)
    return digest.hexdigest(), size


def _publish_portable_fixture(publication: _DescriptorPublication) -> tuple[int, int]:
    if publication.unsupported_linkat:
        raise InstallError("setup unsupported: linkat AT_EMPTY_PATH unavailable (injected)")
    final_fd = os.open(
        publication.destination_name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=publication.directory_fd,
    )
    try:
        os.lseek(publication.staging_fd, 0, os.SEEK_SET)
        _copy_and_hash(publication.staging_fd, final_fd, None)
        os.fchmod(final_fd, 0o644)
        os.fsync(final_fd)
        return inode_identity(os.fstat(final_fd))
    finally:
        os.close(final_fd)


def _publish_anonymous(publication: _DescriptorPublication) -> tuple[int, int]:
    match publication.backend:
        case BackendKind.LINUX_ANONYMOUS:
            return _linkat_empty_path(publication)
        case BackendKind.DARWIN_FIXTURE:
            return _publish_portable_fixture(publication)
        case unreachable:
            assert_never(unreachable)


def _crash(point: CrashPoint | None, expected: CrashPoint) -> None:
    if point is expected:
        os._exit(CRASH_STATUS)


def install(
    request: InstallRequest,
    crash_point: CrashPoint | None = None,
    test_hooks: InstallTestHooks | None = None,
) -> None:
    require(HEX64.fullmatch(request.expected_sha256) is not None, "expected SHA-256 must be lowercase 64-hex")
    require(type(request.expected_size) is int and request.expected_size > 0, "expected size must be a positive integer")
    source = canonical_absolute(request.source, "source")
    destination_directory = canonical_absolute(request.destination_directory, "destination directory")
    destination_name = simple_name(request.destination_name)
    linked = False
    backend = test_hooks.backend if test_hooks is not None else BackendKind.LINUX_ANONYMOUS
    unsupported_tmpfile = test_hooks is not None and test_hooks.unsupported_tmpfile
    unsupported_linkat = test_hooks is not None and test_hooks.unsupported_linkat
    with opened(source, directory=False) as source_fd, opened(destination_directory, directory=True) as directory_fd:
        source_before = os.fstat(source_fd)
        staging_fd = -1
        try:
            staging_fd = _open_anonymous_file(
                _OpenAnonymousRequest(directory_fd, destination_directory, backend, unsupported_tmpfile)
            )
            actual_sha256, actual_size = _copy_and_hash(source_fd, staging_fd, crash_point)
            if test_hooks is not None and test_hooks.after_stream is not None:
                test_hooks.after_stream()
            require(stable_identity(source_before) == stable_identity(os.fstat(source_fd)), "source changed while streaming")
            require(actual_size == request.expected_size, "source size mismatch")
            require(actual_sha256 == request.expected_sha256, "source SHA-256 mismatch")
            os.fchmod(staging_fd, 0o644)
            os.fsync(staging_fd)
            _crash(crash_point, CrashPoint.VERIFIED)
            if test_hooks is not None and test_hooks.before_publish is not None:
                test_hooks.before_publish(directory_fd, destination_name)
            published_identity = _publish_anonymous(
                _DescriptorPublication(staging_fd, directory_fd, destination_name, backend, unsupported_linkat)
            )
            linked = True
            final_fd = os.open(destination_name, READ_FLAGS, dir_fd=directory_fd)
            try:
                require(inode_identity(os.fstat(final_fd)) == published_identity, "published final inode identity changed")
            finally:
                os.close(final_fd)
            _crash(crash_point, CrashPoint.LINKED)
            os.fsync(directory_fd)
            _crash(crash_point, CrashPoint.FINAL)
        except (InstallError, OSError):
            if linked:
                raise DurabilityError(
                    f"final path was linked; publication durability is uncertain and the final is retained: {destination_directory}/{destination_name}"
                ) from None
            raise
        finally:
            if staging_fd >= 0:
                os.close(staging_fd)
