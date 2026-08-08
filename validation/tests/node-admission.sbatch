#!/usr/bin/env bash
# DESCRIPTION: Unprivileged node admission inventory and GPU/NIC health evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=node-admission

# Everything here is readable by an ordinary batch user: nvidia-smi queries, sysfs,
# and the CPU count. Xid decoding needs privileged access, so this suite records it
# as unavailable and leaves it to the site's node-health tooling rather than
# pretending to have checked it.
#
# An unavailable optional diagnostic is a WARN, not a pass: "we could not look" and
# "we looked and it was fine" are different results.
#
# Fixtures are selected by name rather than by directory: the cases are synthesized
# inventories with no observable hardware analogue to record.

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
fixture="$(validation_fixture_name VALIDATION_TEST_NODE_ADMISSION)"
case "${fixture}" in
    ""|healthy|ecc-fault|inventory-mismatch|missing-optional-diagnostic) ;;
    *) printf 'unknown node-admission fixture: %s\n' "${fixture}" >&2; exit 2 ;;
esac

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init node-admission "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export NODE_ADMISSION_FIXTURE="${fixture}"
export NODE_ADMISSION_CAPABILITY="${validation_dir}/config/capability.yaml"
export NODE_ADMISSION_NODE="${node}"
export NODE_ADMISSION_RESULT="${results_dir}/node_admission.json"
export NODE_ADMISSION_PROM="${results_dir}/node_admission.prom"

python3 <<'PY'
import json
import os
import pathlib
import subprocess

import yaml


def command(*args):
    try:
        completed = subprocess.run(args, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return completed.stdout if completed.returncode == 0 else None


def configured_expectations():
    document = yaml.safe_load(pathlib.Path(os.environ["NODE_ADMISSION_CAPABILITY"]).read_text(encoding="utf-8")) or {}
    node_expectations = document.get("node", {}) or {}
    mapping = {
        "cpus": node_expectations.get("expected_cpus"),
        "gpus": node_expectations.get("expected_gpus"),
        "ib_nics": node_expectations.get("expected_ib_nics"),
    }
    # An absent key is uncompared rather than compared against zero.
    return {key: int(value) for key, value in mapping.items() if value is not None}


def fixture_payload(name):
    payload = {
        "node": "fixture-node",
        "expected": {"cpus": 64, "gpus": 2, "ib_nics": 1},
        "inventory": {
            "cpu": {"logical_cpus": 64, "model": "fixture-cpu"},
            "gpus": [{"uuid": "GPU-0"}, {"uuid": "GPU-1"}],
            "nic": {"infiniband_count": 1, "interfaces": ["ib0", "eth0"]},
        },
        "diagnostics": {
            "ecc": {"available": True, "uncorrected_total": 0},
            "xid": {"available": True, "count": 0, "source": "fixture"},
            "pcie": {"available": True, "healthy": True},
            "nvlink_nvswitch": {"available": True, "fault": False},
        },
    }
    if name == "ecc-fault":
        payload["diagnostics"]["ecc"]["uncorrected_total"] = 1
    elif name == "inventory-mismatch":
        payload["inventory"]["gpus"] = [{"uuid": "GPU-0"}]
    elif name == "missing-optional-diagnostic":
        payload["diagnostics"]["nvlink_nvswitch"] = {
            "available": False,
            "reason": "fixture optional diagnostic unavailable",
        }
    return payload


fixture = os.environ["NODE_ADMISSION_FIXTURE"]
if fixture:
    payload = fixture_payload(fixture)
else:
    gpu_rows = command(
        "nvidia-smi",
        "--query-gpu=uuid,pci.bus_id,ecc.errors.uncorrected.aggregate.total,"
        "ecc.errors.uncorrected.volatile.total,pcie.link.gen.current,pcie.link.width.current",
        "--format=csv,noheader,nounits",
    )
    gpus = []
    ecc_total = 0
    pcie_healthy = True
    if gpu_rows is not None:
        for row in gpu_rows.splitlines():
            fields = [field.strip() for field in row.split(",")]
            if len(fields) != 6:
                continue
            aggregate, volatile, generation, width = fields[2:]
            values = [int(value) for value in (aggregate, volatile) if value.isdigit()]
            ecc_total += sum(values)
            pcie_healthy = pcie_healthy and generation.isdigit() and int(generation) > 0 and width.isdigit() and int(width) > 0
            gpus.append({"uuid": fields[0], "pci_bus_id": fields[1], "pcie_generation": generation, "pcie_width": width})
    nvlink = command("nvidia-smi", "nvlink", "--status")
    topology = command("nvidia-smi", "topo", "-m")
    interfaces = sorted(path.name for path in pathlib.Path("/sys/class/net").iterdir()) if pathlib.Path("/sys/class/net").is_dir() else []
    infiniband = pathlib.Path("/sys/class/infiniband")
    payload = {
        "node": os.environ["NODE_ADMISSION_NODE"],
        "expected": configured_expectations(),
        "inventory": {
            "cpu": {"logical_cpus": os.cpu_count() or 0, "lscpu_json": command("lscpu", "-J")},
            "gpus": gpus,
            "nic": {"infiniband_count": len(list(infiniband.iterdir())) if infiniband.is_dir() else 0, "interfaces": interfaces},
        },
        "diagnostics": {
            "ecc": {"available": gpu_rows is not None, "uncorrected_total": ecc_total},
            "xid": {"available": False, "source": "site-managed NHC/prolog"},
            "pcie": {"available": gpu_rows is not None, "healthy": pcie_healthy},
            "nvlink_nvswitch": {"available": nvlink is not None and topology is not None, "fault": "ERR!" in (nvlink or "") or "ERR!" in (topology or "")},
        },
    }

failures = []
warnings = []
inventory = payload["inventory"]
for key, actual in {
    "cpus": inventory["cpu"]["logical_cpus"],
    "gpus": len(inventory["gpus"]),
    "ib_nics": inventory["nic"]["infiniband_count"],
}.items():
    if key in payload["expected"] and actual != payload["expected"][key]:
        failures.append(f"{key} inventory: expected={payload['expected'][key]}, got={actual}")

diagnostics = payload["diagnostics"]
if diagnostics["ecc"]["available"] and diagnostics["ecc"]["uncorrected_total"] > 0:
    failures.append("uncorrected ECC errors detected")
# The live path reports xid as unavailable and carries no count, so this must not
# assume the key exists: if privileged Xid decoding is ever wired up, an absent
# count should read as zero rather than crash the suite.
if diagnostics["xid"]["available"] and diagnostics["xid"].get("count", 0) > 0:
    failures.append("Xid errors detected")
if diagnostics["pcie"]["available"] and not diagnostics["pcie"]["healthy"]:
    failures.append("PCIe link is not active")
if diagnostics["nvlink_nvswitch"]["available"] and diagnostics["nvlink_nvswitch"]["fault"]:
    failures.append("NVLink/NVSwitch fault reported")
for name, diagnostic in diagnostics.items():
    if not diagnostic["available"]:
        warnings.append(f"optional {name} diagnostic unavailable")

payload["failures"] = failures
payload["warnings"] = warnings
payload["verdict"] = "FAIL" if failures else "WARN" if warnings else "PASS"
with open(os.environ["NODE_ADMISSION_RESULT"], "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")

lines = [
    "# HELP chapar_node_admission_inventory_mismatch Inventory mismatch (1=true)",
    "# TYPE chapar_node_admission_inventory_mismatch gauge",
    f'chapar_node_admission_inventory_mismatch{{node="{payload["node"]}"}} {int(any("inventory" in failure for failure in failures))}',
    "# HELP chapar_node_admission_uncorrected_ecc Uncorrected GPU ECC errors",
    "# TYPE chapar_node_admission_uncorrected_ecc gauge",
    f'chapar_node_admission_uncorrected_ecc{{node="{payload["node"]}"}} {diagnostics["ecc"]["uncorrected_total"]}',
]
with open(os.environ["NODE_ADMISSION_PROM"], "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/node_admission.json")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${results_dir}/node_admission.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
esac

printf 'Node-admission results written to %s\n' "${results_dir}" >&2
