#!/usr/bin/env bash
# DESCRIPTION: Bounded allowlisted storage burn-in with sentinel-owned cleanup
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --job-name=storage-burnin

# Writes a bounded amount of data to a runner-resolved scratch target and measures
# it. Two properties matter more than the numbers:
#
#   - the workload is bounded before it starts. Every knob has a ceiling, the
#     planned aggregate must fit under the declared maximum, and the target must
#     have that much free space plus a reserve, so a validation run cannot fill a
#     shared filesystem.
#   - cleanup is sentinel-owned. The suite only ever removes a directory it
#     created: the name must match its own prefix, the parent must be exactly the
#     validated target root, and the sentinel inside must be a regular file it owns
#     containing the token it generated. Anything else, and it refuses to delete
#     and fails rather than guessing.
#
# Nothing in this repository resolves the runner storage contract yet. With none of
# it present the suite SKIPs; with it half-present it FAILs, because a partially
# configured runner is an error rather than an absence.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

require_uint() {
    local name="$1" maximum="$2" value="${!1}"
    if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( 10#${value} > maximum )); then
        fail "${name} must be an integer no greater than ${maximum}"
    fi
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

runner_contract_present() {
    [ -n "${STORAGE_BURNIN_TARGET:-}" ] ||
        [ -n "${STORAGE_BURNIN_TARGET_ROOT:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" ] ||
        [ -n "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESULTS_TARGET:-}" ] ||
        [ -n "${VALIDATION_STORAGE_RESULTS_ROOT:-}" ]
}

validate_target() {
    case "${STORAGE_BURNIN_TARGET:-}" in job-scratch) ;; *) fail 'STORAGE_BURNIN_TARGET must be the allowlisted logical target job-scratch'; return ;; esac
    [ "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" = "${STORAGE_BURNIN_TARGET}" ] || { fail 'runner did not resolve STORAGE_BURNIN_TARGET through validation policy'; return; }
    [ "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" = 1 ] || { fail 'runner storage-policy resolution marker is missing'; return; }
    [ "${VALIDATION_STORAGE_RESULTS_TARGET:-}" = managed-results ] || { fail 'runner must declare managed-results as the distinct result target'; return; }
    TARGET_ROOT="$(canonical_directory "${STORAGE_BURNIN_TARGET_ROOT:-}")" || return
    RESULTS_STORAGE_ROOT="$(canonical_directory "${VALIDATION_STORAGE_RESULTS_ROOT:-}")" || return
    RESULTS_ROOT_CANONICAL="$(canonical_directory "${RESULTS_ROOT}")" || return
    # Benchmark data and results must not share a tree, in either direction: the
    # burn-in would otherwise measure the filesystem it is writing its own evidence
    # to, and cleanup could reach the evidence.
    case "${TARGET_ROOT}/" in "${RESULTS_STORAGE_ROOT}/"*|"${RESULTS_ROOT_CANONICAL}/"*) fail 'benchmark target must not be inside results storage'; return ;; esac
    case "${RESULTS_STORAGE_ROOT}/" in "${TARGET_ROOT}/"*) fail 'results storage must not be inside benchmark target'; return ;; esac
}

load_limits() {
    STORAGE_BURNIN_MAX_BYTES="${STORAGE_BURNIN_MAX_BYTES:-536870912}"
    STORAGE_BURNIN_MIN_FREE_BYTES="${STORAGE_BURNIN_MIN_FREE_BYTES:-1073741824}"
    STORAGE_BURNIN_IOR_RANKS="${STORAGE_BURNIN_IOR_RANKS:-1}"
    STORAGE_BURNIN_IOR_BLOCK_BYTES="${STORAGE_BURNIN_IOR_BLOCK_BYTES:-67108864}"
    STORAGE_BURNIN_IOR_TRANSFER_BYTES="${STORAGE_BURNIN_IOR_TRANSFER_BYTES:-1048576}"
    STORAGE_BURNIN_MDTEST_FILES="${STORAGE_BURNIN_MDTEST_FILES:-1000}"
    STORAGE_BURNIN_FIO_BYTES="${STORAGE_BURNIN_FIO_BYTES:-67108864}"
    STORAGE_BURNIN_H5BENCH_BYTES="${STORAGE_BURNIN_H5BENCH_BYTES:-33554432}"
    require_uint STORAGE_BURNIN_MAX_BYTES 1099511627776
    require_uint STORAGE_BURNIN_MIN_FREE_BYTES 1099511627776
    require_uint STORAGE_BURNIN_IOR_RANKS 4
    require_uint STORAGE_BURNIN_IOR_BLOCK_BYTES 536870912
    require_uint STORAGE_BURNIN_IOR_TRANSFER_BYTES 67108864
    require_uint STORAGE_BURNIN_MDTEST_FILES 10000
    require_uint STORAGE_BURNIN_FIO_BYTES 536870912
    require_uint STORAGE_BURNIN_H5BENCH_BYTES 536870912
    (( STORAGE_BURNIN_IOR_RANKS >= 1 )) || fail 'STORAGE_BURNIN_IOR_RANKS must be at least one'
    (( STORAGE_BURNIN_IOR_TRANSFER_BYTES >= 1 && STORAGE_BURNIN_IOR_TRANSFER_BYTES <= STORAGE_BURNIN_IOR_BLOCK_BYTES )) || { fail 'IOR transfer bytes must be positive and no greater than the IOR block size'; return; }
    PLANNED_BYTES=$((2 * STORAGE_BURNIN_IOR_RANKS * STORAGE_BURNIN_IOR_BLOCK_BYTES + STORAGE_BURNIN_FIO_BYTES + STORAGE_BURNIN_H5BENCH_BYTES))
    (( PLANNED_BYTES <= STORAGE_BURNIN_MAX_BYTES )) || { fail "planned aggregate bytes ${PLANNED_BYTES} exceed STORAGE_BURNIN_MAX_BYTES"; return; }
    TARGET_FREE_BYTES=$(( $(df -Pk "${TARGET_ROOT}" | awk 'NR==2 {print $4}') * 1024 ))
    (( TARGET_FREE_BYTES >= STORAGE_BURNIN_MIN_FREE_BYTES + PLANNED_BYTES )) || { fail 'benchmark target has insufficient free space for the bounded workload'; return; }
    STORAGE_BURNIN_BASELINE_VERDICT="${STORAGE_BURNIN_BASELINE_VERDICT:-NOT_EVALUATED}"
    case "${STORAGE_BURNIN_BASELINE_VERDICT}" in PASS|WARN|FAIL|NOT_EVALUATED) ;; *) fail 'STORAGE_BURNIN_BASELINE_VERDICT must be PASS, WARN, FAIL, or NOT_EVALUATED' ;; esac
}

create_work_directory() {
    STORAGE_BURNIN_WORK_DIR="$(mktemp -d "${TARGET_ROOT}/chapar-storage-burnin.XXXXXX")"
    chmod 700 "${STORAGE_BURNIN_WORK_DIR}"
    [ ! -L "${STORAGE_BURNIN_WORK_DIR}" ] || fail 'generated benchmark directory is a symlink'
    [ "$(cd -P -- "$(dirname "${STORAGE_BURNIN_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || { fail 'generated benchmark directory escaped the validated target root'; return; }
    STORAGE_BURNIN_SENTINEL="${STORAGE_BURNIN_WORK_DIR}/.chapar-storage-burnin-sentinel"
    STORAGE_BURNIN_SENTINEL_TOKEN="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "${STORAGE_BURNIN_SENTINEL_TOKEN}" > "${STORAGE_BURNIN_SENTINEL}"
    [ -O "${STORAGE_BURNIN_SENTINEL}" ] || fail 'benchmark sentinel is not owned by the validation user'
}

# Deletes only what this run created. Every condition here is load-bearing; the
# suite would rather leak a directory than remove one it cannot prove it owns.
cleanup_work_directory() {
    [ -n "${STORAGE_BURNIN_WORK_DIR:-}" ] || return 0
    [ -n "${TARGET_ROOT:-}" ] || return 1
    [ -d "${STORAGE_BURNIN_WORK_DIR}" ] && [ ! -L "${STORAGE_BURNIN_WORK_DIR}" ] || return 1
    [[ "$(basename "${STORAGE_BURNIN_WORK_DIR}")" = chapar-storage-burnin.* ]] || return 1
    [ "$(cd -P -- "$(dirname "${STORAGE_BURNIN_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || return 1
    [ -f "${STORAGE_BURNIN_SENTINEL:-}" ] && [ ! -L "${STORAGE_BURNIN_SENTINEL}" ] && [ -O "${STORAGE_BURNIN_SENTINEL}" ] || return 1
    [ "$(<"${STORAGE_BURNIN_SENTINEL}")" = "${STORAGE_BURNIN_SENTINEL_TOKEN:-}" ] || return 1
    rm -rf -- "${STORAGE_BURNIN_WORK_DIR}"
    STORAGE_BURNIN_WORK_DIR=""
}

finalize_with_cleanup() {
    local status="$1"
    trap - EXIT
    if ! cleanup_work_directory; then
        status=1
        validation_set_verdict FAIL 'guarded cleanup refused the generated benchmark directory'
    fi
    validation_result_finalize "${status}"
}

stage_h5bench_config() {
    local template="${STORAGE_BURNIN_H5BENCH_CONFIG_TEMPLATE:-}"
    [ -n "${template}" ] || fail 'STORAGE_BURNIN_H5BENCH_CONFIG_TEMPLATE is required for bounded h5bench'
    [ -f "${template}" ] && [ ! -L "${template}" ] || fail 'h5bench config template must be a regular non-symlink file'
    STORAGE_BURNIN_H5BENCH_CONFIG="${STORAGE_BURNIN_WORK_DIR}/h5bench.conf"
    python3 - "${template}" "${STORAGE_BURNIN_H5BENCH_CONFIG}" "${STORAGE_BURNIN_WORK_DIR}" "${STORAGE_BURNIN_H5BENCH_BYTES}" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1])
destination = Path(sys.argv[2])
work_dir = sys.argv[3]
max_bytes = sys.argv[4]
text = template.read_text(encoding="utf-8")
if "@WORK_DIR@" not in text or "@MAX_BYTES@" not in text:
    raise SystemExit("h5bench template must contain @WORK_DIR@ and @MAX_BYTES@ placeholders")
if ".." in text:
    raise SystemExit("h5bench template may not contain parent-directory traversal")
destination.write_text(text.replace("@WORK_DIR@", work_dir).replace("@MAX_BYTES@", max_bytes), encoding="utf-8")
PY
    [ ! -L "${STORAGE_BURNIN_H5BENCH_CONFIG}" ] || fail 'staged h5bench config became a symlink'
}

run_benchmarks() {
    local name
    for name in mpirun ior mdtest h5bench fio; do
        command -v "${name}" >/dev/null || validation_resource_unavailable "required command is unavailable: ${name}" mandatory
    done
    mpirun -np "${STORAGE_BURNIN_IOR_RANKS}" ior -a POSIX -w -r -C -e -g -t "${STORAGE_BURNIN_IOR_TRANSFER_BYTES}" \
        -b "${STORAGE_BURNIN_IOR_BLOCK_BYTES}" -o "${STORAGE_BURNIN_WORK_DIR}/ior-posix" \
        > "${results_dir}/ior-posix.log" 2>&1
    mpirun -np "${STORAGE_BURNIN_IOR_RANKS}" ior -a MPIIO -w -r -C -e -g -t "${STORAGE_BURNIN_IOR_TRANSFER_BYTES}" \
        -b "${STORAGE_BURNIN_IOR_BLOCK_BYTES}" -o "${STORAGE_BURNIN_WORK_DIR}/ior-mpiio" \
        > "${results_dir}/ior-mpiio.log" 2>&1
    mdtest -d "${STORAGE_BURNIN_WORK_DIR}/mdtest" -n "${STORAGE_BURNIN_MDTEST_FILES}" -i 1 \
        > "${results_dir}/mdtest.log" 2>&1
    stage_h5bench_config
    h5bench --debug "${STORAGE_BURNIN_H5BENCH_CONFIG}" > "${results_dir}/h5bench.log" 2>&1 || true
    fio --name=bounded-write --directory="${STORAGE_BURNIN_WORK_DIR}" --rw=write --bs=1m --iodepth=4 \
        --direct=1 --size="${STORAGE_BURNIN_FIO_BYTES}" --verify=crc32c --do_verify=1 \
        --output-format=json > "${results_dir}/fio.json" 2>"${results_dir}/fio.err"
}

validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_STORAGE)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init storage-burnin "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

if [ -z "${fixture}" ]; then
    if ! runner_contract_present; then
        validation_resource_unavailable 'the runner storage contract is not configured on this node' optional
    fi
    validate_target
    load_limits
    create_work_directory
    trap 'finalize_with_cleanup "$?"' EXIT
    run_benchmarks
    STORAGE_BURNIN_OBSERVED="${results_dir}/storage_observed.json"
    python3 - "${STORAGE_BURNIN_OBSERVED}" "${results_dir}" "${TARGET_FREE_BYTES}" "${PLANNED_BYTES}" "${STORAGE_BURNIN_BASELINE_VERDICT}" <<'PY'
import json
import pathlib
import re
import sys

destination, results_dir, free_bytes, planned_bytes, baseline = sys.argv[1:]
directory = pathlib.Path(results_dir)


def read(name):
    path = directory / name
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def rate(text, pattern):
    values = [float(value) for value in re.findall(pattern, text)]
    return max(values) if values else 0.0


fio_document = {}
if (directory / "fio.json").is_file():
    try:
        fio_document = json.loads((directory / "fio.json").read_text(encoding="utf-8"))
    except ValueError:
        fio_document = {}
fio_bandwidth = 0.0
for job in fio_document.get("jobs", []):
    fio_bandwidth = max(fio_bandwidth, float(job.get("write", {}).get("bw", 0)) / 1024.0)

observed = {
    "target_free_bytes": int(free_bytes),
    "planned_bytes": int(planned_bytes),
    "baseline_verdict": baseline,
    "ior_posix_mibps": rate(read("ior-posix.log"), r"write\s+([0-9.]+)"),
    "ior_mpiio_mibps": rate(read("ior-mpiio.log"), r"write\s+([0-9.]+)"),
    "mdtest_ops_per_second": rate(read("mdtest.log"), r"File creation\s+:\s+([0-9.]+)"),
    "fio_mibps": fio_bandwidth,
    "benchmarks_completed": all(
        (directory / name).is_file() for name in ("ior-posix.log", "ior-mpiio.log", "mdtest.log", "fio.json")
    ),
}
pathlib.Path(destination).write_text(json.dumps(observed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
else
    STORAGE_BURNIN_OBSERVED="${results_dir}/storage_observed.json"
    python3 - "${fixture}/manifest.json" "${STORAGE_BURNIN_OBSERVED}" <<'PY'
import json
import pathlib
import sys

document = json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(document["storage_observed"], indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
fi

export STORAGE_BURNIN_OBSERVED
export STORAGE_BURNIN_FIXTURE="${fixture}"
export STORAGE_BURNIN_RESULT="${results_dir}/storage-burnin.json"
export STORAGE_BURNIN_PROM="${results_dir}/storage-burnin.prom"
export STORAGE_BURNIN_NODE="${node}"

python3 <<'PY'
import json
import os
import pathlib

observed = json.load(open(os.environ["STORAGE_BURNIN_OBSERVED"]))
fixture = os.environ["STORAGE_BURNIN_FIXTURE"]
failures = []
warnings = []

if not observed.get("benchmarks_completed", False):
    failures.append("bounded benchmark set did not complete")
for name in ("ior_posix_mibps", "ior_mpiio_mibps", "fio_mibps"):
    if observed.get(name, 0) <= 0:
        failures.append(f"{name} reported no throughput")
if observed.get("mdtest_ops_per_second", 0) <= 0:
    failures.append("mdtest reported no metadata operations")

baseline = observed.get("baseline_verdict", "NOT_EVALUATED")
if baseline == "FAIL":
    failures.append("storage baseline comparison failed")
elif baseline == "WARN":
    warnings.append("storage baseline comparison warned")
elif baseline == "NOT_EVALUATED":
    # No baseline is a known gap, not a silent pass.
    warnings.append("no storage baseline was evaluated for this run")

verdict = "FAIL" if failures else "WARN" if warnings else "PASS"
if fixture:
    declared = json.load(open(f"{fixture}/manifest.json")).get("verdicts", {}).get("storage-burnin", "")
    if declared and declared != verdict:
        failures.append(f"fixture declared {declared} but validation produced {verdict}")
        verdict = "FAIL"

payload = {
    "fixture": bool(fixture), "node": os.environ["STORAGE_BURNIN_NODE"],
    "observed": observed, "verdict": verdict, "failures": failures, "warnings": warnings,
}
pathlib.Path(os.environ["STORAGE_BURNIN_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
codes = {"PASS": 0, "WARN": 1, "FAIL": 2, "NOT_EVALUATED": -1}
lines = [
    "# HELP chapar_storage_burnin_target_free_bytes Free bytes on the benchmark target",
    "# TYPE chapar_storage_burnin_target_free_bytes gauge",
    f'chapar_storage_burnin_target_free_bytes{{node="{payload["node"]}"}} {observed.get("target_free_bytes", 0)}',
    "# HELP chapar_storage_burnin_ior_posix_mibps IOR POSIX write throughput",
    "# TYPE chapar_storage_burnin_ior_posix_mibps gauge",
    f'chapar_storage_burnin_ior_posix_mibps{{node="{payload["node"]}"}} {observed.get("ior_posix_mibps", 0)}',
    "# HELP chapar_storage_burnin_fio_mibps fio verified write throughput",
    "# TYPE chapar_storage_burnin_fio_mibps gauge",
    f'chapar_storage_burnin_fio_mibps{{node="{payload["node"]}"}} {observed.get("fio_mibps", 0)}',
    "# HELP chapar_storage_burnin_baseline_verdict Baseline comparison (PASS=0 WARN=1 FAIL=2 NOT_EVALUATED=-1)",
    "# TYPE chapar_storage_burnin_baseline_verdict gauge",
    f'chapar_storage_burnin_baseline_verdict{{node="{payload["node"]}"}} {codes.get(baseline, -1)}',
]
pathlib.Path(os.environ["STORAGE_BURNIN_PROM"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/storage-burnin.json")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${results_dir}/storage-burnin.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
esac

printf 'Storage burn-in evidence written to %s\n' "${results_dir}" >&2
