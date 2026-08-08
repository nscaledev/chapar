#!/usr/bin/env bash
set -euo pipefail

# Drives cpu-platform, slurm-placement and node-admission against recorded
# observations. No Slurm allocation, no GPU, no privileged access.
#
# Each case asserts the exit code and the verdict together: a suite that fails for
# the wrong reason still exits non-zero, and would otherwise look correct.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/chapar-cpu-fixtures.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 700 "${work}"
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

staged_root="${work}/fixtures"
mkdir -p "${staged_root}"
chmod 700 "${staged_root}"
cp -R "${validation_dir}/fixtures/cpu" "${staged_root}/cpu"

results_root="${work}/results"
mkdir -p "${results_root}"

stub_dir="${work}/bin"
mkdir -p "${stub_dir}"
marker="${work}/forbidden-command"
for command_name in srun sbatch module spack nvidia-smi readelf lscpu; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
        "${command_name}" "${marker}" > "${stub_dir}/${command_name}"
    chmod 0755 "${stub_dir}/${command_name}"
done

assert_verdict() {
    local suite="$1" artifact="$2" expected_verdict="$3"
    local report verdict manifest
    report="$(find "${results_root}/${suite}" -name "${artifact}" -print | head -n 1)"
    if [ -z "${report}" ]; then
        printf 'FAIL: %s produced no %s\n' "${suite}" "${artifact}" >&2
        exit 1
    fi
    verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${report}")"
    if [ "${verdict}" != "${expected_verdict}" ]; then
        printf 'FAIL: %s verdict was %s, expected %s\n' "${suite}" "${verdict}" "${expected_verdict}" >&2
        exit 1
    fi
    manifest="$(find "${results_root}/${suite}" -name suite-manifest.json -print | head -n 1)"
    python3 - "${validation_dir}/lib/result-manifest.schema.json" "${manifest}" "${suite}" <<'PY'
import json
import sys

import jsonschema

schema = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
jsonschema.Draft202012Validator(
    schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER
).validate(manifest)
assert manifest["suite"] == sys.argv[3], manifest
PY
    rm -rf "${results_root}/${suite}"
}

run_shared_case() {
    local name="$1" cpu_exit="$2" cpu_verdict="$3" placement_exit="$4" placement_verdict="$5"
    local status=0
    PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
    VALIDATION_TEST_CPU="cpu/${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
        bash "${script_dir}/cpu-platform.sbatch" >"${work}/${name}-cpu.out" 2>"${work}/${name}-cpu.err" || status=$?
    if [ "${status}" -ne "${cpu_exit}" ]; then
        printf 'FAIL: cpu-platform %s exited %s, expected %s\n' "${name}" "${status}" "${cpu_exit}" >&2
        sed -n '1,20p' "${work}/${name}-cpu.err" >&2
        exit 1
    fi
    assert_verdict cpu-platform cpu_platform.json "${cpu_verdict}"

    status=0
    PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
    VALIDATION_TEST_CPU="cpu/${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
        bash "${script_dir}/slurm-placement.sbatch" >"${work}/${name}-placement.out" 2>"${work}/${name}-placement.err" || status=$?
    if [ "${status}" -ne "${placement_exit}" ]; then
        printf 'FAIL: slurm-placement %s exited %s, expected %s\n' "${name}" "${status}" "${placement_exit}" >&2
        sed -n '1,20p' "${work}/${name}-placement.err" >&2
        exit 1
    fi
    assert_verdict slurm-placement slurm_placement.json "${placement_verdict}"
    printf 'PASS: %s (cpu-platform %s, slurm-placement %s)\n' "${name}" "${cpu_verdict}" "${placement_verdict}"
}

run_shared_case intel-x86 0 PASS 0 PASS
run_shared_case amd-x86 0 PASS 0 PASS
run_shared_case nvidia-grace 0 PASS 0 PASS
run_shared_case generic-aarch64 0 PASS 0 PASS
run_shared_case elf-mismatch 1 FAIL 0 PASS
run_shared_case zen-release-on-intel 1 FAIL 0 PASS
run_shared_case missing-feature 1 FAIL 0 PASS
# No allocation is a SKIP, never a pass.
run_shared_case unallocated 0 PASS 77 SKIP
run_shared_case no-binding-mask 0 PASS 1 FAIL

run_admission_case() {
    local name="$1" expected_exit="$2" expected_verdict="$3"
    local status=0
    PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
    VALIDATION_TEST_NODE_ADMISSION="${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
        bash "${script_dir}/node-admission.sbatch" >"${work}/${name}-admission.out" 2>"${work}/${name}-admission.err" || status=$?
    if [ "${status}" -ne "${expected_exit}" ]; then
        printf 'FAIL: node-admission %s exited %s, expected %s\n' "${name}" "${status}" "${expected_exit}" >&2
        sed -n '1,20p' "${work}/${name}-admission.err" >&2
        exit 1
    fi
    assert_verdict node-admission node_admission.json "${expected_verdict}"
    printf 'PASS: node-admission %s (%s)\n' "${name}" "${expected_verdict}"
}

run_admission_case healthy 0 PASS
run_admission_case ecc-fault 1 FAIL
run_admission_case inventory-mismatch 1 FAIL
# "We could not look" is a WARN, distinct from "we looked and it was fine".
run_admission_case missing-optional-diagnostic 0 WARN

if [ -e "${marker}" ]; then
    printf 'FAIL: fixture mode invoked a scheduler or a hardware tool:\n' >&2
    sort -u "${marker}" >&2
    exit 1
fi

printf 'cpu, placement and admission fixtures: evaluators verified without an allocation or a GPU\n'
