"""`chapar image preflight`: fail-closed image host checks per role.

Modes map to the three host roles of the image pipeline: `build` (a builder
producing a candidate .sqsh), `runtime` (a validator running the sealed
candidate under Slurm/Pyxis), and `publisher` (the identity sealing a validated
candidate into the durable image root). Identity (software set, target, base
container) comes from the release directory when given, otherwise from the
site-settings environment (CHAPAR_SOFTWARE_SET, CHAPAR_TARGET,
CHAPAR_CONTAINER_BASE exported by etc/chapar-defaults.sh).

The site settings file itself is one of the checked hosts' inputs: it is read
with the same O_NOFOLLOW/ownership/mode posture the retired site-contract
installer enforced, so a symlinked, non-root-owned, or group/world-writable
settings file fails the host, never silently configures it.

Test-mode knobs (VLAD_PREFLIGHT_TEST_*) confine every probe and override to an
owner-only test root so the suite can exercise the fail-closed paths without a
privileged host. Stdlib only.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Final

from chapar.common.jsonio import ChaparError, fail
from chapar.common.release import Release, verify_release
from chapar.image.registry import (
    default_registry_dir,
    parse_containers,
    parse_sources,
    parse_targets,
    require_complete_lock,
)

PUBLIC_ROOTS: Final = (Path("/resources"), Path("/shared"), Path("/etc"))
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
# Minimum CPUID/ELF x86-64 psABI level each x86 target may run on. The generic
# target deliberately stays at the portable baseline; the v4 target requires
# AVX-512F/BW/CD/DQ/VL evidence from both the CPU and the built binaries.
X86_ISA_LEVEL: Final = {
    "linux-x86_64-generic": "x86-64-v1",
    "linux-x86_64-v4": "x86-64-v4",
}
# Pinned builder toolchain per target. Every target uses the enroot-only path
# (enroot import/create/start/export) that `chapar image build` implements --
# none of them need a Docker daemon on the builder.
BUILD_TOOLS: Final = {
    "linux-x86_64-generic": ("enroot", "squashfs-tools", "zstd", "syft", "jq", "skopeo"),
    "linux-x86_64-v4": ("enroot", "squashfs-tools", "zstd", "syft", "jq", "skopeo"),
    "linux-aarch64-generic": ("enroot", "squashfs-tools", "zstd", "syft", "jq", "skopeo"),
    "linux-aarch64-gb300": ("enroot", "squashfs-tools", "zstd", "syft", "jq", "skopeo"),
}
ROLE_BY_MODE: Final = {"build": "builder", "runtime": "validator", "publisher": "publisher"}
# The aarch64 targets are NVIDIA GPU targets, so both declare gpu/infiniband/
# network. A declared-but-absent feature is a skip (exit 77), never a pass, so
# listing them is what keeps an unaccelerated node from reporting success.
RUNTIME_FEATURES: Final = {
    "linux-x86_64-generic": ("physical_x86_64_v1", "pmix", "pyxis", "munge", "shared_image"),
    "linux-x86_64-v4": ("physical_x86_64_v4", "pmix", "pyxis", "munge", "shared_image"),
    "linux-aarch64-generic": ("pmix", "pyxis", "munge", "gpu", "infiniband", "network", "shared_image"),
    "linux-aarch64-gb300": ("gb300", "pmix", "pyxis", "munge", "gpu", "infiniband", "network", "shared_image"),
}
RUNTIME_DIAGNOSTICS: Final = {
    "linux-x86_64-generic": ("pmix_plugins", "pyxis_flags", "munge_domain", "network_expectation", "lscpu", "cpuid_isa_level", "elf_isa_level"),
    "linux-x86_64-v4": ("pmix_plugins", "pyxis_flags", "munge_domain", "network_expectation", "lscpu", "cpuid_isa_level", "elf_isa_level"),
    "linux-aarch64-generic": ("pmix_plugins", "pyxis_flags", "munge_domain", "driver_version", "gpu_topology", "infiniband_devices", "network_expectation"),
    "linux-aarch64-gb300": ("pmix_plugins", "pyxis_flags", "munge_domain", "driver_version", "gpu_topology", "infiniband_devices", "network_expectation"),
}
ALLOWED_TEST_VARIABLES: Final = frozenset(
    {
        "VLAD_PREFLIGHT_TEST_MODE",
        "VLAD_PREFLIGHT_TEST_ROOT",
        "VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER",
        "VLAD_PREFLIGHT_TEST_CONTRACT_UID",
        "VLAD_PREFLIGHT_TEST_SOURCES_LOCK",
        "VLAD_PREFLIGHT_TEST_TARGETS",
        "VLAD_PREFLIGHT_TEST_CONTAINERS",
        "VLAD_PREFLIGHT_TEST_UNAME_M",
        "VLAD_PREFLIGHT_TEST_MACHINE_ID",
        "VLAD_PREFLIGHT_TEST_BOOT_ID",
        "VLAD_PREFLIGHT_TEST_INVENTORY",
        "VLAD_PREFLIGHT_TEST_FILESYSTEMS",
        "VLAD_PREFLIGHT_TEST_TOOL_DIR",
        "VLAD_PREFLIGHT_TEST_FREE_BYTES",
    }
)


class OptionalRuntimeFeatureMissing(Exception):
    """A declared runtime hardware feature is absent: skip (77), never pass."""


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(payload: bytes, label: str) -> dict[str, Any]:
    try:
        loaded = json.loads(payload, object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read valid {label} JSON: {error}")
    if not isinstance(loaded, dict):
        fail(f"{label} must be a JSON object")
    return loaded


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        return load_json_bytes(path.read_bytes(), label)
    except OSError as error:
        fail(f"cannot read valid {label} JSON: {path}: {error}")


def under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def validate_absolute_path(raw: str, label: str) -> Path:
    if not raw or any(ord(character) < 32 for character in raw):
        fail(f"{label} is empty or contains control characters")
    path = Path(raw)
    if not path.is_absolute() or path != Path(os.path.normpath(raw)) or ".." in path.parts:
        fail(f"{label} must be a normalized absolute path")
    return path


def repo_root() -> Path:
    return default_registry_dir().parents[1]


def validate_not_workspace(path: Path, label: str) -> None:
    candidates = [repo_root()]
    for name in ("GITHUB_WORKSPACE", "RUNNER_WORKSPACE"):
        value = os.environ.get(name)
        if value:
            candidates.append(Path(value).resolve())
    resolved = path.resolve(strict=False)
    if any(under(resolved, candidate.resolve()) for candidate in candidates):
        fail(f"{label} cannot be under a CI workspace or source checkout")


def validate_test_root(raw: str | None) -> Path:
    if raw is None:
        fail("test mode requires VLAD_PREFLIGHT_TEST_ROOT")
    root = validate_absolute_path(raw, "test root")
    try:
        root_stat = root.lstat()
    except OSError as error:
        fail(f"cannot stat test root: {error}")
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        fail("test root must be a real directory")
    if root_stat.st_uid != os.geteuid() or stat.S_IMODE(root_stat.st_mode) & 0o077:
        fail("test root must be owner-only and owned by the test identity")
    if stat.S_IMODE(root_stat.st_mode) & 0o700 != 0o700:
        fail("test root must grant owner read/write/search access")
    if root.resolve() != root:
        fail("test root cannot contain symlink components")
    if any(under(root, public_root) for public_root in PUBLIC_ROOTS) or under(root, repo_root()):
        fail("test root cannot be public or workspace-local")
    return root


def validate_test_path(path: Path, label: str, test_root: Path | None) -> Path:
    if test_root is None:
        fail(f"test override without a test root: {label}")
    resolved = path.resolve(strict=False)
    if path != Path(os.path.normpath(str(path))) or resolved == test_root or not under(resolved, test_root):
        fail(f"test override escapes the protected test root: {label}")
    return resolved


def read_secure_site_settings(path: Path, expected_uid: int, test_mode: bool) -> bytes:
    """Single O_NOFOLLOW read of the installed site settings file.

    The settings file configures every consumer on the host, so it gets the
    same posture the retired site-contract installer enforced: a regular,
    root-owned (or, in test mode, fixture-owned) file at mode 0644 or stricter,
    reachable only through root-owned, non-group/world-writable directories,
    and unchanged between stat and open.
    """
    try:
        file_stat = path.lstat()
    except OSError as error:
        fail(f"cannot stat site settings: {error}")
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        fail("site settings must be a regular file and not a symlink")
    if file_stat.st_uid != expected_uid:
        fail("site settings must be root-owned")
    file_mode = stat.S_IMODE(file_stat.st_mode)
    if file_mode & ~0o644 or not file_mode & stat.S_IRUSR:
        fail("site settings mode must be 0644 or stricter")
    current = path.parent
    allowed_parent_uids = {0, expected_uid} if test_mode else {0}
    while True:
        try:
            parent_stat = current.lstat()
        except OSError as error:
            fail(f"cannot stat site settings parent {current}: {error}")
        if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
            fail(f"site settings parent is not a real directory: {current}")
        if parent_stat.st_uid not in allowed_parent_uids:
            fail(f"site settings parent is not root-owned: {current}")
        if stat.S_IMODE(parent_stat.st_mode) & 0o022:
            fail(f"site settings parent is group/world writable: {current}")
        if current == current.parent:
            break
        current = current.parent
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        opened_stat = os.fstat(descriptor)
        if (opened_stat.st_dev, opened_stat.st_ino, opened_stat.st_uid, stat.S_IMODE(opened_stat.st_mode)) != (
            file_stat.st_dev,
            file_stat.st_ino,
            file_stat.st_uid,
            file_mode,
        ):
            fail("site settings changed while they were being opened")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            return stream.read()
    except OSError as error:
        fail(f"cannot securely open site settings: {error}")


def read_regular_once(path: Path, label: str) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be absolute without traversal")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_flags = flags | getattr(os, "O_DIRECTORY", 0)
    try:
        directory = os.open(path.anchor, directory_flags)
        try:
            for component in path.parts[1:-1]:
                child = os.open(component, directory_flags, dir_fd=directory)
                os.close(directory)
                directory = child
            descriptor = os.open(path.name, flags, dir_fd=directory)
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    fail(f"{label} must be a regular file")
                return stream.read()
        finally:
            os.close(directory)
    except OSError as error:
        fail(f"cannot securely read {label}: {error}")


def command_path(name: str, test_mode: bool) -> str | None:
    if test_mode:
        directory = os.environ.get("VLAD_PREFLIGHT_TEST_TOOL_DIR")
        root = os.environ.get("VLAD_PREFLIGHT_TEST_ROOT")
        if not directory or not root:
            return None
        candidate = Path(directory) / name
        resolved = candidate.resolve(strict=False)
        if not under(resolved, Path(root).resolve()) or not os.access(candidate, os.X_OK):
            return None
        return str(resolved)
    return shutil.which(name)


def run_probe(command: list[str], timeout_seconds: int) -> str:
    try:
        completed = subprocess.run(command, check=False, text=True, capture_output=True, timeout=timeout_seconds)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"capability probe failed or timed out: {command[0]}: {error}")
    if completed.returncode != 0:
        fail(f"capability probe failed: {command[0]} (exit {completed.returncode})")
    return completed.stdout


def verify_pinned_tools(
    source_lock: dict[str, Any],
    identities: tuple[str, ...],
    native_arch: str,
    test_mode: bool,
    timeout_seconds: int,
) -> dict[str, str]:
    try:
        entries = source_lock["verified"]["builder_tools"]
        by_id = {entry["id"]: entry for entry in entries}
    except (KeyError, TypeError) as error:
        fail(f"source lock builder_tools are missing or malformed: {error}")
    commands: dict[str, str] = {}
    version_commands = {
        "enroot": lambda found: [found["enroot"], "version"],
        "squashfs-tools": lambda found: [found["mksquashfs"], "-version"],
        "zstd": lambda found: [found["zstd"], "--version"],
        "syft": lambda found: [found["syft"], "version"],
        "jq": lambda found: [found["jq"], "--version"],
        "skopeo": lambda found: [found["skopeo"], "--version"],
    }
    for identity in identities:
        try:
            entry = by_id[identity]
            pinned = {binary["name"]: binary["sha256"] for binary in entry["assets"][native_arch]["binaries"]}
        except (KeyError, TypeError):
            fail(f"source lock does not pin builder tool: {identity}/{native_arch}")
        found: dict[str, str] = {}
        for name, expected_sha256 in pinned.items():
            path = command_path(name, test_mode)
            if path is None:
                fail(f"required pinned tool binary is missing: {identity}/{name}")
            try:
                actual_sha256 = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            except OSError as error:
                fail(f"cannot hash pinned tool binary {identity}/{name}: {error}")
            if actual_sha256 != expected_sha256:
                fail(f"pinned tool binary checksum mismatch: {identity}/{name}")
            found[name] = path
            commands[name] = path
        version_output = run_probe(version_commands[identity](found), timeout_seconds)
        version_pattern = re.compile(rf"(?<![A-Za-z0-9.+:~_-]){re.escape(entry['version'])}(?![A-Za-z0-9.+:~_-])")
        if version_pattern.search(version_output) is None:
            fail(f"pinned tool version mismatch: {identity}")
    return commands


def require_tools(names: tuple[str, ...], test_mode: bool) -> dict[str, str]:
    found: dict[str, str] = {}
    for name in names:
        path = command_path(name, test_mode)
        if path is None:
            fail(f"required tool is missing: {name}")
        found[name] = path
    if command_path("sha256sum", test_mode) is None and command_path("shasum", test_mode) is None:
        fail("required SHA-256 tool is missing: sha256sum or shasum")
    return found


def load_inventory(test_mode: bool, test_root: Path | None, timeout_seconds: int) -> dict[str, Any]:
    if test_mode:
        raw = os.environ.get("VLAD_PREFLIGHT_TEST_INVENTORY")
        if not raw:
            fail("test mode requires VLAD_PREFLIGHT_TEST_INVENTORY")
        path = validate_absolute_path(raw, "test inventory")
        validate_test_path(path, "test inventory", test_root)
        return load_json(path, "test inventory")
    sinfo = command_path("sinfo", False)
    if sinfo is None:
        fail("required tool is missing: sinfo")
    try:
        loaded = json.loads(run_probe([sinfo, "--json"], timeout_seconds), object_pairs_hook=unique_object)
    except json.JSONDecodeError as error:
        fail(f"live Slurm inventory is not valid JSON: {error}")
    if not isinstance(loaded, dict):
        fail("live Slurm inventory must be a JSON object")
    return loaded


def inventory_has_pair(inventory: dict[str, Any], partition: str, constraint: str) -> bool:
    partitions = inventory.get("partitions")
    if not isinstance(partitions, list):
        fail("Slurm inventory does not contain a partitions array")
    for entry in partitions:
        if not isinstance(entry, dict):
            continue
        name = entry.get("partition") or entry.get("name") or entry.get("partition_name")
        constraints = entry.get("constraints", entry.get("features", []))
        if isinstance(constraints, str):
            constraints = [item for item in re.split(r"[,+]", constraints) if item]
        if (
            name == partition
            and isinstance(constraints, list)
            and constraint in constraints
            and entry.get("available", True) is not False
        ):
            return True
    nodes = inventory.get("nodes", [])
    if isinstance(nodes, list):
        for entry in nodes:
            if not isinstance(entry, dict):
                continue
            node_partitions = entry.get("partitions", entry.get("partition", []))
            features = entry.get("active_features", entry.get("features", []))
            if isinstance(node_partitions, str):
                node_partitions = [item for item in node_partitions.split(",") if item]
            if isinstance(features, str):
                features = [item for item in features.split(",") if item]
            if partition in node_partitions and constraint in features and entry.get("state", "") not in {"DOWN", "DRAIN"}:
                return True
    return False


def filesystem_record(path: Path, test_mode: bool, test_root: Path | None, timeout_seconds: int) -> dict[str, Any]:
    if test_mode:
        raw = os.environ.get("VLAD_PREFLIGHT_TEST_FILESYSTEMS")
        if not raw:
            fail("test mode requires VLAD_PREFLIGHT_TEST_FILESYSTEMS")
        inventory_path = validate_absolute_path(raw, "test filesystem inventory")
        validate_test_path(inventory_path, "test filesystem inventory", test_root)
        records = load_json(inventory_path, "test filesystem inventory").get("paths")
        if not isinstance(records, dict):
            fail("test filesystem inventory requires a paths object")
        matches = [(Path(prefix), value) for prefix, value in records.items() if path == Path(prefix) or under(path, Path(prefix))]
        if not matches:
            fail(f"test filesystem inventory has no record for path: {path}")
        record = max(matches, key=lambda item: len(item[0].parts))[1]
        if not isinstance(record, dict):
            fail(f"invalid test filesystem record for path: {path}")
        return record
    findmnt = command_path("findmnt", False)
    if findmnt is None:
        fail("required tool is missing: findmnt")
    try:
        document = json.loads(run_probe([findmnt, "-J", "-T", str(path), "-o", "FSTYPE,MAJ:MIN,TARGET"], timeout_seconds))
        filesystems = document["filesystems"]
        record = filesystems[0]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
        fail(f"cannot inspect filesystem for {path}: {error}")
    return {"fstype": record.get("fstype"), "device": record.get("maj:min"), "acl_ok": True}


def require_nfs(path: Path, test_mode: bool, test_root: Path | None, timeout_seconds: int) -> dict[str, Any]:
    record = filesystem_record(path, test_mode, test_root, timeout_seconds)
    if record.get("fstype") not in {"nfs", "nfs4"}:
        fail(f"path is not on NFS: {path}")
    return record


def require_directory(path: Path, label: str, writable: bool | None = None) -> None:
    current = path
    while True:
        try:
            component_stat = current.lstat()
        except OSError as error:
            fail(f"{label} contains a missing or inaccessible component: {current}: {error}")
        if stat.S_ISLNK(component_stat.st_mode):
            fail(f"{label} cannot contain a symlink component: {current}")
        if current == current.parent:
            break
        current = current.parent
    if not path.is_dir():
        fail(f"{label} must be an existing directory: {path}")
    if not os.access(path, os.R_OK | os.X_OK):
        fail(f"{label} is not readable/searchable: {path}")
    if writable is True and not os.access(path, os.W_OK | os.X_OK):
        fail(f"{label} is not writable: {path}")
    if writable is False and os.access(path, os.W_OK):
        fail(f"{label} must not be writable by this role: {path}")


def validate_publisher_directory(
    path: Path, label: str, record: dict[str, Any], test_mode: bool, tool: str, timeout_seconds: int
) -> None:
    path_stat = path.stat()
    if path_stat.st_uid != os.geteuid():
        fail(f"{label} is not owned by the publisher identity: {path}")
    mode = stat.S_IMODE(path_stat.st_mode)
    if mode & 0o022 or mode & (stat.S_ISUID | stat.S_ISGID):
        fail(f"{label} has an unsafe mode: {path}")
    if test_mode:
        raw_acl = record.get("acl")
        if not isinstance(raw_acl, list) or not all(isinstance(line, str) for line in raw_acl):
            fail(f"{label} test ACL inventory is missing or malformed")
        acl_lines = raw_acl
    else:
        acl_lines = run_probe([tool, "-cp", str(path)], timeout_seconds).splitlines()
    for raw_line in acl_lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("default:"):
            default_permissions = line.rsplit(":", 1)[-1].split()
            if not default_permissions:
                fail(f"{label} ACL contains a malformed default entry: {path}")
            if "w" in default_permissions[0]:
                fail(f"{label} default ACL grants write authority: {path}")
            continue
        fields = line.split(":", 2)
        if len(fields) != 3 or fields[0] not in {"user", "group", "mask", "other"}:
            fail(f"{label} ACL contains an unrecognized entry: {path}")
        permission_fields = fields[2].split("#effective:", 1)[-1].strip().split()
        if not permission_fields:
            fail(f"{label} ACL contains an empty permission set: {path}")
        permissions = permission_fields[0]
        if re.fullmatch(r"[r-][w-][x-]", permissions) is None:
            fail(f"{label} ACL contains malformed permissions: {path}")
        named_user = fields[0] == "user" and fields[1] != ""
        group_entry = fields[0] == "group"
        world_entry = fields[0] == "other"
        if "w" in permissions and (named_user or group_entry or world_entry):
            fail(f"{label} ACL grants non-owner write authority: {path}")


def probe_publisher_durability(path: Path, record: dict[str, Any], test_mode: bool) -> None:
    if test_mode and record.get("fsync_ok") is not True:
        fail("publisher filesystem fixture reports fsync/rename failure")
    token = uuid.uuid4().hex
    source_name = f".preflight-fsync.{token}.tmp"
    renamed_name = f".preflight-fsync.{token}.renamed"
    directory_fd = -1
    failure: OSError | None = None
    try:
        directory_fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0))
        file_fd = os.open(source_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600, dir_fd=directory_fd)
        try:
            os.write(file_fd, b"vlad-publisher-fsync-probe\n")
            os.fsync(file_fd)
        finally:
            os.close(file_fd)
        os.rename(source_name, renamed_name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        if test_mode and record.get("fsync_fail_at") == "after-rename":
            raise OSError(errno.EIO, "injected durability probe failure after rename")
        os.fsync(directory_fd)
        verify_fd = os.open(renamed_name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        try:
            if os.read(verify_fd, 64) != b"vlad-publisher-fsync-probe\n":
                fail("publisher durability probe readback mismatch")
        finally:
            os.close(verify_fd)
        os.unlink(renamed_name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as error:
        failure = error
    finally:
        if directory_fd >= 0:
            for name in (source_name, renamed_name):
                try:
                    os.unlink(name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                except OSError as error:
                    failure = failure or error
            try:
                os.fsync(directory_fd)
            except OSError as error:
                failure = failure or error
            os.close(directory_fd)
    if failure is not None:
        fail(f"publisher filesystem does not support clean file/directory fsync and rename: {failure}")


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        fail(f"{name} is not set; source etc/chapar-defaults.sh or export it")
    return value


def _identity(arguments: argparse.Namespace, targets_path: Path) -> tuple[str, str, Release | None]:
    """(software_set, target, release) from --release-dir or the environment."""
    if arguments.release_dir:
        release_dir = validate_absolute_path(arguments.release_dir, "release dir")
        release = verify_release(release_dir, targets_registry=targets_path)
        if arguments.target and arguments.target != release.target:
            fail(f"--target does not match the release target: {arguments.target} != {release.target}")
        return release.software_set, release.target, release
    target = arguments.target or _required_env("CHAPAR_TARGET")
    software_set = _required_env("CHAPAR_SOFTWARE_SET")
    return software_set, target, None


def run_preflight(arguments: argparse.Namespace) -> int:
    try:
        return _run_preflight(arguments)
    except OptionalRuntimeFeatureMissing as error:
        print(f"preflight skip: {error}", file=sys.stderr)
        return 77
    except (ValueError, TypeError, UnicodeError, KeyError, IndexError) as error:
        # Untrusted inputs must fail closed rather than surface a traceback.
        raise ChaparError(f"preflight failed: {error!r}") from error


def _run_preflight(arguments: argparse.Namespace) -> int:
    test_mode = os.environ.get("VLAD_PREFLIGHT_TEST_MODE") == "1"
    test_root = validate_test_root(os.environ.get("VLAD_PREFLIGHT_TEST_ROOT")) if test_mode else None
    if test_mode:
        unknown_test_variables = sorted(
            name for name in os.environ if name.startswith("VLAD_PREFLIGHT_TEST_") and name not in ALLOWED_TEST_VARIABLES
        )
        if unknown_test_variables:
            fail("unknown preflight test override: " + ",".join(unknown_test_variables))
        marker_raw = os.environ.get("VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        if marker_raw is None:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        validate_test_path(validate_absolute_path(marker_raw, "test side-effect marker"), "test side-effect marker", test_root)
    if not ID_RE.fullmatch(arguments.image_id):
        fail("image ID must be a lowercase simple identifier")
    if arguments.sha256 is not None and SHA256_RE.fullmatch(arguments.sha256) is None:
        fail("--sha256 must be a full lowercase SHA-256")
    if arguments.mode in {"runtime", "publisher"} and arguments.sha256 is None:
        fail(f"--sha256 is required in {arguments.mode} mode")

    # --- installed site settings ---------------------------------------------
    site_raw = os.environ.get("CHAPAR_SITE_CONFIG") or str(repo_root() / "etc/chapar-site.env")
    site_path = validate_absolute_path(site_raw, "site settings")
    expected_uid = int(os.environ.get("VLAD_PREFLIGHT_TEST_CONTRACT_UID", "0")) if test_mode else 0
    if test_mode:
        validate_test_path(site_path, "site settings", test_root)
    site_bytes = read_secure_site_settings(site_path, expected_uid, test_mode)
    site_sha256 = hashlib.sha256(site_bytes).hexdigest()

    # --- registries ------------------------------------------------------------
    registry_dir = Path(arguments.registry_dir).resolve() if arguments.registry_dir else default_registry_dir()
    targets_path = registry_dir / "targets.json"
    containers_path = registry_dir / "containers.json"
    sources_path = registry_dir / "sources-lock.json"
    if test_mode:
        target_override = os.environ.get("VLAD_PREFLIGHT_TEST_TARGETS")
        container_override = os.environ.get("VLAD_PREFLIGHT_TEST_CONTAINERS")
        source_override = os.environ.get("VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        if target_override:
            targets_path = validate_test_path(validate_absolute_path(target_override, "test target registry"), "test target registry", test_root)
        if container_override:
            containers_path = validate_test_path(validate_absolute_path(container_override, "test container registry"), "test container registry", test_root)
        if not source_override:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        sources_path = validate_test_path(validate_absolute_path(source_override, "test source lock"), "test source lock", test_root)

        required_test_paths = () if arguments.plan_only else (
            ("VLAD_PREFLIGHT_TEST_BOOT_ID", "test boot ID"),
            ("VLAD_PREFLIGHT_TEST_INVENTORY", "test inventory"),
            ("VLAD_PREFLIGHT_TEST_FILESYSTEMS", "test filesystem inventory"),
            ("VLAD_PREFLIGHT_TEST_TOOL_DIR", "test tool directory"),
        )
        for variable, label in required_test_paths:
            value = os.environ.get(variable)
            if value is None:
                fail(f"test mode requires {variable}")
            validate_test_path(validate_absolute_path(value, label), label, test_root)

    targets_bytes = read_regular_once(targets_path, "target registry")
    containers_bytes = read_regular_once(containers_path, "container registry")
    source_bytes = read_regular_once(sources_path, "source lock")
    targets = parse_targets(targets_bytes)
    sources = parse_sources(source_bytes)
    containers = parse_containers(containers_bytes, targets, sources)

    software_set, target_id, release = _identity(arguments, targets_path)
    base_id = arguments.base or _required_env("CHAPAR_CONTAINER_BASE")

    timeout_seconds = int(os.environ.get("VLAD_PREFLIGHT_PROBE_TIMEOUT_SECONDS", "30"))
    if not 1 <= timeout_seconds <= 300:
        fail("probe timeout must be between 1 and 300 seconds")
    source_lock = load_json_bytes(source_bytes, "source lock")
    if arguments.plan_only:
        if source_lock.get("status") != "complete" or source_lock.get("unresolved"):
            fail("source lock is blocked or incomplete")
    else:
        require_complete_lock(source_lock)

    native_arch = os.environ.get("VLAD_PREFLIGHT_TEST_UNAME_M") if test_mode else os.uname().machine
    target_fact = targets.get(target_id)
    base_fact = containers.get(base_id)
    if target_fact is None or base_fact is None:
        fail("selected target or container is absent from the registries")
    if software_set not in base_fact.accepted_software_sets:
        fail(f"selected container does not accept software set: {software_set}")
    if target_id not in base_fact.allowed_targets:
        fail("selected container does not allow requested target")
    if native_arch != target_fact.native_arch:
        fail(f"native architecture mismatch: target requires {target_fact.native_arch}, host is {native_arch}")

    # --- site-derived paths ------------------------------------------------------
    namespace = Path(software_set) / target_id
    image_root = validate_absolute_path(_required_env("CHAPAR_CONTAINER_OUTPUT_ROOT"), "container output root") / namespace
    validation_root = validate_absolute_path(_required_env("CHAPAR_VALIDATION_ROOT"), "validation root") / namespace
    candidate_root = image_root / "staging"
    paths = {
        "candidate_root": candidate_root,
        "validation_root": validation_root,
        "image_root": image_root,
    }
    for label, path in paths.items():
        validate_not_workspace(path, label)
        if test_mode:
            validate_test_path(path, label, test_root)

    role = ROLE_BY_MODE[arguments.mode]
    if arguments.plan_only:
        print(
            json.dumps(
                {
                    "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-preflight-plan/v2",
                    "software_set": software_set,
                    "target": target_id,
                    "container": base_id,
                    "role": role,
                    "release_id": release.release_id if release else None,
                    "site_settings_sha256": site_sha256,
                    "paths": {key: str(value) for key, value in paths.items()},
                    "slurm": {
                        "partition": os.environ.get("CHAPAR_SLURM_PARTITION", ""),
                        "constraint": os.environ.get("CHAPAR_SLURM_CONSTRAINT", ""),
                    },
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0

    inventory = load_inventory(test_mode, test_root, timeout_seconds)
    partition = os.environ.get("CHAPAR_SLURM_PARTITION", "")
    constraint = os.environ.get("CHAPAR_SLURM_CONSTRAINT", "")
    if partition and constraint and not inventory_has_pair(inventory, partition, constraint):
        fail("site Slurm partition/constraint pair is absent from live Slurm inventory")

    qualified_candidate = candidate_root / arguments.image_id
    capabilities: dict[str, Any] = {}
    if arguments.mode == "build":
        tools = verify_pinned_tools(source_lock, BUILD_TOOLS[target_id], str(native_arch), test_mode, timeout_seconds)
        tools.update(require_tools(("python3",), test_mode))
        require_directory(qualified_candidate, "target/image-qualified candidate work root", writable=True)
        candidate_fs = require_nfs(qualified_candidate, test_mode, test_root, timeout_seconds)
        require_directory(image_root, "final image root", writable=False)
        minimum_free = int(os.environ.get("VLAD_IMAGE_MIN_FREE_BYTES", str(100 * 1024**3)))
        if minimum_free <= 0:
            fail("minimum free-space requirement must be positive")
        free_bytes = (
            int(os.environ.get("VLAD_PREFLIGHT_TEST_FREE_BYTES", str(shutil.disk_usage(qualified_candidate).free)))
            if test_mode
            else shutil.disk_usage(qualified_candidate).free
        )
        if free_bytes < minimum_free:
            fail("candidate work root has insufficient free space")
        if not test_mode:
            descriptor = source_lock["verified"][base_fact.source_lock_category]["platforms"][target_id]["descriptor_digest"]
            run_probe([tools["skopeo"], "inspect", f"docker://{base_fact.base_image}@{descriptor}"], timeout_seconds)
        capabilities = {"candidate_filesystem": candidate_fs.get("fstype"), "free_bytes": free_bytes, "required_tools": sorted(tools)}
    elif arguments.mode == "runtime":
        runtime_tools = ("srun", "enroot", "python3", "lscpu") if target_id in X86_ISA_LEVEL else ("srun", "enroot", "python3", "nvidia-smi")
        tools = require_tools(runtime_tools, test_mode)
        tools.update(verify_pinned_tools(source_lock, ("enroot",), str(native_arch), test_mode, timeout_seconds))
        sealed_candidate = qualified_candidate / arguments.sha256
        receipt_root = validation_root / arguments.image_id / arguments.sha256
        require_directory(sealed_candidate, "SHA-qualified sealed candidate", writable=False)
        require_directory(receipt_root, "run-scoped receipt root", writable=True)
        require_nfs(sealed_candidate, test_mode, test_root, timeout_seconds)
        runtime = inventory.get("runtime")
        if not isinstance(runtime, dict):
            fail("live inventory does not contain runtime capability data")
        diagnostics: dict[str, Any] = {}
        for key in RUNTIME_DIAGNOSTICS[target_id]:
            value = runtime.get(key)
            if not isinstance(value, (str, list)) or value in ("", []):
                fail(f"live runtime inventory is missing diagnostic: {key}")
            if isinstance(value, list) and not all(isinstance(item, str) and item for item in value):
                fail(f"live runtime inventory diagnostic is malformed: {key}")
            diagnostics[key] = value
        expected_isa = X86_ISA_LEVEL.get(target_id)
        if expected_isa is not None and (
            diagnostics["cpuid_isa_level"] != expected_isa or diagnostics["elf_isa_level"] != expected_isa
        ):
            fail(f"{target_id} runtime requires physical CPUID and ELF {expected_isa} evidence")
        missing = [feature for feature in RUNTIME_FEATURES[target_id] if runtime.get(feature) is not True]
        if missing:
            raise OptionalRuntimeFeatureMissing("absent declared runtime hardware/features: " + ",".join(missing))
        capabilities = {
            "required_tools": sorted(tools),
            "runtime_features": sorted(RUNTIME_FEATURES[target_id]),
            "runtime_inventory": diagnostics,
        }
    else:
        tools = require_tools(("python3", "getfacl"), test_mode)
        sealed_candidate = qualified_candidate / arguments.sha256
        receipts = validation_root / arguments.image_id / arguments.sha256
        releases = image_root / "releases"
        require_directory(sealed_candidate, "SHA-qualified sealed candidate", writable=False)
        require_directory(receipts, "validation receipt root", writable=False)
        require_directory(image_root, "selected final image root", writable=True)
        require_directory(releases, "selected final releases root", writable=True)
        candidate_fs = require_nfs(sealed_candidate, test_mode, test_root, timeout_seconds)
        validation_fs = require_nfs(receipts, test_mode, test_root, timeout_seconds)
        image_fs = require_nfs(image_root, test_mode, test_root, timeout_seconds)
        releases_fs = require_nfs(releases, test_mode, test_root, timeout_seconds)
        if image_fs.get("device") != releases_fs.get("device"):
            fail("publisher staging and release roots are not on the same filesystem")
        validate_publisher_directory(image_root, "selected final image root", image_fs, test_mode, tools["getfacl"], timeout_seconds)
        validate_publisher_directory(releases, "selected final releases root", releases_fs, test_mode, tools["getfacl"], timeout_seconds)
        probe_publisher_durability(releases, releases_fs, test_mode)
        capabilities = {
            "candidate_filesystem": candidate_fs.get("fstype"),
            "validation_filesystem": validation_fs.get("fstype"),
            "image_filesystem": image_fs.get("fstype"),
            "required_tools": sorted(tools),
        }

    boot_id_path = Path(os.environ.get("VLAD_PREFLIGHT_TEST_BOOT_ID", "/proc/sys/kernel/random/boot_id")) if test_mode else Path("/proc/sys/kernel/random/boot_id")
    try:
        boot_id = boot_id_path.read_text(encoding="ascii").strip()
    except OSError:
        boot_id = "unavailable"
    evidence = {
        "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-preflight-evidence/v2",
        "schema_version": 2,
        "status": "pass",
        "mode": arguments.mode,
        "software_set": software_set,
        "target": target_id,
        "container": base_id,
        "image_id": arguments.image_id,
        "image_sha256": arguments.sha256,
        "native_arch": native_arch,
        "role": role,
        "hostname_diagnostic": socket.gethostname(),
        "boot_id_diagnostic": boot_id,
        "site_settings_sha256": site_sha256,
        "release_id": release.release_id if release else None,
        "release_lock_sha256": release.lock_sha256 if release else None,
        "slurm": {"partition": partition, "constraint": constraint},
        "paths": {key: str(value) for key, value in paths.items()},
        "capabilities": capabilities,
    }
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    return 0
