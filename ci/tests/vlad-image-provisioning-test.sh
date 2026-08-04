#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
INSTALLER="${ROOT_DIR}/ci/install-vlad-image-site-contract.sh"
REGISTER="${ROOT_DIR}/ci/register-vlad-image-runner.sh"
TRACKED_SCHEMA="${ROOT_DIR}/containers/images/site-contract.schema.json"
TRACKED_LOCK="${ROOT_DIR}/containers/images/sources-lock.json"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/vlad-image-provisioning.XXXXXX")"
TMP_BASE="$(cd "${TMP_BASE}" && pwd -P)"
chmod 0700 "${TMP_BASE}"
cleanup() {
    rm -rf "${TMP_BASE}"
    printf 'CLEANUP: removed disposable Vlad image provisioning fixture\n'
}
trap cleanup EXIT HUP INT TERM

FIXTURE="${TMP_BASE}/fixture"
SOURCE_DIR="${FIXTURE}/source"
DESTINATION="${FIXTURE}/installed/site-contract.json"
SCHEMA="${FIXTURE}/site-contract.schema.json"
ACTIVE_CONTRACT="${SOURCE_DIR}/site-contract.json"
EXAMPLE_CONTRACT="${SOURCE_DIR}/site-contract.example.json"
MACHINE_ID="${FIXTURE}/machine-id"
OS_RELEASE="${FIXTURE}/os-release"
CREDENTIAL="${FIXTURE}/registration-token"
REMOVAL_TOKEN="${FIXTURE}/runner-removal-token"
COMPLETE_LOCK="${FIXTURE}/sources-lock.complete.json"
BLOCKED_LOCK="${FIXTURE}/sources-lock.blocked.json"
INSTALL_MARKER="${FIXTURE}/installer-side-effect"
RUNNER_MARKER="${FIXTURE}/runner-side-effect"

mkdir -p "${SOURCE_DIR}" "$(dirname "${DESTINATION}")"
chmod 0755 "${FIXTURE}" "${SOURCE_DIR}" "$(dirname "${DESTINATION}")"
cp "${TRACKED_SCHEMA}" "${SCHEMA}"
chmod 0600 "${SCHEMA}"
printf '%s\n' 0123456789abcdef0123456789abcdef >"${MACHINE_ID}"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"${OS_RELEASE}"
printf '%s\n' fixture-registration-token >"${CREDENTIAL}"
printf '%s\n' fixture-runner-removal-token >"${REMOVAL_TOKEN}"
chmod 0600 "${MACHINE_ID}" "${OS_RELEASE}" "${CREDENTIAL}" "${REMOVAL_TOKEN}"

python3 - "${MACHINE_ID}" "${ACTIVE_CONTRACT}" "${EXAMPLE_CONTRACT}" "${TRACKED_LOCK}" "${COMPLETE_LOCK}" "${BLOCKED_LOCK}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

machine_id, active_path, example_path, tracked_lock, complete_path, blocked_path = map(Path, sys.argv[1:])
identity = hashlib.sha256(machine_id.read_bytes()).hexdigest()
active = {
    "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-site-contract/v1",
    "schema_version": 1,
    "status": "active",
    "roles": {
        "builders": [identity],
        "publishers": ["b" * 64],
        "validators": ["c" * 64],
    },
    "targets": {
        "linux-x86_64-generic": {
            "hardware_class": "physical-x86-64-v1",
            "partition": "x86v1",
            "constraint": "physical_v1",
        },
        "linux-x86_64-v4": {
            "hardware_class": "physical-x86-64-v4",
            "partition": "x86v4",
            "constraint": "physical_v4",
        },
        "linux-aarch64-gb300": {
            "hardware_class": "gb300",
            "partition": "gb300",
            "constraint": "gb300_nodes",
        },
    },
}
active_path.write_text(json.dumps(active), encoding="utf-8")
example = json.loads(json.dumps(active))
example["status"] = "example"
example["targets"]["linux-x86_64-generic"]["partition"] = "REPLACE_WITH_PARTITION"
example_path.write_text(json.dumps(example), encoding="utf-8")

source = json.loads(tracked_lock.read_text(encoding="utf-8"))
source["status"] = "complete"
source["unresolved"] = []
for category in source["contract"]["required_categories"]:
    source["verified"].setdefault(category, {"fixture": True})
source["verified"]["nvidia_hpc_benchmarks_oci"] = {
    "index_digest": "sha256:" + "1" * 64,
    "platforms": {
        "linux-x86_64-generic": {
            "oci_platform": "linux/amd64",
            "descriptor_digest": "sha256:" + "2" * 64,
            "config_digest": "sha256:" + "3" * 64,
        },
        # Both x86 targets consume the single linux/amd64 descriptor of the
        # 26.02 index, so they must name the same descriptor and config digests.
        # This fixture is what pins that per-OCI-platform invariant.
        "linux-x86_64-v4": {
            "oci_platform": "linux/amd64",
            "descriptor_digest": "sha256:" + "2" * 64,
            "config_digest": "sha256:" + "3" * 64,
        },
        "linux-aarch64-gb300": {
            "oci_platform": "linux/arm64",
            "descriptor_digest": "sha256:" + "4" * 64,
            "config_digest": "sha256:" + "5" * 64,
        },
    },
}
source["verified"]["actions_runner_archives"] = [
    {
        "architecture": architecture,
        "version": "2.999.0",
        "url": f"https://github.com/actions/runner/releases/download/v2.999.0/actions-runner-linux-{architecture}-2.999.0.tar.gz",
        "sha256": digest * 64,
    }
    for architecture, digest in (("x64", "6"), ("arm64", "7"))
]
for category in ("ubuntu_builder_packages", "ubuntu_final_packages"):
    source["verified"][category] = [
        {
            "architecture": architecture,
            "packages": [{
                "name": "fixture-package",
                "version": "1.0-1",
                "url": f"https://snapshot.ubuntu.com/ubuntu/fixture/{architecture}/fixture-package.deb",
                "sha256": digest * 64,
            }],
        }
        for architecture, digest in (("amd64", "8"), ("arm64", "9"))
    ]
complete_path.write_text(json.dumps(source), encoding="utf-8")
source["status"] = "blocked"
blocked_path.write_text(json.dumps(source), encoding="utf-8")
PY
chmod 0600 "${ACTIVE_CONTRACT}" "${EXAMPLE_CONTRACT}" "${COMPLETE_LOCK}" "${BLOCKED_LOCK}"

hash_file() {
    python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

expect_failure_without_marker() {
    local name="$1"
    local marker="$2"
    shift 2
    rm -f "${marker}"
    set +e
    "$@" >"${FIXTURE}/${name}.out" 2>"${FIXTURE}/${name}.err"
    local status=$?
    set -e
    if [ "${status}" -eq 0 ]; then
        printf 'FAIL: %s unexpectedly succeeded\n' "${name}" >&2
        exit 1
    fi
    if [ -e "${marker}" ]; then
        printf 'FAIL: %s reached the privileged side-effect boundary\n' "${name}" >&2
        exit 1
    fi
    printf 'PASS: %s failed closed (%s) before side effects\n' "${name}" "${status}"
}

install_args() {
    INSTALL_ARGS=(
        --source "${ACTIVE_CONTRACT}"
        --expected-sha256 "$(hash_file "${ACTIVE_CONTRACT}")"
        --schema "${SCHEMA}"
        --destination "${DESTINATION}"
    )
}

export VLAD_IMAGE_CONTRACT_INSTALL_TEST_MODE=1
export VLAD_IMAGE_CONTRACT_INSTALL_TEST_ROOT="${TMP_BASE}"
export VLAD_IMAGE_CONTRACT_INSTALL_SIDE_EFFECT_MARKER="${INSTALL_MARKER}"

install_args
mv "${ACTIVE_CONTRACT}" "${ACTIVE_CONTRACT}.real"
ln -s "${ACTIVE_CONTRACT}.real" "${ACTIVE_CONTRACT}"
INSTALL_ARGS[3]="$(hash_file "${ACTIVE_CONTRACT}.real")"
expect_failure_without_marker installer-source-symlink "${INSTALL_MARKER}" "${INSTALLER}" "${INSTALL_ARGS[@]}"
rm "${ACTIVE_CONTRACT}"
mv "${ACTIVE_CONTRACT}.real" "${ACTIVE_CONTRACT}"

install_args
ln -s "${ACTIVE_CONTRACT}" "${DESTINATION}"
expect_failure_without_marker installer-destination-symlink "${INSTALL_MARKER}" "${INSTALLER}" "${INSTALL_ARGS[@]}"
rm "${DESTINATION}"

mkdir "${SOURCE_DIR}/writable"
chmod 0770 "${SOURCE_DIR}/writable"
cp "${ACTIVE_CONTRACT}" "${SOURCE_DIR}/writable/site-contract.json"
chmod 0600 "${SOURCE_DIR}/writable/site-contract.json"
WRITABLE_ARGS=(
    --source "${SOURCE_DIR}/writable/site-contract.json"
    --expected-sha256 "$(hash_file "${SOURCE_DIR}/writable/site-contract.json")"
    --schema "${SCHEMA}"
    --destination "${DESTINATION}"
)
expect_failure_without_marker installer-writable-parent "${INSTALL_MARKER}" "${INSTALLER}" "${WRITABLE_ARGS[@]}"

install_args
INSTALL_ARGS[3]="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_failure_without_marker installer-wrong-hash "${INSTALL_MARKER}" "${INSTALLER}" "${INSTALL_ARGS[@]}"

EXAMPLE_ARGS=(
    --source "${EXAMPLE_CONTRACT}"
    --expected-sha256 "$(hash_file "${EXAMPLE_CONTRACT}")"
    --schema "${SCHEMA}"
    --destination "${DESTINATION}"
)
expect_failure_without_marker installer-example-contract "${INSTALL_MARKER}" "${INSTALLER}" "${EXAMPLE_ARGS[@]}"

install_args
rm -f "${INSTALL_MARKER}"
"${INSTALLER}" "${INSTALL_ARGS[@]}" >"${FIXTURE}/installer-manual-qa.out"
if [ ! -f "${DESTINATION}" ] || [ -L "${DESTINATION}" ] || [ "$(hash_file "${DESTINATION}")" != "$(hash_file "${ACTIVE_CONTRACT}")" ]; then
    printf 'FAIL: disposable installer Manual QA did not atomically install the contract\n' >&2
    exit 1
fi
if [ "$(tr -d '\n' <"$(dirname "${DESTINATION}")/site-contract.sha256")" != "$(hash_file "${ACTIVE_CONTRACT}")" ]; then
    printf 'FAIL: disposable installer Manual QA did not install the protected hash\n' >&2
    exit 1
fi
python3 - "${DESTINATION}" "$(dirname "${DESTINATION}")/site-contract.sha256" <<'PY'
import os
import pathlib
import stat
import sys

contract, protected_hash = map(pathlib.Path, sys.argv[1:])
assert stat.S_IMODE(contract.lstat().st_mode) == 0o644
assert stat.S_IMODE(protected_hash.lstat().st_mode) == 0o600
assert contract.lstat().st_uid == protected_hash.lstat().st_uid == os.geteuid()
assert not contract.is_symlink() and not protected_hash.is_symlink()
PY
printf 'PASS: CLI-shaped disposable installer installed matching non-symlink contract and protected hash\n'
rm -f "${INSTALL_MARKER}"

export VLAD_IMAGE_RUNNER_TEST_MODE=1
export VLAD_IMAGE_RUNNER_TEST_ROOT="${TMP_BASE}"
export VLAD_IMAGE_RUNNER_TEST_SITE_CONTRACT="${DESTINATION}"
export VLAD_IMAGE_RUNNER_TEST_EXPECTED_HASH_FILE="$(dirname "${DESTINATION}")/site-contract.sha256"
export VLAD_IMAGE_RUNNER_TEST_MACHINE_ID="${MACHINE_ID}"
export VLAD_IMAGE_RUNNER_TEST_UNAME_M=x86_64
export VLAD_IMAGE_RUNNER_SIDE_EFFECT_MARKER="${RUNNER_MARKER}"

# The os-release fixture must live directly under the runner's test root, not
# under FIXTURE: register-vlad-image-runner.sh requires the standard symlink to
# sit exactly at <anchor>/etc/os-release, and the anchor must be 0700 or
# stricter. TMP_BASE satisfies both (FIXTURE is deliberately 0755 for the
# installer cases), and every other runner input is already under it.
mkdir -p "${TMP_BASE}/etc" "${TMP_BASE}/usr/lib"
mv "${OS_RELEASE}" "${TMP_BASE}/usr/lib/os-release"
ln -s ../usr/lib/os-release "${TMP_BASE}/etc/os-release"
export VLAD_IMAGE_RUNNER_TEST_OS_RELEASE="${TMP_BASE}/etc/os-release"

RUNNER_ARGS=(
    --role builder
    --target linux-x86_64-generic
    --credential-file "${CREDENTIAL}"
    --removal-token-file "${REMOVAL_TOKEN}"
    --runner-name fixture-vlad-builder
)

export VLAD_IMAGE_RUNNER_TEST_SOURCES_LOCK="${BLOCKED_LOCK}"
expect_failure_without_marker runner-blocked-lock "${RUNNER_MARKER}" "${REGISTER}" "${RUNNER_ARGS[@]}"

export VLAD_IMAGE_RUNNER_TEST_SOURCES_LOCK="${COMPLETE_LOCK}"
expect_failure_without_marker runner-wrong-architecture "${RUNNER_MARKER}" env VLAD_IMAGE_RUNNER_TEST_UNAME_M=aarch64 "${REGISTER}" "${RUNNER_ARGS[@]}"

INVALID_ROLE_ARGS=(--role administrator --credential-file "${CREDENTIAL}" --removal-token-file "${REMOVAL_TOKEN}")
expect_failure_without_marker runner-invalid-role "${RUNNER_MARKER}" "${REGISTER}" "${INVALID_ROLE_ARGS[@]}"

cp "${CREDENTIAL}" "${REMOVAL_TOKEN}.same"
chmod 0600 "${REMOVAL_TOKEN}.same"
SAME_TOKEN_ARGS=(
    --role builder
    --target linux-x86_64-generic
    --credential-file "${CREDENTIAL}"
    --removal-token-file "${REMOVAL_TOKEN}.same"
    --runner-name fixture-vlad-builder
)
expect_failure_without_marker runner-registration-token-reused-for-removal "${RUNNER_MARKER}" "${REGISTER}" "${SAME_TOKEN_ARGS[@]}"

mv "$(dirname "${DESTINATION}")/site-contract.sha256" "$(dirname "${DESTINATION}")/site-contract.sha256.hidden"
expect_failure_without_marker runner-missing-expected-hash "${RUNNER_MARKER}" "${REGISTER}" "${RUNNER_ARGS[@]}"
mv "$(dirname "${DESTINATION}")/site-contract.sha256.hidden" "$(dirname "${DESTINATION}")/site-contract.sha256"

ESCAPED_MARKER="${TMP_BASE}/escaped-runner-marker"
rm -f "${ESCAPED_MARKER}"
expect_failure_without_marker runner-marker-dotdot-escape "${RUNNER_MARKER}" env \
    VLAD_IMAGE_RUNNER_SIDE_EFFECT_MARKER="${FIXTURE}/../escaped-runner-marker" \
    "${REGISTER}" "${RUNNER_ARGS[@]}"
if [ -e "${ESCAPED_MARKER}" ]; then
    printf 'FAIL: runner marker escaped the canonical test root\n' >&2
    exit 1
fi
printf 'PASS: canonical marker containment rejected dot-dot escape\n'

rm "${TMP_BASE}/etc/os-release"
ln -s ../machine-id "${TMP_BASE}/etc/os-release"
expect_failure_without_marker runner-arbitrary-os-release-symlink "${RUNNER_MARKER}" "${REGISTER}" "${RUNNER_ARGS[@]}"
rm "${TMP_BASE}/etc/os-release"
ln -s ../usr/lib/os-release "${TMP_BASE}/etc/os-release"

rm -f "${RUNNER_MARKER}"
"${REGISTER}" "${RUNNER_ARGS[@]}" >"${FIXTURE}/runner-manual-qa.json"
python3 - "${FIXTURE}/runner-manual-qa.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["repository"] == "https://github.com/nscaledev/chapar"
assert value["runner_arch"] == "x64"
assert value["labels"] == "chapar,ubuntu24.04,vlad-image-builder,amd64"
assert value["role"] == "builder"
assert value["os_release_path"].endswith("/usr/lib/os-release")
assert value["staging_policy"] == "root-owned-0700-inactive-atomic-swap"
assert value["cleanup_authority"] == "dedicated-github-removal-token"
assert value["boot_cleanup"] == "enabled-oneshot-before-builder-registration"
PY
printf 'PASS: standard Ubuntu os-release symlink resolved to its canonical protected target\n'

assert_runner_source_contains() {
    local name="$1"
    local pattern="$2"
    if ! grep -Fq -- "${pattern}" "${REGISTER}"; then
        printf 'FAIL: %s lifecycle invariant is absent\n' "${name}" >&2
        exit 1
    fi
    printf 'PASS: %s lifecycle invariant is present\n' "${name}"
}

assert_runner_source_contains staging-root-owner 'install -d -o root -g root -m 0700 "${RUNTIME_DIR}" "${REMOVAL_STATE_DIR}" "${STAGING_DIR}"'
assert_runner_source_contains staging-extraction 'python3 - "${ARCHIVE}" "${STAGING_DIR}"'
assert_runner_source_contains atomic-inactive-swap 'os.rename(staging, active)'
assert_runner_source_contains staging-race-detection 'raise SystemExit("runner staging tree changed before activation")'
assert_runner_source_contains staging-concurrency-lock 'if ! flock -n 9; then'
assert_runner_source_contains failed-start-stop-disable 'systemctl disable --now "${UNIT_NAME}"'
assert_runner_source_contains failed-start-unit-removal 'rm -f -- "${UNIT_PATH}" "${UNIT_TEMP}"'
assert_runner_source_contains failed-start-daemon-reload 'systemctl daemon-reload >/dev/null 2>&1 || true'
assert_runner_source_contains rollback-old-tree-restore 'mv -- "${BACKUP_DIR}" "${RUNNER_DIR}"'
assert_runner_source_contains dedicated-removal-authority 'removal_token_path='
assert_runner_source_contains reboot-cleanup-unit 'chapar-vlad-image-builder-boot-cleanup.service'
assert_runner_source_contains reboot-cleanup-order 'After=network-online.target'
assert_runner_source_contains reboot-cleanup-registration 'ExecStart=${CLEANUP}'
printf 'PASS: staging race, failed-start rollback, and reboot cleanup semantics are locked by focused source regressions\n'
printf 'PASS: CLI-shaped disposable runner QA selected locked native x64 archive and exact builder labels\n'
printf 'PASS: no package, archive, Docker, GitHub, service-manager, or public-root action ran\n'
printf 'PASS: Vlad image provisioning focused fixture suite complete\n'
