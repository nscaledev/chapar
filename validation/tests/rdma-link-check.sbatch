#!/usr/bin/env bash
# DESCRIPTION: Expectation-selected RDMA HCA identity, link, counter, and bounded verbs evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=rdma-link-check

# Checks the HCAs this node actually presents against the tracked expectations:
# device identity, firmware, PCI address, per-port state, width, rate, link layer,
# GUID/LID/GID evidence, and error counters that must not move during the run.
#
# Fabric-wide discovery (iblinkinfo, ibnetdiscover, show_gids) reaches beyond this
# allocation, so it runs only when the expectations authorize it, and running it
# unauthorized is itself a failure. This suite claims nothing about fabric topology.

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
fixture="$(validation_fixture_dir VALIDATION_TEST_RDMA)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init rdma-link-check "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export RDMA_LINK_FIXTURE="${fixture}"
export RDMA_LINK_CAPABILITY="${validation_dir}/config/capability.yaml"
export RDMA_LINK_RESULT="${results_dir}/rdma_link_check.json"
export RDMA_LINK_PROM="${results_dir}/rdma_link_check.prom"
export RDMA_LINK_NODE="${node}"

python3 <<'PY'
import json
import os
import pathlib
import re
import subprocess

import yaml


def command(*args):
    try:
        completed = subprocess.run(args, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return completed.stdout if completed.returncode == 0 else None


def read_text(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def counter_snapshot(port_path):
    counters = pathlib.Path(port_path) / "counters"
    if not counters.is_dir():
        return {}
    return {
        entry.name: int(read_text(entry))
        for entry in counters.iterdir()
        if entry.is_file() and read_text(entry).isdigit()
    }


def ibv_value(text, key):
    match = re.search(rf"^\s*{re.escape(key)}\s*:\s*(.+)$", text or "", re.MULTILINE)
    return match.group(1).strip() if match else ""


def live_observed(rdma_expectations):
    observed_hcas = []
    commands = {}
    root = pathlib.Path("/sys/class/infiniband")
    for hca_path in sorted(root.iterdir()) if root.is_dir() else []:
        hca = hca_path.name
        ibv = command("ibv_devinfo", "-d", hca) or ""
        commands["ibv_devinfo"] = bool(ibv)
        commands["ibstat"] = command("ibstat", hca) is not None
        commands["rdma_link"] = command("rdma", "link", "show") is not None
        pci = pathlib.Path(os.path.realpath(hca_path / "device")).name
        model = command("lspci", "-s", pci) or ""
        commands["lspci"] = bool(model)
        ibdev = command("ibdev2netdev") or ""
        commands["ibdev2netdev"] = bool(ibdev)
        ports = []
        ports_root = hca_path / "ports"
        for port_path in sorted(ports_root.iterdir()) if ports_root.is_dir() else []:
            port = int(port_path.name)
            rate = read_text(port_path / "rate")
            rate_match = re.search(r"([0-9.]+)\s*Gb/sec.*?\(([0-9]+X)", rate)
            netdev_match = re.search(rf"^{re.escape(hca)}\s+port\s+{port}\s+==>\s+(\S+)", ibdev, re.MULTILINE)
            gids = [read_text(path) for path in sorted((port_path / "gids").glob("*")) if read_text(path)]
            before = counter_snapshot(port_path)
            after = counter_snapshot(port_path)
            ports.append({
                "port": port,
                "state": read_text(port_path / "state").split()[-1] if read_text(port_path / "state") else "",
                "width": rate_match.group(2) if rate_match else "",
                "rate_gbps": float(rate_match.group(1)) if rate_match else 0,
                "link_layer": ibv_value(ibv, "link_layer"),
                "guid": ibv_value(ibv, "node_guid"),
                "lid": read_text(port_path / "lid"),
                "gids": gids,
                "netdev": netdev_match.group(1) if netdev_match else "",
                "counters_before": before,
                "counters_after": after,
            })
        observed_hcas.append({"name": hca, "model": model, "firmware": ibv_value(ibv, "fw_ver"), "pci_bdf": pci, "ports": ports})
    fabric_queries = {}
    if rdma_expectations.get("fabric_query_authorized", False):
        for name in ("iblinkinfo", "ibnetdiscover", "show_gids"):
            fabric_queries[name] = command(name) is not None
    return {"commands": commands, "hcas": observed_hcas, "benchmark_edges": [], "fabric_queries": fabric_queries}


fixture_path = os.environ["RDMA_LINK_FIXTURE"]
fixture_data = json.loads((pathlib.Path(fixture_path) / "manifest.json").read_text(encoding="utf-8")) if fixture_path else {}
if fixture_path:
    expectations = fixture_data.get("expectations", {})
    observed = fixture_data.get("rdma_observed", {})
else:
    expectations = yaml.safe_load(pathlib.Path(os.environ["RDMA_LINK_CAPABILITY"]).read_text(encoding="utf-8")) or {}
    observed = live_observed(expectations.get("rdma", {}) or {})

errors: list[str] = []
warnings: list[str] = []
verdict = "PASS"
selected: list[dict] = []
rdma = expectations.get("rdma", {}) or {}

if not expectations:
    errors.append("capability config declares no expectations")
    verdict = "FAIL"
elif expectations.get("fabric") != "infiniband":
    verdict = "SKIP"
elif not rdma:
    errors.append("rdma expectations are required on an InfiniBand fabric")
    verdict = "FAIL"
else:
    for expected in rdma.get("hcas", []):
        matches = [hca for hca in observed.get("hcas", []) if re.fullmatch(expected["name_pattern"], hca.get("name", ""))]
        if not matches:
            errors.append(f"no HCA matches expected pattern {expected['name_pattern']}")
        for hca in matches:
            selected.append(hca)
            for field, pattern in (
                ("model", expected["model_pattern"]),
                ("firmware", expected["firmware_pattern"]),
                ("pci_bdf", expected["pci_bdf_pattern"]),
            ):
                if not re.search(pattern, hca.get(field, "")):
                    errors.append(f"{hca.get('name', '?')} {field} does not match the expectations")
            ports = {port.get("port"): port for port in hca.get("ports", [])}
            for expected_port in expected["ports"]:
                port = ports.get(expected_port["port"])
                if not port:
                    errors.append(f"{hca['name']} missing port {expected_port['port']}")
                    continue
                for field in ("state", "width", "link_layer"):
                    if port.get(field) != expected_port[field]:
                        errors.append(f"{hca['name']} port {port['port']} {field} mismatch")
                if port.get("rate_gbps", 0) < expected_port["minimum_rate_gbps"]:
                    errors.append(f"{hca['name']} port {port['port']} rate below the expected minimum")
                if not re.search(expected["netdev_pattern"], port.get("netdev", "")):
                    errors.append(f"{hca['name']} port {port['port']} netdev does not match the expectations")
                if not port.get("guid") or not port.get("lid") or not port.get("gids"):
                    errors.append(f"{hca['name']} port {port['port']} is missing GUID, LID, or GID evidence")
                # A counter that moved during the run is a live link fault, which a
                # single snapshot could not distinguish from historical damage.
                for counter, maximum in expected_port["max_counter_delta"].items():
                    delta = port.get("counters_after", {}).get(counter, 0) - port.get("counters_before", {}).get(counter, 0)
                    if delta > maximum:
                        errors.append(f"{hca['name']} port {port['port']} {counter} delta {delta} exceeds {maximum}")
    edges = observed.get("benchmark_edges", [])
    if len(edges) > rdma["max_benchmark_edges"]:
        errors.append("verbs benchmark edge count exceeds the expected bound")
    for edge in edges:
        if not edge.get("verbs_success", False):
            errors.append(f"verbs benchmark failed on {edge.get('id', 'unnamed-edge')}")
        if edge.get("bandwidth_gbps", 0) < rdma["minimum_bandwidth_gbps"]:
            errors.append(f"verbs bandwidth below the expected minimum on {edge.get('id', 'unnamed-edge')}")
        if edge.get("latency_us", float("inf")) > rdma["maximum_latency_us"]:
            errors.append(f"verbs latency exceeds the expected maximum on {edge.get('id', 'unnamed-edge')}")
    if not edges:
        warnings.append("two-node verbs benchmarks are recorded by ib-pairwise, not this one-node suite")
    authorized = rdma["fabric_query_authorized"]
    if not authorized and observed.get("fabric_queries"):
        errors.append("fabric topology query ran without authorization")
    if authorized and not observed.get("fabric_queries"):
        warnings.append("fabric discovery is authorized but no batch-visible query command is available")
    verdict = "FAIL" if errors else "WARN" if warnings else "PASS"

declared = fixture_data.get("verdicts", {}).get("rdma-link-check", "")
if declared and verdict != declared:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture_path), "node": os.environ["RDMA_LINK_NODE"],
    "selected_hcas": [hca.get("name") for hca in selected],
    "hca_count": len(observed.get("hcas", [])),
    "benchmark_edge_count": len(observed.get("benchmark_edges", [])),
    "fabric_query_authorized": rdma.get("fabric_query_authorized", False),
    "fabric_topology_claimed": False,
    "verdict": verdict, "failures": errors, "warnings": warnings,
}
pathlib.Path(os.environ["RDMA_LINK_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(os.environ["RDMA_LINK_PROM"]).write_text(
    "# HELP chapar_rdma_link_hcas Expectation-selected RDMA HCAs\n"
    "# TYPE chapar_rdma_link_hcas gauge\n"
    f'chapar_rdma_link_hcas{{node="{payload["node"]}"}} {len(payload["selected_hcas"])}\n',
    encoding="utf-8",
)
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/rdma_link_check.json")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${results_dir}/rdma_link_check.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
    SKIP) validation_resource_unavailable 'expectations do not declare an InfiniBand fabric' optional ;;
esac

printf 'RDMA link evidence written to %s\n' "${results_dir}" >&2
