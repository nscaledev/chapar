#!/usr/bin/env bash
# DESCRIPTION: Pyxis container smoke - injected release loads and keeps the base image intact
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --job-name=container-smoke

# Runs the selected release from inside its sealed .sqsh under Pyxis. This is the
# only validation suite that exercises a container, and it is the source of the
# pyxis-smoke.txt artifact that ci/vlad_source_approval/image_receipts.py digests
# into the runtime receipt.
#
# Custody: the image path must lie inside the site's container output root
# (CHAPAR_CONTAINER_OUTPUT_ROOT) and match a digest supplied alongside it. An
# arbitrary ambient path is refused, the same way every other consumer refuses
# ambient authority.
#
# Fixture mode evaluates a recorded in-container observation instead, so the
# evaluator below is exercised in CI with no image, no enroot and no GPU. The
# evaluation is the same code either way -- only where `observed` comes from
# differs.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${validation_dir}/.." && pwd)"
# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

if [ -n "${ENV_NAME:-}" ] || [ -n "${MODULE_PATH:-}" ]; then
    echo "ERROR: ENV_NAME and MODULE_PATH are obsolete selection overrides" >&2
    exit 2
fi
validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_CONTAINER_SMOKE)"

# Builders have no uv; the chapar package runs stdlib-only from the checkout.
chapar_validate() {
    PYTHONPATH="${repository_root}/src${PYTHONPATH:+:${PYTHONPATH}}" python3 -m chapar validate "$@"
}

if [ -z "${fixture}" ]; then
    # Live runs go through the release gateway: a verified immutable release
    # directory and the identity its metadata records.
    release_dir="${CHAPAR_RELEASE_DIR:?CHAPAR_RELEASE_DIR is required}"
    # An exported RESULTS_ROOT (validation/run always sets one) is forwarded so
    # a manual invocation needs no site settings beyond the release directory.
    plan_args=(--release-dir "${release_dir}" --test container-smoke)
    if [ -n "${RESULTS_ROOT:-}" ]; then plan_args+=(--results-root "${RESULTS_ROOT}"); fi
    identity="$(chapar_validate plan --format shell "${plan_args[@]}")"
    IFS=$'\t' read -r software_set target release_id _release_run_id _module_path result_namespace <<< "${identity}"
    results_root="${RESULTS_ROOT:-${result_namespace}}"
else
    # Fixture runs evaluate a recorded observation, so they deliberately do not
    # consult a release: there is no release, no image and no tuple to verify,
    # and requiring one would make the evaluator untestable without a build.
    software_set=fixture
    target=fixture
    release_id=fixture
    results_root="${RESULTS_ROOT:?RESULTS_ROOT is required in fixture mode}"
fi
node="${SLURM_NODELIST:-$(hostname -s)}"

validation_result_init container-smoke "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"
observed_path="${results_dir}/container_observed.json"
smoke_path="${results_dir}/pyxis-smoke.txt"
report_path="${results_dir}/container_smoke.json"

container_outputs=""
module_destination=""
store=""
if [ -z "${fixture}" ]; then
    # The in-image module destination is a container-registry fact keyed by the
    # site's CHAPAR_CONTAINER_BASE, the outputs root is the site's
    # CHAPAR_CONTAINER_OUTPUT_ROOT, and the install tree is the release's own
    # recorded root. Nothing is re-derived from the job environment beyond
    # those declared facts.
    if [ -z "${CHAPAR_CONTAINER_BASE:-}" ] || [ -z "${CHAPAR_CONTAINER_OUTPUT_ROOT:-}" ]; then
        validation_resource_unavailable 'no container delivery is configured for this target' optional
    fi
    container_outputs="${CHAPAR_CONTAINER_OUTPUT_ROOT}"
    read -r module_destination store <<< "$(python3 - "${CHAPAR_CONTAINER_BASE}" "${repository_root}/containers/images/containers.json" "${release_dir}/metadata.json" <<'PY'
import json
import sys

base, registry_path, metadata_path = sys.argv[1:]
registry = json.load(open(registry_path))["containers"]
if base not in registry:
    raise SystemExit(f"CHAPAR_CONTAINER_BASE is not a registered container: {base}")
metadata = json.load(open(metadata_path))
print(registry[base]["module_destination"], metadata["roots"]["install_tree"])
PY
)"
    if [ -z "${CHAPAR_CONTAINER_IMAGE:-}" ] || [ -z "${CHAPAR_CONTAINER_IMAGE_SHA256:-}" ]; then
        validation_resource_unavailable 'no sealed container image was supplied' optional
    fi
    image="${CHAPAR_CONTAINER_IMAGE}"
    image_sha256="${CHAPAR_CONTAINER_IMAGE_SHA256}"
    case "${image}" in
        "${container_outputs}"/*) ;;
        *)
            validation_set_verdict FAIL 'container image is outside the site container output root'
            exit 1
            ;;
    esac
    if [ -L "${image}" ] || [ ! -f "${image}" ]; then
        validation_set_verdict FAIL "container image must be a regular file, not a symlink: ${image}"
        exit 1
    fi
    image_digest="$(sha256sum "${image}" | awk '{print $1}')"
    if [ "${image_digest}" != "${image_sha256}" ]; then
        validation_set_verdict FAIL 'container image digest mismatch'
        exit 1
    fi
    command -v enroot >/dev/null 2>&1 || validation_resource_unavailable 'enroot runtime' optional
    srun --help 2>&1 | grep -q -- '--container-image' || validation_resource_unavailable 'Pyxis SPANK plugin' optional

    # Root module checks come from the release-local spack.lock, so this asserts
    # the same inventory the bare-metal integrity suite asserts, resolved in the
    # container.
    chapar_validate plan --format checks "${plan_args[@]}" > "${results_dir}/root-checks.tsv"

    # The checks file lives on the host, so it has to be mounted in: a container
    # cannot read a host path merely because the suite knows its name.
    cat > "${results_dir}/in-container.sh" <<'INNER'
set -u
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }

for tool in python3 mpirun nvcc cmake; do
    resolved="$(command -v "$tool" 2>/dev/null || true)"
    emit base_tool "$tool" "$resolved"
done

if command -v module >/dev/null 2>&1; then
    emit module_command present true
else
    emit module_command present false
fi

emit modulefiles count "$(find "$CHAPAR_MODULE_DESTINATION" -type f 2>/dev/null | wc -l | tr -d ' ')"

# shellcheck disable=SC1090
if command -v module >/dev/null 2>&1; then
    for arch_dir in "$CHAPAR_MODULE_DESTINATION"/*; do
        [ -d "$arch_dir" ] || continue
        module use "$arch_dir" 2>/dev/null || true
    done
fi

while IFS="$(printf '\t')" read -r module_name check_cmd _description; do
    [ -n "$module_name" ] || continue
    if command -v module >/dev/null 2>&1 && module load "$module_name" 2>/dev/null && eval "$check_cmd" >/dev/null 2>&1; then
        emit root_check "$module_name" pass
    else
        emit root_check "$module_name" fail
    fi
done < /chapar-validation/root-checks.tsv

if command -v ucx_info >/dev/null 2>&1; then
    transports="$(ucx_info -d 2>/dev/null || true)"
    for expected in _mlx5 cuda_ipc gdr_copy; do
        if printf '%s' "$transports" | grep -q -- "$expected"; then
            emit ucx "$expected" present
        else
            emit ucx "$expected" absent
        fi
    done
else
    emit ucx tool absent
fi

if command -v fi_info >/dev/null 2>&1; then
    providers="$(fi_info 2>/dev/null || true)"
    for expected in verbs shm; do
        if printf '%s' "$providers" | grep -q -- "$expected"; then
            emit libfabric "$expected" present
        else
            emit libfabric "$expected" absent
        fi
    done
else
    emit libfabric tool absent
fi
INNER

    srun_status=0
    srun --container-image="${image}" \
        --container-readonly \
        --no-container-mount-home \
        --container-mounts="${results_dir}:/chapar-validation:ro" \
        --export=ALL,PYTHONNOUSERSITE=1,CHAPAR_MODULE_DESTINATION="${module_destination}",CHAPAR_STORE="${store}" \
        bash /chapar-validation/in-container.sh > "${smoke_path}" 2>&1 || srun_status=$?
    if [ "${srun_status}" -ne 0 ]; then
        validation_set_verdict FAIL "in-container smoke run exited ${srun_status}"
    fi
    python3 - "${smoke_path}" "${module_destination}" "${store}" > "${observed_path}" <<'PY'
import json
import sys

records = []
with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
    for line in stream:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3:
            records.append(parts)
observed = {
    "base_tools": [
        {"tool": name, "resolved": value} for kind, name, value in records if kind == "base_tool"
    ],
    "module_command": any(
        value == "true" for kind, _name, value in records if kind == "module_command"
    ),
    "modulefiles": next(
        (int(value) for kind, _name, value in records if kind == "modulefiles" and value.isdigit()),
        0,
    ),
    "root_checks": [
        {"module": name, "result": value} for kind, name, value in records if kind == "root_check"
    ],
    "ucx": {name: value for kind, name, value in records if kind == "ucx"},
    "libfabric": {name: value for kind, name, value in records if kind == "libfabric"},
    "module_destination": sys.argv[2],
    "store": sys.argv[3],
}
print(json.dumps(observed, indent=2, sort_keys=True))
PY
else
    python3 - "${fixture}/manifest.json" > "${observed_path}" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1]))
print(json.dumps(document["container_observed"], indent=2, sort_keys=True))
PY
fi

# One evaluator for both paths.
python3 - "${observed_path}" "${report_path}" "${fixture}" "${release_id}" "${software_set}" "${target}" <<'PY'
import json
import sys

observed_path, report_path, fixture, release_id, software_set, target = sys.argv[1:]
observed = json.load(open(observed_path))
failures: list[str] = []
warnings: list[str] = []

module_destination = observed.get("module_destination", "")
store = observed.get("store", "")

# The base image must still win by default: a release that shadowed the image's own
# interpreters on the default PATH would pass every positive check while breaking
# the software the image exists to provide.
for entry in observed.get("base_tools", []):
    resolved = entry.get("resolved") or ""
    if not resolved:
        continue
    for injected in (module_destination, store):
        if injected and resolved.startswith(injected):
            failures.append(f"{entry['tool']} resolves to {resolved} before any module load")

if not observed.get("module_command"):
    failures.append("no module command inside the image")
if not observed.get("modulefiles"):
    failures.append("no modulefiles at the registry module destination")

root_checks = observed.get("root_checks", [])
if not root_checks:
    failures.append("no root module checks were evaluated")
for check in root_checks:
    if check.get("result") != "pass":
        failures.append(f"root module check failed: {check.get('module')}")

# The kernel-coupled halves of the transports come from the host; the userspace
# halves must come from the injected release, so this is where the split is proven.
ucx = observed.get("ucx", {})
if ucx.get("tool") == "absent":
    failures.append("ucx_info unavailable after module load")
else:
    for expected in ("_mlx5", "cuda_ipc", "gdr_copy"):
        if ucx.get(expected) != "present":
            failures.append(f"ucx transport absent: {expected}")
libfabric = observed.get("libfabric", {})
if libfabric.get("tool") == "absent":
    failures.append("fi_info unavailable after module load")
else:
    for expected in ("verbs", "shm"):
        if libfabric.get(expected) != "present":
            failures.append(f"libfabric provider absent: {expected}")

verdict = "FAIL" if failures else ("WARN" if warnings else "PASS")
if fixture:
    declared = json.load(open(f"{fixture}/manifest.json")).get("verdicts", {}).get("container-smoke", "")
    if declared and declared != verdict:
        failures.append(f"fixture declared {declared} but validation produced {verdict}")
        verdict = "FAIL"

report = {
    "suite": "container-smoke",
    "release_id": release_id,
    "software_set": software_set,
    "target": target,
    "fixture": fixture or None,
    "observed": observed,
    "failures": failures,
    "warnings": warnings,
    "verdict": verdict,
}
with open(report_path, "w", encoding="utf-8") as stream:
    json.dump(report, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(verdict)
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${report_path}")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${report_path}")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
    SKIP) validation_resource_unavailable 'container smoke reported SKIP' optional ;;
esac
