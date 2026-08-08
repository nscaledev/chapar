#!/usr/bin/env bash
set -euo pipefail

# Drives rdma-link-check and rocev2-pairwise against recorded observations. No
# HCA, no fabric, no perftest binaries, no two-node allocation.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/chapar-transport-fixtures.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 700 "${work}"
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

staged_root="${work}/fixtures"
mkdir -p "${staged_root}"
chmod 700 "${staged_root}"
cp -R "${validation_dir}/fixtures/rdma" "${staged_root}/rdma"
cp -R "${validation_dir}/fixtures/roce" "${staged_root}/roce"

results_root="${work}/results"
mkdir -p "${results_root}"

stub_dir="${work}/bin"
mkdir -p "${stub_dir}"
marker="${work}/forbidden-command"
for command_name in srun sbatch module spack ibv_devinfo ibstat rdma lspci ibdev2netdev \
    show_gids ethtool ip scontrol iblinkinfo ibnetdiscover ib_write_bw ib_read_bw ib_send_lat; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
        "${command_name}" "${marker}" > "${stub_dir}/${command_name}"
    chmod 0755 "${stub_dir}/${command_name}"
done

run_case() {
    local suite="$1" artifact="$2" area="$3" name="$4" expected_exit="$5" expected_verdict="$6"
    local variable status=0 report verdict manifest
    case "${area}" in
        rdma) variable=VALIDATION_TEST_RDMA ;;
        roce) variable=VALIDATION_TEST_ROCE ;;
        *) printf 'unknown fixture area: %s\n' "${area}" >&2; exit 2 ;;
    esac
    # env, not an assignment prefix: the variable name is chosen at run time and
    # bash resolves assignment prefixes before expansion.
    env PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
        "${variable}=${area}/${name}" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
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

# A healthy one-node link warns rather than passing: two-node verbs evidence is
# ib-pairwise's job, and this suite must not imply it measured throughput.
run_case rdma-link-check rdma_link_check.json rdma connectx8-match 0 WARN
run_case rdma-link-check rdma_link_check.json rdma connectx8-mismatch 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma firmware-mismatch 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma down-port 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma degraded-rate 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma counter-regression 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma missing-gid-evidence 1 FAIL
# Reaching beyond the allocation is the failure, whatever the query returned.
run_case rdma-link-check rdma_link_check.json rdma unauthorized-fabric-query 1 FAIL
run_case rdma-link-check rdma_link_check.json rdma ethernet-fabric 77 SKIP

run_case rocev2-pairwise rocev2_pairwise.json roce ethernet-valid 0 PASS
run_case rocev2-pairwise rocev2_pairwise.json roce bad-gid 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce bad-mtu 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce bad-vlan 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce infiniband-link-layer 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce no-carrier 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce counter-regression 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce low-bandwidth 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce no-benchmarks 1 FAIL
run_case rocev2-pairwise rocev2_pairwise.json roce infiniband-fabric 77 SKIP

# Endpoint telemetry never becomes a switch-QoS claim.
PATH="${stub_dir}:${PATH}" VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${staged_root}" \
VALIDATION_TEST_ROCE="roce/ethernet-valid" RESULTS_ROOT="${results_root}" SLURM_NODELIST=fixture-node \
    bash "${script_dir}/rocev2-pairwise.sbatch" >/dev/null 2>&1
report="$(find "${results_root}/rocev2-pairwise" -name rocev2_pairwise.json -print | head -n 1)"
python3 - "${report}" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1]))
assert document["switch_qos_claimed"] is False, document
assert document["fabric_proof_claimed"] is False, document
assert document["endpoint_telemetry_only"] is True, document
assert document["provider_transport"]["gid_pinned"] is True, document
PY
rm -rf "${results_root}/rocev2-pairwise"
printf 'PASS: RoCE evidence stays endpoint-only and GID-pinned\n'

if [ -e "${marker}" ]; then
    printf 'FAIL: fixture mode invoked a fabric tool or scheduler:\n' >&2
    sort -u "${marker}" >&2
    exit 1
fi

printf 'transport fixtures: RDMA and RoCEv2 evaluators verified without a fabric\n'
