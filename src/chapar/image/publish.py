"""`chapar image publish`: hard-link publication of a validated .sqsh.

The indivisible publication state machine: stream the verified source into an
exclusive partial inode, verify size and digest against the values recorded at
validation time, then publish the *verified descriptor's* inode via linkat so a
concurrent replacement of the partial name can never be published. A final that
already exists is never overwritten. Stdlib only.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import os
import re
import secrets
import stat
import sys
import tempfile
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum, unique
from pathlib import Path
from typing import Final, assert_never

from chapar.common.jsonio import fail

HEX64: Final = re.compile(r"[0-9a-f]{64}")
CHUNK: Final = 1024 * 1024
READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
DIR_FLAGS: Final = READ_FLAGS | os.O_DIRECTORY
CRASH_STATUS: Final = 97


@unique
class CrashPoint(StrEnum):
    INCOMPLETE = "incomplete"
    VERIFIED = "verified"
    LINKED = "linked"
    FINAL = "final"


@dataclass(frozen=True, slots=True)
class InstallRequest:
    source: str
    destination_directory: str
    destination_name: str
    expected_sha256: str
    expected_size: int


@dataclass(frozen=True, slots=True)
class _InstallTestHooks:
    before_publish: Callable[[int, str], None] | None = None
    portable_descriptor_link: bool = False


@dataclass(frozen=True, slots=True)
class _DescriptorPublication:
    partial_fd: int
    directory_fd: int
    destination_name: str
    portable_anchor: str | None


class InstallError(Exception):
    __slots__ = ("detail",)

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


class DurabilityError(Exception):
    __slots__ = ("detail",)

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise InstallError(detail)


def canonical_absolute(raw: str, label: str) -> str:
    require(raw.startswith("/") and os.path.normpath(raw) == raw, f"{label} must be canonical absolute path")
    parts = raw.split("/")[1:]
    require(bool(parts) and all(part not in ("", ".", "..") for part in parts), f"{label} has invalid components")
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


def unlink_if_owned(directory_fd: int, name: str, owned_identity: tuple[int, int]) -> bool:
    try:
        candidate_fd = os.open(name, READ_FLAGS, dir_fd=directory_fd)
    except FileNotFoundError:
        return False
    except OSError as error:
        if error.errno == errno.ELOOP:
            return False
        raise
    try:
        if inode_identity(os.fstat(candidate_fd)) != owned_identity:
            return False
    finally:
        os.close(candidate_fd)
    os.unlink(name, dir_fd=directory_fd)
    return True


def link_verified_fd(publication: _DescriptorPublication) -> None:
    if publication.portable_anchor is not None:
        os.link(
            publication.portable_anchor,
            publication.destination_name,
            src_dir_fd=publication.directory_fd,
            dst_dir_fd=publication.directory_fd,
            follow_symlinks=False,
        )
        return
    require(sys.platform.startswith("linux"), "setup unsupported: descriptor-bound publication requires Linux linkat")
    libc = ctypes.CDLL(None, use_errno=True)
    ctypes.set_errno(0)
    result = libc.linkat(
        publication.partial_fd,
        ctypes.c_char_p(b""),
        publication.directory_fd,
        ctypes.c_char_p(os.fsencode(publication.destination_name)),
        0x1000,
    )
    if result == 0:
        return
    empty_path_error = ctypes.get_errno()
    if empty_path_error not in (errno.EINVAL, errno.ENOENT, errno.EPERM):
        raise OSError(empty_path_error, "linkat AT_EMPTY_PATH failed")
    ctypes.set_errno(0)
    proc_path = os.fsencode(f"/proc/self/fd/{publication.partial_fd}")
    result = libc.linkat(
        -100,
        ctypes.c_char_p(proc_path),
        publication.directory_fd,
        ctypes.c_char_p(os.fsencode(publication.destination_name)),
        0x400,
    )
    if result != 0:
        proc_error = ctypes.get_errno()
        raise OSError(proc_error, f"descriptor-bound linkat unavailable (AT_EMPTY_PATH errno {empty_path_error})")


def crash(point: CrashPoint | None, expected: CrashPoint) -> None:
    if point is expected:
        os._exit(CRASH_STATUS)


def copy_and_hash(source_fd: int, partial_fd: int, point: CrashPoint | None) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    first = True
    while chunk := os.read(source_fd, CHUNK):
        view = memoryview(chunk)
        while view:
            written = os.write(partial_fd, view)
            view = view[written:]
        digest.update(chunk)
        size += len(chunk)
        if first:
            first = False
            crash(point, CrashPoint.INCOMPLETE)
    if first:
        crash(point, CrashPoint.INCOMPLETE)
    return digest.hexdigest(), size


def install(
    request: InstallRequest,
    crash_point: CrashPoint | None = None,
    test_hooks: _InstallTestHooks | None = None,
) -> None:
    require(HEX64.fullmatch(request.expected_sha256) is not None, "expected SHA-256 must be lowercase 64-hex")
    require(type(request.expected_size) is int and request.expected_size > 0, "expected size must be a positive integer")
    source = canonical_absolute(request.source, "source")
    destination_directory = canonical_absolute(request.destination_directory, "destination directory")
    destination_name = simple_name(request.destination_name)
    partial_name = f".{destination_name}.partial.{os.getpid()}.{secrets.token_hex(16)}"
    linked = False
    with opened(source, directory=False) as source_fd, opened(destination_directory, directory=True) as directory_fd:
        source_before = os.fstat(source_fd)
        partial_fd = -1
        partial_identity: tuple[int, int] | None = None
        portable_anchor: str | None = None
        try:
            partial_fd = os.open(
                partial_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=directory_fd,
            )
            if test_hooks is not None and test_hooks.portable_descriptor_link:
                portable_anchor = f".{destination_name}.verified-fd.{os.getpid()}.{secrets.token_hex(16)}"
                os.link(partial_name, portable_anchor, src_dir_fd=directory_fd, dst_dir_fd=directory_fd, follow_symlinks=False)
            actual_sha256, actual_size = copy_and_hash(source_fd, partial_fd, crash_point)
            source_after = os.fstat(source_fd)
            require(stable_identity(source_before) == stable_identity(source_after), "source changed while streaming")
            require(actual_size == request.expected_size, "source size mismatch")
            require(actual_sha256 == request.expected_sha256, "source SHA-256 mismatch")
            os.fchmod(partial_fd, 0o644)
            os.fsync(partial_fd)
            partial_identity = inode_identity(os.fstat(partial_fd))
            crash(crash_point, CrashPoint.VERIFIED)
            if test_hooks is not None and test_hooks.before_publish is not None:
                test_hooks.before_publish(directory_fd, partial_name)
            link_verified_fd(_DescriptorPublication(partial_fd, directory_fd, destination_name, portable_anchor))
            linked = True
            final_fd = os.open(destination_name, READ_FLAGS, dir_fd=directory_fd)
            try:
                require(inode_identity(os.fstat(final_fd)) == partial_identity, "published final inode differs from verified partial")
            finally:
                os.close(final_fd)
            crash(crash_point, CrashPoint.LINKED)
            os.fsync(directory_fd)
            unlink_if_owned(directory_fd, partial_name, partial_identity)
            if portable_anchor is not None:
                unlink_if_owned(directory_fd, portable_anchor, partial_identity)
            crash(crash_point, CrashPoint.FINAL)
            os.fsync(directory_fd)
        except (InstallError, OSError):
            if linked:
                raise DurabilityError(
                    "final path was linked; publication durability is uncertain and the final is retained: "
                    f"{destination_directory}/{destination_name}"
                ) from None
            if partial_identity is None and partial_fd >= 0:
                partial_identity = inode_identity(os.fstat(partial_fd))
            if partial_identity is not None:
                unlink_if_owned(directory_fd, partial_name, partial_identity)
                if portable_anchor is not None:
                    unlink_if_owned(directory_fd, portable_anchor, partial_identity)
            raise
        finally:
            if partial_fd >= 0:
                os.close(partial_fd)


def partials(directory: Path, name: str) -> tuple[Path, ...]:
    prefix = f".{name}.partial."
    return tuple(entry for entry in directory.iterdir() if entry.name.startswith(prefix))


def run_crash(request: InstallRequest, point: CrashPoint) -> None:
    child = os.fork()
    if child == 0:
        install(request, point, _InstallTestHooks(portable_descriptor_link=True))
        os._exit(0)
    _, status = os.waitpid(child, 0)
    require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == CRASH_STATUS, f"crash fixture failed at {point}")


def assert_crash_state(directory: Path, name: str, point: CrashPoint) -> None:
    final = directory / name
    stale = partials(directory, name)
    match point:
        case CrashPoint.INCOMPLETE:
            require(not final.exists() and len(stale) == 1, "incomplete crash state mismatch")
            require(stat.S_IMODE(stale[0].stat().st_mode) == 0o600, "incomplete partial mode mismatch")
        case CrashPoint.VERIFIED:
            require(not final.exists() and len(stale) == 1, "verified crash state mismatch")
            require(stat.S_IMODE(stale[0].stat().st_mode) == 0o644, "verified partial mode mismatch")
        case CrashPoint.LINKED:
            require(final.exists() and len(stale) == 1, "linked crash state mismatch")
            require(final.stat().st_ino == stale[0].stat().st_ino, "linked final and partial differ")
        case CrashPoint.FINAL:
            require(final.exists() and stale == (), "final-only crash state mismatch")
        case unreachable:
            assert_never(unreachable)


def self_test() -> None:
    require(hasattr(os, "fork"), "installer self-test requires POSIX fork")
    cases: list[str] = []
    with tempfile.TemporaryDirectory(prefix="validated-sqsh-self-test-") as temp:
        root = Path(temp).resolve()
        source = root / "source.sqsh"
        content = (b"validated-sqsh\n" * 8192) + b"end"
        source.write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        destination = root / "destination"
        destination.mkdir()
        portable_hooks = _InstallTestHooks(portable_descriptor_link=True)
        request = InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content))
        install(request, test_hooks=portable_hooks)
        final = destination / request.destination_name
        require(final.read_bytes() == content and stat.S_IMODE(final.stat().st_mode) == 0o644, "happy publication mismatch")
        require(partials(destination, request.destination_name) == (), "happy publication left a partial")
        cases.append("happy-publication")
        try:
            install(request, test_hooks=portable_hooks)
        except OSError as error:
            require(error.errno == errno.EEXIST, f"final collision failed for wrong reason: {error}")
        else:
            raise InstallError("final collision unexpectedly succeeded")
        cases.append("final-collision-portable")
        require(final.read_bytes() == content, "final collision changed destination")
        wrong = InstallRequest(str(source), str(destination), "wrong.sqsh", "0" * 64, len(content))
        try:
            install(wrong, test_hooks=portable_hooks)
        except InstallError:
            digest_rejected = True
        else:
            raise InstallError("wrong digest passed")
        require(digest_rejected, "wrong digest rejection was not observed")
        require(
            not (destination / wrong.destination_name).exists() and partials(destination, wrong.destination_name) == (),
            "prelink failure left output",
        )
        cases.append("digest-mismatch")
        wrong_size = InstallRequest(str(source), str(destination), "wrong-size.sqsh", digest, len(content) + 1)
        try:
            install(wrong_size, test_hooks=portable_hooks)
        except InstallError as error:
            require("size mismatch" in str(error), f"size mismatch failed for wrong reason: {error}")
        else:
            raise InstallError("wrong size passed")
        cases.append("size-mismatch")
        source_link = root / "source-link.sqsh"
        source_link.symlink_to(source)
        symlink_request = InstallRequest(str(source_link), str(destination), "link.sqsh", digest, len(content))
        try:
            install(symlink_request)
        except OSError:
            symlink_rejected = True
        else:
            raise InstallError("symlink source passed")
        require(symlink_rejected, "symlink rejection was not observed")
        cases.append("symlink-source")
        real_destination = root / "real-destination"
        real_destination.mkdir()
        destination_link = root / "destination-link"
        destination_link.symlink_to(real_destination)
        symlink_destination_request = InstallRequest(str(source), str(destination_link), "image.sqsh", digest, len(content))
        try:
            install(symlink_destination_request)
        except OSError:
            destination_symlink_rejected = True
        else:
            raise InstallError("symlink destination passed")
        require(destination_symlink_rejected, "symlink destination rejection was not observed")
        cases.append("symlink-destination")
        noncanonical = InstallRequest(
            str(source).replace(source.name, f"./{source.name}"), str(destination), "invalid.sqsh", digest, len(content)
        )
        try:
            install(noncanonical)
        except InstallError as error:
            require("canonical absolute path" in str(error), f"noncanonical path failed for wrong reason: {error}")
        else:
            raise InstallError("noncanonical path passed")
        cases.append("noncanonical-path")
        replacement = b"unverified replacement"
        replacement_name: str | None = None
        replacement_owned_identity: tuple[int, int] | None = None

        def replace_before_publish(directory_fd: int, partial_name: str) -> None:
            nonlocal replacement_name, replacement_owned_identity
            replacement_name = partial_name
            replacement_owned_identity = inode_identity(os.stat(partial_name, dir_fd=directory_fd, follow_symlinks=False))
            os.unlink(partial_name, dir_fd=directory_fd)
            replacement_fd = os.open(partial_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
            try:
                os.write(replacement_fd, replacement)
            finally:
                os.close(replacement_fd)

        replacement_request = InstallRequest(str(source), str(destination), "replacement-race.sqsh", digest, len(content))
        install(replacement_request, test_hooks=_InstallTestHooks(before_publish=replace_before_publish, portable_descriptor_link=True))
        replacement_final = destination / replacement_request.destination_name
        require(replacement_final.read_bytes() == content, "prelink replacement published an unverified inode")
        require(
            replacement_owned_identity is not None and inode_identity(replacement_final.stat()) == replacement_owned_identity,
            "final inode differs from the verified partial inode",
        )
        require(
            replacement_name is not None and (destination / replacement_name).read_bytes() == replacement,
            "prelink replacement was deleted",
        )
        cases.append("prelink-replacement-not-published")

        cleanup_replacement_name: str | None = None

        def replace_before_cleanup_failure(directory_fd: int, partial_name: str) -> None:
            nonlocal cleanup_replacement_name
            cleanup_replacement_name = partial_name
            os.unlink(partial_name, dir_fd=directory_fd)
            replacement_fd = os.open(partial_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
            try:
                os.write(replacement_fd, replacement)
            finally:
                os.close(replacement_fd)
            raise OSError(errno.EIO, "forced prelink failure")

        cleanup_request = InstallRequest(str(source), str(destination), "cleanup-race.sqsh", digest, len(content))
        try:
            install(cleanup_request, test_hooks=_InstallTestHooks(before_publish=replace_before_cleanup_failure, portable_descriptor_link=True))
        except OSError as error:
            require(error.errno == errno.EIO, f"cleanup race failed for wrong reason: {error}")
        else:
            raise InstallError("forced prelink failure unexpectedly succeeded")
        require(
            cleanup_replacement_name is not None and (destination / cleanup_replacement_name).read_bytes() == replacement,
            "prelink cleanup deleted a replacement inode",
        )
        require(not (destination / cleanup_request.destination_name).exists(), "prelink failure published a final")
        cases.append("prelink-failure-retains-replacement")
        platform_request = InstallRequest(str(source), str(destination), "platform-link.sqsh", digest, len(content))
        if sys.platform.startswith("linux"):
            install(platform_request)
            require((destination / platform_request.destination_name).read_bytes() == content, "Linux descriptor-link publication failed")
            cases.append("linux-descriptor-link")
        else:
            try:
                install(platform_request)
            except InstallError as error:
                require(
                    "setup unsupported: descriptor-bound publication requires Linux linkat" in str(error),
                    f"unsupported platform failed for wrong reason: {error}",
                )
            else:
                raise InstallError("unsupported platform publication unexpectedly succeeded")
            require(not (destination / platform_request.destination_name).exists(), "unsupported platform created a final")
            print(f"SETUP-UNSUPPORTED:linux-descriptor-link: platform={sys.platform}")
        for point in CrashPoint:
            name = f"crash-{point}.sqsh"
            crash_request = InstallRequest(str(source), str(destination), name, digest, len(content))
            run_crash(crash_request, point)
            assert_crash_state(destination, name, point)
            cases.append(f"crash-{point}")
            stale_before = partials(destination, name)
            if point in (CrashPoint.LINKED, CrashPoint.FINAL):
                try:
                    install(crash_request, test_hooks=portable_hooks)
                except OSError:
                    rerun_rejected = True
                else:
                    raise InstallError(f"rerun overwrote final after {point}")
                require(rerun_rejected, f"rerun rejection was not observed after {point}")
                require(partials(destination, name) == stale_before, "rerun deleted stale partials")
                cases.append(f"rerun-final-eexist-{point}")
    print("validated SQSH installer self-test passed: " + ",".join(cases))


def required(value: str | None, label: str) -> str:
    require(value is not None and value != "", f"{label} is required")
    assert value is not None
    return value


def required_size(value: int | None) -> int:
    require(type(value) is int and value > 0, "expected size is required and must be positive")
    assert value is not None
    return value


def run_publish(arguments: argparse.Namespace) -> int:
    try:
        if arguments.self_test:
            self_test()
        else:
            request = InstallRequest(
                required(arguments.source, "source"),
                required(arguments.destination_directory, "destination directory"),
                required(arguments.destination_name, "destination name"),
                required(arguments.expected_sha256, "expected SHA-256"),
                required_size(arguments.expected_size),
            )
            install(request)
            print(f"installed {request.destination_directory}/{request.destination_name}")
    except (InstallError, DurabilityError, OSError) as error:
        fail(f"validated SQSH installation failed: {error}")
    return 0
