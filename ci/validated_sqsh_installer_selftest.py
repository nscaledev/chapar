"""Executable state-machine fixtures loaded by the protected installer wrapper."""

from __future__ import annotations

import errno
import hashlib
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING, Final, assert_never

if TYPE_CHECKING:
    from validated_sqsh_installer import (
        CRASH_STATUS,
        BackendKind,
        CrashPoint,
        InstallError,
        InstallRequest,
        InstallTestHooks,
        inode_identity,
        install,
        opened,
        require,
    )


TEST_BACKEND: Final[BackendKind] = (
    BackendKind.DARWIN_FIXTURE if sys.platform == "darwin" else BackendKind.LINUX_ANONYMOUS
)
PROTECTED_HELPERS: Final = (
    "validated_sqsh_installer.py",
    "validated_sqsh_linkat.py",
    "validated_sqsh_linkat_selftest.py",
    "validated_sqsh_installer_selftest.py",
)


def require_terminal_entries(directory: Path, expected: frozenset[str], label: str) -> None:
    actual = frozenset(entry.name for entry in directory.iterdir())
    require(actual == expected, f"{label} terminal entries mismatch: expected {sorted(expected)}, got {sorted(actual)}")
    forbidden = (".partial.", ".verified-fd.", ".quarantine.", ".validated-sqsh-retained.")
    require(all(not any(marker in name for marker in forbidden) for name in actual), f"{label} left a forbidden staging entry")


def require_install_error(request: InstallRequest, hooks: InstallTestHooks | None, expected: str) -> None:
    try:
        install(request, test_hooks=hooks)
    except InstallError as error:
        require(expected in str(error), f"expected {expected!r}, got: {error}")
    else:
        raise InstallError(f"expected installation failure containing {expected!r}")


def require_os_error(request: InstallRequest, hooks: InstallTestHooks | None, expected_errno: int | None) -> None:
    try:
        install(request, test_hooks=hooks)
    except OSError as error:
        require(expected_errno is None or error.errno == expected_errno, f"expected errno {expected_errno}, got: {error}")
    else:
        raise InstallError("expected OS-level installation failure")


def run_crash(request: InstallRequest, point: CrashPoint) -> None:
    child = os.fork()
    if child == 0:
        install(request, point, InstallTestHooks(backend=TEST_BACKEND))
        os._exit(0)
    _, status = os.waitpid(child, 0)
    require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == CRASH_STATUS, f"crash fixture failed at {point}")


def assert_crash_state(request: InstallRequest, point: CrashPoint) -> None:
    directory = Path(request.destination_directory)
    final = directory / request.destination_name
    match point:
        case CrashPoint.INCOMPLETE:
            require_terminal_entries(directory, frozenset(), "incomplete crash")
        case CrashPoint.VERIFIED:
            require_terminal_entries(directory, frozenset(), "verified crash")
        case CrashPoint.LINKED | CrashPoint.FINAL:
            require_terminal_entries(directory, frozenset({request.destination_name}), f"{point} crash")
            crash_identity = inode_identity(final.stat())
            require_os_error(request, InstallTestHooks(backend=TEST_BACKEND), errno.EEXIST)
            require(inode_identity(final.stat()) == crash_identity, f"rerun replaced final after {point}")
            require_terminal_entries(directory, frozenset({request.destination_name}), f"rerun after {point}")
        case unreachable:
            assert_never(unreachable)
    if final.exists():
        info = final.stat()
        require(
            info.st_size == request.expected_size
            and stat.S_IMODE(info.st_mode) == 0o644
            and hashlib.sha256(final.read_bytes()).hexdigest() == request.expected_sha256,
            f"{point} final size, mode, or digest mismatch",
        )


def require_helper_drift_rejected(root: Path, helper_name: str, label: str) -> None:
    drift_root = root / f"{label}-drift"
    drift_root.mkdir()
    wrapper = drift_root / "install-validated-sqsh.py"
    helper = drift_root / helper_name
    replacement = drift_root / "replacement.py"
    sentinel = drift_root / f"untrusted-{label}-executed"
    wrapper.write_bytes(Path(__file__).read_bytes())
    for protected_helper in PROTECTED_HELPERS:
        (drift_root / protected_helper).write_bytes(Path(__file__).with_name(protected_helper).read_bytes())
    original_identity = inode_identity(helper.stat())
    payload = f'\nopen({str(sentinel)!r}, "wb").write(b"executed")\n'.encode()
    replacement.write_bytes(helper.read_bytes() + payload)
    os.replace(replacement, helper)
    require(inode_identity(helper.stat()) != original_identity, f"{label} replacement fixture did not replace the inode")
    result = subprocess.run([sys.executable, str(wrapper)], check=False, capture_output=True, text=True)
    expected = f"validated SQSH installation failed: protected {label} SHA-256 mismatch\n"
    require(
        result.returncode == 1 and result.stdout == "" and result.stderr == expected and not sentinel.exists(),
        f"protected {label} drift was not rejected before execution",
    )


def self_test() -> None:
    require(hasattr(os, "fork"), "installer self-test requires POSIX fork")
    with tempfile.TemporaryDirectory(prefix="validated-sqsh-self-test-") as temp:
        root = Path(temp).resolve()
        source = root / "source.sqsh"
        content = (b"validated-sqsh\n" * 8192) + b"end"
        source.write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        destination = root / "destination"
        destination.mkdir()
        require_helper_drift_rejected(root, "validated_sqsh_installer.py", "core")
        require_helper_drift_rejected(root, "validated_sqsh_linkat.py", "linkat backend")
        require_linkat_backend_coverage(root, content, digest)
        fixture_hooks = InstallTestHooks(backend=TEST_BACKEND)
        expected_entries: set[str] = set()
        request = InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content))
        drift_source = root / "drift-source.sqsh"
        drift_source.write_bytes(content)
        drift_replacement = root / "drift-replacement.sqsh"
        drift_replacement.write_bytes(content)

        def replace_source_after_stream() -> None:
            os.replace(drift_replacement, drift_source)

        drift_request = InstallRequest(str(drift_source), str(destination), "source-drift.sqsh", digest, len(content))
        require_install_error(
            drift_request,
            InstallTestHooks(after_stream=replace_source_after_stream, backend=TEST_BACKEND),
            "source changed",
        )
        require_terminal_entries(destination, frozenset(), "source replacement")
        install(request, test_hooks=fixture_hooks)
        final = destination / request.destination_name
        require(final.read_bytes() == content and stat.S_IMODE(final.stat().st_mode) == 0o644, "happy publication mismatch")
        require(hashlib.sha256(final.read_bytes()).hexdigest() == digest and final.stat().st_size == len(content), "happy digest or size mismatch")
        final_identity = inode_identity(final.stat())
        with opened(str(final), directory=False) as reopened_final_fd:
            require(inode_identity(os.fstat(reopened_final_fd)) == final_identity, "happy final identity changed on re-open")
        expected_entries.add(request.destination_name)
        require_terminal_entries(destination, frozenset(expected_entries), "happy publication")
        require_os_error(request, fixture_hooks, errno.EEXIST)
        require(final.read_bytes() == content and inode_identity(final.stat()) == final_identity, "final collision changed destination")
        require_terminal_entries(destination, frozenset(expected_entries), "final collision")
        wrong = InstallRequest(str(source), str(destination), "wrong.sqsh", "0" * 64, len(content))
        require_install_error(wrong, fixture_hooks, "SHA-256 mismatch")
        require_terminal_entries(destination, frozenset(expected_entries), "digest mismatch")
        wrong_size = InstallRequest(str(source), str(destination), "wrong-size.sqsh", digest, len(content) + 1)
        require_install_error(wrong_size, fixture_hooks, "size mismatch")
        require_terminal_entries(destination, frozenset(expected_entries), "size mismatch")
        source_link = root / "source-link.sqsh"
        source_link.symlink_to(source)
        symlink_request = InstallRequest(str(source_link), str(destination), "link.sqsh", digest, len(content))
        require_os_error(symlink_request, None, None)
        require_terminal_entries(destination, frozenset(expected_entries), "symlink source")
        real_destination = root / "real-destination"
        real_destination.mkdir()
        destination_link = root / "destination-link"
        destination_link.symlink_to(real_destination)
        symlink_destination_request = InstallRequest(str(source), str(destination_link), "image.sqsh", digest, len(content))
        require_os_error(symlink_destination_request, None, None)
        require_terminal_entries(real_destination, frozenset(), "symlink destination")
        noncanonical = InstallRequest(str(source).replace(source.name, f"./{source.name}"), str(destination), "invalid.sqsh", digest, len(content))
        require_install_error(noncanonical, None, "canonical absolute path")
        require_terminal_entries(destination, frozenset(expected_entries), "noncanonical source")
        replacement = b"unverified replacement"
        replacement_identity: tuple[int, int] | None = None

        def replace_before_publish(directory_fd: int, final_name: str) -> None:
            nonlocal replacement_identity
            with os.fdopen(
                os.open(final_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd),
                "wb",
            ) as replacement_file:
                replacement_file.write(replacement)
                replacement_identity = inode_identity(os.fstat(replacement_file.fileno()))

        replacement_request = InstallRequest(str(source), str(destination), "replacement-race.sqsh", digest, len(content))
        require_os_error(
            replacement_request,
            InstallTestHooks(before_publish=replace_before_publish, backend=TEST_BACKEND),
            errno.EEXIST,
        )
        replacement_final = destination / replacement_request.destination_name
        require(replacement_identity is not None, "replacement race did not create the competing inode")
        require(replacement_final.read_bytes() == replacement, "replacement race changed competing bytes")
        require(inode_identity(replacement_final.stat()) == replacement_identity, "replacement race replaced the competing inode")
        expected_entries.add(replacement_request.destination_name)
        require_terminal_entries(destination, frozenset(expected_entries), "replacement race")
        failure_identity: tuple[int, int] | None = None

        def replace_before_failure(directory_fd: int, final_name: str) -> None:
            nonlocal failure_identity
            with os.fdopen(
                os.open(final_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd),
                "wb",
            ) as replacement_file:
                replacement_file.write(replacement)
                failure_identity = inode_identity(os.fstat(replacement_file.fileno()))
            raise OSError(errno.EIO, "forced prelink failure")

        failure_request = InstallRequest(str(source), str(destination), "prepublish-failure.sqsh", digest, len(content))
        require_os_error(
            failure_request,
            InstallTestHooks(before_publish=replace_before_failure, backend=TEST_BACKEND),
            errno.EIO,
        )
        failure_final = destination / failure_request.destination_name
        require(failure_identity is not None and inode_identity(failure_final.stat()) == failure_identity, "prepublish failure replaced its competing inode")
        require(failure_final.read_bytes() == replacement, "prepublish failure changed competing bytes")
        expected_entries.add(failure_request.destination_name)
        require_terminal_entries(destination, frozenset(expected_entries), "prepublish failure")
        unsupported_tmpfile = InstallRequest(str(source), str(destination), "unsupported-tmpfile.sqsh", digest, len(content))
        require_install_error(
            unsupported_tmpfile,
            InstallTestHooks(backend=TEST_BACKEND, unsupported_tmpfile=True),
            "setup unsupported: anonymous destination inode unavailable",
        )
        require_terminal_entries(destination, frozenset(expected_entries), "unsupported O_TMPFILE")
        unsupported_linkat = InstallRequest(str(source), str(destination), "unsupported-linkat.sqsh", digest, len(content))
        require_install_error(
            unsupported_linkat,
            InstallTestHooks(backend=TEST_BACKEND, unsupported_linkat=True),
            "setup unsupported: linkat AT_EMPTY_PATH unavailable",
        )
        require_terminal_entries(destination, frozenset(expected_entries), "unsupported linkat")
        platform_request = InstallRequest(str(source), str(destination), "platform-link.sqsh", digest, len(content))
        if sys.platform.startswith("linux"):
            install(platform_request)
            platform_final = destination / platform_request.destination_name
            require(platform_final.read_bytes() == content, "Linux anonymous publication failed")
            require(stat.S_IMODE(platform_final.stat().st_mode) == 0o644, "Linux anonymous publication mode mismatch")
            expected_entries.add(platform_request.destination_name)
            require_terminal_entries(destination, frozenset(expected_entries), "Linux anonymous publication")
        else:
            require_install_error(platform_request, None, "setup unsupported: anonymous destination inode requires Linux")
            require_terminal_entries(destination, frozenset(expected_entries), "unsupported platform")
            print(f"SETUP-UNSUPPORTED:anonymous-publication: platform={sys.platform}")
        for point in CrashPoint:
            crash_directory = root / f"crash-{point}"
            crash_directory.mkdir()
            crash_request = InstallRequest(str(source), str(crash_directory), "image.sqsh", digest, len(content))
            run_crash(crash_request, point)
            assert_crash_state(crash_request, point)
    platform_case = ",linux-anonymous-publication" if sys.platform.startswith("linux") else ""
    summary = (
        "core-drift-rejected,linkat-backend-drift-rejected,source-replacement,happy-publication,final-collision-no-clobber,digest-mismatch,size-mismatch,symlink-source,symlink-destination,noncanonical-path,replacement-race-preserved,"
        f"prepublish-failure-preserved,unsupported-tmpfile,unsupported-linkat,crash-incomplete,crash-verified,crash-linked,rerun-final-eexist-linked,crash-final,rerun-final-eexist-final{platform_case}"
    )
    print("validated SQSH installer self-test passed: " + summary)
