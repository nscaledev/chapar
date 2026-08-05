#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from validated_sqsh_installer import (
        DurabilityError,
        InstallError,
        InstallRequest,
        install,
        required,
        required_size,
    )
    from validated_sqsh_installer_selftest import self_test


CORE_NAME: Final = "validated_sqsh_installer.py"
CORE_SHA256: Final = "6e0004106b6d9164fd2bbf690841a3a7210ad41fdda2f88d02bfc5458ef55612"
LINKAT_NAME: Final = "validated_sqsh_linkat.py"
LINKAT_SHA256: Final = "eff4d6712d6cf3deff6251a2ac8c400995fbb22e11bf9c72b0faee2f9cf0e67b"
LINKAT_SELF_TEST_NAME: Final = "validated_sqsh_linkat_selftest.py"
LINKAT_SELF_TEST_SHA256: Final = "31ccfb6d994943b823f6eb8cc1c6db4e4d0f8473fe78d0ce96adc5b89ba450f7"
SELF_TEST_NAME: Final = "validated_sqsh_installer_selftest.py"
SELF_TEST_SHA256: Final = "58c30e89485f7542327e20bcacd279e24b2ea786633200f2fa5a4af53b601d87"
MAX_PROTECTED_CODE_SIZE: Final = 1024 * 1024
PROTECTED_READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
PROTECTED_DIR_FLAGS: Final = PROTECTED_READ_FLAGS | os.O_DIRECTORY


class ProtectedCodeError(Exception):
    """Reject an untrusted executable sibling before its bytes run."""


def protected_identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def require_protected(condition: bool, detail: str) -> None:
    if not condition:
        raise ProtectedCodeError(detail)


def read_protected_sibling(name: str, expected_sha256: str, label: str) -> bytes:
    script_path = os.path.abspath(__file__)
    require_protected(
        os.path.normpath(script_path) == script_path and os.path.realpath(script_path) == script_path,
        "protected launcher path is not canonical and symlink-free",
    )
    directory_path = os.path.dirname(script_path)
    script_name = os.path.basename(script_path)
    directory_fd = os.open(directory_path, PROTECTED_DIR_FLAGS)
    script_fd = -1
    code_fd = -1
    try:
        script_fd = os.open(script_name, PROTECTED_READ_FLAGS, dir_fd=directory_fd)
        code_fd = os.open(name, PROTECTED_READ_FLAGS, dir_fd=directory_fd)
        directory_info = os.fstat(directory_fd)
        script_info = os.fstat(script_fd)
        code_before = os.fstat(code_fd)
        require_protected(stat.S_ISDIR(directory_info.st_mode), "protected code parent is not a directory")
        require_protected(stat.S_ISREG(script_info.st_mode), "protected launcher is not a regular file")
        require_protected(stat.S_ISREG(code_before.st_mode), f"protected {label} is not a regular file")
        require_protected(
            directory_info.st_uid == script_info.st_uid == code_before.st_uid,
            f"protected {label} owner differs from launcher custody",
        )
        require_protected(
            all(not (info.st_mode & 0o022) for info in (directory_info, script_info, code_before)),
            f"protected {label} custody is group/world writable",
        )
        directory_path_info = os.stat(directory_path, follow_symlinks=False)
        script_path_info = os.stat(script_name, dir_fd=directory_fd, follow_symlinks=False)
        code_path_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        require_protected(
            protected_identity(directory_path_info) == protected_identity(directory_info),
            "protected code parent path identity changed",
        )
        require_protected(
            protected_identity(script_path_info) == protected_identity(script_info),
            "protected launcher path identity changed",
        )
        require_protected(
            protected_identity(code_path_info) == protected_identity(code_before),
            f"protected {label} path identity changed",
        )
        require_protected(
            0 < code_before.st_size <= MAX_PROTECTED_CODE_SIZE,
            f"protected {label} size is outside the bounded contract",
        )
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(code_fd, 1024 * 1024):
            total += len(chunk)
            require_protected(total <= MAX_PROTECTED_CODE_SIZE, f"protected {label} exceeded the size bound")
            chunks.append(chunk)
        code = b"".join(chunks)
        code_after = os.fstat(code_fd)
        require_protected(
            protected_identity(code_before) == protected_identity(code_after) and len(code) == code_before.st_size,
            f"protected {label} changed while reading",
        )
        require_protected(
            hashlib.sha256(code).hexdigest() == expected_sha256,
            f"protected {label} SHA-256 mismatch",
        )
        return code
    finally:
        if code_fd >= 0:
            os.close(code_fd)
        if script_fd >= 0:
            os.close(script_fd)
        os.close(directory_fd)


def execute_protected_sibling(name: str, expected_sha256: str, label: str) -> None:
    code = read_protected_sibling(name, expected_sha256, label)
    filename = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    exec(compile(code, filename, "exec"), globals())


try:
    execute_protected_sibling(CORE_NAME, CORE_SHA256, "core")
    execute_protected_sibling(LINKAT_NAME, LINKAT_SHA256, "linkat backend")
    execute_protected_sibling(LINKAT_SELF_TEST_NAME, LINKAT_SELF_TEST_SHA256, "linkat self-test")
except (OSError, ProtectedCodeError) as error:
    print(f"validated SQSH installation failed: {error}", file=sys.stderr)
    raise SystemExit(1) from None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source")
    parser.add_argument("--destination-directory")
    parser.add_argument("--destination-name")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--expected-size", type=int)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.self_test:
            execute_protected_sibling(SELF_TEST_NAME, SELF_TEST_SHA256, "self-test")
            self_test()
        else:
            request = InstallRequest(
                required(args.source, "source"),
                required(args.destination_directory, "destination directory"),
                required(args.destination_name, "destination name"),
                required(args.expected_sha256, "expected SHA-256"),
                required_size(args.expected_size),
            )
            install(request)
            print(f"installed {request.destination_directory}/{request.destination_name}")
    except (InstallError, DurabilityError, OSError, ProtectedCodeError) as error:
        print(f"validated SQSH installation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
