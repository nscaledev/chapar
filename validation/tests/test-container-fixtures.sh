#!/usr/bin/env bash
set -euo pipefail

# Drives container-smoke against recorded observations. No image, no enroot, no
# Pyxis, no GPU: this proves the evaluator and the verdict mapping, never the
# platform.
#
# Each case asserts both the exit code and the verdict, because a suite that
# fails for the wrong reason still exits non-zero and would otherwise look correct.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
fixture_root="${validation_dir}/fixtures/container"

work="$(mktemp -d "${TMPDIR:-/tmp}/chapar-container-fixtures.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 700 "${work}"
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

# The fixture root has to satisfy the same owner-only, symlink-free rules a real
# run would, so it is staged into the private work directory rather than read from
# the source tree.
staged_root="${work}/fixtures"
mkdir -p "${staged_root}"
chmod 700 "${staged_root}"
cp -R "${fixture_root}/." "${staged_root}/"

results_root="${work}/results"
mkdir -p "${results_root}"

# A stub PATH proves the suite never reaches for a scheduler or a container
# runtime in fixture mode.
stub_dir="${work}/bin"
mkdir -p "${stub_dir}"
marker="${work}/forbidden-command"
for command_name in srun sbatch enroot module spack sha256sum; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
        "${command_name}" "${marker}" > "${stub_dir}/${command_name}"
    chmod 0755 "${stub_dir}/${command_name}"
done

run_case() {
    local name="$1" expected_exit="$2" expected_verdict="$3"
    local status=0 report verdict
    PATH="${stub_dir}:${PATH}" \
    VALIDATION_TEST_MODE=1 \
    VALIDATION_TEST_ROOT="${staged_root}" \
    VALIDATION_TEST_CONTAINER_SMOKE="${name}" \
    RESULTS_ROOT="${results_root}" \
    SLURM_NODELIST=fixture-node \
        bash "${script_dir}/container-smoke.sbatch" >"${work}/${name}.out" 2>"${work}/${name}.err" || status=$?
    if [ "${status}" -ne "${expected_exit}" ]; then
        printf 'FAIL: %s exited %s, expected %s\n' "${name}" "${status}" "${expected_exit}" >&2
        sed -n '1,20p' "${work}/${name}.err" >&2
        exit 1
    fi
    report="$(find "${results_root}/container-smoke" -name container_smoke.json -print | head -n 1)"
    if [ -z "${report}" ]; then
        printf 'FAIL: %s produced no container_smoke.json\n' "${name}" >&2
        exit 1
    fi
    verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${report}")"
    if [ "${verdict}" != "${expected_verdict}" ]; then
        printf 'FAIL: %s verdict was %s, expected %s\n' "${name}" "${verdict}" "${expected_verdict}" >&2
        exit 1
    fi
    # Every bound suite must also leave a schema-valid manifest behind.
    local manifest
    manifest="$(find "${results_root}/container-smoke" -name suite-manifest.json -print | head -n 1)"
    python3 - "${validation_dir}/lib/result-manifest.schema.json" "${manifest}" <<'PY'
import json
import sys

import jsonschema

schema = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
jsonschema.Draft202012Validator(
    schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER
).validate(manifest)
assert manifest["suite"] == "container-smoke", manifest
assert manifest["provenance"] == {"mode": "manual", "ci_authoritative": False}, manifest
PY
    rm -rf "${results_root}/container-smoke"
    printf 'PASS: %s (%s, exit %s)\n' "${name}" "${expected_verdict}" "${expected_exit}"
}

run_case accelerated 0 PASS
run_case shadowed-base-tool 1 FAIL
run_case no-module-command 1 FAIL
run_case no-modulefiles 1 FAIL
run_case root-check-failure 1 FAIL
run_case degraded-transport 1 FAIL
run_case missing-libfabric-shm 1 FAIL
run_case transport-tools-absent 1 FAIL
# The fixture claims PASS while the evaluator finds a failure; the disagreement
# itself must fail, or fixtures would decorate rather than assert.
run_case declared-verdict-mismatch 1 FAIL

if [ -e "${marker}" ]; then
    printf 'FAIL: fixture mode invoked a scheduler or container runtime:\n' >&2
    sort -u "${marker}" >&2
    exit 1
fi

printf 'container smoke fixtures: evaluator and verdict mapping verified without a container\n'
