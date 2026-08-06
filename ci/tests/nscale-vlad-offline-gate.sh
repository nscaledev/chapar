#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="${ROOT_DIR}/ci/tests/nscale-vlad-offline-gate.sh"
HOST_TMPDIR_INPUT="${TMPDIR-}"
START_HEAD="2b289898a7fad2ab106bd29699fb1b37cd65cabe"
HISTORICAL_BASE="1d7ffe739ee58a485a86ea7bf5cddbd4ffd8589e"
SOURCE_LOCK_SHA256="e093e3e213af0351a10aed5a5bbef0b27051c4f0b36503b77453d810a7dd9d12"
PYTHON_INPUT="${CHAPAR_OFFLINE_PYTHON:-python3}"
PYTHON_MODULE_PATH_INPUT="${CHAPAR_OFFLINE_PYTHONPATH:-}"
TARGET_POLICY_PYTHON_INPUT="${CHAPAR_OFFLINE_TARGET_POLICY_PYTHON:-${PYTHON_INPUT}}"
TARGET_POLICY_MODULE_PATH_INPUT="${CHAPAR_OFFLINE_TARGET_POLICY_PYTHONPATH:-${PYTHON_MODULE_PATH_INPUT}}"
SPACK_SOURCE_INPUT="${CHAPAR_OFFLINE_SPACK_SOURCE:-}"
SPACK_PACKAGES_SOURCE_INPUT="${CHAPAR_OFFLINE_SPACK_PACKAGES_SOURCE:-}"
PYTHON_BIN=""
PYTHON_MODULE_PATH=""
TARGET_POLICY_PYTHON_BIN=""
TARGET_POLICY_MODULE_PATH=""
SPACK_SOURCE=""
SPACK_PACKAGES_SOURCE=""
RUNTIME_PATH=""
ALLOWLIST=(
    AGENTS.md
    Makefile
    README.md
    agents/skills/chapar-vlad-image/SKILL.md
    ci/install-validated-sqsh.py
    ci/validated_sqsh_installer.py
    ci/validated_sqsh_installer_selftest.py
    ci/validated_sqsh_linkat.py
    ci/validated_sqsh_linkat_selftest.py
    ci/sbatch-env-build.sh
    ci/tests/no-direct-install-surface-test.py
    ci/tests/no_direct_install_inputs.py
    ci/tests/nscale-vlad-offline-gate.sh
    ci/tests/nscale-vlad-runbook-test.py
    ci/verify-vlad-source-approval.py
    containers/README.md
    containers/images/build-image.sh
    containers/images/tests/build-image-plan-test.sh
    containers/images/tests/validate-locks.sh
    docs/buildcache.md
    docs/ci-github-actions.md
    docs/nscale-vlad-manual-build.md
    envs/vlad/README.md
    envs/vlad/spack.yaml
    envs/vlad/tests/target-policy-test.py
    envs/vlad/tests/target_policy_yaml.py
    etc/system/base/repos.yaml
    opencode.json
    spack_repo/README.md
)
PROHIBITED_TOOLS=(
    ssh scp sudo mount umount
    sbatch srun sinfo
    spack skopeo enroot
    nvidia-smi ibv_devices ip lscpu munge unmunge unsquashfs
    docker podman curl wget helm kubectl tofu terraform ansible ansible-playbook
    apt apt-get brew pip pip3 uv node ruby perl php lua
)
GATE_RUN_PREFIXES=(
    nscale-cleanup-race.
    nscale-offline-delete.
    nscale-scope.
    nscale-offline-gate.
    nscale-offline-self-test.
    nscale-offline-root-probe.
    nscale-offline-signal.
)
PRODUCT_CACHE_DIRECTORIES=(
    ci/__pycache__
    ci/tests/__pycache__
    envs/vlad/tests/__pycache__
)
PRODUCT_CACHE_FILES=(
    ci/__pycache__/install-validated-sqsh.cpython-312.pyc
    ci/__pycache__/install-validated-sqsh.cpython-314.pyc
    ci/__pycache__/verify-vlad-source-approval.cpython-314.pyc
    ci/tests/__pycache__/no-direct-install-surface-test.cpython-314.pyc
    ci/tests/__pycache__/nscale-vlad-runbook-test.cpython-314.pyc
    envs/vlad/tests/__pycache__/target-policy-test.cpython-314.pyc
)
HOST_TEMP_ROOT=""
ACTIVE_RUN_ROOT=""
ACTIVE_RUN_DEVICE=""
ACTIVE_RUN_INODE=""

fail() {
    printf 'offline gate failed: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail "setup error: missing regular file: $1"
}

join_by_colon() {
    local result=""
    local item
    for item in "$@"; do
        result="${result:+${result}:}${item}"
    done
    printf '%s\n' "${result}"
}

resolve_executable() {
    local input="$1"
    local label="$2"
    local resolved
    if [[ "${input}" == */* ]]; then
        resolved="${input}"
    else
        resolved="$(command -v -- "${input}" 2>/dev/null || true)"
    fi
    [ -n "${resolved}" ] || fail "setup error: cannot resolve ${label}: ${input}"
    resolved="$("${resolved}" -c 'import os, sys; print(os.path.realpath(sys.executable))' 2>/dev/null)" || \
        fail "setup error: cannot execute ${label}: ${input}"
    [ -n "${resolved}" ] && [ -f "${resolved}" ] && [ ! -L "${resolved}" ] || \
        fail "setup error: ${label} did not resolve to a regular non-symlinked executable"
    printf '%s\n' "${resolved}"
}

hash_file() {
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" -I -S - "$1" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
PY
}

self_test_hash_tool_portability() {
    local tool_dir digest status
    tool_dir="${ACTIVE_RUN_ROOT}/hash-tools-none"
    mkdir -p "${tool_dir}"
    chmod 0700 "${tool_dir}"
    set +e
    digest="$(PATH="${tool_dir}" hash_file "${ROOT_DIR}/containers/images/sources-lock.json" 2>&1)"
    status=$?
    set -e
    [ "${status}" -eq 0 ] && [ "${digest}" = "${SOURCE_LOCK_SHA256}" ] || \
        fail "portable hash self-test failed status=${status} digest=${digest}"
    set +e
    PATH="${tool_dir}" command -v sha256sum >/dev/null 2>&1 || sha_status=$?
    PATH="${tool_dir}" command -v shasum >/dev/null 2>&1 || shasum_status=$?
    set -e
    [ "${sha_status:-0}" -ne 0 ] && [ "${shasum_status:-0}" -ne 0 ] || \
        fail "portable hash self-test unexpectedly found an external digest utility"
    printf 'PASS: source-lock digest is exact with neither sha256sum nor shasum on PATH\n'
}

canonicalize_path_list() {
    local value="$1"
    local label="$2"
    [ -n "${value}" ] || return 0
    "${PYTHON_BIN}" - "${value}" "${label}" <<'PY'
import os
import stat
import sys

value, label = sys.argv[1:]
result = []
seen = set()
for raw in value.split(os.pathsep):
    if not raw or not os.path.isabs(raw) or any(token in raw for token in ("\0", "\n", "\r", "\t")):
        raise SystemExit(f"offline gate failed: setup error: invalid {label} entry: {raw!r}")
    canonical = os.path.realpath(raw)
    info = os.lstat(canonical)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SystemExit(f"offline gate failed: setup error: {label} entry is not a directory: {canonical}")
    if canonical in seen:
        raise SystemExit(f"offline gate failed: setup error: duplicate {label} entry: {canonical}")
    seen.add(canonical)
    result.append(canonical)
print(os.pathsep.join(result))
PY
}

resolve_source_root() {
    local input="$1"
    local label="$2"
    "${PYTHON_BIN}" - "${input}" "${label}" <<'PY'
import os
import stat
import sys

raw, label = sys.argv[1:]
if not os.path.isabs(raw) or any(token in raw for token in ("\0", "\n", "\r", "\t")):
    raise SystemExit(f"offline gate failed: setup error: {label} must be an absolute path")
canonical = os.path.realpath(raw)
info = os.lstat(canonical)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
    raise SystemExit(f"offline gate failed: setup error: {label} is not a non-symlink directory: {canonical}")
print(canonical)
PY
}

resolve_runtime_configuration() {
    local tool resolved directory
    local -a runtime_directories=()
    PYTHON_BIN="$(resolve_executable "${PYTHON_INPUT}" CHAPAR_OFFLINE_PYTHON)"
    TARGET_POLICY_PYTHON_BIN="$(resolve_executable "${TARGET_POLICY_PYTHON_INPUT}" CHAPAR_OFFLINE_TARGET_POLICY_PYTHON)"
    PYTHON_MODULE_PATH="$(canonicalize_path_list "${PYTHON_MODULE_PATH_INPUT}" CHAPAR_OFFLINE_PYTHONPATH)"
    TARGET_POLICY_MODULE_PATH="$(canonicalize_path_list "${TARGET_POLICY_MODULE_PATH_INPUT}" CHAPAR_OFFLINE_TARGET_POLICY_PYTHONPATH)"
    if { [ -n "${SPACK_SOURCE_INPUT}" ] && [ -z "${SPACK_PACKAGES_SOURCE_INPUT}" ]; } || \
       { [ -z "${SPACK_SOURCE_INPUT}" ] && [ -n "${SPACK_PACKAGES_SOURCE_INPUT}" ]; }; then
        fail "setup error: CHAPAR_OFFLINE_SPACK_SOURCE and CHAPAR_OFFLINE_SPACK_PACKAGES_SOURCE must be supplied together"
    fi
    if [ -n "${SPACK_SOURCE_INPUT}" ]; then
        SPACK_SOURCE="$(resolve_source_root "${SPACK_SOURCE_INPUT}" CHAPAR_OFFLINE_SPACK_SOURCE)"
        SPACK_PACKAGES_SOURCE="$(resolve_source_root "${SPACK_PACKAGES_SOURCE_INPUT}" CHAPAR_OFFLINE_SPACK_PACKAGES_SOURCE)"
    fi
    for tool in bash git make; do
        resolved="$(command -v -- "${tool}" 2>/dev/null || true)"
        [ -n "${resolved}" ] || fail "setup error: missing required tool: ${tool}"
        directory="$(cd "$(dirname "${resolved}")" && pwd -P)"
        [[ ":$(join_by_colon "${runtime_directories[@]}"):" == *":${directory}:"* ]] || runtime_directories+=("${directory}")
    done
    for resolved in "${PYTHON_BIN}" "${TARGET_POLICY_PYTHON_BIN}"; do
        directory="$(dirname "${resolved}")"
        [[ ":$(join_by_colon "${runtime_directories[@]}"):" == *":${directory}:"* ]] || runtime_directories+=("${directory}")
    done
    for directory in /usr/bin /bin /usr/sbin /sbin; do
        [ -d "${directory}" ] || continue
        [[ ":$(join_by_colon "${runtime_directories[@]}"):" == *":${directory}:"* ]] || runtime_directories+=("${directory}")
    done
    RUNTIME_PATH="$(join_by_colon "${runtime_directories[@]}")"
}

capture_secure_host_temp_root() {
    local candidate="$1"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - "${candidate}" "${ROOT_DIR}" <<'PY'
from __future__ import annotations

import os
import stat
import sys


def reject(reason: str) -> None:
    raise SystemExit(f"offline gate failed: setup error: {reason}")


raw = sys.argv[1]
product_root = os.path.realpath(sys.argv[2])
if not raw:
    reject("host temp root is unset")
if any(token in raw for token in ("\0", "\n", "\r", "\t")):
    reject("host temp root contains a control character")
if not os.path.isabs(raw):
    reject(f"host temp root is not absolute: {raw}")
candidate = os.path.normpath(raw)
try:
    supplied = os.lstat(candidate)
except OSError as error:
    reject(f"cannot lstat host temp root {candidate}: {error.strerror}")
if stat.S_ISLNK(supplied.st_mode):
    reject(f"host temp root is a symlink: {candidate}")
canonical = os.path.realpath(candidate)
try:
    info = os.lstat(canonical)
except OSError as error:
    reject(f"cannot lstat canonical host temp root {canonical}: {error.strerror}")
if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
    reject(f"host temp root is not a non-symlink directory: {canonical}")
try:
    inside_product = os.path.commonpath((canonical, product_root)) == product_root
except ValueError:
    inside_product = False
if inside_product:
    reject(f"host temp root is inside the product tree: {canonical}")
mode = stat.S_IMODE(info.st_mode)
if mode != 0o700:
    reject(f"host temp root mode is {mode:04o}, expected 0700: {canonical}")
if info.st_uid != os.getuid():
    reject(f"host temp root uid {info.st_uid} does not match current uid {os.getuid()}: {canonical}")
print(canonical)
PY
}

validate_run_root() {
    local run_root="$1"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${run_root}" "${HOST_TEMP_ROOT}" "${ROOT_DIR}" <<'PY'
from __future__ import annotations

import os
import stat
import sys


def reject(reason: str) -> None:
    raise SystemExit(f"offline gate failed: setup error: {reason}")


raw, host_root, product_root = sys.argv[1:]
if not os.path.isabs(raw):
    reject(f"run root is not absolute: {raw}")
canonical = os.path.realpath(raw)
if canonical != os.path.normpath(raw):
    reject(f"run root is not canonical: {raw}")
if os.path.dirname(canonical) != host_root:
    reject(f"run root is not an immediate child of the secure host temp root: {canonical}")
try:
    info = os.lstat(canonical)
except OSError as error:
    reject(f"cannot lstat run root {canonical}: {error.strerror}")
if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
    reject(f"run root is not a non-symlink directory: {canonical}")
if info.st_uid != os.getuid():
    reject(f"run root uid {info.st_uid} does not match current uid {os.getuid()}: {canonical}")
mode = stat.S_IMODE(info.st_mode)
if mode != 0o700:
    reject(f"run root mode is {mode:04o}, expected 0700: {canonical}")
product_root = os.path.realpath(product_root)
if os.path.commonpath((canonical, product_root)) == product_root:
    reject(f"run root is inside the product tree: {canonical}")
print(f"{canonical}\t{info.st_dev}\t{info.st_ino}")
PY
}

remove_exact_run_root() {
    local run_root="$1"
    local expected_device="$2"
    local expected_inode="$3"
    local race_retained_path="${4:-}"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${run_root}" "${HOST_TEMP_ROOT}" "${expected_device}" "${expected_inode}" "${race_retained_path}" <<'PY'
from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile


def reject(reason: str) -> None:
    raise SystemExit(f"offline gate cleanup failed: {reason}")


root, host_root, expected_device, expected_inode, race_retained_path = sys.argv[1:]
if not os.path.isabs(root) or os.path.realpath(root) != os.path.normpath(root):
    reject(f"run root identity is no longer canonical: {root}")
if os.path.dirname(root) != host_root:
    reject(f"run root parent identity changed: {root}")
try:
    info = os.lstat(root)
except OSError as error:
    reject(f"cannot lstat exact run root {root}: {error.strerror}")
if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
    reject(f"exact run root is not a non-symlink directory: {root}")
if info.st_uid != os.getuid():
    reject(f"exact run root uid changed: {root}")
if info.st_dev != int(expected_device) or info.st_ino != int(expected_inode):
    reject(f"exact run root device/inode changed: {root}")
if not shutil.rmtree.avoids_symlink_attacks:
    reject("this Python runtime lacks symlink-safe recursive removal")
if race_retained_path:
    if os.path.dirname(race_retained_path) != host_root or os.path.lexists(race_retained_path):
        reject("invalid cleanup replacement-race fixture path")
    os.rename(root, race_retained_path)
    os.mkdir(root, mode=0o700)
    with open(os.path.join(root, "replacement-marker"), "xb") as stream:
        stream.write(b"replacement")
deletion_parent = tempfile.mkdtemp(prefix="nscale-offline-delete.", dir=host_root)
deletion_root = os.path.join(deletion_parent, "run-root")
os.rename(root, deletion_root)
try:
    moved = os.lstat(deletion_root)
except OSError as error:
    reject(f"cannot lstat quarantined run root {deletion_root}: {error.strerror}")
if moved.st_dev != int(expected_device) or moved.st_ino != int(expected_inode):
    # The pathname may have been replaced after the identity check.  Never
    # recursively remove that replacement: put it back before rejecting the
    # cleanup.  If another entry arrived meanwhile, leave both paths intact
    # for an operator rather than choosing one to delete.
    if not os.path.lexists(root):
        os.rename(deletion_root, root)
        os.rmdir(deletion_parent)
        reject(f"quarantined run root device/inode changed: {deletion_root}")
    reject(f"quarantined run root device/inode changed with replacement preserved: {deletion_root}")
shutil.rmtree(deletion_root)
os.rmdir(deletion_parent)
if os.path.lexists(root):
    reject(f"replacement appeared at exact run-root path during cleanup: {root}")
PY
}

remove_unvalidated_empty_run_root() {
    local run_root="$1"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${run_root}" "${HOST_TEMP_ROOT}" <<'PY'
from __future__ import annotations

import os
import stat
import sys


root, host_root = sys.argv[1:]
if not os.path.isabs(root) or os.path.realpath(root) != os.path.normpath(root):
    raise SystemExit(1)
if os.path.dirname(root) != host_root:
    raise SystemExit(1)
try:
    info = os.lstat(root)
except OSError:
    raise SystemExit(1) from None
if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
    raise SystemExit(1)
with os.scandir(root) as entries:
    if next(entries, None) is not None:
        raise SystemExit(1)
os.rmdir(root)
PY
}

self_test_cleanup_replacement_race() {
    local fixture identity run_root device inode retained status output
    fixture="$(mktemp -d "${HOST_TEMP_ROOT}/nscale-cleanup-race.XXXXXX")" || return 1
    chmod 0700 "${fixture}"
    printf 'original\n' >"${fixture}/original-marker"
    identity="$(validate_run_root "${fixture}")" || return 1
    IFS=$'\t' read -r run_root device inode <<<"${identity}"
    retained="${fixture}.retained"
    set +e
    output="$(remove_exact_run_root "${run_root}" "${device}" "${inode}" "${retained}" 2>&1)"
    status=$?
    set -e
    if [ "${status}" -eq 0 ] || [[ "${output}" != *"quarantined run root device/inode changed"* ]] || \
       [ ! -f "${retained}/original-marker" ] || [ ! -f "${fixture}/replacement-marker" ]; then
        printf 'RED: cleanup replacement race status=%s original_preserved=%s replacement_preserved=%s\n' \
            "${status}" "$([ -f "${retained}/original-marker" ] && printf yes || printf no)" \
            "$([ -f "${fixture}/replacement-marker" ] && printf yes || printf no)" >&2
        return 1
    fi
    rm -- "${fixture}/replacement-marker" "${retained}/original-marker"
    rmdir -- "${fixture}" "${retained}"
    printf 'PASS: same-UID cleanup replacement race preserved original and replacement inodes\n'
}

self_test_default_clean_scope_wiring() {
    "${PYTHON_BIN}" - "${SCRIPT_PATH}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
body = text.rsplit("\nrun_default_gate() {", 1)[1].split("\ngit_fixture_commit() {", 1)[0]
if "check_scope --require-clean" not in body:
    raise SystemExit("RED: default gate omits check_scope --require-clean")
print("PASS: default gate invokes check_scope --require-clean")
PY
}

self_test_portability_contract() {
    "${PYTHON_BIN}" - "${SCRIPT_PATH}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8").split("\nself_test_portability_contract() {", 1)[0]
for forbidden in ("/" + "Users/mrez", "/opt/" + "homebrew"):
    if forbidden in text:
        raise SystemExit(f"RED: production gate contains machine-local path: {forbidden}")
required = (
    "CHAPAR_OFFLINE_PYTHON",
    "CHAPAR_OFFLINE_PYTHONPATH",
    "CHAPAR_OFFLINE_TARGET_POLICY_PYTHON",
    "CHAPAR_OFFLINE_TARGET_POLICY_PYTHONPATH",
    "CHAPAR_OFFLINE_SPACK_SOURCE",
    "CHAPAR_OFFLINE_SPACK_PACKAGES_SOURCE",
)
missing = [name for name in required if name not in text]
if missing:
    raise SystemExit(f"RED: portability contract variables missing: {missing!r}")
print("PASS: runtime and semantic-source inputs use the explicit portable environment contract")
PY
}

self_test_duplicate_module_paths() {
    local temp="$1"
    local host module_dir label value python_path target_path output status
    host="${temp}/duplicate-module-path-host"
    module_dir="$(dirname "${SCRIPT_PATH}")"
    mkdir "${host}"
    chmod 0700 "${host}"

    for label in CHAPAR_OFFLINE_PYTHONPATH CHAPAR_OFFLINE_TARGET_POLICY_PYTHONPATH; do
        for value in "${module_dir}:${module_dir}" "${module_dir}:${module_dir}/."; do
            python_path="${module_dir}"
            target_path="${module_dir}"
            if [ "${label}" = CHAPAR_OFFLINE_PYTHONPATH ]; then
                python_path="${value}"
            else
                target_path="${value}"
            fi
            set +e
            output="$(env TMPDIR="${host}" OFFLINE_GATE_INTERNAL_SELF_TEST=1 \
                CHAPAR_OFFLINE_PYTHON="${PYTHON_BIN}" \
                CHAPAR_OFFLINE_TARGET_POLICY_PYTHON="${TARGET_POLICY_PYTHON_BIN}" \
                CHAPAR_OFFLINE_PYTHONPATH="${python_path}" \
                CHAPAR_OFFLINE_TARGET_POLICY_PYTHONPATH="${target_path}" \
                bash "${SCRIPT_PATH}" --internal-temp-root-probe 2>&1)"
            status=$?
            set -e
            [ "${status}" -eq 1 ] && [[ "${output}" == *"duplicate ${label} entry"* ]] || \
                fail "duplicate canonical ${label} self-test accepted ${value@Q}: status ${status}; output ${output@Q}"
        done
    done
    printf 'PASS: duplicate and lexical-alias Python module paths are rejected after canonicalization\n'
}

cleanup_active_run_root() {
    local run_root="${ACTIVE_RUN_ROOT}"
    local device="${ACTIVE_RUN_DEVICE}"
    local inode="${ACTIVE_RUN_INODE}"
    [ -n "${run_root}" ] || return 0
    remove_exact_run_root "${run_root}" "${device}" "${inode}" || return
    clear_active_run_root_state
}

clear_active_run_root_state() {
    ACTIVE_RUN_ROOT=""
    ACTIVE_RUN_DEVICE=""
    ACTIVE_RUN_INODE=""
}

cleanup_on_exit() {
    local status="$1"
    trap - EXIT HUP INT TERM
    if ! cleanup_active_run_root; then
        status=1
    fi
    exit "${status}"
}

cleanup_on_signal() {
    local signal_name="$1"
    local signal_status="$2"
    trap - EXIT HUP INT TERM
    cleanup_active_run_root || exit 1
    exit "${signal_status}"
}

assert_no_stale_gate_roots() {
    local host_root="$1"
    local allowed_root="$2"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${host_root}" "${allowed_root}" "${GATE_RUN_PREFIXES[@]}" <<'PY'
from __future__ import annotations

import os
import stat
import sys


host_root = os.path.realpath(sys.argv[1])
allowed_root = os.path.realpath(sys.argv[2])
prefixes = tuple(sys.argv[3:])
if not prefixes or os.path.dirname(allowed_root) != host_root:
    raise SystemExit("offline gate failed: setup error: invalid gate-root residue inventory boundary")
unexpected: list[str] = []
with os.scandir(host_root) as stream:
    for entry in stream:
        path = os.path.join(host_root, entry.name)
        matching_prefix = next((prefix for prefix in prefixes if entry.name.startswith(prefix)), None)
        if matching_prefix is None or path == allowed_root:
            continue
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            unexpected.append(path)
            continue
        suffix = entry.name[len(matching_prefix):]
        owner_pid, separator, _token = suffix.partition(".")
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or not separator
            or not owner_pid.isdecimal()
            or int(owner_pid) <= 0
        ):
            unexpected.append(path)
            continue
        try:
            os.kill(int(owner_pid), 0)
        except ProcessLookupError:
            unexpected.append(path)
        except PermissionError:
            pass
if unexpected:
    raise SystemExit(f"offline gate failed: stale gate run-root residue: {sorted(unexpected)!r}")
PY
}

create_active_run_root() {
    local label="$1"
    local created_root identity run_root device inode status owner_pid
    umask 077
    owner_pid="${BASHPID}"
    ACTIVE_RUN_ROOT="$(mktemp -d "${HOST_TEMP_ROOT}/${label}.${owner_pid}.XXXXXX")" || fail "setup error: could not create run root"
    created_root="${ACTIVE_RUN_ROOT}"
    if [ "${OFFLINE_GATE_INTERNAL_SELF_TEST:-}" = 1 ] && [ "${OFFLINE_GATE_INTERNAL_INVALID_RUN_ROOT:-}" = 1 ]; then
        chmod 0755 "${created_root}"
    fi
    if identity="$(validate_run_root "${created_root}")"; then
        :
    else
        status=$?
        remove_unvalidated_empty_run_root "${created_root}" >/dev/null 2>&1 || true
        clear_active_run_root_state
        return "${status}"
    fi
    IFS=$'\t' read -r run_root device inode <<<"${identity}"
    if [ -z "${run_root}" ] || [ -z "${device}" ] || [ -z "${inode}" ]; then
        remove_unvalidated_empty_run_root "${created_root}" >/dev/null 2>&1 || true
        clear_active_run_root_state
        fail "setup error: incomplete run root identity"
    fi
    ACTIVE_RUN_ROOT="${run_root}"
    ACTIVE_RUN_DEVICE="${device}"
    ACTIVE_RUN_INODE="${inode}"
    trap 'cleanup_on_exit "$?"' EXIT
    trap 'cleanup_on_signal HUP 129' HUP
    trap 'cleanup_on_signal INT 130' INT
    trap 'cleanup_on_signal TERM 143' TERM
    assert_no_stale_gate_roots "${HOST_TEMP_ROOT}" "${ACTIVE_RUN_ROOT}"
}

prepare_run_environment() {
    local run_root="$1"
    [ "${run_root}" = "${ACTIVE_RUN_ROOT}" ] || fail "setup error: environment root does not match the active run root"
    mkdir -p \
        "${run_root}/home" \
        "${run_root}/matplotlib-cache" \
        "${run_root}/pip-cache" \
        "${run_root}/python-cache" \
        "${run_root}/python-user" \
        "${run_root}/spack-cache" \
        "${run_root}/tmp" \
        "${run_root}/uv-cache" \
        "${run_root}/xdg-cache"
    export HOME="${run_root}/home"
    export MPLCONFIGDIR="${run_root}/matplotlib-cache"
    export PIP_CACHE_DIR="${run_root}/pip-cache"
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONPYCACHEPREFIX="${run_root}/python-cache"
    export PYTHONUSERBASE="${run_root}/python-user"
    export SPACK_USER_CACHE_PATH="${run_root}/spack-cache"
    export TMPDIR="${run_root}/tmp"
    export UV_CACHE_DIR="${run_root}/uv-cache"
    export XDG_CACHE_HOME="${run_root}/xdg-cache"
}

cleanup_observed_python_caches() {
    local repository="$1"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${repository}" "${PRODUCT_CACHE_DIRECTORIES[@]}" -- "${PRODUCT_CACHE_FILES[@]}" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path, PurePosixPath


root = Path(sys.argv[1])
separator = sys.argv.index("--", 2)
directories = tuple(PurePosixPath(item) for item in sys.argv[2:separator])
files = tuple(PurePosixPath(item) for item in sys.argv[separator + 1 :])
expected_files = frozenset(files)
existing_directories: list[PurePosixPath] = []

for relative in directories:
    path = root / relative
    try:
        info = path.lstat()
    except FileNotFoundError:
        continue
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SystemExit(f"cache cleanup refused non-directory or symlink: {relative}")
    if info.st_uid != os.getuid():
        raise SystemExit(f"cache cleanup refused unowned directory: {relative}")
    existing_directories.append(relative)

if not existing_directories:
    print("PASS: enumerated product Python caches were already absent")
    raise SystemExit(0)

if frozenset(existing_directories) != frozenset(directories):
    raise SystemExit("cache cleanup refused partial observed directory inventory")

actual_files: set[PurePosixPath] = set()
for relative in directories:
    path = root / relative
    with os.scandir(path) as stream:
        entries = list(stream)
    for entry in entries:
        child = relative / entry.name
        info = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise SystemExit(f"cache cleanup refused non-regular or symlink entry: {child}")
        if info.st_uid != os.getuid():
            raise SystemExit(f"cache cleanup refused unowned file: {child}")
        actual_files.add(child)

if actual_files != expected_files:
    missing = sorted(str(item) for item in expected_files - actual_files)
    extra = sorted(str(item) for item in actual_files - expected_files)
    raise SystemExit(f"cache cleanup refused inventory drift: missing={missing!r} extra={extra!r}")

for relative in files:
    (root / relative).unlink()
for relative in directories:
    (root / relative).rmdir()
for relative in (*directories, *files):
    if os.path.lexists(root / relative):
        raise SystemExit(f"cache cleanup failed to remove exact observed path: {relative}")
print(f"PASS: removed exact observed product Python cache inventory directories={len(directories)} files={len(files)}")
PY
}

snapshot_physical_tree() {
    local repository="$1"
    local output="$2"
    "${PYTHON_BIN}" - "${repository}" "${output}" <<'PY'
from __future__ import annotations

import os
import stat
import sys

root = os.fsencode(sys.argv[1])
output = os.fsencode(sys.argv[2])
records: list[bytes] = []

def visit(directory: bytes, relative: bytes) -> None:
    with os.scandir(directory) as stream:
        entries = sorted(stream, key=lambda entry: entry.name)
    for entry in entries:
        name = entry.name
        if not relative and name == b".git":
            continue
        child_relative = name if not relative else relative + b"/" + name
        info = entry.stat(follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            records.extend((b"D", child_relative))
            visit(entry.path, child_relative)
        elif stat.S_ISREG(info.st_mode):
            records.extend((b"F", child_relative))
        elif stat.S_ISLNK(info.st_mode):
            records.extend((b"L", child_relative, os.fsencode(os.readlink(entry.path))))
        else:
            records.extend((b"O", child_relative))

visit(root, b"")
with open(output, "wb") as stream:
    stream.write(b"\0".join(records) + (b"\0" if records else b""))
PY
}

host_preflight() {
    local tool
    for tool in bash git make; do
        command -v "${tool}" >/dev/null 2>&1 || fail "setup error: missing required tool: ${tool}"
    done
    require_file "${PYTHON_BIN}"
    PYTHONNOUSERSITE=1 PYTHONPATH="${PYTHON_MODULE_PATH}" "${PYTHON_BIN}" - <<'PY'
import importlib

missing = []
for module in ("jsonschema", "yaml"):
    try:
        importlib.import_module(module)
    except ModuleNotFoundError as error:
        if error.name != module:
            raise
        missing.append("PyYAML" if module == "yaml" else module)
if missing:
    raise SystemExit(
        "setup error: offline gate Python is missing required modules: "
        + ", ".join(missing)
        + "; install jsonschema and PyYAML in the isolated interpreter or set "
        "CHAPAR_OFFLINE_PYTHON and CHAPAR_OFFLINE_PYTHONPATH"
    )

import jsonschema
import yaml
assert jsonschema.validators.validator_for({"$schema": "https://json-schema.org/draft/2020-12/schema"})
assert yaml.safe_load("value: 1") == {"value": 1}
PY
}

audit_manifest() {
    local output_dir="$1"
    mkdir -p "${output_dir}"
    "${PYTHON_BIN}" - "${ROOT_DIR}" "${output_dir}" <<'PY'
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = Path(sys.argv[2])
expected = {
    "containers/images/preflight.sh": "eccc4c77782bbb0ca49a598cb7df1c088b7a030905279c4ce958dfb37030d3c7",
    "containers/images/build-image.sh": "bde2745dbdc6226bca6df3d74a25df2b9ad8cc672d3ceaf57b9510498b6afd46",
    "containers/images/tests/validate-locks.sh": "e544a92b18891313d4bdad7542ca306499a6af8e11a59b9414b0893ba2f32ed2",
    "containers/images/tests/preflight-test.sh": "63953116d29516e9ff4d7283768f4e170d1a85a3dd4691d3f15509db644dc9cd",
    "ci/tests/vlad-image-provisioning-test.sh": "d98484412d3bd869e76501a8565238cdf94b7d793580a0e97c84e80a2e3a1260",
    "ci/install-vlad-image-site-contract.sh": "732358b74359d70c23ac2444ed9d8d0c62187110203c69811a384666968acbab",
    "ci/register-vlad-image-runner.sh": "e4d6751278fb1beaa5a38a72e98ac90afd5b733a264968068b8ae34f3068b770",
    "ci/sbatch-env-build.sh": "7a9fa1659d6be1ee69ed4a918a9d99a54c0df91e6c8ce88d316444644e1390e2",
    "agents/skills/skill-creator/scripts/quick_validate.py": "38aca4cfdd814407fceb47ee663d50eb4a55ef9c48cbdab6ee9e9e5ad5aa0618",
    "etc/init.sh": "91aa4e4a9548df898fa102c44c1c3f0a78881e71d51412c8b7b29d6e52fb9392",
    "envs/vlad/release.sh": "2a88119229b2c7134a248363fc443c4af7517f193846cdad5dbbe148ff644b67",
    "envs/hpcsim/release.sh": "e866b0a25af62bb4626d3f677b0fa5bd0cd32dbc7f2f0ef2427f35d8b6a4b7d0",
    "envs/vlad/tests/target-policy-test.py": "eb5c1829499b63f309cecb78a7985e7a73df9d34097f5feae2203bed88d6fdb2",
    "envs/vlad/tests/target_policy_yaml.py": "da8f42e3f78070265a014a05b2ae078d4611397a05c0393b58a5687e2a676858",
    "containers/images/tests/build-image-plan-test.sh": "44c5cc4ffda11e16b10b58e82b47e870e2380453b74dcf9712eac57332cbf350",
    "ci/tests/no-direct-install-surface-test.py": "99e77a6248def13a944fce5490ad1b51101c3b1867ff5b00674cd9ca1a6f38c5",
    "ci/tests/no_direct_install_inputs.py": "3f84b748f5213199db3e037f6b824c7265ce867f2d7ba88fd9b6987de3ef1f19",
    "ci/tests/nscale-vlad-runbook-test.py": "9d6d6cbb5f66210678f8232e4cb27d8fa52a0955d298639dda03667c8ddd4973",
    "ci/verify-vlad-source-approval.py": "dbdecb13726ee0287d83986666bc199725b7cc6e7191d66f875116256d6ad090",
    "ci/install-validated-sqsh.py": "e2163e20271724fd09e65563d9e9508cdff7673473e1bfc1fcb15d480b194ef6",
    "ci/validated_sqsh_installer.py": "6e0004106b6d9164fd2bbf690841a3a7210ad41fdda2f88d02bfc5458ef55612",
    "ci/validated_sqsh_installer_selftest.py": "58c30e89485f7542327e20bcacd279e24b2ea786633200f2fa5a4af53b601d87",
    "ci/validated_sqsh_linkat.py": "eff4d6712d6cf3deff6251a2ac8c400995fbb22e11bf9c72b0faee2f9cf0e67b",
    "ci/validated_sqsh_linkat_selftest.py": "31ccfb6d994943b823f6eb8cc1c6db4e4d0f8473fe78d0ce96adc5b89ba450f7",
}
gate = "ci/tests/nscale-vlad-offline-gate.sh"
manifest = tuple(expected) + (gate,)
for relative in manifest:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"manifest audit failed: missing regular helper: {relative}")
for relative, digest in expected.items():
    actual = hashlib.sha256((root / relative).read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"manifest audit failed: helper bytes drifted: {relative}")

sbatch = (root / "ci/sbatch-env-build.sh").read_text(encoding="utf-8")
dynamic = re.findall(r'bash "\$\{ENV_PATH\}/release\.sh" (?:status|build "\$RELEASE_ID"|promote "\$RELEASE_ID"|publish-modules "\$RELEASE_ID"|module-use "\$RELEASE_ID")', sbatch)
if len(dynamic) != 5 or len(set(dynamic)) != 5:
    raise SystemExit("manifest audit failed: sbatch ENV_PATH helper forms are not the exact five-command set")
if 'envs/${ENV_NAME}' not in sbatch:
    raise SystemExit("manifest audit failed: sbatch ENV_PATH derivation drifted")
if re.search(r'\beval\b|/dev/tcp|/dev/udp', sbatch):
    raise SystemExit("manifest audit failed: sbatch contains a computed shell escape")

ledger = (
    "agents/skills/skill-creator/scripts/quick_validate.py\tpython-only\n"
    "ci/install-validated-sqsh.py\tdeferred-descriptor-publication\n"
    "ci/validated_sqsh_installer.py\tdeferred-anonymous-publication-helper\n"
    "ci/validated_sqsh_installer_selftest.py\tportable-installer-state-machine-fixtures\n"
    "ci/validated_sqsh_linkat.py\tunprivileged-linux-linkat-adapter\n"
    "ci/validated_sqsh_linkat_selftest.py\tportable-linkat-fallback-fixtures\n"
    "ci/install-vlad-image-site-contract.sh\tdeferred-site-contract-write\n"
    "ci/register-vlad-image-runner.sh\tdeferred-network-package-service-write\n"
    "ci/sbatch-env-build.sh\tdeferred-finite-env-release-or-concretize\n"
    "ci/tests/no-direct-install-surface-test.py\tlocal-git-python\n"
    "ci/tests/no_direct_install_inputs.py\ttracked-input-classification-helper\n"
    "ci/tests/nscale-vlad-offline-gate.sh\tinstrumented-gate\n"
    "ci/tests/nscale-vlad-runbook-test.py\tlocal-python-bash\n"
    "ci/tests/vlad-image-provisioning-test.sh\tdisposable-provisioning-fixture\n"
    "ci/verify-vlad-source-approval.py\tlocal-git-capture-and-deferred-receipts\n"
    "containers/images/build-image.sh\tplan-only-or-deferred-image-tools\n"
    "containers/images/preflight.sh\tdisposable-probes-or-deferred-live-probes\n"
    "containers/images/tests/build-image-plan-test.sh\tdisposable-plan-fixture\n"
    "containers/images/tests/preflight-test.sh\tdisposable-preflight-fixture\n"
    "containers/images/tests/validate-locks.sh\tpython-only\n"
    "envs/hpcsim/release.sh\tdeferred-release-write-and-spack\n"
    "envs/vlad/release.sh\tdeferred-release-write-and-spack\n"
    "envs/vlad/tests/target-policy-test.py\toffline-pinned-python\n"
    "envs/vlad/tests/target_policy_yaml.py\toffline-yaml-structure-helper\n"
    "etc/init.sh\tdeferred-sourced-spack-environment\n"
)
ledger_path = output / "deferred-ledger.tsv"
ledger_path.write_text(ledger, encoding="ascii")
if ledger_path.read_text(encoding="ascii") != ledger or len(ledger.splitlines()) != len(manifest):
    raise SystemExit("manifest audit failed: deferred ledger mismatch")
(output / "manifest.nul").write_bytes(b"\0".join(item.encode() for item in manifest) + b"\0")
print(f"PASS: audited exact helper manifest members={len(manifest)} before sentinels")
print(f"PASS: deferred ledger entries={len(manifest)}")
PY
}

static_denial_reason() {
    local fixture="$1"
    "${PYTHON_BIN}" - "${fixture}" <<'PY'
import ast
import re
import sys

text = sys.argv[1]
rules = (
    (r"/dev/(?:tcp|udp)/", "special-device network escape"),
    (r"\beval\b", "computed eval helper"),
    (r"(?:^|[ ;|&])(?:node|ruby|perl|php|lua)(?:[ ;|&]|$)", "non-Python runtime"),
    (r"python(?:3)?\s+-(?:I|E|S|s)\b", "Python isolation escape"),
    (r"(?:PYTHONPATH=|env\s+-i).*python", "Python environment-strip escape"),
    (r"(?:>|>>)\s*(?:/etc|/resources|/shared|/vast|/home/hpcadmin)/", "live absolute write"),
    (
        r"(?:^|[ ;|&])(?:ssh|scp|sudo|mount|umount|sbatch|srun|sinfo|spack|skopeo|enroot|"
        r"nvidia-smi|ibv_devices|ip|lscpu|munge|unmunge|unsquashfs|docker|podman|curl|wget)"
        r"(?:[ ;|&]|$)",
        "denied live tool",
    ),
)
for pattern, reason in rules:
    if re.search(pattern, text, re.MULTILINE):
        print(reason)
        raise SystemExit(1)
try:
    tree = ast.parse(text)
except SyntaxError:
    tree = None
if tree is not None:
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            value = node.func.value
            name = f"{value.id}.{node.func.attr}" if isinstance(value, ast.Name) else node.func.attr
            if name in {"os.system", "os.popen", "os.execv", "os.execve", "os.spawnv"}:
                print("computed Python process escape")
                raise SystemExit(1)
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [item.name for item in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            if any(name in {"socket", "urllib", "urllib.request", "http.client", "requests"} for name in names):
                print("Python socket or DNS escape")
                raise SystemExit(1)
print("accepted static fixture")
PY
}

capture_scope_streams() {
    local repository="$1"
    local start="$2"
    local directory="$3"
    mkdir -p "${directory}"
    GIT_MASTER=1 git -C "${repository}" diff --name-status -z --no-renames "${start}..HEAD" >"${directory}/committed.nul"
    GIT_MASTER=1 git -C "${repository}" diff --cached --name-status -z >"${directory}/cached.nul"
    GIT_MASTER=1 git -C "${repository}" diff --name-status -z >"${directory}/unstaged.nul"
    GIT_MASTER=1 git -C "${repository}" ls-files --others --exclude-standard -z >"${directory}/untracked.nul"
    GIT_MASTER=1 git -C "${repository}" ls-files --stage -z >"${directory}/index.nul"
    GIT_MASTER=1 git -C "${repository}" ls-files --unmerged -z >"${directory}/unmerged.nul"
}

parse_scope_streams() {
    local repository="$1"
    local directory="$2"
    shift 2
    "${PYTHON_BIN}" - "${repository}" "${directory}" "$@" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
streams = Path(sys.argv[2])
allowed = frozenset(sys.argv[3:])
if not allowed:
    raise SystemExit("scope check failed: empty allowlist")

def decode(payload: bytes, label: str) -> list[str]:
    if payload and not payload.endswith(b"\0"):
        raise SystemExit(f"scope check failed: {label} is not NUL terminated")
    raw = payload[:-1].split(b"\0") if payload else []
    result: list[str] = []
    for entry in raw:
        try:
            result.append(entry.decode("utf-8"))
        except UnicodeDecodeError:
            raise SystemExit(f"scope check failed: {label} contains non-UTF-8 path") from None
    return result

records: list[tuple[str, str, str]] = []
for name in ("committed", "cached", "unstaged"):
    fields = decode((streams / f"{name}.nul").read_bytes(), name)
    index = 0
    while index < len(fields):
        status_code = fields[index]
        index += 1
        path_count = 2 if status_code[:1] in {"R", "C"} else 1
        if len(fields) - index < path_count:
            raise SystemExit(f"scope check failed: {name} has missing path")
        paths = fields[index:index + path_count]
        index += path_count
        if path_count == 2:
            raise SystemExit(
                f"scope check failed: forbidden status {status_code[:1]}: "
                f"{paths[0]} -> {paths[1]}"
            )
        records.append((name, status_code, paths[0]))
for path in decode((streams / "untracked.nul").read_bytes(), "untracked"):
    records.append(("untracked", "A", path))
if (streams / "unmerged.nul").read_bytes():
    raise SystemExit("scope check failed: unmerged index stages are forbidden")

seen: dict[str, tuple[str, str]] = {}
changed: set[str] = set()
for source, status_code, path_text in records:
    if not path_text:
        raise SystemExit(f"scope check failed: {source} has missing path")
    path = PurePosixPath(path_text)
    if path.is_absolute() or ".." in path.parts or path_text in {"", "."}:
        raise SystemExit(f"scope check failed: invalid path: {path_text}")
    if status_code not in {"A", "M"}:
        raise SystemExit(f"scope check failed: forbidden status {status_code}: {path_text}")
    if path_text not in allowed:
        raise SystemExit(f"scope check failed: unlisted path: {path_text}")
    if path_text in seen:
        prior_source, prior_status = seen[path_text]
        raise SystemExit(
            f"scope check failed: duplicate/conflicting path: {path_text}: "
            f"{prior_source}/{prior_status} and {source}/{status_code}"
        )
    seen[path_text] = (source, status_code)
    changed.add(path_text)

index_modes: dict[str, list[tuple[str, str]]] = {}
for record in decode((streams / "index.nul").read_bytes(), "index"):
    metadata, separator, path_text = record.partition("\t")
    fields = metadata.split()
    if not separator or len(fields) != 3:
        raise SystemExit("scope check failed: malformed index record")
    mode, _object_id, stage = fields
    index_modes.setdefault(path_text, []).append((mode, stage))

for path_text in changed:
    absolute = root / path_text
    try:
        info = absolute.lstat()
    except FileNotFoundError:
        raise SystemExit(f"scope check failed: missing changed path: {path_text}") from None
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"scope check failed: symlink or non-regular changed path: {path_text}")
    if seen[path_text][0] != "untracked":
        modes = index_modes.get(path_text, [])
        if len(modes) != 1 or modes[0][1] != "0" or modes[0][0] not in {"100644", "100755"}:
            raise SystemExit(f"scope check failed: unsafe index mode/stage: {path_text}")
print(f"PASS: scope paths={len(changed)} statuses=A/M only")
PY
}

check_scope_repository() {
    local repository="$1"
    local start="$2"
    local base="$3"
    local require_clean="$4"
    local output_dir="$5"
    shift 5
    GIT_MASTER=1 git -C "${repository}" merge-base --is-ancestor "${start}" HEAD || fail "scope check failed: starting HEAD is not an ancestor"
    [ "$(GIT_MASTER=1 git -C "${repository}" rev-parse "${start}^")" = "${base}" ] || fail "scope check failed: historical parent mismatch"
    capture_scope_streams "${repository}" "${start}" "${output_dir}" || return
    parse_scope_streams "${repository}" "${output_dir}" "$@" || return
    GIT_MASTER=1 git -C "${repository}" diff --check || return
    if [ "${require_clean}" = true ]; then
        GIT_MASTER=1 git -C "${repository}" status --porcelain=v2 -z --untracked-files=all >"${output_dir}/porcelain-v2.nul"
        [ ! -s "${output_dir}/porcelain-v2.nul" ] || fail "scope check failed: --require-clean status is not byte-empty"
    fi
}

check_scope() {
    local require_clean=false
    if [ "${1:-}" = "--require-clean" ]; then
        require_clean=true
        shift
    fi
    [ "$#" -eq 0 ] || fail "usage: $0 --check-scope [--require-clean]"
    local temp="${ACTIVE_RUN_ROOT}/scope"
    mkdir -p "${temp}"
    check_scope_repository "${ROOT_DIR}" "${START_HEAD}" "${HISTORICAL_BASE}" "${require_clean}" "${temp}" "${ALLOWLIST[@]}"
}

install_instrumentation() {
    local run_root="$1"
    local sentinel_dir="${run_root}/sentinels"
    local wrapper_dir="${run_root}/python-bin"
    local guard_dir="${run_root}/python-guard"
    local tool
    mkdir -p "${sentinel_dir}" "${wrapper_dir}" "${guard_dir}"
    : >"${run_root}/tool-calls.log"
    for tool in "${PROHIBITED_TOOLS[@]}"; do
        cat >"${sentinel_dir}/${tool}" <<'TOOL'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename "$0")" "$*" >>"${OFFLINE_GATE_TOOL_LOG:?}"
printf 'offline gate denied tool: %s\n' "$(basename "$0")" >&2
exit 97
TOOL
        chmod 0755 "${sentinel_dir}/${tool}"
    done
    cat >"${guard_dir}/sitecustomize.py" <<PY
import os
import pathlib
import sys

ROOT = pathlib.Path(${run_root@Q}).resolve()
def under(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False

def audit(event, arguments):
    if event in {"socket.connect", "socket.connect_ex", "socket.getaddrinfo", "socket.bind", "socket.listen"}:
        raise RuntimeError(f"offline gate denied socket/DNS event: {event}")
    if event in {"os.system", "os.exec", "os.spawn", "os.posix_spawn"}:
        raise RuntimeError(f"offline gate denied process escape: {event}")
    if event == "open" and arguments and isinstance(arguments[0], (str, bytes)):
        raw = os.fsdecode(arguments[0])
        mode = arguments[1] if len(arguments) > 1 else None
        flags = arguments[2] if len(arguments) > 2 else 0
        writing = (isinstance(mode, str) and any(token in mode for token in "wax+")) or (
            isinstance(flags, int) and bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND))
        )
        if writing:
            path = pathlib.Path(raw)
            if path.is_absolute() and path != pathlib.Path("/dev/null") and not under(path.resolve(strict=False), ROOT):
                raise RuntimeError(f"offline gate denied absolute write: {path}")

sys.addaudithook(audit)
PY
    cat >"${wrapper_dir}/python3" <<PY
#!/usr/bin/env bash
export PYTHONDONTWRITEBYTECODE=1
if [ "\${1:-}" = envs/vlad/tests/target-policy-test.py ]; then
    export PYTHONPATH=${guard_dir@Q}${TARGET_POLICY_MODULE_PATH:+:${TARGET_POLICY_MODULE_PATH@Q}}
    exec ${TARGET_POLICY_PYTHON_BIN@Q} "\$@"
fi
export PYTHONPATH=${guard_dir@Q}${PYTHON_MODULE_PATH:+:${PYTHON_MODULE_PATH@Q}}
exec ${PYTHON_BIN@Q} "\$@"
PY
    chmod 0755 "${wrapper_dir}/python3"
    ln -s python3 "${wrapper_dir}/python"
    printf '%s\n' "${sentinel_dir}:${wrapper_dir}:${RUNTIME_PATH}"
}

run_clean() {
    local run_root="$1"
    local path_value="$2"
    shift 2
    env -i \
        HOME="${run_root}/home" \
        USER="${USER:-offline-gate}" \
        LOGNAME="${USER:-offline-gate}" \
        LANG=C \
        LC_ALL=C \
        MPLCONFIGDIR="${run_root}/matplotlib-cache" \
        PATH="${path_value}" \
        PIP_CACHE_DIR="${run_root}/pip-cache" \
        PYTHONDONTWRITEBYTECODE=1 \
        PYTHONPYCACHEPREFIX="${run_root}/python-cache" \
        PYTHONUSERBASE="${run_root}/python-user" \
        SPACK_USER_CACHE_PATH="${run_root}/spack-cache" \
        TMPDIR="${run_root}/tmp" \
        UV_CACHE_DIR="${run_root}/uv-cache" \
        XDG_CACHE_HOME="${run_root}/xdg-cache" \
        OFFLINE_GATE_TOOL_LOG="${run_root}/tool-calls.log" \
        "$@"
}

run_expected_failure() {
    local expected_status="$1"
    local expected_message="$2"
    local label="$3"
    local output_dir="$4"
    shift 4
    local status
    set +e
    "$@" >"${output_dir}/${label}.out" 2>"${output_dir}/${label}.err"
    status=$?
    set -e
    [ "${status}" -eq "${expected_status}" ] || fail "${label} status ${status}, expected ${expected_status}"
    grep -Fq -- "${expected_message}" "${output_dir}/${label}.out" "${output_dir}/${label}.err" || fail "${label} did not report: ${expected_message}"
    if grep -Eq 'command not found|No such file or directory|ModuleNotFoundError' "${output_dir}/${label}.out" "${output_dir}/${label}.err"; then
        fail "${label} was rejected by missing setup"
    fi
    printf 'PASS: intended failure %s status=%s\n' "${label}" "${status}"
}

run_target_policy_self_test() {
    local run_root="$1"
    local path_value="$2"
    local expected output status_count status_line
    if [ -n "${SPACK_SOURCE}" ]; then
        expected="TARGET_POLICY_SEMANTIC_VALIDATION=PASSED spack_commit=fff95dd9aed0af7c7a8252adbef5623fcd4187f7 spack_packages_commit=65f3228ea2533e8413c17661a3a0db3636269631"
        output="$(run_clean "${run_root}" "${path_value}" python3 envs/vlad/tests/target-policy-test.py \
            --self-test \
            --spack-source "${SPACK_SOURCE}" \
            --spack-packages-source "${SPACK_PACKAGES_SOURCE}")"
    else
        expected="TARGET_POLICY_SEMANTIC_VALIDATION=SKIPPED reason=source-inputs-not-supplied"
        output="$(run_clean "${run_root}" "${path_value}" python3 envs/vlad/tests/target-policy-test.py --self-test)"
    fi
    printf '%s\n' "${output}"
    status_count="$(printf '%s\n' "${output}" | grep -c '^TARGET_POLICY_SEMANTIC_VALIDATION=' || true)"
    status_line="$(printf '%s\n' "${output}" | grep '^TARGET_POLICY_SEMANTIC_VALIDATION=' || true)"
    [ "${status_count}" -eq 1 ] || fail "target-policy self-test emitted ${status_count} semantic status lines, expected exactly 1"
    [ "${status_line}" = "${expected}" ] || fail "target-policy self-test semantic status mismatch: ${status_line}"
    printf 'PASS: target-policy self-test semantic status is exact and singular\n'
}

run_default_gate() {
    local run_root path_value tracked_nul before_status after_status before_tree after_tree before_lock after_lock shell_file
    run_root="${ACTIVE_RUN_ROOT}"
    check_scope --require-clean
    before_tree="${run_root}/tree-before.nul"
    after_tree="${run_root}/tree-after.nul"
    host_preflight
    cleanup_observed_python_caches "${ROOT_DIR}"
    snapshot_physical_tree "${ROOT_DIR}" "${before_tree}"
    audit_manifest "${run_root}/audit"
    path_value="$(install_instrumentation "${run_root}")"
    before_lock="$(hash_file "${ROOT_DIR}/containers/images/sources-lock.json")"
    [ "${before_lock}" = "${SOURCE_LOCK_SHA256}" ] || fail "tracked source lock digest drifted before gate"
    "${PYTHON_BIN}" - "${ROOT_DIR}/containers/images/sources-lock.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["status"] == "blocked" and value["unresolved"]
PY
    before_status="${run_root}/status-before.nul"
    after_status="${run_root}/status-after.nul"
    GIT_MASTER=1 git -C "${ROOT_DIR}" status --porcelain=v2 -z --untracked-files=all >"${before_status}"
    tracked_nul="${run_root}/tracked-files.nul"
    GIT_MASTER=1 git -C "${ROOT_DIR}" ls-files -z >"${tracked_nul}"
    [ -s "${tracked_nul}" ] || fail "tracked file list is empty"

    while IFS= read -r -d '' shell_file; do
        case "${shell_file}" in
            *.sh) bash -n "${ROOT_DIR}/${shell_file}" ;;
        esac
    done <"${run_root}/audit/manifest.nul"

    cd "${ROOT_DIR}"
    run_clean "${run_root}" "${path_value}" python3 envs/vlad/tests/target-policy-test.py envs/vlad/spack.yaml containers/images/targets.json
    if [ -n "${SPACK_SOURCE}" ]; then
        run_clean "${run_root}" "${path_value}" python3 envs/vlad/tests/target-policy-test.py \
            --spack-source "${SPACK_SOURCE}" \
            --spack-packages-source "${SPACK_PACKAGES_SOURCE}" \
            envs/vlad/spack.yaml containers/images/targets.json
    else
        printf 'SKIP: pinned RequirementParser semantic validation (CHAPAR_OFFLINE_SPACK_SOURCE and CHAPAR_OFFLINE_SPACK_PACKAGES_SOURCE unset)\n'
    fi
    run_target_policy_self_test "${run_root}" "${path_value}"
    run_clean "${run_root}" "${path_value}" bash containers/images/tests/validate-locks.sh --self-test
    run_expected_failure 1 "source lock is blocked and must fail closed for production use" lock-require-complete "${run_root}" \
        run_clean "${run_root}" "${path_value}" bash containers/images/tests/validate-locks.sh --require-complete
    run_clean "${run_root}" "${path_value}" bash containers/images/tests/preflight-test.sh
    run_clean "${run_root}" "${path_value}" bash ci/tests/vlad-image-provisioning-test.sh
    run_clean "${run_root}" "${path_value}" bash containers/images/tests/build-image-plan-test.sh
    run_clean "${run_root}" "${path_value}" make -n build ENV=vlad RELEASE_ID=plan-fixture-20260805
    run_expected_failure 2 "RELEASE_ID is required for build" make-missing-release "${run_root}" \
        run_clean "${run_root}" "${path_value}" make -n build ENV=vlad
    run_expected_failure 2 "ENV is required for build" make-missing-env "${run_root}" \
        run_clean "${run_root}" "${path_value}" make -n build RELEASE_ID=plan-fixture-20260805 ENV=
    run_clean "${run_root}" "${path_value}" python3 ci/tests/no-direct-install-surface-test.py --file-list "${tracked_nul}" .
    run_clean "${run_root}" "${path_value}" python3 ci/tests/no-direct-install-surface-test.py --self-test
    run_clean "${run_root}" "${path_value}" python3 ci/tests/nscale-vlad-runbook-test.py docs/nscale-vlad-manual-build.md
    run_clean "${run_root}" "${path_value}" python3 ci/tests/nscale-vlad-runbook-test.py --self-test
    run_clean "${run_root}" "${path_value}" python3 ci/tests/nscale-vlad-runbook-test.py --check-links docs/nscale-vlad-manual-build.md
    run_clean "${run_root}" "${path_value}" python3 ci/tests/nscale-vlad-runbook-test.py --check-matrix docs/nscale-vlad-manual-build.md docs/ci-github-actions.md containers/images/build-image.sh
    run_clean "${run_root}" "${path_value}" python3 ci/verify-vlad-source-approval.py --self-test
    run_clean "${run_root}" "${path_value}" python3 ci/install-validated-sqsh.py --self-test
    run_clean "${run_root}" "${path_value}" python3 agents/skills/skill-creator/scripts/quick_validate.py agents/skills/chapar-vlad-image
    run_expected_failure 2 "direct Spack build mode is forbidden" sbatch-direct-spack "${run_root}" \
        run_clean "${run_root}" "${path_value}" env CHAPAR_ROOT="${ROOT_DIR}" OS_NAME=ubuntu24.04 ENV_NAME=vlad ENV_PATH=envs/vlad CHAPAR_ENV_ACTION=build CHAPAR_ENV_BUILD_MODE=spack bash ci/sbatch-env-build.sh

    [ ! -s "${run_root}/tool-calls.log" ] || fail "denied tool call log is not empty"
    after_lock="$(hash_file "${ROOT_DIR}/containers/images/sources-lock.json")"
    [ "${after_lock}" = "${before_lock}" ] || fail "tracked source lock changed during gate"
    GIT_MASTER=1 git -C "${ROOT_DIR}" status --porcelain=v2 -z --untracked-files=all >"${after_status}"
    cmp -s "${before_status}" "${after_status}" || fail "gate changed repository status or generated paths"
    snapshot_physical_tree "${ROOT_DIR}" "${after_tree}"
    cmp -s "${before_tree}" "${after_tree}" || fail "gate changed physical repository tree"
    assert_no_stale_gate_roots "${HOST_TEMP_ROOT}" "${ACTIVE_RUN_ROOT}"
    GIT_MASTER=1 git -C "${ROOT_DIR}" diff --check
    printf 'PASS: zero denied tool calls, no generated paths, blocked source lock byte-identical\n'
    printf 'PASS: instrumented offline integration gate complete\n'
}

git_fixture_commit() {
    local repository="$1"
    local message="$2"
    GIT_AUTHOR_NAME='Offline Fixture' GIT_AUTHOR_EMAIL='offline@example.invalid' \
    GIT_COMMITTER_NAME='Offline Fixture' GIT_COMMITTER_EMAIL='offline@example.invalid' \
        GIT_MASTER=1 git -C "${repository}" commit -q -m "${message}"
}

expect_scope_failure() {
    local label="$1"
    local expected="$2"
    local repository="$3"
    local start="$4"
    local base="$5"
    local temp="$6"
    local status output
    shift 6
    set +e
    output="$(check_scope_repository "${repository}" "${start}" "${base}" false "${temp}/${label}-streams" "$@" 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] || fail "scope self-test ${label} unexpectedly passed"
    [[ "${output}" == *"${expected}"* ]] || fail "scope self-test ${label} failed for wrong reason: ${output}"
    printf 'PASS: scope rejected %s\n' "${label}"
}

expect_stream_failure() {
    local label="$1"
    local expected="$2"
    local repository="$3"
    local streams="$4"
    shift 4
    local status output
    set +e
    output="$(parse_scope_streams "${repository}" "${streams}" "$@" 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] || fail "scope stream self-test ${label} unexpectedly passed"
    [[ "${output}" == *"${expected}"* ]] || fail "scope stream self-test ${label} failed for wrong reason: ${output}"
    printf 'PASS: scope stream rejected %s\n' "${label}"
}

self_test_scope() {
    local temp template base start head synthetic status_code output status
    temp="$1"
    template="${temp}/scope-template"
    GIT_MASTER=1 git init -q "${template}"
    mkdir -p "${template}/ci/tests"
    printf 'gate base\n' >"${template}/ci/tests/nscale-vlad-offline-gate.sh"
    printf 'delete historically\n' >"${template}/old-delete"
    printf 'rename historically\n' >"${template}/old-name"
    printf 'tracked unlisted\n' >"${template}/unlisted-tracked"
    GIT_MASTER=1 git -C "${template}" add ci/tests/nscale-vlad-offline-gate.sh old-delete old-name unlisted-tracked
    git_fixture_commit "${template}" base
    base="$(GIT_MASTER=1 git -C "${template}" rev-parse HEAD)"
    GIT_MASTER=1 git -C "${template}" rm -q old-delete
    GIT_MASTER=1 git -C "${template}" mv old-name historical-renamed
    git_fixture_commit "${template}" start
    start="$(GIT_MASTER=1 git -C "${template}" rev-parse HEAD)"
    printf 'gate modified\n' >>"${template}/ci/tests/nscale-vlad-offline-gate.sh"
    printf 'all:\n\t@true\n' >"${template}/Makefile"
    GIT_MASTER=1 git -C "${template}" add ci/tests/nscale-vlad-offline-gate.sh Makefile
    git_fixture_commit "${template}" executor
    head="$(GIT_MASTER=1 git -C "${template}" rev-parse HEAD)"
    [ "${head}" != "${start}" ] || fail "scope fixture did not create executor commit"
    check_scope_repository "${template}" "${start}" "${base}" true "${temp}/happy-streams" ci/tests/nscale-vlad-offline-gate.sh Makefile
    printf 'PASS: scope preserved base-to-start deletion/rename isolation and accepted A/M\n'

    GIT_MASTER=1 git clone -q "${template}" "${temp}/stable-dirty"
    printf 'unchanged dirty content\n' >>"${temp}/stable-dirty/unlisted-tracked"
    set +e
    output="$(check_scope_repository "${temp}/stable-dirty" "${start}" "${base}" true \
        "${temp}/stable-dirty-streams" ci/tests/nscale-vlad-offline-gate.sh Makefile unlisted-tracked 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] && [[ "${output}" == *"--require-clean status is not byte-empty"* ]] || \
        fail "scope self-test accepted unchanged dirty content under --require-clean: ${output}"
    printf 'PASS: --require-clean rejected unchanged dirty allowed content\n'

    GIT_MASTER=1 git clone -q "${template}" "${temp}/untracked"
    printf 'bad\n' >"${temp}/untracked/bad-untracked"
    expect_scope_failure unlisted-untracked "unlisted path" "${temp}/untracked" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/staged"
    printf 'bad\n' >"${temp}/staged/bad-staged"
    GIT_MASTER=1 git -C "${temp}/staged" add bad-staged
    expect_scope_failure unlisted-staged "unlisted path" "${temp}/staged" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/unstaged"
    printf 'bad\n' >>"${temp}/unstaged/unlisted-tracked"
    expect_scope_failure unlisted-unstaged "unlisted path" "${temp}/unstaged" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/deleted"
    rm "${temp}/deleted/Makefile"
    expect_scope_failure deleted "forbidden status D" "${temp}/deleted" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/renamed"
    GIT_MASTER=1 git -C "${temp}/renamed" mv Makefile RenamedMakefile
    expect_scope_failure renamed "forbidden status R" "${temp}/renamed" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile RenamedMakefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/type"
    rm "${temp}/type/Makefile"
    ln -s ci/tests/nscale-vlad-offline-gate.sh "${temp}/type/Makefile"
    GIT_MASTER=1 git -C "${temp}/type" add Makefile
    expect_scope_failure type-change "forbidden status T" "${temp}/type" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/duplicate"
    printf 'cached\n' >>"${temp}/duplicate/Makefile"
    GIT_MASTER=1 git -C "${temp}/duplicate" add Makefile
    printf 'unstaged\n' >>"${temp}/duplicate/Makefile"
    expect_scope_failure duplicate "duplicate/conflicting path" "${temp}/duplicate" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    GIT_MASTER=1 git clone -q "${template}" "${temp}/unmerged"
    printf 'ancestor\n' | GIT_MASTER=1 git -C "${temp}/unmerged" hash-object -w --stdin >"${temp}/ancestor"
    printf 'ours\n' | GIT_MASTER=1 git -C "${temp}/unmerged" hash-object -w --stdin >"${temp}/ours"
    printf 'theirs\n' | GIT_MASTER=1 git -C "${temp}/unmerged" hash-object -w --stdin >"${temp}/theirs"
    printf '100644 %s 1\tMakefile\n100644 %s 2\tMakefile\n100644 %s 3\tMakefile\n' \
        "$(<"${temp}/ancestor")" "$(<"${temp}/ours")" "$(<"${temp}/theirs")" | GIT_MASTER=1 git -C "${temp}/unmerged" update-index --index-info
    expect_scope_failure unmerged "unmerged index stages" "${temp}/unmerged" "${start}" "${base}" "${temp}" ci/tests/nscale-vlad-offline-gate.sh Makefile

    synthetic="${temp}/synthetic-streams"
    capture_scope_streams "${template}" "${start}" "${synthetic}"
    for status_code in C U X B; do
        : >"${synthetic}/committed.nul"
        : >"${synthetic}/unstaged.nul"
        : >"${synthetic}/untracked.nul"
        if [ "${status_code}" = C ]; then
            printf 'C100\0Makefile\0CopiedMakefile\0' >"${synthetic}/cached.nul"
        else
            printf '%s\0Makefile\0' "${status_code}" >"${synthetic}/cached.nul"
        fi
        expect_stream_failure "status-${status_code}" "forbidden status ${status_code}" "${template}" "${synthetic}" ci/tests/nscale-vlad-offline-gate.sh Makefile CopiedMakefile
    done
    : >"${synthetic}/committed.nul"
    : >"${synthetic}/unstaged.nul"
    : >"${synthetic}/untracked.nul"
    printf 'M\0' >"${synthetic}/cached.nul"
    expect_stream_failure missing-path "missing path" "${template}" "${synthetic}" ci/tests/nscale-vlad-offline-gate.sh Makefile
}

self_test_physical_snapshot() {
    local temp="$1"
    local fixture="${temp}/tree-fixture"
    local before="${temp}/tree-fixture-before.nul"
    local after="${temp}/tree-fixture-after.nul"
    mkdir -p "${fixture}/empty-directory"
    printf 'content\n' >"${fixture}/regular-file"
    ln -s regular-file "${fixture}/symbolic-link"
    snapshot_physical_tree "${fixture}" "${before}"
    "${PYTHON_BIN}" - "${before}" <<'PY'
import sys
from pathlib import Path

fields = Path(sys.argv[1]).read_bytes().removesuffix(b"\0").split(b"\0")
required = ((b"D", b"empty-directory"), (b"F", b"regular-file"), (b"L", b"symbolic-link", b"regular-file"))
for record in required:
    width = len(record)
    if not any(tuple(fields[index:index + width]) == record for index in range(len(fields) - width + 1)):
        raise SystemExit(f"physical snapshot omitted record: {record!r}")
PY
    mkdir -p "${fixture}/.git/ignored"
    snapshot_physical_tree "${fixture}" "${after}"
    cmp -s "${before}" "${after}" || fail "physical snapshot did not ignore only root .git internals"
    mkdir "${fixture}/generated-empty-directory"
    snapshot_physical_tree "${fixture}" "${after}"
    cmp -s "${before}" "${after}" && fail "physical snapshot missed an empty generated directory"
    rmdir "${fixture}/generated-empty-directory"
    snapshot_physical_tree "${fixture}" "${after}"
    cmp -s "${before}" "${after}" || fail "physical snapshot did not restore after empty-directory removal"
    printf 'PASS: physical snapshot covers directories, files, symlinks, and empty-directory drift\n'
}

expect_bad_host_temp_root() {
    local label="$1"
    local expected="$2"
    local output_dir="$3"
    shift 3
    local status
    set +e
    "$@" >"${output_dir}/${label}.out" 2>"${output_dir}/${label}.err"
    status=$?
    set -e
    [ "${status}" -eq 1 ] || fail "unsafe host temp root ${label} status ${status}, expected 1"
    grep -Fq -- "${expected}" "${output_dir}/${label}.out" "${output_dir}/${label}.err" || \
        fail "unsafe host temp root ${label} failed for the wrong reason"
    printf 'PASS: rejected unsafe host temp root %s before run-root creation\n' "${label}"
}

self_test_secure_temp_roots() {
    local temp="$1"
    local fixture="${temp}/host-root-fixtures"
    local child_root output status
    mkdir -p "${fixture}/secure" "${fixture}/world-writable"
    chmod 0700 "${fixture}/secure"
    chmod 0777 "${fixture}/world-writable"
    ln -s "${fixture}/secure" "${fixture}/symlink"

    expect_bad_host_temp_root unset "host temp root is unset" "${fixture}" \
        env -u TMPDIR OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root relative "host temp root is not absolute" "${fixture}" \
        env TMPDIR=relative-temp OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root symlink "host temp root is a symlink" "${fixture}" \
        env TMPDIR="${fixture}/symlink" OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root tmp-symlink "host temp root is a symlink: /tmp" "${fixture}" \
        env TMPDIR=/tmp OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root private-tmp "host temp root mode is 1777, expected 0700: /private/tmp" "${fixture}" \
        env TMPDIR=/private/tmp OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root world-writable "host temp root mode is 0777, expected 0700" "${fixture}" \
        env TMPDIR="${fixture}/world-writable" OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe
    expect_bad_host_temp_root worktree-contained "host temp root is inside the product tree" "${fixture}" \
        env TMPDIR="${ROOT_DIR}" OFFLINE_GATE_INTERNAL_SELF_TEST=1 bash "${SCRIPT_PATH}" --internal-temp-root-probe

    set +e
    output="$(env TMPDIR="${fixture}/secure" OFFLINE_GATE_INTERNAL_SELF_TEST=1 \
        bash "${SCRIPT_PATH}" --internal-temp-root-probe 2>"${fixture}/secure-child.err")"
    status=$?
    set -e
    [ "${status}" -eq 0 ] || fail "secure host temp root child failed status ${status}"
    child_root="${output#RUN_ROOT=}"
    [ "${child_root}" != "${output}" ] && [ -n "${child_root}" ] || fail "secure host temp child omitted run-root receipt"
    [ ! -e "${child_root}" ] && [ ! -L "${child_root}" ] || fail "secure host temp child leaked its exact run root"
    printf 'PASS: secure host temp root child created and cleaned its exact run root\n'
}

self_test_gate_root_inventory() {
    local temp="$1"
    local host="${temp}/gate-root-inventory-host"
    local allowed="${host}/nscale-offline-self-test.allowed"
    local stale="${host}/nscale-scope.missed-prefix"
    local output status
    mkdir -p "${allowed}" "${stale}"
    chmod 0700 "${host}" "${allowed}" "${stale}"
    set +e
    output="$(assert_no_stale_gate_roots "${host}" "${allowed}" 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] && [[ "${output}" == *"stale gate run-root residue"* ]] && [[ "${output}" == *"nscale-scope.missed-prefix"* ]] || \
        fail "gate-root inventory missed the nscale-scope prefix"
    [ -d "${allowed}" ] && [ ! -L "${allowed}" ] && [ -d "${stale}" ] && [ ! -L "${stale}" ] || \
        fail "gate-root inventory modified residue while rejecting it"
    rmdir "${stale}"
    assert_no_stale_gate_roots "${host}" "${allowed}"
    printf 'PASS: gate-root inventory covers every owned prefix and fails without deleting residue\n'
}

self_test_invalid_run_root_cleanup() {
    local temp="$1"
    local host="${temp}/invalid-run-root-host"
    local output status
    mkdir "${host}"
    chmod 0700 "${host}"
    set +e
    output="$(env TMPDIR="${host}" OFFLINE_GATE_INTERNAL_SELF_TEST=1 OFFLINE_GATE_INTERNAL_INVALID_RUN_ROOT=1 \
        bash "${SCRIPT_PATH}" --internal-temp-root-probe 2>&1)"
    status=$?
    set -e
    [ "${status}" -eq 1 ] || fail "invalid run-root cleanup fixture status ${status}, expected 1"
    [[ "${output}" == *"run root mode is 0755, expected 0700"* ]] || \
        fail "invalid run-root cleanup fixture failed for the wrong reason: ${output}"
    assert_no_stale_gate_roots "${host}" "${host}/nscale-offline-root-probe.allowed"
    printf 'PASS: invalid pre-validation run root retained its validation failure and left no owned residue\n'
}

self_test_cache_cleanup() {
    local temp="$1"
    local fixture="${temp}/cache-cleanup-fixture"
    local symlink_fixture="${temp}/cache-symlink-fixture"
    local relative output status
    mkdir -p "${fixture}"
    for relative in "${PRODUCT_CACHE_DIRECTORIES[@]}"; do
        mkdir -p "${fixture}/${relative}"
    done
    for relative in "${PRODUCT_CACHE_FILES[@]}"; do
        : >"${fixture}/${relative}"
    done
    cleanup_observed_python_caches "${fixture}"
    for relative in "${PRODUCT_CACHE_DIRECTORIES[@]}" "${PRODUCT_CACHE_FILES[@]}"; do
        [ ! -e "${fixture}/${relative}" ] && [ ! -L "${fixture}/${relative}" ] || \
            fail "cache cleanup fixture retained exact observed path: ${relative}"
    done

    for relative in "${PRODUCT_CACHE_DIRECTORIES[@]}"; do
        mkdir -p "${fixture}/${relative}"
    done
    for relative in "${PRODUCT_CACHE_FILES[@]}"; do
        : >"${fixture}/${relative}"
    done
    : >"${fixture}/ci/__pycache__/unexpected.pyc"
    set +e
    output="$(cleanup_observed_python_caches "${fixture}" 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] && [[ "${output}" == *"cache cleanup refused inventory drift"* ]] || \
        fail "cache cleanup did not reject an extra entry"
    for relative in "${PRODUCT_CACHE_DIRECTORIES[@]}" "${PRODUCT_CACHE_FILES[@]}"; do
        [ -e "${fixture}/${relative}" ] && [ ! -L "${fixture}/${relative}" ] || \
            fail "cache cleanup modified inventory before rejecting drift: ${relative}"
    done
    [ -f "${fixture}/ci/__pycache__/unexpected.pyc" ] || fail "cache cleanup removed unexpected entry before rejecting drift"

    mkdir -p "${symlink_fixture}"
    for relative in "${PRODUCT_CACHE_DIRECTORIES[@]}"; do
        mkdir -p "${symlink_fixture}/${relative}"
    done
    for relative in "${PRODUCT_CACHE_FILES[@]}"; do
        : >"${symlink_fixture}/${relative}"
    done
    rm -- "${symlink_fixture}/${PRODUCT_CACHE_FILES[0]}"
    ln -s "${PRODUCT_CACHE_FILES[1]##*/}" "${symlink_fixture}/${PRODUCT_CACHE_FILES[0]}"
    set +e
    output="$(cleanup_observed_python_caches "${symlink_fixture}" 2>&1)"
    status=$?
    set -e
    [ "${status}" -ne 0 ] && [[ "${output}" == *"cache cleanup refused non-regular or symlink entry"* ]] || \
        fail "cache cleanup did not reject a symlinked observed file"
    [ -L "${symlink_fixture}/${PRODUCT_CACHE_FILES[0]}" ] || fail "cache cleanup modified symlink fixture before rejecting it"
    printf 'PASS: cache cleanup is exact, owner/type checked, and fail-before-write on inventory drift\n'
}

self_test_signal_cleanup() {
    local temp="$1"
    local signal_host="${temp}/signal-host"
    mkdir -p "${signal_host}"
    chmod 0700 "${signal_host}"
    PYTHONNOUSERSITE=1 PYTHONPATH='' "${PYTHON_BIN}" - \
        "${SCRIPT_PATH}" "${signal_host}" "${temp}/signal-children" <<'PY'
from __future__ import annotations

import os
import signal
import stat
import subprocess
import sys
from pathlib import Path


script = Path(sys.argv[1])
host_root = Path(sys.argv[2])
output_root = Path(sys.argv[3])
output_root.mkdir()
for signal_name, signal_value, expected_status in (
    ("INT", signal.SIGINT, 130),
    ("TERM", signal.SIGTERM, 143),
):
    environment = os.environ.copy()
    environment["TMPDIR"] = str(host_root)
    environment["OFFLINE_GATE_INTERNAL_SELF_TEST"] = "1"
    process = subprocess.Popen(
        ["bash", str(script), "--internal-signal-wait"],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    line = process.stdout.readline().strip()
    if not line.startswith("RUN_ROOT="):
        process.kill()
        stdout, stderr = process.communicate()
        raise SystemExit(f"{signal_name} child omitted run-root receipt: {line!r} {stdout!r} {stderr!r}")
    run_root = Path(line.removeprefix("RUN_ROOT="))
    info = run_root.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        process.kill()
        process.communicate()
        raise SystemExit(f"{signal_name} child exposed an unsafe run root: {run_root}")
    probe = subprocess.run(
        ["bash", str(script), "--internal-temp-root-probe"],
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if probe.returncode != 0 or not probe.stdout.startswith("RUN_ROOT="):
        process.kill()
        process.communicate()
        raise SystemExit(
            f"concurrent probe failed beside {signal_name} child: "
            f"status={probe.returncode} stdout={probe.stdout!r} stderr={probe.stderr!r}"
        )
    probe_root = Path(probe.stdout.strip().removeprefix("RUN_ROOT="))
    if os.path.lexists(probe_root):
        process.kill()
        process.communicate()
        raise SystemExit(f"concurrent probe leaked exact run root: {probe_root}")
    print(f"PASS: concurrent probe ran beside active {signal_name} child")
    os.kill(process.pid, signal_value)
    stdout, stderr = process.communicate(timeout=10)
    (output_root / f"{signal_name}.stdout").write_text(line + "\n" + stdout, encoding="utf-8")
    (output_root / f"{signal_name}.stderr").write_text(stderr, encoding="utf-8")
    if process.returncode != expected_status:
        raise SystemExit(f"{signal_name} child status {process.returncode}, expected {expected_status}")
    if os.path.lexists(run_root):
        raise SystemExit(f"{signal_name} child leaked exact run root: {run_root}")
    print(f"PASS: {signal_name} child cleaned exact run root and exited {expected_status}")
PY
}

run_self_test() {
    local temp run_root path_value label fixture reason status output before_tree after_tree regression_failures=0
    temp="${ACTIVE_RUN_ROOT}"
    before_tree="${temp}/product-tree-before.nul"
    after_tree="${temp}/product-tree-after.nul"
    host_preflight
    self_test_cleanup_replacement_race || regression_failures=$((regression_failures + 1))
    self_test_default_clean_scope_wiring || regression_failures=$((regression_failures + 1))
    self_test_portability_contract || regression_failures=$((regression_failures + 1))
    self_test_hash_tool_portability || regression_failures=$((regression_failures + 1))
    self_test_duplicate_module_paths "${temp}" || regression_failures=$((regression_failures + 1))
    [ "${regression_failures}" -eq 0 ] || fail "failing-first security regressions=${regression_failures}"
    cleanup_observed_python_caches "${ROOT_DIR}"
    snapshot_physical_tree "${ROOT_DIR}" "${before_tree}"
    audit_manifest "${temp}/audit"
    self_test_scope "${temp}"
    self_test_physical_snapshot "${temp}"
    self_test_secure_temp_roots "${temp}"
    self_test_gate_root_inventory "${temp}"
    self_test_invalid_run_root_cleanup "${temp}"
    self_test_cache_cleanup "${temp}"
    self_test_signal_cleanup "${temp}"
    fixtures=(
        'ssh host'
        'import socket'
        'open("/etc/escape", "w")'
        'cat </dev/tcp/example/443'
        'python3 -I script.py'
        'env -i python3 script.py'
        'node script.js'
        'printf x >/resources/live'
        'eval "$HELPER"'
    )
    reasons=(
        'denied live tool'
        'Python socket or DNS escape'
        'accepted static fixture'
        'special-device network escape'
        'Python isolation escape'
        'Python environment-strip escape'
        'non-Python runtime'
        'live absolute write'
        'computed eval helper'
    )
    for label in "${!fixtures[@]}"; do
        set +e
        output="$(static_denial_reason "${fixtures[$label]}" 2>&1)"
        status=$?
        set -e
        if [ "${label}" -eq 2 ]; then
            [ "${status}" -eq 0 ] && [[ "${output}" == *"${reasons[$label]}"* ]] || fail "static fixture parser setup failed: ${output}"
        else
            [ "${status}" -eq 1 ] && [[ "${output}" == *"${reasons[$label]}"* ]] || fail "static denial ${label} failed for wrong reason: ${output}"
        fi
    done
    run_root="${temp}"
    path_value="$(install_instrumentation "${run_root}")"
    run_expected_failure 97 "offline gate denied tool: ssh" tool-sentinel "${run_root}" \
        run_clean "${run_root}" "${path_value}" ssh example.invalid
    run_expected_failure 1 "offline gate denied socket/DNS event" socket-sentinel "${run_root}" \
        run_clean "${run_root}" "${path_value}" python3 -c 'import socket; socket.getaddrinfo("example.invalid", 443)'
    run_expected_failure 1 "offline gate denied absolute write" absolute-write-sentinel "${run_root}" \
        run_clean "${run_root}" "${path_value}" python3 -c 'open("/etc/offline-gate-self-test", "w")'
    run_expected_failure 97 "offline gate denied tool: node" runtime-sentinel "${run_root}" \
        run_clean "${run_root}" "${path_value}" node -e 'process.exit(0)'
    [ "$(wc -l <"${run_root}/tool-calls.log" | tr -d ' ')" -eq 2 ] || fail "self-test tool call ledger count mismatch"
    assert_no_stale_gate_roots "${HOST_TEMP_ROOT}" "${ACTIVE_RUN_ROOT}"
    snapshot_physical_tree "${ROOT_DIR}" "${after_tree}"
    cmp -s "${before_tree}" "${after_tree}" || fail "self-test changed physical repository tree"
    printf 'PASS: self-test proved tool, socket/DNS, absolute-path, /dev/tcp, Python-isolation, environment-strip, non-Python-runtime, and live-write denials\n'
}

resolve_runtime_configuration
require_file "${PYTHON_BIN}"
HOST_TEMP_ROOT="$(capture_secure_host_temp_root "${HOST_TMPDIR_INPUT}")"

case "${1:-}" in
    --check-scope)
        shift
        create_active_run_root nscale-scope
        prepare_run_environment "${ACTIVE_RUN_ROOT}"
        check_scope "$@"
        ;;
    --self-test)
        shift
        [ "$#" -eq 0 ] || fail "--self-test accepts no arguments"
        create_active_run_root nscale-offline-self-test
        prepare_run_environment "${ACTIVE_RUN_ROOT}"
        run_self_test
        ;;
    --internal-temp-root-probe)
        shift
        [ "$#" -eq 0 ] && [ "${OFFLINE_GATE_INTERNAL_SELF_TEST:-}" = 1 ] || fail "internal temp-root probe is unavailable"
        create_active_run_root nscale-offline-root-probe
        prepare_run_environment "${ACTIVE_RUN_ROOT}"
        printf 'RUN_ROOT=%s\n' "${ACTIVE_RUN_ROOT}"
        ;;
    --internal-signal-wait)
        shift
        [ "$#" -eq 0 ] && [ "${OFFLINE_GATE_INTERNAL_SELF_TEST:-}" = 1 ] || fail "internal signal fixture is unavailable"
        create_active_run_root nscale-offline-signal
        prepare_run_environment "${ACTIVE_RUN_ROOT}"
        printf 'RUN_ROOT=%s\n' "${ACTIVE_RUN_ROOT}"
        while :; do
            :
        done
        ;;
    "")
        create_active_run_root nscale-offline-gate
        prepare_run_environment "${ACTIVE_RUN_ROOT}"
        run_default_gate
        ;;
    *)
        fail "usage: $0 [--check-scope [--require-clean] | --self-test]"
        ;;
esac
