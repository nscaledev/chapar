#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="${SCRIPT_DIR}" exec python3 - "${SCRIPT_DIR}" "$@" <<'PY'
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Final

SCRIPT_DIR = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]
from registry import RegistryError, parse_containers, parse_sources, parse_targets
from selection_contract import SelectionError, validate_selection

TARGETS_PATH = SCRIPT_DIR / "targets.json"
CONTAINERS_PATH = SCRIPT_DIR / "containers.json"
SOURCES_PATH = SCRIPT_DIR / "sources-lock.json"
LOCK_VALIDATOR = SCRIPT_DIR / "tests" / "validate-locks.sh"
TARGET_CONTRACT_SCHEMA = "https://nscaledev.github.io/chapar/schemas/target-contract/v1"
PUBLIC_ROOTS = (Path("/resources"), Path("/shared"), Path("/etc"))
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
DIGEST_RE: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE: Final = re.compile(r"^[0-9a-f]{40}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
TOKEN_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
CONSTRAINT_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.&|!()+:-]{0,127}$")
# Minimum CPUID/ELF x86-64 psABI level each x86 target may run on. The generic
# target deliberately stays at the portable baseline; the v4 target requires
# AVX-512F/BW/CD/DQ/VL evidence from both the CPU and the built binaries.
X86_ISA_LEVEL: Final = {
    "linux-x86_64-generic": "x86-64-v1",
    "linux-x86_64-v4": "x86-64-v4",
}
# Pinned builder toolchain per target. Every target uses the enroot-only path
# that fleet-manager's images/build.sh uses (enroot import/create/start/
# export) and that build-image.sh implements -- none of them need a Docker
# daemon on the builder.
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


class PreflightError(Exception):
    pass


class OptionalRuntimeFeatureMissing(PreflightError):
    pass


def fail(message: str) -> None:
    raise PreflightError(message)


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


def validate_not_workspace(path: Path, label: str) -> None:
    candidates = [SCRIPT_DIR.parents[3]]
    for name in ("GITHUB_WORKSPACE", "RUNNER_WORKSPACE"):
        value = os.environ.get(name)
        if value:
            candidates.append(Path(value).resolve())
    resolved = path.resolve(strict=False)
    if any(under(resolved, candidate.resolve()) for candidate in candidates):
        fail(f"{label} cannot be under an Actions workspace or source checkout")


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
    if any(under(root, public_root) for public_root in PUBLIC_ROOTS) or under(root, SCRIPT_DIR.parents[3]):
        fail("test root cannot be public or workspace-local")
    return root


def validate_test_path(path: Path, label: str, test_root: Path) -> Path:
    resolved = path.resolve(strict=False)
    if path != Path(os.path.normpath(str(path))) or resolved == test_root or not under(resolved, test_root):
        fail(f"test override escapes the protected test root: {label}")
    return resolved


def read_secure_contract(path: Path, expected_uid: int, test_mode: bool) -> bytes:
    try:
        file_stat = path.lstat()
    except OSError as error:
        fail(f"cannot stat site contract: {error}")
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        fail("site contract must be a regular file and not a symlink")
    if file_stat.st_uid != expected_uid:
        fail("site contract must be root-owned")
    file_mode = stat.S_IMODE(file_stat.st_mode)
    if file_mode & ~0o644 or not file_mode & stat.S_IRUSR:
        fail("site contract mode must be 0644 or stricter")
    current = path.parent
    allowed_parent_uids = {0, expected_uid} if test_mode else {0}
    while True:
        try:
            parent_stat = current.lstat()
        except OSError as error:
            fail(f"cannot stat site contract parent {current}: {error}")
        if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
            fail(f"site contract parent is not a real directory: {current}")
        if parent_stat.st_uid not in allowed_parent_uids:
            fail(f"site contract parent is not root-owned: {current}")
        if stat.S_IMODE(parent_stat.st_mode) & 0o022:
            fail(f"site contract parent is group/world writable: {current}")
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
            fail("site contract changed while it was being opened")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            return stream.read()
    except OSError as error:
        fail(f"cannot securely open site contract: {error}")


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


def validate_source_lock(payload: bytes, timeout_seconds: int) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="chapar-source-lock.") as directory:
        sealed = Path(directory) / "sources-lock.json"
        sealed.write_bytes(payload)
        sealed.chmod(0o400)
        environment = os.environ.copy()
        environment["SOURCES_PATH_OVERRIDE"] = str(sealed)
        try:
            completed = subprocess.run(
                ["bash", str(LOCK_VALIDATOR), "--require-complete"],
                check=False, text=True, capture_output=True,
                timeout=timeout_seconds, env=environment,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            fail(f"source-lock validator failed or timed out: {error}")
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()[-1] if completed.stderr.strip() else "closed source-lock validation failed"
        fail(f"source lock is blocked or invalid: {detail}")
    return load_json_bytes(payload, "source lock")


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


def verify_pinned_tools(source_lock: dict[str, Any], identities: tuple[str, ...], native_arch: str, test_mode: bool, timeout_seconds: int) -> dict[str, str]:
    entries = source_lock["verified"]["builder_tools"]
    by_id = {entry["id"]: entry for entry in entries}
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
        entry = by_id[identity]
        pinned = {binary["name"]: binary["sha256"] for binary in entry["assets"][native_arch]["binaries"]}
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


def run_probe(command: list[str], timeout_seconds: int) -> str:
    try:
        completed = subprocess.run(command, check=False, text=True, capture_output=True, timeout=timeout_seconds)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"capability probe failed or timed out: {command[0]}: {error}")
    if completed.returncode != 0:
        fail(f"capability probe failed: {command[0]} (exit {completed.returncode})")
    return completed.stdout


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
        if name == partition and isinstance(constraints, list) and constraint in constraints and entry.get("available", True) is not False:
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


def validate_publisher_directory(path: Path, label: str, record: dict[str, Any], test_mode: bool, tool: str, timeout_seconds: int) -> None:
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fail-closed native Vlad HPL image host preflight")
    parser.add_argument("--target", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--sha256")
    parser.add_argument("--selection", required=True)
    parser.add_argument("--selection-sha256", required=True)
    parser.add_argument("--target-contract", required=True)
    parser.add_argument("--target-contract-sha256", required=True)
    parser.add_argument("--mode", required=True, choices=("build", "runtime", "publisher"))
    parser.add_argument("--plan-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    test_mode = os.environ.get("VLAD_PREFLIGHT_TEST_MODE") == "1"
    test_root = validate_test_root(os.environ.get("VLAD_PREFLIGHT_TEST_ROOT")) if test_mode else None
    if test_mode:
        allowed_test_variables = {
            "VLAD_PREFLIGHT_TEST_MODE",
            "VLAD_PREFLIGHT_TEST_ROOT",
            "VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER",
            "VLAD_PREFLIGHT_TEST_CONTRACT_UID",
            "VLAD_PREFLIGHT_TEST_ROLE_IDENTITY",
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
            "VLAD_PREFLIGHT_TEST_SWAP_SELECTION",
            "VLAD_PREFLIGHT_TEST_SWAP_CONTRACT",
            "VLAD_PREFLIGHT_TEST_SWAP_SOURCE_LOCK",
            "VLAD_PREFLIGHT_TEST_SWAP_TARGETS",
            "VLAD_PREFLIGHT_TEST_SWAP_CONTAINERS",
        }
        unknown_test_variables = sorted(name for name in os.environ if name.startswith("VLAD_PREFLIGHT_TEST_") and name not in allowed_test_variables)
        if unknown_test_variables:
            fail("unknown preflight test override: " + ",".join(unknown_test_variables))
    if not ID_RE.fullmatch(args.image_id):
        fail("image ID must be a lowercase simple identifier")
    if args.sha256 is not None and SHA256_RE.fullmatch(args.sha256) is None:
        fail("--sha256 must be a full lowercase SHA-256")
    if args.mode in {"runtime", "publisher"} and args.sha256 is None:
        fail(f"--sha256 is required in {args.mode} mode")
    if SHA256_RE.fullmatch(args.selection_sha256) is None or SHA256_RE.fullmatch(args.target_contract_sha256) is None:
        fail("selection and target-contract digests must be full lowercase SHA-256 values")
    selection_path = validate_absolute_path(args.selection, "selection")
    target_contract_path = validate_absolute_path(args.target_contract, "target contract")
    expected_uid = int(os.environ.get("VLAD_PREFLIGHT_TEST_CONTRACT_UID", "0")) if test_mode else 0
    selection_bytes = read_secure_contract(selection_path, expected_uid, test_mode)
    contract_bytes = read_secure_contract(target_contract_path, expected_uid, test_mode)
    if hashlib.sha256(selection_bytes).hexdigest() != args.selection_sha256:
        fail("selection SHA-256 mismatch")
    if hashlib.sha256(contract_bytes).hexdigest() != args.target_contract_sha256:
        fail("target contract SHA-256 mismatch")
    if test_mode:
        for variable, destination in (
            ("VLAD_PREFLIGHT_TEST_SWAP_SELECTION", selection_path),
            ("VLAD_PREFLIGHT_TEST_SWAP_CONTRACT", target_contract_path),
        ):
            replacement = os.environ.get(variable)
            if replacement:
                replacement_path = validate_test_path(
                    validate_absolute_path(replacement, variable), variable, test_root
                )
                os.replace(replacement_path, destination)
    selection_document = load_json_bytes(selection_bytes, "selection")
    contract = load_json_bytes(contract_bytes, "target contract")
    selection = validate_selection(selection_document)
    contract_fields = {
        "schema", "schema_version", "datacenter_id", "status", "target",
        "allowed_software_sets", "container_selections", "paths", "slurm",
        "roles", "sharing", "publication", "provenance",
    }
    if set(contract) != contract_fields:
        fail("target contract contains missing or unknown top-level fields")
    if contract.get("schema") != TARGET_CONTRACT_SCHEMA or contract.get("schema_version") != 1:
        fail("target contract schema identity is unsupported")
    policy = selection.policy
    selection_paths = selection.paths
    authorities = selection.authorities
    roles = contract.get("roles")
    if not isinstance(roles, dict) or set(roles) != set(ROLE_BY_MODE.values()):
        fail("target contract roles must contain exactly builder, validator, and publisher")
    if any(not isinstance(value, str) or not value for value in roles.values()) or len(set(roles.values())) != len(roles):
        fail("target contract role identities must be distinct non-empty usernames")
    if policy.get("target") != args.target or args.base not in selection.containers:
        fail("selection does not bind requested target and container")
    if authorities.get("target_contract") != args.target_contract_sha256:
        fail("selection target-contract digest mismatch")
    if contract.get("datacenter_id") != policy.get("datacenter") or contract.get("target") != args.target:
        fail("target contract identity differs from selection")
    if policy.get("software_set") not in contract.get("allowed_software_sets", []):
        fail("target contract does not allow selected software set")
    selected = [item for item in contract.get("container_selections", []) if isinstance(item, dict) and item.get("software_set") == policy.get("software_set")]
    if len(selected) != 1 or selected[0].get("container") != args.base:
        fail("target contract does not select requested container")
    contract_paths = contract.get("paths")
    if not isinstance(contract_paths, dict):
        fail("target contract paths are missing")
    durable = contract_paths.get("durable_writable")
    temporary = contract_paths.get("temporary")
    if not isinstance(durable, dict) or not isinstance(temporary, dict):
        fail("target contract writable path roots are missing")
    namespace = Path(policy["datacenter"], policy["software_set"], policy["target"])
    release_id = selection.invocation["release_id"]
    run_id = selection.invocation["run_id"]
    expected_image_paths = {
        "candidate_root": Path(str(temporary.get("image_staging", ""))) / namespace / run_id,
        "validation_root": Path(str(durable.get("receipts", ""))) / namespace / release_id,
        "image_root": Path(str(durable.get("container_outputs", ""))) / namespace / release_id,
    }
    selected_image_paths = {
        "candidate_root": Path(selection_paths["image_staging"]),
        "validation_root": Path(selection_paths["receipts"]),
        "image_root": Path(selection_paths["container_outputs"]),
    }
    if selected_image_paths != expected_image_paths:
        fail("selection image paths differ from target contract")
    paths = {
        "candidate_root": validate_absolute_path(str(expected_image_paths["candidate_root"]), "candidate root"),
        "validation_root": validate_absolute_path(str(expected_image_paths["validation_root"]), "validation root"),
        "image_root": validate_absolute_path(str(expected_image_paths["image_root"]), "image root"),
        "site_contract": target_contract_path,
        "selection": selection_path,
    }
    for label, path in paths.items():
        validate_not_workspace(path, label)
        if test_mode:
            validate_test_path(path, label, test_root)
    if not test_mode and contract.get("status") != "active":
        fail("production target contract must be active")

    targets_path = TARGETS_PATH
    containers_path = CONTAINERS_PATH
    sources_path = SOURCES_PATH
    if test_mode:
        marker_raw = os.environ.get("VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        if marker_raw is None:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        validate_test_path(validate_absolute_path(marker_raw, "test side-effect marker"), "test side-effect marker", test_root)
        target_override = os.environ.get("VLAD_PREFLIGHT_TEST_TARGETS")
        container_override = os.environ.get("VLAD_PREFLIGHT_TEST_CONTAINERS")
        source_override = os.environ.get("VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        if target_override:
            targets_path = validate_absolute_path(target_override, "test target registry")
            validate_test_path(targets_path, "test target registry", test_root)
        if container_override:
            containers_path = validate_absolute_path(container_override, "test container registry")
            validate_test_path(containers_path, "test container registry", test_root)
        if not source_override:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        sources_path = validate_absolute_path(source_override, "test source lock")
        validate_test_path(sources_path, "test source lock", test_root)

        required_test_paths = () if args.plan_only else (
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
    if test_mode:
        for variable, destination in (
            ("VLAD_PREFLIGHT_TEST_SWAP_TARGETS", targets_path),
            ("VLAD_PREFLIGHT_TEST_SWAP_CONTAINERS", containers_path),
            ("VLAD_PREFLIGHT_TEST_SWAP_SOURCE_LOCK", sources_path),
        ):
            replacement = os.environ.get(variable)
            if replacement:
                replacement_path = validate_test_path(
                    validate_absolute_path(replacement, variable), variable, test_root
                )
                os.replace(replacement_path, destination)
    targets = parse_targets(targets_bytes)
    sources = parse_sources(source_bytes)
    containers = parse_containers(containers_bytes, targets, sources)
    if hashlib.sha256(targets_bytes).hexdigest() != authorities.get("target_registry"):
        fail("selection target-registry authority digest mismatch")
    if hashlib.sha256(containers_bytes).hexdigest() != authorities.get("container_registry"):
        fail("selection container-registry authority digest mismatch")
    timeout_seconds = int(os.environ.get("VLAD_PREFLIGHT_PROBE_TIMEOUT_SECONDS", "30"))
    if not 1 <= timeout_seconds <= 300:
        fail("probe timeout must be between 1 and 300 seconds")
    if args.plan_only:
        source_lock = load_json_bytes(source_bytes, "source lock")
        if source_lock.get("status") != "complete" or source_lock.get("unresolved"):
            fail("source lock is blocked or incomplete")
    else:
        source_lock = validate_source_lock(source_bytes, timeout_seconds)
    native_arch = os.environ.get("VLAD_PREFLIGHT_TEST_UNAME_M") if test_mode else os.uname().machine
    target_fact = targets.get(args.target)
    base_fact = containers.get(args.base)
    if target_fact is None or base_fact is None:
        fail("selected target or container is absent from authenticated registries")
    if args.target not in base_fact.allowed_targets:
        fail("selected container does not allow requested target")
    if native_arch != target_fact.native_arch:
        fail(f"native architecture mismatch: target requires {target_fact.native_arch}, host is {native_arch}")

    actual_contract_sha256 = hashlib.sha256(contract_bytes).hexdigest()
    role = ROLE_BY_MODE[args.mode]
    role_identity = os.environ.get("VLAD_PREFLIGHT_TEST_ROLE_IDENTITY") if test_mode else pwd.getpwuid(os.geteuid()).pw_name
    if roles.get(role) != role_identity:
        fail(f"execution identity does not own selected contract role: {role}")

    if args.plan_only:
        print(json.dumps({
            "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-preflight-plan/v1",
            "datacenter": policy.get("datacenter"),
            "software_set": policy.get("software_set"),
            "target": args.target,
            "container": args.base,
            "role": role,
            "role_identity": role_identity,
            "selection_sha256": args.selection_sha256,
            "target_contract_sha256": actual_contract_sha256,
            "paths": {key: str(value) for key, value in paths.items() if key not in {"site_contract", "selection"}},
            "slurm": contract.get("slurm"),
        }, sort_keys=True, separators=(",", ":")))
        return 0

    inventory = load_inventory(test_mode, test_root, timeout_seconds)
    target_contract = contract.get("slurm")
    if not isinstance(target_contract, dict):
        fail("target contract Slurm placement is missing")
    if not inventory_has_pair(inventory, target_contract["partition"], target_contract["constraint"]):
        fail("validated target partition/constraint pair is absent from live Slurm inventory")

    qualified_candidate = paths["candidate_root"] / args.image_id
    selected_image_root = paths["image_root"]
    capabilities: dict[str, Any] = {}
    if args.mode == "build":
        tools = verify_pinned_tools(source_lock, BUILD_TOOLS[args.target], native_arch, test_mode, timeout_seconds)
        tools.update(require_tools(("python3",), test_mode))
        require_directory(qualified_candidate, "target/image-qualified candidate work root", writable=True)
        candidate_fs = require_nfs(qualified_candidate, test_mode, test_root, timeout_seconds)
        require_directory(paths["image_root"], "final image root", writable=False)
        require_directory(selected_image_root, "selected final image root", writable=False)
        minimum_free = int(os.environ.get("VLAD_IMAGE_MIN_FREE_BYTES", str(100 * 1024**3)))
        if minimum_free <= 0:
            fail("minimum free-space requirement must be positive")
        free_bytes = int(os.environ.get("VLAD_PREFLIGHT_TEST_FREE_BYTES", str(shutil.disk_usage(qualified_candidate).free))) if test_mode else shutil.disk_usage(qualified_candidate).free
        if free_bytes < minimum_free:
            fail("candidate work root has insufficient free space")
        if not test_mode:
            descriptor = source_lock["verified"][base_fact.source_lock_category]["platforms"][args.target]["descriptor_digest"]
            run_probe([tools["skopeo"], "inspect", f"docker://{base_fact.base_image}@{descriptor}"], timeout_seconds)
        capabilities = {"candidate_filesystem": candidate_fs.get("fstype"), "free_bytes": free_bytes, "required_tools": sorted(tools)}
    elif args.mode == "runtime":
        runtime_tools = ("srun", "enroot", "python3", "lscpu") if args.target in X86_ISA_LEVEL else ("srun", "enroot", "python3", "nvidia-smi")
        tools = require_tools(runtime_tools, test_mode)
        tools.update(verify_pinned_tools(source_lock, ("enroot",), native_arch, test_mode, timeout_seconds))
        sealed_candidate = qualified_candidate / args.sha256
        receipt_root = paths["validation_root"] / args.image_id / args.sha256
        require_directory(sealed_candidate, "SHA-qualified sealed candidate", writable=False)
        require_directory(receipt_root, "run-scoped receipt root", writable=True)
        require_nfs(sealed_candidate, test_mode, test_root, timeout_seconds)
        runtime = inventory.get("runtime")
        if not isinstance(runtime, dict):
            fail("live inventory does not contain runtime capability data")
        diagnostics: dict[str, Any] = {}
        for key in RUNTIME_DIAGNOSTICS[args.target]:
            value = runtime.get(key)
            if not isinstance(value, (str, list)) or value in ("", []):
                fail(f"live runtime inventory is missing diagnostic: {key}")
            if isinstance(value, list) and not all(isinstance(item, str) and item for item in value):
                fail(f"live runtime inventory diagnostic is malformed: {key}")
            diagnostics[key] = value
        expected_isa = X86_ISA_LEVEL.get(args.target)
        if expected_isa is not None and (
            diagnostics["cpuid_isa_level"] != expected_isa or diagnostics["elf_isa_level"] != expected_isa
        ):
            fail(f"{args.target} runtime requires physical CPUID and ELF {expected_isa} evidence")
        missing = [feature for feature in RUNTIME_FEATURES[args.target] if runtime.get(feature) is not True]
        if missing:
            raise OptionalRuntimeFeatureMissing("absent declared runtime hardware/features: " + ",".join(missing))
        capabilities = {
            "required_tools": sorted(tools),
            "runtime_features": sorted(RUNTIME_FEATURES[args.target]),
            "runtime_inventory": diagnostics,
        }
    else:
        tools = require_tools(("python3", "getfacl"), test_mode)
        sealed_candidate = qualified_candidate / args.sha256
        receipts = paths["validation_root"] / args.image_id / args.sha256
        releases = selected_image_root / "releases"
        require_directory(sealed_candidate, "SHA-qualified sealed candidate", writable=False)
        require_directory(receipts, "validation receipt root", writable=False)
        require_directory(selected_image_root, "selected final image root", writable=True)
        require_directory(releases, "selected final releases root", writable=True)
        candidate_fs = require_nfs(sealed_candidate, test_mode, test_root, timeout_seconds)
        validation_fs = require_nfs(receipts, test_mode, test_root, timeout_seconds)
        image_fs = require_nfs(selected_image_root, test_mode, test_root, timeout_seconds)
        releases_fs = require_nfs(releases, test_mode, test_root, timeout_seconds)
        if image_fs.get("device") != releases_fs.get("device"):
            fail("publisher staging and release roots are not on the same filesystem")
        validate_publisher_directory(selected_image_root, "selected final image root", image_fs, test_mode, tools["getfacl"], timeout_seconds)
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
        "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-preflight-evidence/v1",
        "schema_version": 1,
        "status": "pass",
        "mode": args.mode,
        "target": args.target,
        "image_id": args.image_id,
        "image_sha256": args.sha256,
        "native_arch": native_arch,
        "role": role,
        "role_identity": role_identity,
        "hostname_diagnostic": socket.gethostname(),
        "boot_id_diagnostic": boot_id,
        "target_contract_sha256": actual_contract_sha256,
        "selection_sha256": args.selection_sha256,
        "datacenter": policy.get("datacenter"),
        "software_set": policy.get("software_set"),
        "slurm": {"partition": target_contract["partition"], "constraint": target_contract["constraint"]},
        "paths": {key: str(value) for key, value in paths.items() if key != "site_contract"},
        "capabilities": capabilities,
    }
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    return 0


try:
    raise SystemExit(main())
except OptionalRuntimeFeatureMissing as error:
    print(f"preflight skip: {error}", file=sys.stderr)
    raise SystemExit(77)
except (PreflightError, RegistryError, SelectionError, ValueError, TypeError, UnicodeError, KeyError, IndexError) as error:
    print(f"preflight failed: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
