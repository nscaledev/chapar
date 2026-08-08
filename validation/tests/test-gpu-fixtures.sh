#!/usr/bin/env bash
set -euo pipefail

# Drives gpu-topology and nvlink-p2p against recorded observations. No GPU, no
# NVLink, no Fabric Manager, no allocation.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/chapar-gpu-fixtures.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 700 "${work}"
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

staged_root="${work}/fixtures"
mkdir -p "${staged_root}"
chmod 700 "${staged_root}"
cp -R "${validation_dir}/fixtures/gpu" "${staged_root}/gpu"

results_root="${work}/results"
mkdir -p "${results_root}"

stub_dir="${work}/bin"
mkdir -p "${stub_dir}"
marker="${work}/forbidden-command"
for command_name in srun sbatch module spack nvidia-smi nvbandwidth systemctl; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
        "${command_name}" "${marker}" > "${stub_dir}/${command_name}"
    chmod 0755 "${stub_dir}/${command_name}"
done

run_case() {
    local suite="$1" artifact="$2" name="$3" expected_exit="$4" expected_verdict="$5"
    local status=0 report verdict manifest
    PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
    VALIDATION_TEST_GPU="gpu/${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
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

run_case gpu-topology gpu_topology.json nvswitch-nvls 0 PASS
run_case gpu-topology gpu_topology.json nvlink 0 PASS
run_case gpu-topology gpu_topology.json pcie 0 PASS
run_case gpu-topology gpu_topology.json nvlink-errors 1 FAIL
run_case gpu-topology gpu_topology.json partial-allocation 1 FAIL
run_case gpu-topology gpu_topology.json command-unavailable 1 FAIL
# A CPU-only cluster must SKIP, never report a fabric it does not have.
run_case gpu-topology gpu_topology.json no-accelerator 77 SKIP

run_case nvlink-p2p nvlink_p2p.json nvswitch-nvls 0 PASS
run_case nvlink-p2p nvlink_p2p.json nvlink 0 PASS
run_case nvlink-p2p nvlink_p2p.json pcie 1 FAIL
# Unknown Fabric Manager state warns; a known-inactive one on NVSwitch fails.
run_case nvlink-p2p nvlink_p2p.json fabric-manager-invisible 0 WARN
run_case nvlink-p2p nvlink_p2p.json fabric-manager-inactive 1 FAIL
run_case nvlink-p2p nvlink_p2p.json nvlink-errors 1 FAIL
run_case nvlink-p2p nvlink_p2p.json incomplete-p2p 1 FAIL
run_case nvlink-p2p nvlink_p2p.json command-unavailable 1 FAIL
run_case nvlink-p2p nvlink_p2p.json no-accelerator 77 SKIP

# The Prometheus gauge is named for NVLink errors, so it must carry the error
# counter delta and not total counter movement.
PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
VALIDATION_TEST_GPU="gpu/nvswitch-nvls" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
    bash "${script_dir}/nvlink-p2p.sbatch" >/dev/null 2>&1
prom="$(find "${results_root}/nvlink-p2p" -name nvlink_p2p.prom -print | head -n 1)"
report="$(find "${results_root}/nvlink-p2p" -name nvlink_p2p.json -print | head -n 1)"
python3 - "${prom}" "${report}" <<'PY'
import json
import re
import sys

emitted = re.search(r"chapar_nvlink_error_counter_delta\{[^}]*\}\s+(-?\d+)", open(sys.argv[1]).read())
assert emitted, "error counter gauge missing"
document = json.load(open(sys.argv[2]))
assert int(emitted.group(1)) == document["error_counter_delta"], (emitted.group(1), document)
PY
rm -rf "${results_root}/nvlink-p2p"
printf 'PASS: nvlink error gauge carries the error counter delta\n'

if [ -e "${marker}" ]; then
    printf 'FAIL: fixture mode invoked a GPU tool or scheduler:\n' >&2
    sort -u "${marker}" >&2
    exit 1
fi

printf 'gpu fixtures: topology and P2P evaluators verified without a GPU\n'
