#!/usr/bin/env bash
# DESCRIPTION: Expectation-selected two-node RoCEv2 GID-pinned verbs and endpoint telemetry validation
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:10:00
#SBATCH --job-name=rocev2-pairwise

# Proves a RoCEv2 path end to end from the endpoints: the HCA-to-netdev
# association, the VLAN tuple, the carrier and MTU, and exactly one RoCEv2 GID that
# matches the configured address. Benchmarks are pinned to that GID index, because
# a benchmark that is not GID-pinned may traverse a different path entirely and
# proves nothing about the intended one.
#
# Only endpoint telemetry is recorded. Switch QoS -- PFC and ECN configuration on
# the fabric -- is never claimed from an endpoint, no matter what the counters say.
#
# The suite re-enters itself through srun to run each benchmark on both ranks; that
# path is handled first, before anything else.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"

endpoint_benchmark() {
    local executable="$1" peer="$2" benchmark="$3" selection hca port gid_index
    selection="$(python3 - "${ROCE_CAPABILITY:?}" <<'PY'
import ipaddress
import json
import re
import subprocess
import sys

import yaml


def output(*command):
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return ""
    return completed.stdout if completed.returncode == 0 else ""


def gid_matches_address(gid, address):
    try:
        gid_address = ipaddress.ip_address(gid)
        address_value = ipaddress.ip_address(address)
    except ValueError:
        return False
    return gid_address == address_value or getattr(gid_address, "ipv4_mapped", None) == address_value


with open(sys.argv[1], encoding="utf-8") as stream:
    endpoint = ((yaml.safe_load(stream) or {}).get("roce", {}) or {}).get("endpoint", {})
addresses = [
    entry.get("local", "")
    for interface in json.loads(output("ip", "-j", "addr", "show", "dev", endpoint["vlan_netdev"]) or "[]")
    for entry in interface.get("addr_info", [])
]
matching_addresses = [address for address in addresses if re.fullmatch(endpoint["address_pattern"], address)]
for line in output("show_gids").splitlines():
    fields = line.split()
    if len(fields) < 6 or not fields[1].isdigit() or not fields[2].isdigit():
        continue
    hca, port, gid_index, gid, gid_type, netdev = fields[:6]
    if not re.fullmatch(endpoint["hca_pattern"], hca) or int(port) != endpoint["port"]:
        continue
    if netdev == endpoint["vlan_netdev"] and gid_type.lower() in {"v2", "roce_v2", "roce-v2"} and any(gid_matches_address(gid, address) for address in matching_addresses):
        print(hca, port, gid_index)
        break
PY
)"
    read -r hca port gid_index <<<"${selection}"
    [ -n "${gid_index:-}" ] || { printf 'unable to resolve local RoCEv2 GID tuple\n' >&2; exit 2; }
    local arguments=(-d "${hca}" -i "${port}" -x "${gid_index}" -n "${ROCE_BENCHMARK_ITERS:-10000}" -s "${ROCE_BENCHMARK_BYTES:-65536}")
    [ "${benchmark}" = ib_send_lat ] || arguments+=(--report_gbits)
    if [ "${SLURM_NODEID:-0}" -eq 0 ]; then
        exec timeout "${ROCE_BENCHMARK_TIMEOUT_SECONDS:-90}" "${executable}" "${arguments[@]}"
    fi
    exec timeout "${ROCE_BENCHMARK_TIMEOUT_SECONDS:-90}" "${executable}" "${arguments[@]}" "${peer}"
}

if [ "${1:-}" = --endpoint-benchmark ]; then
    [ "$#" -eq 4 ] || { printf 'usage: %s --endpoint-benchmark <executable> <peer> <benchmark>\n' "$0" >&2; exit 2; }
    endpoint_benchmark "$2" "$3" "$4"
fi

# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_ROCE)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init rocev2-pairwise "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export ROCE_FIXTURE="${fixture}"
export ROCE_CAPABILITY="${validation_dir}/config/capability.yaml"
export ROCE_RESULT="${results_dir}/rocev2_pairwise.json"
export ROCE_PROM="${results_dir}/rocev2_pairwise.prom"
export ROCE_RESULTS_DIR="${results_dir}"
export ROCE_SCRIPT="${script_dir}/rocev2-pairwise.sbatch"
export ROCE_PERFTEST_DIR="${EXTERNAL_PERFTEST_DIR:-${validation_dir}/external/perftest}"

python3 <<'PY'
import ipaddress
import json
import os
import pathlib
import re
import subprocess

import yaml


def output(*command):
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return "", False
    return completed.stdout, completed.returncode == 0


def read(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def gids(text):
    values = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[1].isdigit() and fields[2].isdigit():
            values.append({
                "hca": fields[0], "port": int(fields[1]), "index": int(fields[2]),
                "gid": fields[3], "type": fields[4], "netdev": fields[5],
            })
    return values


def gid_matches_address(gid, address):
    try:
        gid_address = ipaddress.ip_address(gid)
        address_value = ipaddress.ip_address(address)
    except ValueError:
        return False
    return gid_address == address_value or getattr(gid_address, "ipv4_mapped", None) == address_value


def counters(netdev, names):
    text, available = output("ethtool", "-S", netdev)
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() in names and value.strip().isdigit():
            values[key.strip()] = int(value.strip())
    return values, available


def collect(endpoint):
    show_gids, show_gids_available = output("show_gids")
    ibdev, ibdev_available = output("ibdev2netdev")
    rdma_link, rdma_link_available = output("rdma", "link", "show")
    link_text, link_available = output("ip", "-d", "-j", "link", "show", "dev", endpoint["vlan_netdev"])
    address_text, address_available = output("ip", "-j", "addr", "show", "dev", endpoint["vlan_netdev"])
    links = json.loads(link_text) if link_available else []
    addresses = [
        entry.get("local", "")
        for interface in (json.loads(address_text) if address_available else [])
        for entry in interface.get("addr_info", [])
    ]
    vlan = links[0].get("linkinfo", {}) if links else {}
    vlan_data = vlan.get("info_data", {})
    hca_netdev = ""
    for line in ibdev.splitlines():
        match = re.match(r"(\S+)\s+port\s+(\d+)\s+==>\s+(\S+)", line)
        if match and re.fullmatch(endpoint["hca_pattern"], match.group(1)) and int(match.group(2)) == endpoint["port"]:
            hca_netdev = match.group(3)
            break
    hca = next(
        (item["hca"] for item in gids(show_gids) if re.fullmatch(endpoint["hca_pattern"], item["hca"]) and item["port"] == endpoint["port"]),
        "",
    )
    port_root = pathlib.Path("/sys/class/infiniband") / hca / "ports" / str(endpoint["port"])
    names = set().union(endpoint["pfc_max_counter_delta"], endpoint["ecn_max_counter_delta"], endpoint["retransmit_max_counter_delta"])
    counter_values, ethtool_available = counters(endpoint["vlan_netdev"], names)
    return {
        "commands": {
            "show_gids": show_gids_available, "ibdev2netdev": ibdev_available,
            "rdma_link": rdma_link_available, "ip": link_available and address_available,
            "ethtool_stats": ethtool_available,
        },
        "hca": hca,
        "port": endpoint["port"],
        "hca_netdev": hca_netdev,
        "rdma_link": rdma_link,
        "link_layer": read(port_root / "link_layer"),
        "state": read(port_root / "state"),
        "carrier": read(pathlib.Path("/sys/class/net") / endpoint["vlan_netdev"] / "carrier"),
        "mtu": links[0].get("mtu", 0) if links else 0,
        "vlan": {
            "netdev": endpoint["vlan_netdev"], "id": vlan_data.get("id"),
            "parent": links[0].get("link", "") if links else "", "kind": vlan.get("info_kind", ""),
        },
        "addresses": addresses,
        "gids": gids(show_gids),
        "counters_before": counter_values,
        "counters_after": counter_values,
        "benchmarks": [],
    }


def run_benchmarks(roce):
    nodes, available = output("scontrol", "show", "hostnames", os.environ.get("SLURM_NODELIST", ""))
    hosts = nodes.splitlines() if available else []
    if len(hosts) != 2:
        return [], ["a matching two-node Slurm allocation is required for RoCE performance evidence"]
    results, errors = [], []
    for name in ("ib_write_bw", "ib_read_bw", "ib_send_lat"):
        executable = pathlib.Path(os.environ["ROCE_PERFTEST_DIR"]) / name
        if not executable.is_file() or not os.access(executable, os.X_OK):
            errors.append(f"required RoCE benchmark unavailable: {executable}")
            continue
        completed = subprocess.run(
            ["srun", "-n", "2", "--ntasks-per-node=1", os.environ["ROCE_SCRIPT"], "--endpoint-benchmark", str(executable), hosts[0], name],
            check=False, capture_output=True, text=True,
        )
        text = completed.stdout + completed.stderr
        pathlib.Path(os.environ["ROCE_RESULTS_DIR"], f"{name}.log").write_text(text, encoding="utf-8")
        bandwidth = [float(value) for value in re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*(?:Gb/sec|Gbit/sec)", text)]
        latency = [float(value) for value in re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*(?:usec|us)\b", text)]
        result = {
            "name": name, "success": completed.returncode == 0,
            "bandwidth_gbps": max(bandwidth) if bandwidth else None,
            "latency_us": min(latency) if latency else None,
        }
        results.append(result)
        if not result["success"]:
            errors.append(f"{name} failed with exit code {completed.returncode}")
        elif name != "ib_send_lat" and result["bandwidth_gbps"] is None:
            errors.append(f"{name} did not report bandwidth")
        elif name == "ib_send_lat" and result["latency_us"] is None:
            errors.append("ib_send_lat did not report latency")
    return results, errors


fixture_path = os.environ["ROCE_FIXTURE"]
fixture_data = json.loads((pathlib.Path(fixture_path) / "manifest.json").read_text(encoding="utf-8")) if fixture_path else {}
if fixture_path:
    expectations = fixture_data.get("expectations", {})
    observed = fixture_data.get("roce_observed", {})
else:
    expectations = yaml.safe_load(pathlib.Path(os.environ["ROCE_CAPABILITY"]).read_text(encoding="utf-8")) or {}
    roce_expectations = expectations.get("roce", {}) or {}
    observed = collect(roce_expectations["endpoint"]) if expectations.get("fabric") == "roce" and roce_expectations else {}

errors: list[str] = []
warnings: list[str] = []
verdict = "PASS"
benchmarks: list[dict] = []
matching_gids: list[dict] = []

if not expectations:
    errors.append("capability config declares no expectations")
    verdict = "FAIL"
elif expectations.get("fabric") != "roce":
    verdict = "SKIP"
else:
    roce = expectations.get("roce", {}) or {}
    endpoint = roce.get("endpoint", {})
    if not roce:
        errors.append("roce expectations are required on a RoCE fabric")
    for command_name, available in observed.get("commands", {}).items():
        if not available:
            errors.append(f"required discovery command unavailable: {command_name}")
    if observed.get("link_layer", "").lower() != "ethernet":
        errors.append("RDMA port link layer is not Ethernet; this is not RoCE")
    if "active" not in observed.get("state", "").lower():
        errors.append("RoCE RDMA port is not ACTIVE")
    if observed.get("hca_netdev") != endpoint.get("netdev"):
        errors.append("HCA-to-netdev association does not match the configured RoCE netdev")
    if endpoint.get("netdev") and endpoint["netdev"] not in observed.get("rdma_link", ""):
        errors.append("rdma link does not report the configured RoCE netdev")
    if str(observed.get("carrier")) != "1":
        errors.append("configured RoCE VLAN netdev has no carrier")
    if observed.get("mtu") != endpoint.get("mtu"):
        errors.append("configured RoCE VLAN netdev MTU does not match the expectations")
    vlan = observed.get("vlan", {})
    if (
        vlan.get("kind") != "vlan"
        or vlan.get("netdev") != endpoint.get("vlan_netdev")
        or vlan.get("id") != endpoint.get("vlan_id")
        or vlan.get("parent") != endpoint.get("netdev")
    ):
        errors.append("configured RoCE VLAN tuple does not match netdev, VLAN ID, and parent")
    addresses = [address for address in observed.get("addresses", []) if re.fullmatch(endpoint.get("address_pattern", r"$."), address)]
    # Exactly one: an ambiguous GID means a benchmark could be pinned to the wrong
    # path while still reporting a healthy number.
    matching_gids = [
        gid for gid in observed.get("gids", [])
        if re.fullmatch(endpoint.get("hca_pattern", r"$."), gid.get("hca", ""))
        and gid.get("port") == endpoint.get("port")
        and gid.get("netdev") == endpoint.get("vlan_netdev")
        and gid.get("type", "").lower() in {"v2", "roce_v2", "roce-v2"}
        and any(gid_matches_address(gid.get("gid", ""), address) for address in addresses)
    ]
    if not addresses:
        errors.append("no configured RoCE address matches the VLAN netdev")
    if len(matching_gids) != 1:
        errors.append("configured netdev/VLAN/address tuple does not resolve exactly one RoCEv2 GID")
    benchmarks = observed.get("benchmarks", [])
    if not fixture_path and not errors:
        benchmarks, benchmark_errors = run_benchmarks(roce)
        observed["benchmarks"] = benchmarks
        current, _ = counters(
            endpoint["vlan_netdev"],
            set().union(endpoint["pfc_max_counter_delta"], endpoint["ecn_max_counter_delta"], endpoint["retransmit_max_counter_delta"]),
        )
        observed["counters_after"] = current
        errors.extend(benchmark_errors)
    for group in ("pfc_max_counter_delta", "ecn_max_counter_delta", "retransmit_max_counter_delta"):
        for counter, maximum in endpoint.get(group, {}).items():
            before = observed.get("counters_before", {}).get(counter)
            after = observed.get("counters_after", {}).get(counter)
            if before is None or after is None:
                errors.append(f"configured {group} counter is unavailable: {counter}")
            elif after - before > maximum:
                errors.append(f"{group} counter delta exceeds the expectations: {counter}")
    if len(benchmarks) > roce.get("max_benchmark_edges", 0) * 3:
        errors.append("RoCE benchmark command count exceeds the configured edge bound")
    required = {"ib_write_bw", "ib_read_bw", "ib_send_lat"}
    if benchmarks and {item.get("name") for item in benchmarks} != required:
        errors.append("RoCE benchmark set is incomplete")
    for benchmark in benchmarks:
        if not benchmark.get("success"):
            errors.append(f"{benchmark.get('name', 'benchmark')} did not complete")
        if benchmark.get("name") in {"ib_write_bw", "ib_read_bw"} and (
            benchmark.get("bandwidth_gbps") is None or benchmark["bandwidth_gbps"] < roce.get("minimum_bandwidth_gbps", 0)
        ):
            errors.append(f"{benchmark.get('name')} bandwidth is below the expected minimum")
        if benchmark.get("name") == "ib_send_lat" and (
            benchmark.get("latency_us") is None or benchmark["latency_us"] > roce.get("maximum_latency_us", float("inf"))
        ):
            errors.append("ib_send_lat latency exceeds the expected maximum")
    if not benchmarks:
        errors.append("no GID-pinned RoCE benchmark evidence was recorded")
    verdict = "FAIL" if errors else "WARN" if warnings else "PASS"

declared = fixture_data.get("verdicts", {}).get("rocev2-pairwise", "")
if declared and verdict != declared:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture_path), "node": os.environ.get("SLURM_NODELIST", ""),
    "fabric": expectations.get("fabric", ""),
    "benchmark_edge_count": len(benchmarks) // 3,
    "provider_transport": {"provider": "verbs", "transport": "RoCEv2", "gid_pinned": len(matching_gids) == 1},
    "selected_gid": matching_gids[0] if len(matching_gids) == 1 else {},
    "endpoint_telemetry_only": True, "switch_qos_claimed": False, "fabric_proof_claimed": False,
    "observed": observed, "verdict": verdict, "failures": errors, "warnings": warnings,
}
pathlib.Path(os.environ["ROCE_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(os.environ["ROCE_PROM"]).write_text(
    "# HELP chapar_roce_switch_qos_claimed Switch QoS is never claimed from endpoint telemetry\n"
    "# TYPE chapar_roce_switch_qos_claimed gauge\n"
    "chapar_roce_switch_qos_claimed 0\n",
    encoding="utf-8",
)
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/rocev2_pairwise.json")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${results_dir}/rocev2_pairwise.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
    SKIP) validation_resource_unavailable 'expectations do not declare a RoCE fabric' optional ;;
esac

printf 'RoCEv2 pairwise evidence written to %s\n' "${results_dir}" >&2
