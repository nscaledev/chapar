#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "${SCRIPT_DIR}" "$@" <<'PY'
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

SCRIPT_DIR = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]
TARGETS_PATH = SCRIPT_DIR / "targets.json"
SOURCES_PATH = SCRIPT_DIR / "sources-lock.json"
LOCK_VALIDATOR = SCRIPT_DIR / "tests" / "validate-locks.sh"
CONTRACT_SCHEMA = "https://nscaledev.github.io/chapar/schemas/vlad-image-site-contract/v1"
DEFAULT_CONTRACT = "/etc/chapar/vlad-image/site-contract.json"
PUBLIC_ROOTS = (Path("/resources"), Path("/shared"), Path("/etc"))
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
DIGEST_RE: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE: Final = re.compile(r"^[0-9a-f]{40}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
TOKEN_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
CONSTRAINT_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.&|!()+:-]{0,127}$")
PLACEHOLDER_RE: Final = re.compile(r"(?:PLACEHOLDER|REPLACE|CHANGEME|EXAMPLE|TODO)", re.IGNORECASE)
EXPECTED_TARGETS: Final = {
    "linux-x86_64-generic": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64",
        "llvm_targets": ["x86", "nvptx"],
        "cuda_arch": ["75", "80", "86", "87", "89", "90", "90a", "100", "103", "110", "120", "121"],
        "hardware_class": "physical-x86-64-v1",
    },
    "linux-x86_64-v4": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64_v4",
        "llvm_targets": ["x86", "nvptx"],
        "cuda_arch": ["75", "80", "86", "87", "89", "90", "90a", "100", "103", "110", "120", "121"],
        "hardware_class": "physical-x86-64-v4",
    },
    "linux-aarch64-gb300": {
        "oci_platform": "linux/arm64",
        "native_arch": "aarch64",
        "spack_target": "aarch64",
        "llvm_targets": ["aarch64", "nvptx"],
        "cuda_arch": ["103"],
        "hardware_class": "gb300",
    },
}
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
    "linux-aarch64-gb300": ("enroot", "squashfs-tools", "zstd", "syft", "jq", "skopeo"),
}
# Which locked OCI category and registry image each selected container's base
# comes from. Kept in sync with containers/images/build-image.sh's BASES dict;
# preflight only needs the two fields it probes with here.
BASES: Final = {
    "nvidia-vlad": {"lock_category": "nvidia_hpc_benchmarks_oci", "image": "nvcr.io/nvidia/hpc-benchmarks"},
    "ubuntu-hpcsim": {"lock_category": "ubuntu_base_oci", "image": "ubuntu"},
}
ROLE_BY_MODE: Final = {"build": "builders", "runtime": "validators", "publisher": "publishers"}
RUNTIME_FEATURES: Final = {
    "linux-x86_64-generic": ("physical_x86_64_v1", "pmix", "pyxis", "munge", "shared_image"),
    "linux-x86_64-v4": ("physical_x86_64_v4", "pmix", "pyxis", "munge", "shared_image"),
    "linux-aarch64-gb300": ("gb300", "pmix", "pyxis", "munge", "gpu", "infiniband", "network", "shared_image"),
}
RUNTIME_DIAGNOSTICS: Final = {
    "linux-x86_64-generic": ("pmix_plugins", "pyxis_flags", "munge_domain", "network_expectation", "lscpu", "cpuid_isa_level", "elf_isa_level"),
    "linux-x86_64-v4": ("pmix_plugins", "pyxis_flags", "munge_domain", "network_expectation", "lscpu", "cpuid_isa_level", "elf_isa_level"),
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


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read valid {label} JSON: {path}: {error}")
    if not isinstance(loaded, dict):
        fail(f"{label} must be a JSON object")
    return loaded


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


def validate_targets(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if set(document) != {"schema", "schema_version", "targets"} or document.get("schema_version") != 1:
        fail("target registry has unknown fields or unsupported schema")
    targets = document.get("targets")
    if not isinstance(targets, dict) or set(targets) != set(EXPECTED_TARGETS):
        fail("target registry must contain exactly the two approved targets")
    for name, expected in EXPECTED_TARGETS.items():
        target = targets[name]
        approved = {key: value for key, value in expected.items() if key != "hardware_class"}
        if target != approved:
            fail(f"target mapping mismatch: {name}")
    return targets


def validate_source_lock(path: Path, timeout_seconds: int) -> dict[str, Any]:
    environment = os.environ.copy()
    environment["SOURCES_PATH_OVERRIDE"] = str(path)
    try:
        completed = subprocess.run(
            ["bash", str(LOCK_VALIDATOR), "--require-complete"],
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"source-lock validator failed or timed out: {error}")
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()[-1] if completed.stderr.strip() else "closed source-lock validation failed"
        fail(f"source lock is blocked or invalid: {detail}")
    return load_json(path, "source lock")


def validate_contract(document: dict[str, Any]) -> dict[str, Any]:
    if set(document) != {"schema", "schema_version", "status", "roles", "targets"}:
        fail("site contract contains missing or unknown top-level fields")
    if document.get("schema") != CONTRACT_SCHEMA or document.get("schema_version") != 1:
        fail("site contract schema identity is unsupported")
    if document.get("status") != "active":
        fail("example or inactive site contract is forbidden")
    if PLACEHOLDER_RE.search(json.dumps(document, sort_keys=True)):
        fail("site contract contains a placeholder")
    roles = document.get("roles")
    if not isinstance(roles, dict) or set(roles) != {"builders", "publishers", "validators"}:
        fail("site contract roles must contain exactly builders, publishers, and validators")
    all_identities: dict[str, str] = {}
    for role, identities in roles.items():
        if not isinstance(identities, list) or not identities:
            fail(f"site contract role allowlist is empty: {role}")
        if len(identities) != len(set(identities)):
            fail(f"site contract role allowlist has duplicates: {role}")
        for identity in identities:
            if not isinstance(identity, str) or SHA256_RE.fullmatch(identity) is None:
                fail(f"invalid machine-id SHA-256 in role: {role}")
            if identity in all_identities:
                fail(f"machine identity is duplicated across roles: {all_identities[identity]} and {role}")
            all_identities[identity] = role
    target_contracts = document.get("targets")
    if not isinstance(target_contracts, dict) or set(target_contracts) != set(EXPECTED_TARGETS):
        fail("site contract must contain exactly both approved targets")
    for name, expected in EXPECTED_TARGETS.items():
        target = target_contracts[name]
        if not isinstance(target, dict) or set(target) != {"hardware_class", "partition", "constraint"}:
            fail(f"site target contains missing or unknown fields: {name}")
        if target.get("hardware_class") != expected["hardware_class"]:
            fail(f"site target hardware contract mismatch: {name}")
        if not isinstance(target.get("partition"), str) or TOKEN_RE.fullmatch(target["partition"]) is None:
            fail(f"invalid Slurm partition for target: {name}")
        if not isinstance(target.get("constraint"), str) or CONSTRAINT_RE.fullmatch(target["constraint"]) is None:
            fail(f"invalid Slurm constraint for target: {name}")
    return document


def machine_identity(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError as error:
        fail(f"cannot read stable machine identity: {error}")
    text = raw.decode("ascii", errors="strict").strip()
    if re.fullmatch(r"[0-9a-f]{32}", text) is None:
        fail("machine-id must contain exactly 32 lowercase hexadecimal characters")
    return hashlib.sha256(raw).hexdigest()


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
    parser.add_argument("--target", required=True, choices=tuple(EXPECTED_TARGETS))
    parser.add_argument("--base", default="nvidia-vlad", choices=tuple(BASES))
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--sha256")
    parser.add_argument("--candidate-root", required=True)
    parser.add_argument("--validation-root", required=True)
    parser.add_argument("--image-root", required=True)
    parser.add_argument("--site-contract", default=DEFAULT_CONTRACT)
    parser.add_argument("--site-contract-sha256", default=os.environ.get("VLAD_IMAGE_SITE_CONTRACT_SHA256"))
    parser.add_argument("--mode", required=True, choices=("build", "runtime", "publisher"))
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
            "VLAD_PREFLIGHT_TEST_SOURCES_LOCK",
            "VLAD_PREFLIGHT_TEST_TARGETS",
            "VLAD_PREFLIGHT_TEST_UNAME_M",
            "VLAD_PREFLIGHT_TEST_MACHINE_ID",
            "VLAD_PREFLIGHT_TEST_BOOT_ID",
            "VLAD_PREFLIGHT_TEST_INVENTORY",
            "VLAD_PREFLIGHT_TEST_FILESYSTEMS",
            "VLAD_PREFLIGHT_TEST_TOOL_DIR",
            "VLAD_PREFLIGHT_TEST_FREE_BYTES",
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
    if args.site_contract_sha256 is None or SHA256_RE.fullmatch(args.site_contract_sha256) is None:
        fail("--site-contract-sha256 is required and must be a full lowercase SHA-256")

    paths = {
        "candidate_root": validate_absolute_path(args.candidate_root, "candidate root"),
        "validation_root": validate_absolute_path(args.validation_root, "validation root"),
        "image_root": validate_absolute_path(args.image_root, "image root"),
        "site_contract": validate_absolute_path(args.site_contract, "site contract"),
    }
    for label, path in paths.items():
        validate_not_workspace(path, label)
        if test_mode:
            validate_test_path(path, label, test_root)
    if not test_mode and paths["site_contract"] != Path(DEFAULT_CONTRACT):
        fail("production site contract path is fixed and cannot be overridden")

    targets_path = TARGETS_PATH
    sources_path = SOURCES_PATH
    if test_mode:
        marker_raw = os.environ.get("VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        if marker_raw is None:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER")
        validate_test_path(validate_absolute_path(marker_raw, "test side-effect marker"), "test side-effect marker", test_root)
        target_override = os.environ.get("VLAD_PREFLIGHT_TEST_TARGETS")
        source_override = os.environ.get("VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        if target_override:
            targets_path = validate_absolute_path(target_override, "test target registry")
            validate_test_path(targets_path, "test target registry", test_root)
        if not source_override:
            fail("test mode requires VLAD_PREFLIGHT_TEST_SOURCES_LOCK")
        sources_path = validate_absolute_path(source_override, "test source lock")
        validate_test_path(sources_path, "test source lock", test_root)

        for variable, label in (
            ("VLAD_PREFLIGHT_TEST_MACHINE_ID", "test machine ID"),
            ("VLAD_PREFLIGHT_TEST_BOOT_ID", "test boot ID"),
            ("VLAD_PREFLIGHT_TEST_INVENTORY", "test inventory"),
            ("VLAD_PREFLIGHT_TEST_FILESYSTEMS", "test filesystem inventory"),
            ("VLAD_PREFLIGHT_TEST_TOOL_DIR", "test tool directory"),
        ):
            value = os.environ.get(variable)
            if value is None:
                fail(f"test mode requires {variable}")
            validate_test_path(validate_absolute_path(value, label), label, test_root)

    targets = validate_targets(load_json(targets_path, "target registry"))
    timeout_seconds = int(os.environ.get("VLAD_PREFLIGHT_PROBE_TIMEOUT_SECONDS", "30"))
    if not 1 <= timeout_seconds <= 300:
        fail("probe timeout must be between 1 and 300 seconds")
    source_lock = validate_source_lock(sources_path, timeout_seconds)
    native_arch = os.environ.get("VLAD_PREFLIGHT_TEST_UNAME_M") if test_mode else os.uname().machine
    if native_arch != EXPECTED_TARGETS[args.target]["native_arch"]:
        fail(f"native architecture mismatch: target requires {EXPECTED_TARGETS[args.target]['native_arch']}, host is {native_arch}")

    expected_uid = int(os.environ.get("VLAD_PREFLIGHT_TEST_CONTRACT_UID", "0")) if test_mode else 0
    contract_bytes = read_secure_contract(paths["site_contract"], expected_uid, test_mode)
    actual_contract_sha256 = hashlib.sha256(contract_bytes).hexdigest()
    if actual_contract_sha256 != args.site_contract_sha256:
        fail("site contract SHA-256 does not match the protected expected value")
    contract = validate_contract(json.loads(contract_bytes, object_pairs_hook=unique_object))

    machine_id_path = Path(os.environ.get("VLAD_PREFLIGHT_TEST_MACHINE_ID", "/etc/machine-id")) if test_mode else Path("/etc/machine-id")
    role = ROLE_BY_MODE[args.mode]
    identity = machine_identity(machine_id_path)
    if identity not in contract["roles"][role]:
        fail(f"stable machine identity is not allowlisted for role: {role}")

    inventory = load_inventory(test_mode, test_root, timeout_seconds)
    target_contract = contract["targets"][args.target]
    if not inventory_has_pair(inventory, target_contract["partition"], target_contract["constraint"]):
        fail("validated target partition/constraint pair is absent from live Slurm inventory")

    qualified_candidate = paths["candidate_root"] / args.target / args.image_id
    selected_image_root = paths["image_root"] / args.target
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
            base = BASES[args.base]
            descriptor = source_lock["verified"][base["lock_category"]]["platforms"][args.target]["descriptor_digest"]
            run_probe([tools["skopeo"], "inspect", f"docker://{base['image']}@{descriptor}"], timeout_seconds)
        capabilities = {"candidate_filesystem": candidate_fs.get("fstype"), "free_bytes": free_bytes, "required_tools": sorted(tools)}
    elif args.mode == "runtime":
        runtime_tools = ("srun", "enroot", "python3", "lscpu") if args.target in X86_ISA_LEVEL else ("srun", "enroot", "python3", "nvidia-smi")
        tools = require_tools(runtime_tools, test_mode)
        tools.update(verify_pinned_tools(source_lock, ("enroot",), native_arch, test_mode, timeout_seconds))
        sealed_candidate = qualified_candidate / args.sha256
        receipt_root = paths["validation_root"] / args.target / args.image_id / args.sha256
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
        receipts = paths["validation_root"] / args.target / args.image_id / args.sha256
        releases = selected_image_root / "releases"
        require_directory(sealed_candidate, "SHA-qualified sealed candidate", writable=False)
        require_directory(receipts, "validation receipt root", writable=False)
        require_directory(paths["image_root"], "final image root", writable=False)
        require_directory(selected_image_root, "selected final image root", writable=True)
        require_directory(releases, "selected final releases root", writable=True)
        for other_target in set(EXPECTED_TARGETS) - {args.target}:
            other_root = paths["image_root"] / other_target
            if other_root.exists():
                require_directory(other_root, "unselected final image root", writable=False)
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
        "machine_id_sha256": identity,
        "hostname_diagnostic": socket.gethostname(),
        "boot_id_diagnostic": boot_id,
        "site_contract_sha256": actual_contract_sha256,
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
except (PreflightError, ValueError, TypeError, UnicodeError, KeyError, IndexError) as error:
    print(f"preflight failed: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
