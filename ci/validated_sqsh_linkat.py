from __future__ import annotations

import ctypes
import errno
import os
from dataclasses import dataclass
from typing import Final


AT_EMPTY_PATH: Final = 0x1000
AT_SYMLINK_FOLLOW: Final = 0x400
UNSUPPORTED_LINKAT_ERRNOS: Final = frozenset(
    {errno.EINVAL, errno.ENOENT, errno.ENOSYS, errno.EOPNOTSUPP, errno.EPERM}
)
CAPABILITY_EMPTY_PATH_ERRNOS: Final = frozenset({errno.ENOENT, errno.EPERM})


@dataclass(frozen=True, slots=True)
class _LinkatRequest:
    source_fd: int
    source_path: bytes
    destination_fd: int
    destination_name: str
    flags: int


def _linkat(request: _LinkatRequest) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    ctypes.set_errno(0)
    result = libc.linkat(
        request.source_fd,
        ctypes.c_char_p(request.source_path),
        request.destination_fd,
        ctypes.c_char_p(os.fsencode(request.destination_name)),
        request.flags,
    )
    if result != 0:
        raise OSError(ctypes.get_errno(), "linkat failed")


def _linkat_empty_path(publication: _DescriptorPublication) -> tuple[int, int]:
    if publication.unsupported_linkat:
        raise InstallError("setup unsupported: linkat AT_EMPTY_PATH unavailable (injected)")
    staging_identity = inode_identity(os.fstat(publication.staging_fd))
    try:
        _linkat(
            _LinkatRequest(
                publication.staging_fd, b"", publication.directory_fd, publication.destination_name, AT_EMPTY_PATH
            )
        )
    except OSError as error:
        if error.errno not in CAPABILITY_EMPTY_PATH_ERRNOS:
            if error.errno in UNSUPPORTED_LINKAT_ERRNOS:
                raise InstallError(f"setup unsupported: linkat AT_EMPTY_PATH unavailable (errno {error.errno})") from None
            raise
        procfd_path = f"/proc/self/fd/{publication.staging_fd}"
        try:
            require(
                inode_identity(os.stat(procfd_path)) == staging_identity,
                "setup unsupported: /proc/self/fd fallback does not resolve staging inode",
            )
        except OSError as procfs_error:
            raise InstallError(
                f"setup unsupported: /proc/self/fd fallback unavailable (errno {procfs_error.errno})"
            ) from None
        try:
            _linkat(
                _LinkatRequest(
                    publication.staging_fd,
                    os.fsencode(procfd_path),
                    publication.directory_fd,
                    publication.destination_name,
                    AT_SYMLINK_FOLLOW,
                )
            )
        except OSError as fallback_error:
            if fallback_error.errno in UNSUPPORTED_LINKAT_ERRNOS:
                raise InstallError(
                    f"setup unsupported: /proc/self/fd linkat fallback unavailable (errno {fallback_error.errno})"
                ) from None
            raise
    return staging_identity
