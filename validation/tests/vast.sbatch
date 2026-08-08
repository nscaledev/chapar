#!/usr/bin/env bash
# DESCRIPTION: Runner-resolved mounted-filesystem identity and cross-rank correctness before bounded storage burn-in
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:25:00
#SBATCH --job-name=vast-validation

# Establishes that the storage under test is the filesystem the site intended and
# that it behaves coherently across ranks, then hands off to the bounded burn-in.
#
# Identity is read from the mount itself -- findmnt, statfs, and nfsstat -- and
# never from a storage control plane: what a management API reports and what this
# node has mounted are different claims, and only the second one matters here.
#
# Cross-rank correctness is checked directly: every rank writes a payload and its
# checksum, rank zero verifies all of them and performs a rename and a delete, and
# the other ranks must observe both. A shared filesystem that loses any of that is
# not usable for a parallel job however fast it benchmarks.
#
# Nothing in this repository resolves the runner storage contract yet, so with none
# of it present the suite SKIPs; half-present is a FAIL.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

canonical_directory() {
    local directory="$1" canonical
    [ -n "${directory}" ] || fail 'directory is empty'
    [[ "${directory}" = /* ]] || fail "directory is not absolute: ${directory}"
    [ ! -L "${directory}" ] || fail "directory is a symlink: ${directory}"
    [ -d "${directory}" ] || fail "directory does not exist: ${directory}"
    [ -w "${directory}" ] || fail "directory is not writable: ${directory}"
    canonical="$(cd -P -- "${directory}" && pwd -P)"
    [ "${directory}" = "${canonical}" ] || fail "directory must not traverse symlinks: ${directory}"
    printf '%s\n' "${canonical}"
}

# The re-entrant rank check, invoked by srun below. Handled before anything else.
rank_check() {
    local work_dir="$1"
    local rank="${SLURM_PROCID:?SLURM_PROCID is required for rank check}"
    local total="${VAST_RANKS:?VAST_RANKS is required for rank check}"
    local marker="${work_dir}/namespace-marker"
    local token="${VAST_SENTINEL_TOKEN:?VAST_SENTINEL_TOKEN is required for rank check}"
    local deadline=$(($(date +%s) + 30))
    while [ ! -f "${marker}" ]; do
        (( $(date +%s) < deadline )) || fail 'shared namespace marker did not become visible'
        sleep 1
    done
    [ "$(<"${marker}")" = "${token}" ] || fail 'shared namespace marker content mismatch'
    printf 'token=%s rank=%s\n' "${token}" "${rank}" > "${work_dir}/rank-${rank}.payload"
    (cd "${work_dir}" && sha256sum "rank-${rank}.payload" > "rank-${rank}.sha256")
    while [ "$(find "${work_dir}" -maxdepth 1 -name 'rank-*.sha256' | wc -l)" -lt "${total}" ]; do
        (( $(date +%s) < deadline )) || fail 'not every rank payload became visible'
        sleep 1
    done
    if [ "${rank}" -eq 0 ]; then
        (cd "${work_dir}" && sha256sum -c rank-*.sha256 >/dev/null) || fail 'cross-rank payload checksum verification failed'
        printf '%s\n' "${token}" > "${work_dir}/rename-source"
        mv "${work_dir}/rename-source" "${work_dir}/rename-destination"
        [ -f "${work_dir}/rename-destination" ] || fail 'rename was not visible to the writing rank'
        rm -f "${work_dir}/rename-destination"
        [ ! -e "${work_dir}/rename-destination" ] || fail 'delete was not visible to the writing rank'
        printf 'complete\n' > "${work_dir}/cross-rank-complete"
    else
        while [ ! -f "${work_dir}/cross-rank-complete" ]; do
            (( $(date +%s) < deadline )) || fail 'cross-rank completion was not visible'
            sleep 1
        done
        [ ! -e "${work_dir}/rename-destination" ] || fail 'delete was not visible to this rank'
    fi
}

if [ "${1:-}" = --rank-check ]; then
    [ "$#" -eq 2 ] || { printf 'usage: %s --rank-check <work-dir>\n' "$0" >&2; exit 2; }
    rank_check "$2"
    exit 0
fi

# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

runner_contract_present() {
    [ -n "${VAST_STORAGE_TARGET:-}" ] ||
        [ -n "${VAST_STORAGE_TARGET_ROOT:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" ] ||
        [ -n "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESULTS_TARGET:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESULTS_ROOT:-}" ]
}

validate_target() {
    case "${VAST_STORAGE_TARGET:-}" in job-scratch) ;; *) fail 'VAST_STORAGE_TARGET must be the allowlisted logical target job-scratch'; return ;; esac
    [ "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" = "${VAST_STORAGE_TARGET}" ] || { fail 'runner did not resolve VAST_STORAGE_TARGET through validation policy'; return; }
    [ "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" = 1 ] || { fail 'runner storage-policy resolution marker is missing'; return; }
    [ "${VALIDATION_STORAGE_RESULTS_TARGET:-}" = managed-results ] || { fail 'runner must declare managed-results as the distinct result target'; return; }
    TARGET_ROOT="$(canonical_directory "${VAST_STORAGE_TARGET_ROOT:-}")" || return
    RESULTS_STORAGE_ROOT="$(canonical_directory "${VALIDATION_STORAGE_RESULTS_ROOT:-}")" || return
    RESULTS_ROOT_CANONICAL="$(canonical_directory "${RESULTS_ROOT}")" || return
    case "${TARGET_ROOT}/" in "${RESULTS_STORAGE_ROOT}/"*|"${RESULTS_ROOT_CANONICAL}/"*) fail 'benchmark target must not be inside results storage'; return ;; esac
    case "${RESULTS_STORAGE_ROOT}/" in "${TARGET_ROOT}/"*) fail 'results storage must not be inside benchmark target'; return ;; esac
}

create_work_directory() {
    VAST_WORK_DIR="$(mktemp -d "${TARGET_ROOT}/chapar-vast.XXXXXX")"
    chmod 700 "${VAST_WORK_DIR}"
    [ ! -L "${VAST_WORK_DIR}" ] || fail 'generated VAST directory is a symlink'
    [ "$(cd -P -- "$(dirname "${VAST_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || { fail 'generated VAST directory escaped the validated target root'; return; }
    VAST_SENTINEL="${VAST_WORK_DIR}/.chapar-vast-sentinel"
    VAST_SENTINEL_TOKEN="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "${VAST_SENTINEL_TOKEN}" > "${VAST_SENTINEL}"
    [ -O "${VAST_SENTINEL}" ] || fail 'VAST sentinel is not owned by the validation user'
}

cleanup_work_directory() {
    [ -n "${VAST_WORK_DIR:-}" ] || return 0
    [ -n "${TARGET_ROOT:-}" ] || return 1
    [ -d "${VAST_WORK_DIR}" ] && [ ! -L "${VAST_WORK_DIR}" ] || return 1
    [[ "$(basename "${VAST_WORK_DIR}")" = chapar-vast.* ]] || return 1
    [ "$(cd -P -- "$(dirname "${VAST_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || return 1
    [ -f "${VAST_SENTINEL:-}" ] && [ ! -L "${VAST_SENTINEL}" ] && [ -O "${VAST_SENTINEL}" ] || return 1
    [ "$(<"${VAST_SENTINEL}")" = "${VAST_SENTINEL_TOKEN:-}" ] || return 1
    rm -rf -- "${VAST_WORK_DIR}"
    VAST_WORK_DIR=""
}

finalize_with_cleanup() {
    local status="$1"
    trap - EXIT
    if ! cleanup_work_directory; then
        status=1
        validation_set_verdict FAIL 'guarded cleanup refused the generated VAST directory'
    fi
    validation_result_finalize "${status}"
}

validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_STORAGE)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init vast "${results_root}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

export VAST_MOUNT_FIXTURE="${fixture}"
export VAST_CAPABILITY="${validation_dir}/config/capability.yaml"
export VAST_MOUNT_RESULT="${RESULTS_DIR}/vast_mount.json"
export VAST_MOUNT_PROM="${RESULTS_DIR}/vast_mount.prom"
export VAST_MOUNT_FINDMNT="${RESULTS_DIR}/mount.findmnt"
export VAST_MOUNT_STATFS="${RESULTS_DIR}/mount.statfs"
export VAST_MOUNT_NFSSTAT="${RESULTS_DIR}/mount.nfsstat"

if [ -z "${fixture}" ]; then
    if ! runner_contract_present; then
        validation_resource_unavailable 'the runner storage contract is not configured on this node' optional
    fi
    validate_target
    create_work_directory
    trap 'finalize_with_cleanup "$?"' EXIT
    findmnt -n -T "${TARGET_ROOT}" -o SOURCE,FSTYPE,OPTIONS > "${VAST_MOUNT_FINDMNT}"
    stat -f -c '%T' "${TARGET_ROOT}" > "${VAST_MOUNT_STATFS}"
    if grep -q 'nfs' "${VAST_MOUNT_FINDMNT}" && command -v nfsstat >/dev/null 2>&1; then
        nfsstat -m > "${VAST_MOUNT_NFSSTAT}" 2>/dev/null || true
    fi
    VAST_RANKS="${VAST_RANKS:-${SLURM_JOB_NUM_NODES:-2}}"
    [[ "${VAST_RANKS}" =~ ^([2-9]|1[0-6])$ ]] || fail 'VAST_RANKS must be an integer from 2 through 16'
    printf '%s\n' "${VAST_SENTINEL_TOKEN}" > "${VAST_WORK_DIR}/namespace-marker"
    export VAST_RANKS VAST_SENTINEL_TOKEN
    srun --nodes="${VAST_RANKS}" --ntasks="${VAST_RANKS}" --ntasks-per-node=1 "${script_dir}/vast.sbatch" --rank-check "${VAST_WORK_DIR}"
fi

python3 <<'PY'
import json
import os
from pathlib import Path

import yaml

fixture = os.environ["VAST_MOUNT_FIXTURE"]
if fixture:
    data = json.loads((Path(fixture) / "manifest.json").read_text(encoding="utf-8"))
    expected = data["mount_expectation"]
    observed = data["mount_observed"]
    namespace = data["namespace"]
    checksums = data["checksums"]
else:
    data = {}
    configured = (yaml.safe_load(Path(os.environ["VAST_CAPABILITY"]).read_text(encoding="utf-8")) or {}).get("storage", {}) or {}
    source, filesystem_type, options = Path(os.environ["VAST_MOUNT_FINDMNT"]).read_text(encoding="utf-8").strip().split(None, 2)
    expected = {
        "filesystem_class": configured.get("expected_filesystem_class", ""),
        "source_identity": configured.get("expected_mount_source", ""),
        "filesystem_types": list(configured.get("expected_filesystem_types", []) or []),
        "required_options": list(configured.get("required_mount_options", []) or []),
    }
    observed = {
        "source_identity": source,
        "filesystem_type": filesystem_type,
        "options": options.split(","),
        "statfs_type": Path(os.environ["VAST_MOUNT_STATFS"]).read_text(encoding="utf-8").strip(),
        "nfs_client_available": Path(os.environ["VAST_MOUNT_NFSSTAT"]).is_file(),
    }
    # The rank check either completed or the suite already failed, so reaching here
    # means every cross-rank property held.
    namespace = {"marker_visible_to_all_ranks": True, "rename_visible_to_all_ranks": True, "delete_visible_to_all_ranks": True}
    checksums = {"all_rank_writes_verified": True}

errors = []
if expected["filesystem_class"] not in {"vast", "nfs", "generic"}:
    errors.append("configured filesystem class is invalid")
# An empty expected source means the site declared no identity to compare, which is
# uncompared rather than a mismatch.
if expected["source_identity"] and observed["source_identity"] != expected["source_identity"]:
    errors.append("mounted source identity does not match the configured expectation")
if observed["filesystem_type"] not in expected["filesystem_types"]:
    errors.append("mounted filesystem type does not match the configured expectation")
for option in expected["required_options"]:
    if option not in observed["options"]:
        errors.append(f"mounted filesystem is missing required option {option}")
for name, value in namespace.items():
    if not value:
        errors.append(f"cross-rank namespace check failed: {name}")
if not checksums["all_rank_writes_verified"]:
    errors.append("cross-rank payload checksum verification failed")
verdict = "FAIL" if errors else "PASS"
declared = data.get("verdicts", {}).get("vast") if fixture else None
if declared and declared != verdict:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "filesystem_class": expected["filesystem_class"],
    "source_identity_match": (not expected["source_identity"]) or observed["source_identity"] == expected["source_identity"],
    "filesystem_type": observed["filesystem_type"], "statfs_type": observed.get("statfs_type", ""),
    "nfs_client_available": observed["nfs_client_available"], "namespace": namespace,
    "checksums": checksums, "control_plane_consulted": False,
    "verdict": verdict, "failures": errors,
}
Path(os.environ["VAST_MOUNT_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(os.environ["VAST_MOUNT_PROM"]).write_text(
    "# TYPE chapar_vast_mount_identity_match gauge\n"
    f"chapar_vast_mount_identity_match {int(payload['source_identity_match'])}\n"
    "# TYPE chapar_vast_cross_rank_checksum_verified gauge\n"
    f"chapar_vast_cross_rank_checksum_verified {int(payload['checksums']['all_rank_writes_verified'])}\n",
    encoding="utf-8",
)
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${RESULTS_DIR}/vast_mount.json")"
reason="$(python3 -c "import json,sys; print('; '.join(json.load(open(sys.argv[1]))['failures']))" "${RESULTS_DIR}/vast_mount.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
esac

# The burn-in only runs once the storage is known to be the right filesystem and
# coherent across ranks; benchmarking an unverified mount measures the wrong thing.
if [ -z "${fixture}" ] && [ "${verdict}" = PASS ]; then
    STORAGE_BURNIN_TARGET="${VAST_STORAGE_TARGET}" \
    STORAGE_BURNIN_TARGET_ROOT="${VAST_STORAGE_TARGET_ROOT}" \
    STORAGE_BURNIN_IOR_RANKS="${VAST_BURNIN_IOR_RANKS:-${VAST_RANKS}}" \
    RESULTS_ROOT="${RESULTS_ROOT}" \
        bash "${script_dir}/storage-burnin.sbatch"
fi

printf 'VAST mount evidence written to %s\n' "${RESULTS_DIR}" >&2
