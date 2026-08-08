#!/usr/bin/env bash
# DESCRIPTION: Allocation-only Slurm CPU placement and binding evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=slurm-placement

# Records the CPU binding Slurm actually gave this allocation. It deliberately
# claims nothing about whether Slurm honoured a requested CPU architecture: that
# would need a scheduler-side assertion this suite has no standing to make.
#
# With no allocation there is nothing to observe, so the suite SKIPs rather than
# reporting a placement it did not measure.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_CPU)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init slurm-placement "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export SLURM_PLACEMENT_FIXTURE="${fixture}"
export SLURM_PLACEMENT_RESULT="${results_dir}/slurm_placement.json"

if [ -n "${fixture}" ]; then
    binding_output=""
elif [ -z "${SLURM_JOB_ID:-}" ]; then
    binding_output=""
else
    command -v srun >/dev/null 2>&1 || validation_resource_unavailable 'srun is unavailable inside the Slurm allocation' mandatory
    cpus_per_task="${SLURM_CPUS_PER_TASK:-1}"
    [[ "${cpus_per_task}" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid SLURM_CPUS_PER_TASK: %s\n' "${cpus_per_task}" >&2; exit 2; }
    binding_output="$(srun --nodes=1 --ntasks=1 --cpus-per-task="${cpus_per_task}" --cpu-bind=verbose bash -c 'grep ^Cpus_allowed_list: /proc/self/status' 2>&1)"
fi
export SLURM_PLACEMENT_BINDING_OUTPUT="${binding_output}"

python3 <<'PY'
import json
import os
import pathlib
import re

fixture = os.environ["SLURM_PLACEMENT_FIXTURE"]
if fixture:
    fixture_data = json.loads((pathlib.Path(fixture) / "manifest.json").read_text(encoding="utf-8"))
    observed = fixture_data["slurm_placement"]
    declared = fixture_data.get("verdicts", {}).get("slurm-placement", "")
else:
    binding_output = os.environ["SLURM_PLACEMENT_BINDING_OUTPUT"]
    match = re.search(r"Cpus_allowed_list:\s*([^\s]+)", binding_output)
    observed = {
        "allocation": bool(os.environ.get("SLURM_JOB_ID")),
        "job_id": os.environ.get("SLURM_JOB_ID", ""),
        "node_list": os.environ.get("SLURM_NODELIST", ""),
        "cpus_on_node": os.environ.get("SLURM_CPUS_ON_NODE", os.environ.get("SLURM_JOB_CPUS_PER_NODE", "")),
        "cpus_per_task": os.environ.get("SLURM_CPUS_PER_TASK", "1"),
        "binding_cpus": match.group(1) if match else "",
        "binding_output": binding_output,
    }
    declared = ""

failures = []
if observed.get("allocation"):
    # Each of these is evidence the allocation was real; a missing one means the
    # binding cannot be attributed to a placement decision.
    for field, message in (
        ("job_id", "allocation evidence has no Slurm job ID"),
        ("node_list", "allocation evidence has no Slurm node list"),
        ("cpus_on_node", "allocation evidence has no allocated CPU count"),
        ("cpus_per_task", "allocation evidence has no CPUs-per-task value"),
        ("binding_cpus", "Slurm step did not expose a CPU binding mask"),
    ):
        if not str(observed.get(field, "")):
            failures.append(message)
    verdict = "FAIL" if failures else "PASS"
else:
    verdict = "SKIP"
if declared and verdict != declared:
    failures.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "observed": observed, "verdict": verdict,
    "failures": failures,
    "architecture_allocation_proof": False,
    "scope": "This suite verifies placement only for the current allocation. It does not prove that Slurm allocated a requested CPU architecture.",
}
pathlib.Path(os.environ["SLURM_PLACEMENT_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/slurm_placement.json")"
reason="$(python3 -c "import json,sys; print('; '.join(json.load(open(sys.argv[1]))['failures']))" "${results_dir}/slurm_placement.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    SKIP) validation_resource_unavailable 'Slurm placement requires an existing Slurm allocation; no allocation claim is made' optional ;;
esac

printf 'Slurm placement evidence written to %s\n' "${results_dir}" >&2
