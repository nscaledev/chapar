from __future__ import annotations

import ctypes
import errno
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


def require_linkat_backend_coverage(root: Path, content: bytes, digest: str) -> None:
    destination = root / "linkat-backend"
    destination.mkdir()
    source = root / "linkat-source.sqsh"
    source.write_bytes(content)
    request = InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content))
    with tempfile.TemporaryFile(dir=destination) as staging:
        directory_fd = os.open(destination, DIR_FLAGS)
        try:
            publication = _DescriptorPublication(
                staging.fileno(), directory_fd, "direct.sqsh", BackendKind.LINUX_ANONYMOUS, False
            )

            def exercise(errors: list[int], procfs_available: bool) -> tuple[tuple[int, int], list[tuple[bytes, int]]]:
                calls: list[tuple[bytes, int]] = []

                # linkat is a five-argument C ABI; the fixture records its exact old path and flags.
                def linkat(
                    old_fd: int,
                    old_path: ctypes.c_char_p,
                    new_fd: int,
                    new_path: ctypes.c_char_p,
                    flags: int,
                ) -> int:
                    del old_fd, new_fd, new_path
                    calls.append((old_path.value or b"", flags))
                    error_number = errors.pop(0)
                    if error_number == 0:
                        return 0
                    ctypes.set_errno(error_number)
                    return -1

                libc = SimpleNamespace(linkat=linkat)
                procfs_context = (
                    patch.object(os, "stat", return_value=os.fstat(staging.fileno()))
                    if procfs_available
                    else patch.object(os, "stat", side_effect=OSError(errno.ENOENT, "injected missing procfs"))
                )
                with patch.object(ctypes, "CDLL", return_value=libc), procfs_context:
                    return _linkat_empty_path(publication), calls

            direct_identity, direct_calls = exercise([0], True)
            require(
                direct_identity == inode_identity(os.fstat(staging.fileno()))
                and direct_calls == [(b"", AT_EMPTY_PATH)],
                "direct AT_EMPTY_PATH backend fixture failed",
            )
            for capability_errno in (errno.EPERM, errno.ENOENT):
                fallback_identity, fallback_calls = exercise([capability_errno, 0], True)
                require(
                    fallback_identity == inode_identity(os.fstat(staging.fileno()))
                    and fallback_calls
                    == [(b"", AT_EMPTY_PATH), (f"/proc/self/fd/{staging.fileno()}".encode(), AT_SYMLINK_FOLLOW)],
                    "unprivileged procfd fallback backend fixture failed",
                )
            try:
                exercise([errno.EPERM], False)
            except InstallError as error:
                require("/proc/self/fd fallback unavailable" in str(error), "missing procfs was not fail-closed")
            else:
                raise InstallError("missing procfs backend fixture unexpectedly succeeded")
            try:
                exercise([errno.EPERM, errno.EEXIST], True)
            except OSError as error:
                require(error.errno == errno.EEXIST, "procfd fallback did not preserve destination collision")
            else:
                raise InstallError("destination collision backend fixture unexpectedly succeeded")

            def wrong_final_linkat(
                old_fd: int,
                old_path: ctypes.c_char_p,
                new_fd: int,
                new_path: ctypes.c_char_p,
                flags: int,
            ) -> int:
                del old_fd
                if old_path.value == b"":
                    ctypes.set_errno(errno.EPERM)
                    return -1
                require(flags == AT_SYMLINK_FOLLOW, "wrong-final fixture did not use procfd linkat flags")
                final_fd = os.open(
                    os.fsdecode(new_path.value or b""),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                    0o600,
                    dir_fd=new_fd,
                )
                try:
                    os.write(final_fd, b"wrong final")
                finally:
                    os.close(final_fd)
                return 0

            staged_fd = os.dup(staging.fileno())
            with (
                patch.dict(install.__globals__, {"_open_anonymous_file": lambda _: staged_fd}),
                patch.object(ctypes, "CDLL", return_value=SimpleNamespace(linkat=wrong_final_linkat)),
                patch.object(os, "stat", return_value=os.fstat(staging.fileno())),
            ):
                try:
                    install(request, test_hooks=InstallTestHooks(backend=BackendKind.LINUX_ANONYMOUS))
                except DurabilityError:
                    final = destination / request.destination_name
                    require(final.read_bytes() == b"wrong final", "wrong final inode fixture did not retain its competing file")
                    require(inode_identity(os.lstat(final)) != inode_identity(os.fstat(staging.fileno())), "wrong final inode was accepted")
                else:
                    raise InstallError("wrong final inode fixture unexpectedly succeeded")
        finally:
            os.close(directory_fd)
