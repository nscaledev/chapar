#!/usr/bin/env bash
set -euo pipefail

# Drives vast and storage-burnin against recorded observations, and unit-tests the
# sentinel-guarded cleanup directly. No shared filesystem, no allocation, no
# benchmark binaries.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/chapar-storage-fixtures.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 700 "${work}"
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

staged_root="${work}/fixtures"
mkdir -p "${staged_root}"
chmod 700 "${staged_root}"
cp -R "${validation_dir}/fixtures/storage" "${staged_root}/storage"

results_root="${work}/results"
mkdir -p "${results_root}"

stub_dir="${work}/bin"
mkdir -p "${stub_dir}"
marker="${work}/forbidden-command"
for command_name in srun sbatch module spack findmnt nfsstat mpirun ior mdtest h5bench fio elbencho; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
        "${command_name}" "${marker}" > "${stub_dir}/${command_name}"
    chmod 0755 "${stub_dir}/${command_name}"
done

run_case() {
    local suite="$1" artifact="$2" name="$3" expected_exit="$4" expected_verdict="$5"
    local status=0 report verdict manifest
    env PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
        VALIDATION_TEST_STORAGE="storage/${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
        bash "${script_dir}/${suite}.sbatch" >"${work}/${suite}-${name}.out" 2>"${work}/${suite}-${name}.err" || status=$?
    if [ "${status}" -ne "${expected_exit}" ]; then
        printf 'FAIL: %s %s exited %s, expected %s\n' "${suite}" "${name}" "${status}" "${expected_exit}" >&2
        sed -n '1,20p' "${work}/${suite}-${name}.err" >&2
        exit 1
    fi
    report="$(find "${results_root}/${suite}" -name "${artifact}" -print | head -n 1)"
    verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${report}")"
    if [ "${verdict}" != "${expected_verdict}" ]; then
        printf 'FAIL: %s %s verdict was %s, expected %s\n' "${suite}" "${name}" "${verdict}" "${expected_verdict}" >&2
        exit 1
    fi
    manifest="$(find "${results_root}/${suite}" -name suite-manifest.json -print | head -n 1)"
    python3 - "${validation_dir}/lib/result-manifest.schema.json" "${manifest}" "${suite}" <<'PY'
import json
import sys

import jsonschema

jsonschema.Draft202012Validator(
    json.load(open(sys.argv[1])),
    format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
).validate(json.load(open(sys.argv[2])))
assert json.load(open(sys.argv[2]))["suite"] == sys.argv[3]
PY
    rm -rf "${results_root}/${suite}"
    printf 'PASS: %s %s (%s)\n' "${suite}" "${name}" "${expected_verdict}"
}

run_case vast vast_mount.json vast 0 PASS
run_case vast vast_mount.json nfs 0 PASS
run_case vast vast_mount.json mismatch 1 FAIL
run_case vast vast_mount.json non-vast 1 FAIL
run_case vast vast_mount.json missing-mount-option 1 FAIL
# Identity can be right while the namespace is incoherent; both must hold.
run_case vast vast_mount.json namespace-failure 1 FAIL
run_case vast vast_mount.json checksum-corruption 1 FAIL

run_case storage-burnin storage-burnin.json vast 0 PASS
run_case storage-burnin storage-burnin.json burnin-no-throughput 1 FAIL
run_case storage-burnin storage-burnin.json burnin-incomplete 1 FAIL
# No baseline is a known gap, reported rather than passed over.
run_case storage-burnin storage-burnin.json burnin-no-baseline 0 WARN
run_case storage-burnin storage-burnin.json burnin-baseline-regression 1 FAIL

# With no runner storage contract at all, both suites SKIP rather than failing.
for suite in vast storage-burnin; do
    status=0
    env PATH="${stub_dir}:${PATH}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
        bash "${script_dir}/${suite}.sbatch" >"${work}/${suite}-unconfigured.out" 2>"${work}/${suite}-unconfigured.err" || status=$?
    if [ "${status}" -ne 77 ]; then
        printf 'FAIL: %s without a runner contract exited %s, expected 77\n' "${suite}" "${status}" >&2
        sed -n '1,20p' "${work}/${suite}-unconfigured.err" >&2
        exit 1
    fi
    rm -rf "${results_root:?}/${suite}"
    printf 'PASS: %s SKIPs without a runner storage contract\n' "${suite}"
done

# A half-configured runner is an error, not an absence.
status=0
env PATH="${stub_dir}:${PATH}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
    STORAGE_BURNIN_TARGET=job-scratch \
    bash "${script_dir}/storage-burnin.sbatch" >"${work}/partial.out" 2>"${work}/partial.err" || status=$?
if [ "${status}" -eq 0 ] || [ "${status}" -eq 77 ]; then
    printf 'FAIL: a half-configured runner contract exited %s, expected a failure\n' "${status}" >&2
    exit 1
fi
rm -rf "${results_root:?}/storage-burnin"
printf 'PASS: a half-configured runner storage contract fails rather than skipping\n'

# The sentinel-guarded cleanup must refuse a directory it did not create.
target_root="${work}/scratch"
mkdir -p "${target_root}"
foreign="${target_root}/not-ours"
mkdir -p "${foreign}"
printf 'keep\n' > "${foreign}/keep"
python3 - "${script_dir}/storage-burnin.sbatch" "${work}/cleanup-probe.sh" <<'PY'
import pathlib
import sys

# Extract the guard under test rather than re-implementing it, so the probe cannot
# drift away from the code it is asserting.
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("cleanup_work_directory() {")
end = source.index("\n}\n", start) + 3
pathlib.Path(sys.argv[2]).write_text("#!/usr/bin/env bash\nset -uo pipefail\n" + source[start:end], encoding="utf-8")
PY
cat >> "${work}/cleanup-probe.sh" <<'PROBE'
TARGET_ROOT="$1"
STORAGE_BURNIN_WORK_DIR="$2"
STORAGE_BURNIN_SENTINEL="${STORAGE_BURNIN_WORK_DIR}/.chapar-storage-burnin-sentinel"
STORAGE_BURNIN_SENTINEL_TOKEN="expected-token"
cleanup_work_directory
PROBE
if bash "${work}/cleanup-probe.sh" "${target_root}" "${foreign}" 2>/dev/null; then
    printf 'FAIL: guarded cleanup removed a directory it did not create\n' >&2
    exit 1
fi
[ -f "${foreign}/keep" ] || { printf 'FAIL: guarded cleanup deleted foreign content\n' >&2; exit 1; }
printf 'PASS: guarded cleanup refuses a directory it did not create\n'

# And it must accept one it did, with a matching sentinel token.
owned="$(mktemp -d "${target_root}/chapar-storage-burnin.XXXXXX")"
printf 'expected-token\n' > "${owned}/.chapar-storage-burnin-sentinel"
if ! bash "${work}/cleanup-probe.sh" "${target_root}" "${owned}"; then
    printf 'FAIL: guarded cleanup refused a directory it created\n' >&2
    exit 1
fi
[ ! -e "${owned}" ] || { printf 'FAIL: guarded cleanup left its own directory behind\n' >&2; exit 1; }
printf 'PASS: guarded cleanup removes its own sentinel-owned directory\n'

if [ -e "${marker}" ]; then
    printf 'FAIL: fixture mode invoked a storage tool or scheduler:\n' >&2
    sort -u "${marker}" >&2
    exit 1
fi

printf 'storage fixtures: mount identity, cross-rank coherence and guarded cleanup verified without a filesystem\n'
