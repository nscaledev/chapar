#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/install-vlad-image-site-contract.sh \
  --source PATH \
  --expected-sha256 SHA256 \
  --schema PATH \
  --destination /etc/chapar/vlad-image/site-contract.json

Validate and atomically install the host-owned Vlad image site contract and its
protected expected-hash file. Production installation requires root, fixes the
destination to /etc/chapar/vlad-image/site-contract.json, and accepts neither a
workspace-local source nor symlinked or writable path components.

Disposable tests must set VLAD_IMAGE_CONTRACT_INSTALL_TEST_MODE=1 and provide a
private absolute VLAD_IMAGE_CONTRACT_INSTALL_TEST_ROOT. Test mode rejects /etc,
/resources, /shared, the source checkout, and paths outside that test root.
USAGE
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 - "${SCRIPT_DIR}" "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Final

SCRIPT_DIR = Path(sys.argv[1])
REPOSITORY_ROOT = SCRIPT_DIR.parent
TRACKED_SCHEMA = REPOSITORY_ROOT / "containers/images/site-contract.schema.json"
PRODUCTION_DESTINATION = Path("/etc/chapar/vlad-image/site-contract.json")
EXPECTED_SCHEMA_ID: Final = "https://nscaledev.github.io/chapar/schemas/vlad-image-site-contract/v1"
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
PLACEHOLDER_RE: Final = re.compile(r"(?:PLACEHOLDER|REPLACE|CHANGEME|EXAMPLE|TODO)", re.IGNORECASE)
PUBLIC_ROOTS: Final = (Path("/etc"), Path("/resources"), Path("/shared"))
sys.argv = [sys.argv[0], *sys.argv[2:]]


class InstallError(Exception):
    pass


def fail(message: str) -> None:
    raise InstallError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def normalized_absolute(raw: str, label: str) -> Path:
    if not raw or any(ord(character) < 32 for character in raw):
        fail(f"{label} is empty or contains control characters")
    path = Path(raw)
    if not path.is_absolute() or path != Path(os.path.normpath(raw)) or ".." in path.parts:
        fail(f"{label} must be a normalized absolute path")
    return path


def under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def inspect_components(path: Path, stop: Path, expected_uid: int | None, label: str) -> os.stat_result:
    if path != stop and not under(path, stop):
        fail(f"{label} must be below its trust anchor")
    current = path
    final_stat: os.stat_result | None = None
    while True:
        try:
            component_stat = current.lstat()
        except OSError as error:
            fail(f"cannot inspect {label} component {current}: {error}")
        if stat.S_ISLNK(component_stat.st_mode):
            fail(f"{label} contains a symlink component: {current}")
        if current == path:
            final_stat = component_stat
        else:
            if not stat.S_ISDIR(component_stat.st_mode):
                fail(f"{label} parent is not a directory: {current}")
            if expected_uid is not None and component_stat.st_uid != expected_uid:
                fail(f"{label} parent has the wrong owner: {current}")
            if stat.S_IMODE(component_stat.st_mode) & 0o022:
                fail(f"{label} parent is group/world writable: {current}")
        if current == stop:
            break
        current = current.parent
    if final_stat is None:
        fail(f"cannot inspect {label}")
    return final_stat


def secure_read(path: Path, stop: Path, expected_uid: int | None, label: str, require_owner: bool) -> bytes:
    initial = inspect_components(path, stop, expected_uid if require_owner else None, label)
    if not stat.S_ISREG(initial.st_mode):
        fail(f"{label} must be a regular file")
    if require_owner and initial.st_uid != expected_uid:
        fail(f"{label} has the wrong owner")
    mode = stat.S_IMODE(initial.st_mode)
    if require_owner and ((mode & 0o022) or not (mode & stat.S_IRUSR)):
        fail(f"{label} mode must be 0644 or stricter and owner-readable")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot securely open {label}: {error}")
    try:
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino, opened.st_uid, stat.S_IMODE(opened.st_mode))
        expected = (initial.st_dev, initial.st_ino, initial.st_uid, mode)
        if identity != expected or not stat.S_ISREG(opened.st_mode):
            fail(f"{label} changed while it was opened")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            return stream.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def parse_json(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid UTF-8 JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def validate_contract(contract: dict[str, Any], schema: dict[str, Any]) -> None:
    if schema.get("$id") != EXPECTED_SCHEMA_ID or schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("tracked schema identity or draft is unsupported")
    try:
        import jsonschema

        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.Draft202012Validator(schema).validate(contract)
    except ImportError:
        fail("python jsonschema is required before privileged installation")
    except jsonschema.exceptions.SchemaError as error:
        fail(f"tracked schema is invalid: {error.message}")
    except jsonschema.exceptions.ValidationError as error:
        fail(f"site contract does not validate against the tracked schema: {error.message}")
    if contract.get("status") != "active":
        fail("example or inactive site contract is forbidden")
    if PLACEHOLDER_RE.search(json.dumps(contract, sort_keys=True)):
        fail("site contract contains a placeholder")
    roles = contract.get("roles")
    if not isinstance(roles, dict):
        fail("site contract roles are invalid")
    seen: dict[str, str] = {}
    for role in ("builders", "publishers", "validators"):
        identities = roles.get(role)
        if not isinstance(identities, list) or not identities:
            fail(f"site contract role allowlist is empty: {role}")
        for identity in identities:
            if identity in seen:
                fail(f"machine identity is duplicated across roles: {seen[identity]} and {role}")
            seen[identity] = role


def open_directory(path: Path, stop: Path, expected_uid: int, create: bool) -> int:
    relative = path.relative_to(stop)
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(stop, flags)
    try:
        for component in relative.parts:
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(component, 0o755, dir_fd=descriptor)
                child = os.open(component, flags, dir_fd=descriptor)
            component_stat = os.fstat(child)
            if component_stat.st_uid != expected_uid or stat.S_IMODE(component_stat.st_mode) & 0o022:
                os.close(child)
                fail(f"destination parent has unsafe owner or mode: {path}")
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def atomic_write(parent_fd: int, name: str, content: bytes, mode: int, expected_uid: int) -> None:
    try:
        existing = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    if existing is not None:
        if not stat.S_ISREG(existing.st_mode) or existing.st_uid != expected_uid:
            fail(f"destination must be absent or a correctly owned regular file: {name}")
        if stat.S_IMODE(existing.st_mode) & 0o022:
            fail(f"destination file has an unsafe mode: {name}")
    temporary = f".{name}.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600, dir_fd=parent_fd)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            if os.geteuid() == 0:
                os.fchown(stream.fileno(), expected_uid, -1)
        os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass


def validate_destination_before_mutation(destination: Path, stop: Path, expected_uid: int) -> None:
    current = destination.parent
    while True:
        try:
            current.lstat()
            break
        except FileNotFoundError:
            if current == stop:
                fail("destination trust anchor is missing")
            current = current.parent
        except OSError as error:
            fail(f"cannot inspect destination parent {current}: {error}")
    existing_parent = inspect_components(current, stop, expected_uid, "destination parent")
    if not stat.S_ISDIR(existing_parent.st_mode):
        fail("nearest existing destination parent is not a directory")
    try:
        destination.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        fail(f"cannot inspect destination: {error}")
    existing = inspect_components(destination, stop, expected_uid, "destination")
    if not stat.S_ISREG(existing.st_mode) or existing.st_uid != expected_uid:
        fail("destination must be absent or a correctly owned regular file")
    if stat.S_IMODE(existing.st_mode) & 0o022:
        fail("destination file has an unsafe mode")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source", required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()
    if args.help:
        fail("--help must be used by itself")
    return args


def main() -> None:
    args = parse_args()
    if SHA256_RE.fullmatch(args.expected_sha256) is None:
        fail("--expected-sha256 must be a full lowercase SHA-256")
    source = normalized_absolute(args.source, "source contract")
    schema_path = normalized_absolute(args.schema, "schema")
    destination = normalized_absolute(args.destination, "destination")
    test_mode = os.environ.get("VLAD_IMAGE_CONTRACT_INSTALL_TEST_MODE") == "1"

    if test_mode:
        raw_test_root = os.environ.get("VLAD_IMAGE_CONTRACT_INSTALL_TEST_ROOT")
        if raw_test_root is None:
            fail("test mode requires VLAD_IMAGE_CONTRACT_INSTALL_TEST_ROOT")
        trust_anchor = normalized_absolute(raw_test_root, "test root")
        anchor_stat = trust_anchor.lstat()
        expected_uid = os.geteuid()
        if not stat.S_ISDIR(anchor_stat.st_mode) or stat.S_ISLNK(anchor_stat.st_mode):
            fail("test root must be a real directory")
        if anchor_stat.st_uid != expected_uid or stat.S_IMODE(anchor_stat.st_mode) & 0o077:
            fail("test root must be owned by the test identity and mode 0700 or stricter")
        for label, path in (("source contract", source), ("schema", schema_path), ("destination", destination)):
            if not under(path, trust_anchor):
                fail(f"test mode requires {label} below the isolated test root")
            if any(under(path, root) for root in PUBLIC_ROOTS) or under(path, REPOSITORY_ROOT):
                fail(f"test mode rejects public or workspace path for {label}")
    else:
        if os.geteuid() != 0:
            fail("production installation must run as root")
        if destination != PRODUCTION_DESTINATION:
            fail(f"production destination is fixed at {PRODUCTION_DESTINATION}")
        if schema_path != TRACKED_SCHEMA:
            fail(f"production schema is fixed at {TRACKED_SCHEMA}")
        if under(source, REPOSITORY_ROOT):
            fail("production source contract cannot be workspace-local")
        trust_anchor = Path("/")
        expected_uid = 0

    source_bytes = secure_read(source, trust_anchor, expected_uid, "source contract", require_owner=True)
    schema_bytes = secure_read(schema_path, trust_anchor, expected_uid, "schema", require_owner=test_mode)
    actual_sha256 = hashlib.sha256(source_bytes).hexdigest()
    if actual_sha256 != args.expected_sha256:
        fail("source contract SHA-256 does not match the operator-provided expected value")
    validate_contract(parse_json(source_bytes, "source contract"), parse_json(schema_bytes, "schema"))
    validate_destination_before_mutation(destination, trust_anchor, expected_uid)

    marker = os.environ.get("VLAD_IMAGE_CONTRACT_INSTALL_SIDE_EFFECT_MARKER")
    if marker:
        marker_path = normalized_absolute(marker, "side-effect marker")
        if not test_mode or not under(marker_path, trust_anchor):
            fail("side-effect marker is allowed only inside the isolated test root")
        marker_path.touch(exist_ok=False)

    parent_fd = open_directory(destination.parent, trust_anchor, expected_uid, create=True)
    try:
        atomic_write(parent_fd, destination.name, source_bytes, 0o644, expected_uid)
        atomic_write(parent_fd, "site-contract.sha256", (actual_sha256 + "\n").encode("ascii"), 0o600, expected_uid)
    finally:
        os.close(parent_fd)
    print(f"installed Vlad image site contract SHA-256 {actual_sha256} at {destination}")


try:
    main()
except (InstallError, OSError, ValueError, TypeError) as error:
    print(f"site contract installation failed: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
