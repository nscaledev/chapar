#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/register-vlad-image-runner.sh --role ROLE [options]

Required:
  --role builder|validator|publisher
  --credential-file PATH        Root-owned 0600 registration-token file
  --removal-token-file PATH     Root-owned 0600 GitHub runner removal-token file

Builder only:
  --target TARGET               linux-x86_64-generic, linux-x86_64-v4,
                                linux-aarch64-generic, or linux-aarch64-gb300

Options:
  --runner-name NAME            Defaults to chapar-vlad-image-ROLE-HOSTNAME
  --bootstrap-packages          Install only checksum-locked Ubuntu packages
  --runtime-max-seconds N       Builder one-job service limit (default: 21600)
  -h, --help                    Show this help

The repository is fixed at https://github.com/nscaledev/chapar. Production
reads the contract and protected expected hash only from
/etc/chapar/vlad-image/site-contract.{json,sha256}; no hash argument or workflow
output is accepted. Builder registration is ephemeral and one-job. Validator
and publisher runners are persistent, non-Docker submission/publication roles.
The removal token must come from GitHub's runner removal-token endpoint, remain
valid for the builder lifecycle, and be distinct from the registration token.
USAGE
}

ROLE=""
TARGET=""
CREDENTIAL_FILE=""
REMOVAL_TOKEN_FILE=""
RUNNER_NAME=""
BOOTSTRAP_PACKAGES=false
RUNTIME_MAX_SECONDS=21600

while [ "$#" -gt 0 ]; do
    case "$1" in
        --role) ROLE="${2:-}"; shift 2 ;;
        --target) TARGET="${2:-}"; shift 2 ;;
        --credential-file) CREDENTIAL_FILE="${2:-}"; shift 2 ;;
        --removal-token-file) REMOVAL_TOKEN_FILE="${2:-}"; shift 2 ;;
        --runner-name) RUNNER_NAME="${2:-}"; shift 2 ;;
        --bootstrap-packages) BOOTSTRAP_PACKAGES=true; shift ;;
        --runtime-max-seconds) RUNTIME_MAX_SECONDS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SOURCES_LOCK="${REPOSITORY_ROOT}/containers/images/sources-lock.json"
SITE_CONTRACT="/etc/chapar/vlad-image/site-contract.json"
EXPECTED_HASH_FILE="/etc/chapar/vlad-image/site-contract.sha256"
SELECTION="/etc/chapar/vlad-image/selection.json"
SELECTION_HASH_FILE="/etc/chapar/vlad-image/selection.sha256"
MACHINE_ID_FILE="/etc/machine-id"
OS_RELEASE_FILE="/usr/lib/os-release"
TEST_MODE="${VLAD_IMAGE_RUNNER_TEST_MODE:-0}"
TEST_ROOT="${VLAD_IMAGE_RUNNER_TEST_ROOT:-}"

if [ "${TEST_MODE}" = 1 ]; then
    SOURCES_LOCK="${VLAD_IMAGE_RUNNER_TEST_SOURCES_LOCK:-}"
    SITE_CONTRACT="${VLAD_IMAGE_RUNNER_TEST_SITE_CONTRACT:-}"
    EXPECTED_HASH_FILE="${VLAD_IMAGE_RUNNER_TEST_EXPECTED_HASH_FILE:-}"
    SELECTION="${VLAD_IMAGE_RUNNER_TEST_SELECTION:-}"
    SELECTION_HASH_FILE="${VLAD_IMAGE_RUNNER_TEST_SELECTION_HASH_FILE:-}"
    MACHINE_ID_FILE="${VLAD_IMAGE_RUNNER_TEST_MACHINE_ID:-}"
    OS_RELEASE_FILE="${VLAD_IMAGE_RUNNER_TEST_OS_RELEASE:-}"
fi

PREFLIGHT_JSON="$(PYTHONPATH="${REPOSITORY_ROOT}/containers/images" python3 - "${REPOSITORY_ROOT}" "${TEST_MODE}" "${TEST_ROOT}" \
    "${SOURCES_LOCK}" "${SITE_CONTRACT}" "${EXPECTED_HASH_FILE}" "${SELECTION}" "${SELECTION_HASH_FILE}" "${MACHINE_ID_FILE}" \
    "${OS_RELEASE_FILE}" "${ROLE}" "${TARGET}" "${CREDENTIAL_FILE}" "${REMOVAL_TOKEN_FILE}" \
    "${RUNNER_NAME}" "${RUNTIME_MAX_SECONDS}" "${VLAD_IMAGE_RUNNER_SIDE_EFFECT_MARKER:-}" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Final

(
    repository_root_raw,
    test_mode_raw,
    test_root_raw,
    sources_raw,
    contract_raw,
    expected_hash_raw,
    selection_raw,
    selection_hash_raw,
    machine_id_raw,
    os_release_raw,
    role,
    target,
    credential_raw,
    removal_token_raw,
    runner_name,
    runtime_max_raw,
    marker_raw,
) = sys.argv[1:]
repository_root = Path(repository_root_raw)
from registry import parse_targets
from selection_contract import validate_selection

REGISTRY_TARGETS = parse_targets(repository_root / "containers/images/targets.json")
test_mode = test_mode_raw == "1"
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE: Final = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE: Final = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:-[0-9A-Za-z.]+)?$")
NAME_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PLACEHOLDER_RE: Final = re.compile(r"(?:PLACEHOLDER|REPLACE|CHANGEME|EXAMPLE|TODO)", re.IGNORECASE)
EXPECTED_REPOSITORY = "https://github.com/nscaledev/chapar"
ROLE_KEYS: Final = {"builder": "builder", "validator": "validator", "publisher": "publisher"}
PUBLIC_ROOTS: Final = (Path("/etc"), Path("/resources"), Path("/shared"))


class ValidationError(Exception):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def absolute(raw: str, label: str) -> Path:
    if not raw or any(ord(character) < 32 for character in raw):
        fail(f"{label} is missing or contains control characters")
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


def secure_read(path: Path, anchor: Path, expected_uid: int, label: str, maximum_mode: int, require_owner: bool = True) -> bytes:
    current = path
    initial: os.stat_result | None = None
    while True:
        try:
            value = current.lstat()
        except OSError as error:
            fail(f"cannot inspect {label} component {current}: {error}")
        if stat.S_ISLNK(value.st_mode):
            fail(f"{label} contains a symlink component: {current}")
        if current == path:
            initial = value
        else:
            if not stat.S_ISDIR(value.st_mode) or (require_owner and value.st_uid != expected_uid) or stat.S_IMODE(value.st_mode) & 0o022:
                fail(f"{label} parent has unsafe type, owner, or mode: {current}")
        if current == anchor:
            break
        if current == current.parent or not under(current, anchor):
            fail(f"{label} escapes its trust anchor")
        current = current.parent
    if initial is None or not stat.S_ISREG(initial.st_mode) or (require_owner and initial.st_uid != expected_uid):
        fail(f"{label} must be a correctly owned regular file")
    mode = stat.S_IMODE(initial.st_mode)
    if mode & ~maximum_mode or not mode & stat.S_IRUSR:
        fail(f"{label} has an unsafe mode")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot securely open {label}: {error}")
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_uid, stat.S_IMODE(opened.st_mode)) != (
            initial.st_dev, initial.st_ino, initial.st_uid, mode
        ):
            fail(f"{label} changed while it was opened")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            return stream.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def load_json(raw: bytes, label: str) -> dict[str, Any]:
    try:
        loaded = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid UTF-8 JSON: {error}")
    if not isinstance(loaded, dict):
        fail(f"{label} must be a JSON object")
    return loaded


if role not in ROLE_KEYS:
    fail("--role must be exactly builder, validator, or publisher")
if role == "builder":
    if target not in REGISTRY_TARGETS:
        fail("builder requires one approved --target")
else:
    if target:
        fail("--target is accepted only for the builder role")
if runner_name and NAME_RE.fullmatch(runner_name) is None:
    fail("runner name contains unsupported characters")
try:
    runtime_max = int(runtime_max_raw)
except ValueError:
    fail("runtime maximum must be an integer")
if not 60 <= runtime_max <= 86400:
    fail("runtime maximum must be between 60 and 86400 seconds")

paths = {
    "sources lock": absolute(sources_raw, "sources lock"),
    "site contract": absolute(contract_raw, "site contract"),
    "expected hash": absolute(expected_hash_raw, "expected hash"),
    "selection": absolute(selection_raw, "selection"),
    "selection expected hash": absolute(selection_hash_raw, "selection expected hash"),
    "machine ID": absolute(machine_id_raw, "machine ID"),
    "OS release": absolute(os_release_raw, "OS release"),
    "credential": absolute(credential_raw, "credential file"),
    "removal token": absolute(removal_token_raw, "removal token file"),
}
if test_mode:
    anchor_input = absolute(test_root_raw, "test root")
    try:
        anchor = anchor_input.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve test root: {error}")
    if anchor != anchor_input:
        fail("test root must be canonical and contain no symlink components")
    anchor_stat = anchor.lstat()
    expected_uid = os.geteuid()
    if not stat.S_ISDIR(anchor_stat.st_mode) or stat.S_ISLNK(anchor_stat.st_mode) or anchor_stat.st_uid != expected_uid:
        fail("test root must be a real directory owned by the test identity")
    if stat.S_IMODE(anchor_stat.st_mode) & 0o077:
        fail("test root must be mode 0700 or stricter")
    for label, path in paths.items():
        if not under(path, anchor) or any(under(path, root) for root in PUBLIC_ROOTS) or under(path, repository_root):
            fail(f"test mode rejects non-isolated path for {label}")
        if label != "OS release":
            try:
                resolved = path.resolve(strict=True)
            except OSError as error:
                fail(f"cannot resolve test {label}: {error}")
            if resolved != path or not under(resolved, anchor):
                fail(f"test mode requires canonical non-symlink path for {label}")
    marker = absolute(marker_raw, "side-effect marker")
    try:
        marker_parent = marker.parent.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve side-effect marker parent: {error}")
    canonical_marker = marker_parent / marker.name
    if marker != canonical_marker or not under(canonical_marker, anchor):
        fail("side-effect marker must be canonical and below the isolated test root")
    if marker.is_symlink() or (marker.exists() and not marker.is_file()):
        fail("side-effect marker must be absent or a non-symlink regular file")
else:
    if os.geteuid() != 0:
        fail("runner registration must run as root")
    anchor = Path("/")
    expected_uid = 0
    expected_production = {
        "sources lock": repository_root / "containers/images/sources-lock.json",
        "site contract": Path("/etc/chapar/vlad-image/site-contract.json"),
        "expected hash": Path("/etc/chapar/vlad-image/site-contract.sha256"),
        "machine ID": Path("/etc/machine-id"),
        "OS release": Path("/usr/lib/os-release"),
    }
    for label, expected in expected_production.items():
        if paths[label] != expected:
            fail(f"production {label} path is fixed at {expected}")
    if marker_raw:
        fail("side-effect marker is forbidden in production")
    canonical_marker = None

# The blocked lock is intentionally checked before contract, credential, package,
# archive, service, Docker, or public-root access.
source_bytes = secure_read(
    paths["sources lock"], anchor, expected_uid, "sources lock", 0o644 if not test_mode else 0o600, require_owner=test_mode
)
source = load_json(source_bytes, "sources lock")
if source.get("schema_version") != 1 or source.get("status") != "complete":
    fail("source lock is blocked or unsupported and registration must fail closed")
if source.get("unresolved") != []:
    fail("complete source lock must have no unresolved categories")
contract_meta = source.get("contract")
verified = source.get("verified")
required = contract_meta.get("required_categories") if isinstance(contract_meta, dict) else None
if not isinstance(required, list) or len(required) != len(set(required)) or not isinstance(verified, dict):
    fail("source lock required-category contract is invalid")
for category in required:
    if category not in verified or verified[category] in (None, [], {}):
        fail(f"source lock category is missing or empty: {category}")
    if not test_mode and isinstance(verified[category], dict) and verified[category].get("fixture") is True:
        fail(f"fixture source-lock category is forbidden in production: {category}")

for category in ("spack_repositories", "github_actions"):
    entries = verified.get(category)
    if not isinstance(entries, list) or not entries:
        fail(f"source lock category must be a nonempty array: {category}")
    for entry in entries:
        if not isinstance(entry, dict) or COMMIT_RE.fullmatch(str(entry.get("commit", ""))) is None:
            fail(f"floating branch/tag/abbreviated ref in {category}")

archive_entries = verified.get("actions_runner_archives")
if not isinstance(archive_entries, list) or len(archive_entries) != 2:
    fail("source lock requires exactly x64 and arm64 runner archives")
archives: dict[str, dict[str, Any]] = {}
for entry in archive_entries:
    if not isinstance(entry, dict) or set(entry) != {"architecture", "version", "url", "sha256"}:
        fail("runner archive entry has missing or unknown fields")
    architecture = entry.get("architecture")
    version = entry.get("version")
    digest = entry.get("sha256")
    if architecture not in {"x64", "arm64"} or architecture in archives:
        fail("runner archive architecture is invalid or duplicated")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None or "latest" in version.lower():
        fail("runner archive version is missing or floating")
    if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
        fail("runner archive checksum is missing or invalid")
    expected_url = f"https://github.com/actions/runner/releases/download/v{version}/actions-runner-linux-{architecture}-{version}.tar.gz"
    if entry.get("url") != expected_url:
        fail("runner archive URL does not match its immutable native identity")
    archives[architecture] = entry

host_machine = os.environ.get("VLAD_IMAGE_RUNNER_TEST_UNAME_M") if test_mode else os.uname().machine
native_map = {"x86_64": ("x64", "amd64"), "amd64": ("x64", "amd64"), "aarch64": ("arm64", "arm64"), "arm64": ("arm64", "arm64")}
if host_machine not in native_map:
    fail(f"unsupported native architecture: {host_machine}")
runner_arch, architecture_label = native_map[host_machine]
if role == "builder" and REGISTRY_TARGETS[target].native_arch != ("x86_64" if runner_arch == "x64" else "aarch64"):
    fail(f"native architecture mismatch for target: {target}")
archive = archives[runner_arch]
if archive["architecture"] != runner_arch:
    fail("selected runner archive architecture is not native")

os_release_path = paths["OS release"]
if test_mode and os_release_path.is_symlink():
    if os_release_path != anchor / "etc/os-release" or os.readlink(os_release_path) != "../usr/lib/os-release":
        fail("test OS release symlink must be the standard ../usr/lib/os-release link")
    os_release_path = anchor / "usr/lib/os-release"
    if os_release_path.resolve(strict=True) != os_release_path:
        fail("canonical test OS release target contains a symlink")
elif test_mode and os_release_path.resolve(strict=True) != os_release_path:
    fail("test OS release path contains an arbitrary symlink")
os_release = secure_read(os_release_path, anchor, expected_uid, "OS release", 0o644 if not test_mode else 0o600).decode("utf-8")
release_values = {}
for line in os_release.splitlines():
    key, separator, value = line.partition("=")
    if separator and key in {"ID", "VERSION_ID"}:
        release_values[key] = value.strip().strip('"')
if release_values != {"ID": "ubuntu", "VERSION_ID": "24.04"}:
    fail("runner host must be Ubuntu 24.04")

hash_bytes = secure_read(paths["expected hash"], anchor, expected_uid, "protected expected hash", 0o600)
try:
    protected_hash = hash_bytes.decode("ascii").strip()
except UnicodeError:
    fail("protected expected hash is not ASCII")
if SHA256_RE.fullmatch(protected_hash) is None:
    fail("protected expected hash is absent or invalid")
contract_bytes = secure_read(paths["site contract"], anchor, expected_uid, "site contract", 0o644)
if hashlib.sha256(contract_bytes).hexdigest() != protected_hash:
    fail("site contract does not match the protected expected hash")
site = load_json(contract_bytes, "site contract")
if not test_mode and site.get("status") != "active":
    fail("production target contract must be active")
selection_hash_bytes = secure_read(paths["selection expected hash"], anchor, expected_uid, "protected selection hash", 0o600)
try:
    selection_hash = selection_hash_bytes.decode("ascii").strip()
except UnicodeError:
    fail("protected selection hash is not ASCII")
selection_bytes = secure_read(paths["selection"], anchor, expected_uid, "selection", 0o644)
if SHA256_RE.fullmatch(selection_hash) is None or hashlib.sha256(selection_bytes).hexdigest() != selection_hash:
    fail("selection does not match the protected expected hash")
selection = validate_selection(load_json(selection_bytes, "selection"))
policy = selection.policy
authorities = selection.authorities
if authorities.get("target_contract") != protected_hash:
    fail("selection does not bind installed target contract")
if policy.get("datacenter") != site.get("datacenter_id") or policy.get("target") != site.get("target"):
    fail("selection and target contract identities differ")
if role == "builder" and policy.get("target") != target:
    fail("builder target differs from selected contract")
roles = site.get("roles")
if not isinstance(roles, dict) or set(roles) != set(ROLE_KEYS):
    fail("site contract roles are invalid")
if roles.get(ROLE_KEYS[role]) != f"chapar-vlad-{role}":
    fail(f"selected contract role identity mismatch: {role}")

package_category = "ubuntu_builder_packages" if role == "builder" else "ubuntu_final_packages"
package_sets = verified.get(package_category)
if not isinstance(package_sets, list):
    fail(f"{package_category} must be an array")
matching = [item for item in package_sets if isinstance(item, dict) and item.get("architecture") == architecture_label]
if len(matching) != 1 or set(matching[0]) != {"architecture", "packages"} or not isinstance(matching[0]["packages"], list):
    fail(f"{package_category} requires one native architecture package set")
packages = matching[0]["packages"]
for package in packages:
    if not isinstance(package, dict) or set(package) != {"name", "version", "url", "sha256"}:
        fail("locked Ubuntu package has missing or unknown fields")
    if NAME_RE.fullmatch(str(package.get("name", ""))) is None or not str(package.get("version", "")) or "latest" in str(package.get("version", "")).lower():
        fail("locked Ubuntu package name/version is missing or floating")
    if not str(package.get("url", "")).startswith("https://snapshot.ubuntu.com/") or SHA256_RE.fullmatch(str(package.get("sha256", ""))) is None:
        fail("locked Ubuntu package URL or checksum is invalid")

credential_bytes = secure_read(paths["credential"], anchor, expected_uid, "registration credential", 0o600)
try:
    credential = credential_bytes.decode("ascii").strip()
except UnicodeError:
    fail("registration credential is not ASCII")
if not credential or len(credential) > 4096 or any(character.isspace() for character in credential):
    fail("registration credential is empty or malformed")
removal_token_bytes = secure_read(paths["removal token"], anchor, expected_uid, "runner removal token", 0o600)
try:
    removal_token = removal_token_bytes.decode("ascii").strip()
except UnicodeError:
    fail("runner removal token is not ASCII")
if not removal_token or len(removal_token) > 4096 or any(character.isspace() for character in removal_token):
    fail("runner removal token is empty or malformed")
if removal_token == credential:
    fail("runner removal token must be distinct from the registration token")
del credential, credential_bytes, removal_token, removal_token_bytes

labels = {
    "builder": f"chapar,ubuntu24.04,vlad-image-builder,{architecture_label}",
    "validator": "chapar,vlad-image-validator",
    "publisher": "chapar,vlad-image-publisher",
}[role]
print(json.dumps({
    "repository": EXPECTED_REPOSITORY,
    "role": role,
    "target": target or None,
    "runner_arch": runner_arch,
    "architecture_label": architecture_label,
    "labels": labels,
    "archive": archive,
    "packages": packages,
    "role_identity": roles[ROLE_KEYS[role]],
    "site_contract_sha256": protected_hash,
    "selection_sha256": selection_hash,
    "datacenter": policy.get("datacenter"),
    "software_set": policy.get("software_set"),
    "runtime_max_seconds": runtime_max,
    "os_release_path": str(os_release_path),
    "side_effect_marker": str(canonical_marker) if canonical_marker is not None else None,
    "staging_policy": "root-owned-0700-inactive-atomic-swap",
    "cleanup_authority": "dedicated-github-removal-token",
    "boot_cleanup": "enabled-oneshot-before-builder-registration",
}, separators=(",", ":"), sort_keys=True))
PY
)" || exit $?

json_value() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<<"${PREFLIGHT_JSON}"
}

ROLE="$(json_value role)"
RUNNER_ARCH="$(json_value runner_arch)"
LABELS="$(json_value labels)"
RUNNER_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["archive"]["version"])' <<<"${PREFLIGHT_JSON}")"
RUNNER_URL="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["archive"]["url"])' <<<"${PREFLIGHT_JSON}")"
RUNNER_SHA256="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["archive"]["sha256"])' <<<"${PREFLIGHT_JSON}")"
RUNNER_NAME="${RUNNER_NAME:-chapar-vlad-image-${ROLE}-$(hostname -s)}"
SIDE_EFFECT_MARKER="$(python3 -c 'import json,sys; value=json.load(sys.stdin)["side_effect_marker"]; print(value or "")' <<<"${PREFLIGHT_JSON}")"

if [ -n "${SIDE_EFFECT_MARKER}" ]; then
    : >"${SIDE_EFFECT_MARKER}"
fi

if [ "${TEST_MODE}" = 1 ]; then
    printf '%s\n' "${PREFLIGHT_JSON}"
    exit 0
fi

RUNNER_USER="chapar-vlad-${ROLE}"
RUNNER_BASE="/opt/actions-runner"
RUNNER_DIR="${RUNNER_BASE}/chapar-vlad-image-${ROLE}"
STAGING_DIR="${RUNNER_BASE}/.chapar-vlad-image-${ROLE}.staging.$$"
BACKUP_DIR="${RUNNER_BASE}/.chapar-vlad-image-${ROLE}.backup.$$"
WORK_DIR="/var/lib/chapar/vlad-image-runner/${ROLE}"
RUNTIME_DIR="/run/chapar-vlad-image-runner/${ROLE}"
UNIT_NAME="chapar-vlad-image-${ROLE}-runner.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
UNIT_TEMP="${UNIT_PATH}.tmp.$$"
BOOT_CLEANUP_UNIT="chapar-vlad-image-builder-boot-cleanup.service"
BOOT_CLEANUP_PATH="/etc/systemd/system/${BOOT_CLEANUP_UNIT}"
ARCHIVE="${RUNTIME_DIR}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
TOKEN_PATH="${RUNTIME_DIR}/registration-token"
REMOVAL_STATE_DIR="/var/lib/chapar/vlad-image-runner/removal/${ROLE}"
REMOVAL_TOKEN_PATH="${REMOVAL_STATE_DIR}/removal-token"
CLEANUP="/usr/local/libexec/chapar-vlad-image-runner-cleanup-${ROLE}"
RUNNER_LOCK="/run/lock/chapar-vlad-image-${ROLE}-runner.lock"

install -d -o root -g root -m 0755 /run/lock
exec 9>"${RUNNER_LOCK}"
if ! flock -n 9; then
    echo "ERROR: another Vlad image runner registration is active for this role" >&2
    exit 1
fi

PROVISIONING_COMPLETE=false
TREE_ACTIVATED=false
CLEANUP_FAILED=false
rollback_provisioning() {
    local status=$?
    if [ "${PROVISIONING_COMPLETE}" = false ] && [ "${status}" -ne 0 ]; then
        systemctl disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
        rm -f -- "${UNIT_PATH}" "${UNIT_TEMP}"
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [ -x "${CLEANUP}" ] && ! "${CLEANUP}"; then
            CLEANUP_FAILED=true
            printf 'ERROR: GitHub runner deregistration failed; protected removal state was retained for boot-safe retry\n' >&2
        fi
        rm -rf -- "${STAGING_DIR}" "${RUNTIME_DIR}" "${WORK_DIR}"
        if [ "${TREE_ACTIVATED}" = true ] && [ "${CLEANUP_FAILED}" = false ]; then
            rm -rf -- "${RUNNER_DIR}"
            if [ -d "${BACKUP_DIR}" ]; then
                mv -- "${BACKUP_DIR}" "${RUNNER_DIR}"
            fi
        elif [ "${TREE_ACTIVATED}" = false ]; then
            rm -rf -- "${BACKUP_DIR}"
        fi
        if [ "${ROLE}" = builder ] && [ "${CLEANUP_FAILED}" = false ]; then
            systemctl disable "${BOOT_CLEANUP_UNIT}" >/dev/null 2>&1 || true
            rm -f -- "${BOOT_CLEANUP_PATH}"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
    return "${status}"
}
trap rollback_provisioning EXIT
trap 'exit 1' HUP INT TERM

if systemctl is-active --quiet "${UNIT_NAME}"; then
    systemctl stop "${UNIT_NAME}"
fi
if systemctl is-enabled --quiet "${UNIT_NAME}"; then
    systemctl disable "${UNIT_NAME}"
fi

install -d -o root -g root -m 0755 "${RUNNER_BASE}" /var/lib/chapar/vlad-image-runner /usr/local/libexec
install -d -o root -g root -m 0700 "${RUNTIME_DIR}" "${REMOVAL_STATE_DIR}" "${STAGING_DIR}"

secure_copy_token() {
    local source="$1"
    local destination="$2"
    python3 - "${source}" "${destination}" <<'PY'
import os
import stat
import sys

source, destination = sys.argv[1:]
source_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
source_fd = os.open(source, source_flags)
try:
    source_stat = os.fstat(source_fd)
    if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_uid != 0 or stat.S_IMODE(source_stat.st_mode) & ~0o600:
        raise SystemExit("runner credential changed or has unsafe ownership/mode")
    value = os.read(source_fd, 4097)
finally:
    os.close(source_fd)
if not value or len(value) > 4096:
    raise SystemExit("runner credential is empty or oversized")
destination_fd = os.open(destination, destination_flags, 0o600)
try:
    written = os.write(destination_fd, value)
    if written != len(value):
        raise SystemExit("short runner credential write")
    os.fsync(destination_fd)
finally:
    os.close(destination_fd)
PY
}

secure_copy_token "${REMOVAL_TOKEN_FILE}" "${REMOVAL_TOKEN_PATH}"
rm -f -- "${REMOVAL_TOKEN_FILE}"

cat >"${CLEANUP}" <<EOF
#!/usr/bin/env bash
set -uo pipefail
runner_dir='${RUNNER_DIR}'
work_dir='${WORK_DIR}'
runtime_dir='${RUNTIME_DIR}'
removal_token_path='${REMOVAL_TOKEN_PATH}'
runner_name='${RUNNER_NAME}'
runner_user='${RUNNER_USER}'
cleanup_status=0
registration_removed=false
if [ -f "\${runner_dir}/.runner" ]; then
    if [ ! -s "\${removal_token_path}" ] || [ ! -x "\${runner_dir}/config.sh" ]; then
        cleanup_status=1
    else
        removal_token="\$(<"\${removal_token_path}")"
        if runuser -u "\${runner_user}" -- "\${runner_dir}/config.sh" remove --unattended --token "\${removal_token}" >/dev/null 2>&1; then
            registration_removed=true
        else
            cleanup_status=1
        fi
        unset removal_token
    fi
else
    registration_removed=true
fi
if command -v docker >/dev/null 2>&1; then
    mapfile -t containers < <(docker ps -aq --filter "label=chapar.vlad-image.runner=\${runner_name}")
    if [ "\${#containers[@]}" -gt 0 ] && ! docker rm -f "\${containers[@]}" >/dev/null; then cleanup_status=1; fi
fi
rm -rf -- "\${work_dir}" "\${runtime_dir}" || cleanup_status=1
if [ "\${registration_removed}" = true ]; then
    rm -f -- "\${runner_dir}/.runner" "\${runner_dir}/.credentials" "\${runner_dir}/.credentials_rsaparams" || cleanup_status=1
    if [ "\${VLAD_KEEP_REMOVAL_TOKEN:-0}" != 1 ]; then
        rm -f -- "\${removal_token_path}" || cleanup_status=1
        rmdir -- "\$(dirname "\${removal_token_path}")" >/dev/null 2>&1 || true
    fi
fi
exit "\${cleanup_status}"
EOF
chmod 0755 "${CLEANUP}"

if [ "${ROLE}" = builder ]; then
    cat >"${BOOT_CLEANUP_PATH}" <<EOF
[Unit]
Description=Clean stale Chapar Vlad image builder registration after reboot
After=network-online.target
Wants=network-online.target
ConditionPathExists=${RUNNER_DIR}/.runner

[Service]
Type=oneshot
ExecStart=${CLEANUP}
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${RUNNER_DIR} ${WORK_DIR} ${RUNTIME_DIR} ${REMOVAL_STATE_DIR} /var/run/docker.sock

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${BOOT_CLEANUP_PATH}"
    systemctl daemon-reload
    systemctl enable "${BOOT_CLEANUP_UNIT}"
fi

if ! VLAD_KEEP_REMOVAL_TOKEN=1 "${CLEANUP}"; then
    echo "ERROR: prior runner registration could not be proven removed" >&2
    exit 1
fi

install -d -o root -g root -m 0700 "${RUNTIME_DIR}"

if [ "${BOOTSTRAP_PACKAGES}" = true ]; then
    PACKAGE_DIR="${RUNTIME_DIR}/packages"
    install -d -o root -g root -m 0700 "${PACKAGE_DIR}"
    python3 - "${PREFLIGHT_JSON}" "${PACKAGE_DIR}" <<'PY'
import hashlib
import json
import pathlib
import sys
import urllib.request

manifest = json.loads(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
for index, package in enumerate(manifest["packages"]):
    path = destination / f"{index:04d}-{package['name']}.deb"
    with urllib.request.urlopen(package["url"], timeout=120) as response, path.open("xb") as stream:
        while chunk := response.read(1024 * 1024):
            stream.write(chunk)
    if hashlib.sha256(path.read_bytes()).hexdigest() != package["sha256"]:
        raise SystemExit(f"locked package checksum mismatch: {package['name']}")
PY
    mapfile -t PACKAGE_FILES < <(find "${PACKAGE_DIR}" -type f -name '*.deb' -print | sort)
    dpkg -i "${PACKAGE_FILES[@]}"
fi

if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "Chapar Vlad image ${ROLE} runner" "${RUNNER_USER}"
fi
if [ "${ROLE}" = builder ]; then
    getent group docker >/dev/null
    usermod -a -G docker "${RUNNER_USER}"
else
    if id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -Fxq docker; then
        echo "ERROR: ${ROLE} runner user must not have Docker authority" >&2
        exit 1
    fi
fi

python3 - "${RUNNER_URL}" "${ARCHIVE}" "${RUNNER_SHA256}" <<'PY'
import hashlib
import pathlib
import sys
import urllib.request

url, destination_raw, expected = sys.argv[1:]
destination = pathlib.Path(destination_raw)
with urllib.request.urlopen(url, timeout=120) as response, destination.open("xb") as stream:
    while chunk := response.read(1024 * 1024):
        stream.write(chunk)
if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
    raise SystemExit("Actions runner archive checksum mismatch")
PY
python3 - "${ARCHIVE}" "${STAGING_DIR}" <<'PY'
import os
import pathlib
import stat
import tarfile
import sys

archive, destination_raw = sys.argv[1:]
destination = pathlib.Path(destination_raw).resolve()
destination_stat = destination.lstat()
if destination_stat.st_uid != 0 or stat.S_IMODE(destination_stat.st_mode) != 0o700 or destination.is_symlink():
    raise SystemExit("runner staging directory must be root-owned mode 0700")
with tarfile.open(archive, "r:gz") as bundle:
    for member in bundle.getmembers():
        target = (destination / member.name).resolve()
        if destination not in target.parents and target != destination:
            raise SystemExit("runner archive contains a path traversal")
        if member.isdev() or member.isfifo():
            raise SystemExit("runner archive contains a special file")
        if member.issym() or member.islnk():
            link_target = (target.parent / member.linkname).resolve()
            if destination not in link_target.parents and link_target != destination:
                raise SystemExit("runner archive contains an escaping link")
    bundle.extractall(destination, filter="data")
for required in ("config.sh", "run.sh"):
    path = destination / required
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or stat.S_ISLNK(value.st_mode) or value.st_uid != 0:
        raise SystemExit(f"runner archive required file is unsafe: {required}")
after = destination.lstat()
if (after.st_dev, after.st_ino, after.st_uid, stat.S_IMODE(after.st_mode)) != (
    destination_stat.st_dev,
    destination_stat.st_ino,
    0,
    0o700,
):
    raise SystemExit("runner staging directory changed during extraction")
descriptor = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY

python3 - "${RUNNER_BASE}" "${RUNNER_DIR}" "${STAGING_DIR}" "${BACKUP_DIR}" <<'PY'
import os
import pathlib
import stat
import sys

base, active, staging, backup = map(pathlib.Path, sys.argv[1:])
base_stat = base.lstat()
if not stat.S_ISDIR(base_stat.st_mode) or stat.S_ISLNK(base_stat.st_mode) or base_stat.st_uid != 0 or stat.S_IMODE(base_stat.st_mode) & 0o022:
    raise SystemExit("runner base has unsafe ownership or mode")
staging_stat = staging.lstat()
if not stat.S_ISDIR(staging_stat.st_mode) or stat.S_ISLNK(staging_stat.st_mode) or staging_stat.st_uid != 0 or stat.S_IMODE(staging_stat.st_mode) != 0o700:
    raise SystemExit("runner staging tree changed before activation")
if backup.exists() or backup.is_symlink():
    raise SystemExit("runner backup path unexpectedly exists")
if active.exists() or active.is_symlink():
    active_stat = active.lstat()
    if not stat.S_ISDIR(active_stat.st_mode) or stat.S_ISLNK(active_stat.st_mode):
        raise SystemExit("inactive runner tree is not a real directory")
    os.rename(active, backup)
try:
    os.rename(staging, active)
except BaseException:
    if backup.exists() and not active.exists():
        os.rename(backup, active)
    raise
descriptor = os.open(base, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
TREE_ACTIVATED=true
install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0750 "${WORK_DIR}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

run_as_runner() {
    runuser -u "${RUNNER_USER}" -- "$@"
}

secure_copy_token "${CREDENTIAL_FILE}" "${TOKEN_PATH}"
rm -f -- "${CREDENTIAL_FILE}"

TOKEN="$(<"${TOKEN_PATH}")"
CONFIG_ARGS=(--unattended --url "https://github.com/nscaledev/chapar" --token "${TOKEN}" --name "${RUNNER_NAME}" --labels "${LABELS}" --work "${WORK_DIR}" --replace)
if [ "${ROLE}" = builder ]; then
    CONFIG_ARGS+=(--ephemeral)
fi
run_as_runner "${RUNNER_DIR}/config.sh" "${CONFIG_ARGS[@]}"
unset TOKEN CONFIG_ARGS

if [ "${ROLE}" = builder ]; then
    cat >"${UNIT_TEMP}" <<EOF
[Unit]
Description=Chapar Vlad image ephemeral builder runner
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
SupplementaryGroups=docker
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
ExecStopPost=+${CLEANUP}
Restart=no
RuntimeMaxSec=${RUNTIME_MAX_SECONDS}
TimeoutStopSec=120
KillMode=mixed
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${RUNNER_DIR} ${WORK_DIR} ${RUNTIME_DIR} /var/run/docker.sock

[Install]
WantedBy=multi-user.target
EOF
else
    cat >"${UNIT_TEMP}" <<EOF
[Unit]
Description=Chapar Vlad image ${ROLE} runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
InaccessiblePaths=/var/run/docker.sock /run/containerd /root/.docker
ReadWritePaths=${RUNNER_DIR} ${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
fi

chmod 0644 "${UNIT_TEMP}"
mv -- "${UNIT_TEMP}" "${UNIT_PATH}"
systemctl daemon-reload
if [ "${ROLE}" = builder ]; then
    systemctl start "${UNIT_NAME}"
    rm -f -- "${ARCHIVE}"
    rm -rf -- "${RUNTIME_DIR}/packages"
else
    systemctl enable --now "${UNIT_NAME}"
    rm -rf -- "${RUNTIME_DIR}"
    rm -f -- "${REMOVAL_TOKEN_PATH}"
    rmdir -- "${REMOVAL_STATE_DIR}" >/dev/null 2>&1 || true
fi
rm -rf -- "${BACKUP_DIR}"
PROVISIONING_COMPLETE=true
printf 'registered %s runner %s with labels %s using native %s archive\n' "${ROLE}" "${RUNNER_NAME}" "${LABELS}" "${RUNNER_ARCH}"
