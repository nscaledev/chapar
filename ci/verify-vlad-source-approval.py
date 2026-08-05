#!/usr/bin/env python3
# noqa: SIZE_OK - Todo 6 fixes this security boundary to one allowlisted module containing four receipt and six custody operations.

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Final, Iterator, NewType


JsonScalar = str | int | bool | None
JsonValue = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonMap = dict[str, JsonValue]
Sha256 = NewType("Sha256", str)
Commit = NewType("Commit", str)

HEX40: Final = re.compile(r"[0-9a-f]{40}")
HEX64: Final = re.compile(r"[0-9a-f]{64}")
IDENTIFIER: Final = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
TARGETS: Final = frozenset({"linux-x86_64-v4", "linux-aarch64-gb300"})
REMOTE: Final = "https://github.com/nscaledev/chapar.git"
SOURCE_SCHEMA: Final = "chapar-vlad-source-approval/v1"
RELEASE_SCHEMA: Final = "chapar-vlad-release-binding/v1"
BUILDER_SCHEMA: Final = "chapar-vlad-builder-handoff/v1"
RUNTIME_SCHEMA: Final = "chapar-vlad-runtime-receipt/v1"
SCHEMA_KEYS: Final = {
    SOURCE_SCHEMA: frozenset({"schema", "approved_by", "approved_at", "change_ticket", "chapar_remote", "chapar_commit", "source_lock_path", "source_lock_sha256"}),
    RELEASE_SCHEMA: frozenset({"schema", "release_dir", "release_id", "chapar_commit", "source_lock_sha256", "target", "metadata_path", "metadata_sha256", "spack_lock_path", "spack_lock_sha256", "status"}),
    BUILDER_SCHEMA: frozenset({"schema", "build_root", "chapar_commit", "source_lock_sha256", "release_binding", "release_binding_sha256", "target", "image_id", "image_path", "image_sha256", "image_size", "validation_root"}),
    RUNTIME_SCHEMA: frozenset({"schema", "builder_handoff_sha256", "release_binding_sha256", "target", "image_path", "image_sha256", "validator_root", "validator_image_root", "runtime_receipt_path", "runtime_preflight_sha256", "smoke_output_sha256", "status"}),
}
DIRECTORY_IDENTITY_KEYS: Final = frozenset({"directory_identity"})
SEALED_EVIDENCE_KEYS: Final = frozenset({"directory_identity", "file_sha256"})
READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
DIR_FLAGS: Final = READ_FLAGS | os.O_DIRECTORY
CHUNK: Final = 1024 * 1024


class ContractError(Exception):
    __slots__ = ("detail",)

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True, slots=True)
class FileBytes:
    content: bytes
    sha256: Sha256
    size: int
    uid: int
    mode: int


@dataclass(frozen=True, slots=True)
class ReleaseInputs:
    output: str
    release_dir: str
    metadata: str
    spack_lock: str
    chapar_commit: str
    source_lock_sha256: str
    target: str
    release_id: str
    status: str


def fail(detail: str) -> None:
    raise ContractError(detail)


def require(condition: bool, detail: str) -> None:
    if not condition:
        fail(detail)


def unique_pairs(pairs: list[tuple[str, JsonValue]]) -> JsonMap:
    result: JsonMap = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(content: bytes) -> JsonMap:
    try:
        value: JsonValue = json.loads(content, object_pairs_hook=unique_pairs)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        fail(f"invalid JSON: {error}")
    require(type(value) is dict, "JSON root must be an object")
    return value


def canonical_absolute(raw: str, label: str) -> str:
    require(raw.startswith("/") and os.path.normpath(raw) == raw, f"{label} must be canonical absolute path")
    parts = raw.split("/")[1:]
    require(parts and all(part not in ("", ".", "..") for part in parts), f"{label} has invalid path components")
    return raw


def simple_name(raw: str, label: str) -> str:
    require(raw not in ("", ".", "..") and "/" not in raw, f"{label} must be one path component")
    return raw


@contextmanager
def opened_path(raw: str, final_directory: bool = False) -> Iterator[int]:
    absolute = canonical_absolute(raw, "path")
    parts = absolute.split("/")[1:]
    fd = os.open("/", DIR_FLAGS)
    try:
        for index, part in enumerate(parts):
            flags = DIR_FLAGS if index < len(parts) - 1 or final_directory else READ_FLAGS
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


@contextmanager
def opened_parent(raw: str) -> Iterator[tuple[int, str]]:
    absolute = canonical_absolute(raw, "path")
    parent, name = os.path.split(absolute)
    simple_name(name, "file name")
    with opened_path(parent, final_directory=True) as parent_fd:
        yield parent_fd, name


def stable_bytes_fd(fd: int, label: str) -> FileBytes:
    before = os.fstat(fd)
    require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    chunks: list[bytes] = []
    while chunk := os.read(fd, CHUNK):
        digest.update(chunk)
        chunks.append(chunk)
    after = os.fstat(fd)
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    require(identity(before) == identity(after), f"{label} changed while open")
    return FileBytes(b"".join(chunks), Sha256(digest.hexdigest()), before.st_size, before.st_uid, stat.S_IMODE(before.st_mode))


def read_file(raw: str, label: str, required_mode: int | None = None) -> FileBytes:
    with opened_path(raw) as fd:
        result = stable_bytes_fd(fd, label)
    if required_mode is not None:
        require(result.mode == required_mode, f"{label} mode must be {required_mode:04o}")
    return result


def expect_string(data: JsonMap, key: str) -> str:
    value = data.get(key)
    require(type(value) is str, f"{key} must be a string")
    return value


def expect_integer(data: JsonMap, key: str) -> int:
    value = data.get(key)
    require(type(value) is int and value > 0, f"{key} must be a positive integer")
    return value


def require_sha(raw: str, label: str) -> Sha256:
    require(HEX64.fullmatch(raw) is not None, f"{label} must be lowercase SHA-256")
    return Sha256(raw)


def require_commit(raw: str) -> Commit:
    require(HEX40.fullmatch(raw) is not None, "chapar_commit must be lowercase 40-hex")
    return Commit(raw)


def require_identifier(raw: str, label: str) -> str:
    require(IDENTIFIER.fullmatch(raw) is not None, f"{label} is invalid")
    return raw


def require_target(raw: str) -> str:
    require(raw in TARGETS, "target is not a Vlad image target")
    return raw


def require_schema(data: JsonMap, identity: str) -> None:
    require(set(data) == SCHEMA_KEYS[identity], f"{identity} key set mismatch")
    require(expect_string(data, "schema") == identity, f"wrong schema identity: {identity}")


def receipt(raw: str, expected_sha256: str | None = None) -> tuple[JsonMap, FileBytes]:
    file_bytes = read_file(raw, "receipt", 0o444)
    if expected_sha256 is not None:
        require(file_bytes.sha256 == require_sha(expected_sha256, "expected receipt digest"), "receipt SHA-256 mismatch")
    return parse_json(file_bytes.content), file_bytes


def write_exclusive_json(raw: str, data: JsonMap) -> Sha256:
    payload = json.dumps(data, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    with opened_parent(raw) as (parent_fd, name):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o444, dir_fd=parent_fd)
        try:
            os.fchmod(fd, 0o444)
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(parent_fd)
    reread = read_file(raw, "written receipt", 0o444)
    require(reread.content == payload, "written receipt bytes drifted")
    return reread.sha256


def validate_source(data: JsonMap, chapar_root: str, approved_by: str, ticket: str) -> None:
    require_schema(data, SOURCE_SCHEMA)
    root = canonical_absolute(chapar_root, "chapar root")
    require(expect_string(data, "approved_by") == approved_by and approved_by != "", "approved_by mismatch")
    require(expect_string(data, "change_ticket") == ticket and ticket != "", "change_ticket mismatch")
    approved_at = expect_string(data, "approved_at")
    require(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", approved_at) is not None, "approved_at must be RFC3339 UTC")
    try:
        dt.datetime.strptime(approved_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as error:
        fail(f"approved_at is invalid: {error}")
    require(expect_string(data, "chapar_remote") == REMOTE, "chapar_remote mismatch")
    commit = require_commit(expect_string(data, "chapar_commit"))
    lock_path = expect_string(data, "source_lock_path")
    require(lock_path == f"{root}/containers/images/sources-lock.json", "source_lock_path mismatch")
    lock = read_file(lock_path, "source lock")
    require(lock.sha256 == require_sha(expect_string(data, "source_lock_sha256"), "source lock digest"), "source lock content mismatch")
    git_env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"}
    git_prefix = ["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", root, "-c", f"safe.directory={root}", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false"]
    head = subprocess.run([*git_prefix, "rev-parse", "HEAD"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
    remote = subprocess.run([*git_prefix, "remote", "get-url", "origin"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
    require(head == commit, "approved commit does not match checkout HEAD")
    require(remote == REMOTE, "checkout origin does not match approved remote")


def release_data(inputs: ReleaseInputs) -> JsonMap:
    release_dir = canonical_absolute(inputs.release_dir, "release dir")
    metadata = canonical_absolute(inputs.metadata, "metadata path")
    spack_lock = canonical_absolute(inputs.spack_lock, "Spack lock path")
    require(metadata == f"{release_dir}/metadata.txt", "metadata path is outside release")
    build_root = str(Path(spack_lock).parents[2])
    require(spack_lock == f"{build_root}/envs/vlad/spack.lock", "Spack lock path mismatch")
    require(inputs.status == "integrity-passed", "release status must be integrity-passed")
    metadata_bytes = read_file(metadata, "release metadata")
    lock_bytes = read_file(spack_lock, "Spack lock")
    require(f"release_id: {inputs.release_id}\n".encode() in metadata_bytes.content, "release metadata ID mismatch")
    return {
        "schema": RELEASE_SCHEMA, "release_dir": release_dir,
        "release_id": require_identifier(inputs.release_id, "release_id"),
        "chapar_commit": require_commit(inputs.chapar_commit),
        "source_lock_sha256": require_sha(inputs.source_lock_sha256, "source lock digest"),
        "target": require_target(inputs.target), "metadata_path": metadata,
        "metadata_sha256": metadata_bytes.sha256, "spack_lock_path": spack_lock,
        "spack_lock_sha256": lock_bytes.sha256, "status": inputs.status,
    }


def validate_release(data: JsonMap, inputs: ReleaseInputs | None = None) -> None:
    require_schema(data, RELEASE_SCHEMA)
    release_dir = canonical_absolute(expect_string(data, "release_dir"), "release dir")
    release_id = require_identifier(expect_string(data, "release_id"), "release_id")
    require_commit(expect_string(data, "chapar_commit"))
    require_sha(expect_string(data, "source_lock_sha256"), "source lock digest")
    require_target(expect_string(data, "target"))
    metadata = expect_string(data, "metadata_path")
    spack_lock = expect_string(data, "spack_lock_path")
    require(metadata == f"{release_dir}/metadata.txt", "metadata path mismatch")
    require(expect_string(data, "status") == "integrity-passed", "release status mismatch")
    require(read_file(metadata, "release metadata").sha256 == require_sha(expect_string(data, "metadata_sha256"), "metadata digest"), "metadata content drift")
    require(read_file(spack_lock, "Spack lock").sha256 == require_sha(expect_string(data, "spack_lock_sha256"), "Spack lock digest"), "Spack lock content drift")
    require(f"release_id: {release_id}\n".encode() in read_file(metadata, "release metadata").content, "release metadata ID drift")
    if inputs is not None:
        expected = release_data(inputs)
        require(data == expected, "release binding fields do not match expected inputs")


def validate_builder(data: JsonMap, expected_commit: str | None = None) -> None:
    require_schema(data, BUILDER_SCHEMA)
    build_root = canonical_absolute(expect_string(data, "build_root"), "build root")
    commit = require_commit(expect_string(data, "chapar_commit"))
    if expected_commit is not None:
        require(commit == require_commit(expected_commit), "builder commit mismatch")
    source_lock_sha = require_sha(expect_string(data, "source_lock_sha256"), "source lock digest")
    release_path = canonical_absolute(expect_string(data, "release_binding"), "release binding")
    release_json, release_file = receipt(release_path)
    validate_release(release_json)
    require(release_file.sha256 == require_sha(expect_string(data, "release_binding_sha256"), "release binding digest"), "release binding digest mismatch")
    require(expect_string(release_json, "chapar_commit") == commit, "release and builder commits differ")
    require(expect_string(release_json, "source_lock_sha256") == source_lock_sha, "release and builder source locks differ")
    require(expect_string(release_json, "spack_lock_path") == f"{build_root}/envs/vlad/spack.lock", "builder build root mismatch")
    target = require_target(expect_string(data, "target"))
    require(expect_string(release_json, "target") == target, "release and builder targets differ")
    require_identifier(expect_string(data, "image_id"), "image_id")
    image_path = canonical_absolute(expect_string(data, "image_path"), "image path")
    image = read_file(image_path, "builder image")
    require(image.sha256 == require_sha(expect_string(data, "image_sha256"), "image digest"), "builder image digest mismatch")
    require(image.size == expect_integer(data, "image_size"), "builder image size mismatch")
    require(image.mode == 0o444, "builder image is not sealed mode 0444")
    expected_suffix = f"/{target}/{expect_string(data, 'image_id')}/{image.sha256}/{os.path.basename(image_path)}"
    require(image_path.endswith(expected_suffix), "builder image is outside target/image/hash custody")
    validation_root = canonical_absolute(expect_string(data, "validation_root"), "validation root")
    require(os.path.dirname(release_path) == validation_root, "release binding is outside validation root")


def builder_data(args: argparse.Namespace) -> JsonMap:
    release_json, release_file = receipt(args.release_binding)
    validate_release(release_json)
    build_root = canonical_absolute(args.build_root, "build root")
    require(expect_string(release_json, "spack_lock_path") == f"{build_root}/envs/vlad/spack.lock", "build root does not bind release")
    image = read_file(args.image, "builder image")
    require(image.sha256 == require_sha(args.image_sha256, "image digest"), "builder image digest mismatch")
    require(image.size == args.image_size and args.image_size > 0, "builder image size mismatch")
    require(image.mode == 0o444, "builder image is not sealed mode 0444")
    validation_root = os.path.dirname(canonical_absolute(args.output, "builder handoff path"))
    data: JsonMap = {
        "schema": BUILDER_SCHEMA, "build_root": build_root,
        "chapar_commit": require_commit(args.chapar_commit),
        "source_lock_sha256": require_sha(args.source_lock_sha256, "source lock digest"),
        "release_binding": canonical_absolute(args.release_binding, "release binding"),
        "release_binding_sha256": release_file.sha256, "target": require_target(args.target),
        "image_id": require_identifier(args.image_id, "image_id"),
        "image_path": canonical_absolute(args.image, "image path"),
        "image_sha256": image.sha256, "image_size": image.size,
        "validation_root": validation_root,
    }
    validate_builder(data)
    return data


def runtime_data(args: argparse.Namespace) -> JsonMap:
    builder_json, builder_file = receipt(args.builder_handoff, args.builder_handoff_sha256)
    validate_builder(builder_json)
    release_path = canonical_absolute(args.release_binding, "release binding")
    require(release_path == expect_string(builder_json, "release_binding"), "runtime release binding mismatch")
    _, release_file = receipt(release_path, expect_string(builder_json, "release_binding_sha256"))
    target = require_target(args.target)
    require(target == expect_string(builder_json, "target"), "runtime target mismatch")
    image_sha = require_sha(args.sha256, "image digest")
    require(image_sha == expect_string(builder_json, "image_sha256"), "runtime image digest differs from builder")
    validator_root = canonical_absolute(args.validator_root, "validator root")
    validator_image_root = canonical_absolute(args.validator_image_root, "validator image root")
    image_path = canonical_absolute(args.image, "runtime image")
    expected_parent = f"{validator_image_root}/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}"
    require(os.path.dirname(image_path) == expected_parent, "runtime image is outside validator custody")
    image = read_file(image_path, "runtime image")
    require(image.sha256 == image_sha and image.size == expect_integer(builder_json, "image_size"), "runtime image bytes differ from builder")
    output = canonical_absolute(args.output, "runtime receipt path")
    preflight = read_file(args.preflight, "runtime preflight")
    smoke = read_file(args.smoke_output, "smoke output")
    return {
        "schema": RUNTIME_SCHEMA, "builder_handoff_sha256": builder_file.sha256,
        "release_binding_sha256": release_file.sha256, "target": target,
        "image_path": image_path, "image_sha256": image_sha,
        "validator_root": validator_root, "validator_image_root": validator_image_root,
        "runtime_receipt_path": output, "runtime_preflight_sha256": preflight.sha256,
        "smoke_output_sha256": smoke.sha256, "status": "passed",
    }


def validate_runtime(data: JsonMap, args: argparse.Namespace) -> None:
    require_schema(data, RUNTIME_SCHEMA)
    require(expect_string(data, "status") == "passed", "runtime status must be passed")
    require(canonical_absolute(expect_string(data, "runtime_receipt_path"), "runtime receipt path") == canonical_absolute(args.runtime_receipt, "runtime receipt path"), "runtime receipt self-path mismatch")
    builder_json, builder_file = receipt(args.builder_handoff, args.builder_handoff_sha256)
    validate_builder(builder_json)
    require(expect_string(data, "builder_handoff_sha256") == builder_file.sha256, "runtime builder digest mismatch")
    release_path = canonical_absolute(args.release_binding, "release binding")
    require(release_path == expect_string(builder_json, "release_binding"), "runtime release path mismatch")
    _, release_file = receipt(release_path, expect_string(builder_json, "release_binding_sha256"))
    require(expect_string(data, "release_binding_sha256") == release_file.sha256, "runtime release digest mismatch")
    target = require_target(args.target)
    require(expect_string(data, "target") == target == expect_string(builder_json, "target"), "runtime target mismatch")
    image_sha = require_sha(expect_string(data, "image_sha256"), "runtime image digest")
    require(image_sha == expect_string(builder_json, "image_sha256"), "runtime and builder image digests differ")
    image_path = canonical_absolute(expect_string(data, "image_path"), "runtime image")
    validator_image_root = canonical_absolute(expect_string(data, "validator_image_root"), "validator image root")
    expected_parent = f"{validator_image_root}/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}"
    require(os.path.dirname(image_path) == expected_parent, "runtime image custody path mismatch")
    image = read_file(image_path, "runtime image")
    require(image.sha256 == image_sha and image.size == expect_integer(builder_json, "image_size"), "runtime image content drift")
    receipt_root = os.path.dirname(canonical_absolute(args.runtime_receipt, "runtime receipt"))
    require(canonical_absolute(expect_string(data, "validator_root"), "validator root") + f"/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}" == receipt_root, "runtime validator root mismatch")
    require(read_file(f"{receipt_root}/runtime-preflight.json", "runtime preflight").sha256 == require_sha(expect_string(data, "runtime_preflight_sha256"), "preflight digest"), "runtime preflight drift")
    require(read_file(f"{receipt_root}/pyxis-smoke.txt", "smoke output").sha256 == require_sha(expect_string(data, "smoke_output_sha256"), "smoke digest"), "smoke output drift")


def faccess(fd: int, mode: int) -> bool:
    require(sys.platform.startswith("linux"), "faccessat2 descriptor checks require Linux")
    libc = ctypes.CDLL(None, use_errno=True)
    ctypes.set_errno(0)
    result = libc.syscall(439, fd, ctypes.c_char_p(b""), mode, 0x1000 | 0x200)
    error = ctypes.get_errno()
    if result == 0:
        return True
    require(error in (errno.EACCES, errno.EROFS), f"faccessat2 failed: {error}")
    return False


def role_uid(role: str) -> int:
    require(role in ("validator", "publisher"), "owner role must be validator or publisher")
    try:
        return pwd.getpwnam(role).pw_uid
    except KeyError as error:
        fail(f"owner role does not exist: {error}")


def walk_directories(raw: str) -> list[int]:
    absolute = canonical_absolute(raw, "evidence directory")
    fds = [os.open("/", DIR_FLAGS)]
    try:
        for part in absolute.split("/")[1:]:
            fds.append(os.open(part, DIR_FLAGS, dir_fd=fds[-1]))
        return fds
    except OSError:
        for fd in reversed(fds):
            os.close(fd)
        raise


def close_fds(fds: list[int]) -> None:
    for fd in reversed(fds):
        os.close(fd)


def require_owner_mode(info: os.stat_result, uid: int, mode: int, label: str) -> None:
    require(info.st_uid == uid and stat.S_IMODE(info.st_mode) == mode, f"{label} owner/mode mismatch")


def require_directory_identity(info: os.stat_result, expected: str, label: str) -> None:
    require(f"{info.st_dev}:{info.st_ino}" == expected, f"{label} identity drift")


def verify_empty_evidence(raw: str, role: str) -> JsonMap:
    uid = role_uid(role)
    fds = walk_directories(raw)
    try:
        for fd in fds[:-1]:
            info = os.fstat(fd)
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o555 and not faccess(fd, os.W_OK), "evidence ancestor is not root-owned 0555 nonwritable")
        leaf = os.fstat(fds[-1])
        require(leaf.st_uid == uid and stat.S_IMODE(leaf.st_mode) == 0o755, "evidence leaf owner/mode mismatch")
        require(faccess(fds[-1], os.W_OK), "evidence leaf is not writable by owner role")
        require(os.listdir(fds[-1]) == [], "evidence leaf is not empty")
        return {"directory_identity": f"{leaf.st_dev}:{leaf.st_ino}"}
    finally:
        close_fds(fds)


def run_and_capture(args: argparse.Namespace) -> None:
    output = canonical_absolute(args.output, "capture output")
    require(args.command, "capture command is required")
    with opened_parent(output) as (parent_fd, name):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent_fd)
        try:
            completed = subprocess.run(args.command, check=False, stdout=fd, stderr=fd if args.capture_stderr else None)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(parent_fd)
    require(completed.returncode == 0, f"captured command failed with status {completed.returncode}")


def seal_evidence(args: argparse.Namespace) -> None:
    require(args.file_mode == "0444" and args.directory_mode == "0555", "seal modes must be 0444/0555")
    fds = walk_directories(args.seal_evidence_directory)
    try:
        leaf = os.fstat(fds[-1])
        require_directory_identity(leaf, args.expected_directory_identity, "evidence directory")
        require(leaf.st_uid == os.geteuid(), "evidence leaf is not role-owned")
        for name in os.listdir(fds[-1]):
            simple_name(name, "evidence file")
            fd = os.open(name, READ_FLAGS, dir_fd=fds[-1])
            try:
                info = os.fstat(fd)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(), "evidence entry owner/type mismatch")
                os.fchmod(fd, 0o444)
                os.fsync(fd)
            finally:
                os.close(fd)
        os.fchmod(fds[-1], 0o555)
        os.fsync(fds[-1])
        os.fsync(fds[-2])
    finally:
        close_fds(fds)


def verify_sealed(args: argparse.Namespace) -> JsonMap:
    uid = role_uid(args.owner_role)
    expected_sha = require_sha(args.expected_sha256, "expected evidence digest")
    name = simple_name(args.expected_file, "expected evidence file")
    fds = walk_directories(args.verify_sealed_evidence_directory)
    try:
        for fd in fds[:-1]:
            info = os.fstat(fd)
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o555 and not faccess(fd, os.W_OK), "sealed ancestor mismatch")
        leaf = os.fstat(fds[-1])
        require_directory_identity(leaf, args.expected_directory_identity, "sealed directory")
        require(leaf.st_uid == uid and stat.S_IMODE(leaf.st_mode) == 0o555 and not faccess(fds[-1], os.W_OK), "sealed leaf owner/mode mismatch")
        entries = os.listdir(fds[-1])
        require(name in entries, "expected sealed evidence file is absent")
        for entry in entries:
            simple_name(entry, "sealed evidence file")
            entry_fd = os.open(entry, READ_FLAGS, dir_fd=fds[-1])
            try:
                entry_info = os.fstat(entry_fd)
                require(stat.S_ISREG(entry_info.st_mode) and entry_info.st_uid == uid and stat.S_IMODE(entry_info.st_mode) == 0o444, "sealed evidence entry owner/mode/type mismatch")
            finally:
                os.close(entry_fd)
        file_fd = os.open(name, READ_FLAGS, dir_fd=fds[-1])
        try:
            content = stable_bytes_fd(file_fd, "sealed evidence")
        finally:
            os.close(file_fd)
        require(content.uid == uid and content.mode == 0o444, "sealed file owner/mode mismatch")
        require(content.sha256 == expected_sha, "sealed file digest mismatch")
        return {"directory_identity": args.expected_directory_identity, "file_sha256": expected_sha}
    finally:
        close_fds(fds)


def extract_canonical(args: argparse.Namespace) -> None:
    data = parse_json(sys.stdin.buffer.read())
    expected = DIRECTORY_IDENTITY_KEYS if args.schema == "directory-identity" else SEALED_EVIDENCE_KEYS
    require(set(data) == expected, "canonical helper key set mismatch")
    require(args.field in expected, "field is not in canonical schema")
    value = data[args.field]
    require(type(value) in (str, int, bool), "canonical field is not scalar")
    print(value)


def expect_child_failure(label: str, action: Callable[[], None], expected: str) -> str:
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        try:
            action()
        except (ContractError, OSError, subprocess.SubprocessError) as error:
            os.write(write_fd, str(error).encode())
            os.close(write_fd)
            os._exit(41)
        os.write(write_fd, b"unexpected success")
        os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    output = os.read(read_fd, CHUNK).decode()
    os.close(read_fd)
    _, status = os.waitpid(child, 0)
    require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 41, f"{label} child status mismatch: {status}:{output}")
    require(expected in output, f"{label} failed for the wrong reason: {output}")
    return label


def mutated(data: JsonMap, key: str, value: JsonValue) -> JsonMap:
    return {**data, key: value}


def self_test() -> None:
    require(hasattr(os, "fork"), "setup error: receipt self-test requires POSIX fork")
    cases: list[str] = []
    with tempfile.TemporaryDirectory(prefix="vlad-receipt-self-test-") as temp:
        root = Path(temp).resolve()
        payload = root / "payload"
        payload.write_bytes(b"stable bytes\n")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        symlink = root / "symlink"
        symlink.symlink_to(payload)
        cases.append(expect_child_failure("symlink-component", lambda: read_file(str(symlink), "symlink"), "symlink"))
        duplicate = b'{"schema":"x","nested":{"a":1,"a":2}}'
        cases.append(expect_child_failure("recursive-duplicate-key", lambda: parse_json(duplicate), "duplicate JSON key: a"))
        output = root / "receipt.json"
        data: JsonMap = {"directory_identity": "1:2"}
        write_exclusive_json(str(output), data)
        cases.append(expect_child_failure("receipt-o-excl-collision", lambda: write_exclusive_json(str(output), data), "File exists"))
        require(read_file(str(output), "self-test receipt", 0o444).sha256 == hashlib.sha256(output.read_bytes()).hexdigest(), "self-test receipt digest drift")
        require(digest == hashlib.sha256(b"stable bytes\n").hexdigest(), "stable descriptor hash failed")
        replaced = root / "replaced"
        replaced.mkdir()
        with opened_path(str(replaced), final_directory=True) as fd:
            identity = os.fstat(fd).st_ino
            replaced.rmdir()
            replaced.mkdir()
            require(os.fstat(fd).st_ino == identity and os.stat(replaced).st_ino != identity, "replacement race fixture failed")
        cases.append("component-replacement-open-descriptor")

        source_root = root / "source-checkout"
        source_lock = source_root / "containers/images/sources-lock.json"
        source_lock.parent.mkdir(parents=True)
        source_lock.write_text('{"status":"fixture"}\n', encoding="utf-8")
        git_env = {
            "PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_AUTHOR_NAME": "Fixture Author",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture Committer",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        subprocess.run(["/usr/bin/git", "init", "--initial-branch=fixture", str(source_root)], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "add", "containers/images/sources-lock.json"], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "commit", "-m", "fixture source"], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "remote", "add", "origin", REMOTE], check=True, capture_output=True, env=git_env)
        commit = subprocess.run(["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", str(source_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
        source_data: JsonMap = {
            "schema": SOURCE_SCHEMA, "approved_by": "fixture-approver",
            "approved_at": "2026-08-05T12:00:00Z", "change_ticket": "fixture-ticket",
            "chapar_remote": REMOTE, "chapar_commit": commit,
            "source_lock_path": str(source_lock),
            "source_lock_sha256": hashlib.sha256(source_lock.read_bytes()).hexdigest(),
        }
        validate_source(source_data, str(source_root), "fixture-approver", "fixture-ticket")
        cases.append("source-schema-happy")
        unknown_source = {**source_data, "unknown": "rejected"}
        cases.append(expect_child_failure("source-unknown-key", lambda: validate_source(unknown_source, str(source_root), "fixture-approver", "fixture-ticket"), "key set mismatch"))
        cases.append(expect_child_failure("source-wrong-identity", lambda: validate_source(mutated(source_data, "schema", RELEASE_SCHEMA), str(source_root), "fixture-approver", "fixture-ticket"), "wrong schema identity"))
        cases.append(expect_child_failure("source-wrong-time", lambda: validate_source(mutated(source_data, "approved_at", "2026-08-05 12:00:00"), str(source_root), "fixture-approver", "fixture-ticket"), "RFC3339 UTC"))
        cases.append(expect_child_failure("source-no-dot-git-remote", lambda: validate_source(mutated(source_data, "chapar_remote", "https://github.com/nscaledev/chapar"), str(source_root), "fixture-approver", "fixture-ticket"), "chapar_remote mismatch"))
        cases.append(expect_child_failure("source-unrelated-remote", lambda: validate_source(mutated(source_data, "chapar_remote", "https://example.invalid/chapar.git"), str(source_root), "fixture-approver", "fixture-ticket"), "chapar_remote mismatch"))
        cases.append(expect_child_failure("source-noncanonical-path", lambda: validate_source(mutated(source_data, "source_lock_path", str(source_root) + "/./containers/images/sources-lock.json"), str(source_root), "fixture-approver", "fixture-ticket"), "source_lock_path mismatch"))
        cases.append(expect_child_failure("source-lock-hash-drift", lambda: validate_source(mutated(source_data, "source_lock_sha256", "0" * 64), str(source_root), "fixture-approver", "fixture-ticket"), "source lock content mismatch"))

        build_root = root / "build"
        spack_lock = build_root / "envs/vlad/spack.lock"
        spack_lock.parent.mkdir(parents=True)
        spack_lock.write_text('{"lock":"fixture"}\n', encoding="utf-8")
        release_dir = root / "vlad/linux/releases/release-1"
        release_dir.mkdir(parents=True)
        metadata = release_dir / "metadata.txt"
        metadata.write_text("release_id: release-1\n", encoding="utf-8")
        validation_root = root / "validation"
        validation_root.mkdir()
        release_path = validation_root / "release-binding.json"
        release_inputs_fixture = ReleaseInputs(str(release_path), str(release_dir), str(metadata), str(spack_lock), "a" * 40, "b" * 64, "linux-x86_64-v4", "release-1", "integrity-passed")
        release_json = release_data(release_inputs_fixture)
        write_exclusive_json(str(release_path), release_json)
        validate_release(receipt(str(release_path))[0], release_inputs_fixture)
        cases.append("release-schema-happy")
        cases.append(expect_child_failure("release-wrong-status", lambda: validate_release(mutated(release_json, "status", "promoted")), "release status mismatch"))
        cases.append(expect_child_failure("release-unknown-key", lambda: validate_release({**release_json, "unknown": "rejected"}), "key set mismatch"))
        wrong_release_dir = root / "vlad/linux/releases/wrong-release"
        wrong_release_dir.mkdir(parents=True)
        wrong_metadata = wrong_release_dir / "metadata.txt"
        wrong_metadata.write_text("release_id=release-1\n", encoding="utf-8")
        cases.append(expect_child_failure("release-wrong-metadata-delimiter", lambda: release_data(ReleaseInputs(str(root / "wrong.json"), str(wrong_release_dir), str(wrong_metadata), str(spack_lock), "a" * 40, "b" * 64, "linux-x86_64-v4", "release-1", "integrity-passed")), "release metadata ID mismatch"))

        image_bytes = b"sealed image bytes"
        image_sha = hashlib.sha256(image_bytes).hexdigest()
        image_dir = root / f"candidates/linux-x86_64-v4/image-1/{image_sha}"
        image_dir.mkdir(parents=True)
        image = image_dir / "nvidia-vlad.sqsh"
        image.write_bytes(image_bytes)
        image.chmod(0o444)
        builder_path = validation_root / "builder-handoff.json"
        builder_json: JsonMap = {
            "schema": BUILDER_SCHEMA, "build_root": str(build_root),
            "chapar_commit": "a" * 40, "source_lock_sha256": "b" * 64,
            "release_binding": str(release_path),
            "release_binding_sha256": hashlib.sha256(release_path.read_bytes()).hexdigest(),
            "target": "linux-x86_64-v4", "image_id": "image-1",
            "image_path": str(image), "image_sha256": image_sha,
            "image_size": len(image_bytes), "validation_root": str(validation_root),
        }
        validate_builder(builder_json)
        write_exclusive_json(str(builder_path), builder_json)
        cases.append("builder-schema-happy")
        cases.append(expect_child_failure("builder-image-hash-drift", lambda: validate_builder(mutated(builder_json, "image_sha256", "0" * 64)), "builder image digest mismatch"))
        cases.append(expect_child_failure("builder-receipt-unknown-key", lambda: validate_builder({**builder_json, "unknown": "rejected"}), "key set mismatch"))

        validator_image_root = root / "validator-images"
        validator_image_dir = validator_image_root / f"linux-x86_64-v4/image-1/{image_sha}"
        validator_image_dir.mkdir(parents=True)
        validator_image = validator_image_dir / image.name
        validator_image.write_bytes(image_bytes)
        validator_image.chmod(0o444)
        validator_root = root / "validator-receipts"
        receipt_root = validator_root / f"linux-x86_64-v4/image-1/{image_sha}"
        receipt_root.mkdir(parents=True)
        preflight = receipt_root / "runtime-preflight.json"
        smoke = receipt_root / "pyxis-smoke.txt"
        preflight.write_text('{"status":"pass"}\n', encoding="utf-8")
        smoke.write_text("smoke passed\n", encoding="utf-8")
        runtime_path = receipt_root / "receipt.json"
        runtime_args = argparse.Namespace(
            builder_handoff=str(builder_path), builder_handoff_sha256=hashlib.sha256(builder_path.read_bytes()).hexdigest(),
            release_binding=str(release_path), target="linux-x86_64-v4", sha256=image_sha,
            validator_root=str(validator_root), validator_image_root=str(validator_image_root),
            image=str(validator_image), output=str(runtime_path), preflight=str(preflight), smoke_output=str(smoke),
        )
        runtime_json = runtime_data(runtime_args)
        write_exclusive_json(str(runtime_path), runtime_json)
        runtime_verify_args = argparse.Namespace(
            runtime_receipt=str(runtime_path), builder_handoff=str(builder_path),
            builder_handoff_sha256=runtime_args.builder_handoff_sha256,
            release_binding=str(release_path), target="linux-x86_64-v4",
        )
        validate_runtime(runtime_json, runtime_verify_args)
        cases.append("runtime-schema-happy")
        cases.append(expect_child_failure("runtime-wrong-status", lambda: validate_runtime(mutated(runtime_json, "status", "failed"), runtime_verify_args), "runtime status must be passed"))
        cases.append(expect_child_failure("runtime-receipt-self-path-drift", lambda: validate_runtime(mutated(runtime_json, "runtime_receipt_path", str(root / "other.json")), runtime_verify_args), "self-path mismatch"))
        cases.append(expect_child_failure("runtime-preflight-hash-drift", lambda: validate_runtime(mutated(runtime_json, "runtime_preflight_sha256", "0" * 64), runtime_verify_args), "runtime preflight drift"))
        cases.append(expect_child_failure("receipt-digest-drift", lambda: receipt(str(runtime_path), "0" * 64), "receipt SHA-256 mismatch"))

        capture = root / "capture.txt"
        capture_child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--run-and-capture", "--output", str(capture), "--", sys.executable, "-c", "print('captured')"], check=False, capture_output=True, text=True)
        require(capture_child.returncode == 0 and capture.read_text(encoding="utf-8") == "captured\n", f"run-and-capture CLI failed: {capture_child.stderr}")
        cases.append("run-and-capture-cli")
        collision_child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--run-and-capture", "--output", str(capture), "--", sys.executable, "-c", "print('overwrite')"], check=False, capture_output=True, text=True)
        require(collision_child.returncode == 1 and "File exists" in collision_child.stderr, "capture O_EXCL collision failed for wrong reason")
        cases.append("run-and-capture-o-excl")

        evidence = root / "evidence"
        evidence.mkdir()
        evidence_file = evidence / "proof.txt"
        evidence_file.write_text("proof\n", encoding="utf-8")
        original = evidence.stat()
        identity = f"{original.st_dev}:{original.st_ino}"
        seal_args = argparse.Namespace(seal_evidence_directory=str(evidence), expected_directory_identity=identity, file_mode="0444", directory_mode="0555")
        seal_evidence(seal_args)
        cases.append("seal-evidence-happy")
        cases.append(expect_child_failure("sealed-identity-drift", lambda: require_directory_identity(evidence.stat(), "0:0", "sealed directory"), "identity drift"))
        sealed_bytes = read_file(str(evidence_file), "sealed evidence", 0o444)
        cases.append(expect_child_failure("sealed-hash-drift", lambda: require(sealed_bytes.sha256 == Sha256("0" * 64), "sealed file digest mismatch"), "sealed file digest mismatch"))
        cases.append(expect_child_failure("publisher-role-denial", lambda: require_owner_mode(evidence_file.stat(), os.geteuid() + 1, 0o444, "sealed file"), "owner/mode mismatch"))
        cases.append(expect_child_failure("writable-evidence-ancestor", lambda: require_owner_mode(root.stat(), 0, 0o555, "evidence ancestor"), "owner/mode mismatch"))
        evidence.chmod(0o755)
        evidence.rename(root / "evidence-old")
        evidence.mkdir()
        cases.append(expect_child_failure("post-seal-directory-replacement", lambda: seal_evidence(argparse.Namespace(seal_evidence_directory=str(evidence), expected_directory_identity=identity, file_mode="0444", directory_mode="0555")), "identity drift"))
        preseal = root / "preseal"
        preseal.mkdir()
        preseal_info = preseal.stat()
        preseal_identity = f"{preseal_info.st_dev}:{preseal_info.st_ino}"
        preseal.rmdir()
        preseal.mkdir()
        cases.append(expect_child_failure("pre-seal-directory-replacement", lambda: seal_evidence(argparse.Namespace(seal_evidence_directory=str(preseal), expected_directory_identity=preseal_identity, file_mode="0444", directory_mode="0555")), "identity drift"))

        if sys.platform.startswith("linux"):
            cases.append(expect_child_failure("linux-evidence-role-setup", lambda: verify_empty_evidence(str(preseal), "validator"), "owner role"))
        else:
            for label in ("linux-faccess-setup-error", "evidence-cli-boundary-setup-error"):
                setup_case = expect_child_failure(label, lambda: faccess(os.open("/", DIR_FLAGS), os.W_OK), "require Linux")
                print(f"SETUP-UNSUPPORTED:{setup_case}: platform={sys.platform}")
    print("Vlad receipt and evidence self-test passed: " + ",".join(cases))


def add_release_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--release-dir")
    parser.add_argument("--metadata")
    parser.add_argument("--spack-lock")
    parser.add_argument("--chapar-commit")
    parser.add_argument("--source-lock-sha256")
    parser.add_argument("--target")
    parser.add_argument("--release-id")
    parser.add_argument("--status")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--receipt")
    actions.add_argument("--write-release-binding", dest="write_release_binding")
    actions.add_argument("--verify-release-binding", dest="verify_release_binding")
    actions.add_argument("--write-builder-handoff", dest="write_builder_handoff")
    actions.add_argument("--verify-builder-handoff", dest="verify_builder_handoff")
    actions.add_argument("--write-runtime-receipt", dest="write_runtime_receipt")
    actions.add_argument("--verify-runtime-receipt", dest="verify_runtime_receipt")
    actions.add_argument("--verify-empty-evidence-directory", dest="verify_empty_evidence_directory")
    actions.add_argument("--run-and-capture", action="store_true")
    actions.add_argument("--seal-evidence-directory", dest="seal_evidence_directory")
    actions.add_argument("--verify-sealed-evidence-directory", dest="verify_sealed_evidence_directory")
    actions.add_argument("--extract-canonical-field", action="store_true")
    actions.add_argument("--self-test", action="store_true")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--expected-approved-by")
    parser.add_argument("--expected-change-ticket")
    parser.add_argument("--chapar-root")
    add_release_arguments(parser)
    parser.add_argument("--build-root")
    parser.add_argument("--release-binding")
    parser.add_argument("--image-id")
    parser.add_argument("--image")
    parser.add_argument("--image-sha256")
    parser.add_argument("--image-size", type=int)
    parser.add_argument("--expected-chapar-commit")
    parser.add_argument("--builder-handoff")
    parser.add_argument("--builder-handoff-sha256")
    parser.add_argument("--validator-root")
    parser.add_argument("--validator-image-root")
    parser.add_argument("--preflight")
    parser.add_argument("--smoke-output")
    parser.add_argument("--sha256")
    parser.add_argument("--owner-role")
    parser.add_argument("--output")
    parser.add_argument("--capture-stderr", action="store_true")
    parser.add_argument("--expected-directory-identity")
    parser.add_argument("--file-mode")
    parser.add_argument("--directory-mode")
    parser.add_argument("--expected-file")
    parser.add_argument("--schema", choices=("directory-identity", "sealed-evidence"))
    parser.add_argument("--field")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def required(value: str | int | None, label: str) -> str:
    require(type(value) is str and value != "", f"{label} is required")
    return value


def release_inputs(args: argparse.Namespace, output: str) -> ReleaseInputs:
    return ReleaseInputs(output, required(args.release_dir, "release dir"), required(args.metadata, "metadata"), required(args.spack_lock, "Spack lock"), required(args.chapar_commit, "commit"), required(args.source_lock_sha256, "source lock digest"), required(args.target, "target"), required(args.release_id, "release ID"), required(args.status, "status"))


def dispatch(args: argparse.Namespace) -> None:
    if args.self_test:
        self_test()
    elif args.receipt:
        data, _ = receipt(args.receipt, required(args.expected_sha256, "expected digest"))
        validate_source(data, required(args.chapar_root, "chapar root"), required(args.expected_approved_by, "expected approver"), required(args.expected_change_ticket, "expected ticket"))
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_release_binding:
        inputs = release_inputs(args, args.write_release_binding)
        data = release_data(inputs)
        write_exclusive_json(inputs.output, data)
        validate_release(receipt(inputs.output)[0], inputs)
    elif args.verify_release_binding:
        inputs = release_inputs(args, args.verify_release_binding)
        data, _ = receipt(inputs.output)
        validate_release(data, inputs)
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_builder_handoff:
        args.output = args.write_builder_handoff
        data = builder_data(args)
        write_exclusive_json(args.output, data)
        validate_builder(receipt(args.output)[0])
    elif args.verify_builder_handoff:
        data, _ = receipt(args.verify_builder_handoff, required(args.expected_sha256, "expected digest"))
        validate_builder(data, required(args.expected_chapar_commit, "expected commit"))
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_runtime_receipt:
        args.output = args.write_runtime_receipt
        data = runtime_data(args)
        write_exclusive_json(args.output, data)
        verify_args = argparse.Namespace(**vars(args))
        verify_args.runtime_receipt = args.output
        validate_runtime(receipt(args.output)[0], verify_args)
    elif args.verify_runtime_receipt:
        args.runtime_receipt = args.verify_runtime_receipt
        data, _ = receipt(args.runtime_receipt, required(args.expected_sha256, "expected digest"))
        validate_runtime(data, args)
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.verify_empty_evidence_directory:
        print(json.dumps(verify_empty_evidence(args.verify_empty_evidence_directory, required(args.owner_role, "owner role")), sort_keys=True, separators=(",", ":")))
    elif args.run_and_capture:
        if args.command and args.command[0] == "--":
            args.command = args.command[1:]
        run_and_capture(args)
    elif args.seal_evidence_directory:
        seal_evidence(args)
    elif args.verify_sealed_evidence_directory:
        print(json.dumps(verify_sealed(args), sort_keys=True, separators=(",", ":")))
    elif args.extract_canonical_field:
        extract_canonical(args)


def main() -> int:
    try:
        dispatch(parse_args())
    except (ContractError, OSError, subprocess.SubprocessError) as error:
        print(f"Vlad receipt verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
