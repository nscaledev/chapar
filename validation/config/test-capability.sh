#!/usr/bin/env bash
set -euo pipefail

# Offline schema test for the tracked capability expectations. No Slurm, no
# hardware, no network: it only proves that the shipped expectations validate and
# that fail-closed mutations are refused, so a suite can never read an expectation
# the schema would not accept.

config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "${config_dir}/capability.schema.json" "${config_dir}/capability.yaml" <<'PY'
import copy
import json
import sys

import jsonschema
import yaml

schema_path, example_path = sys.argv[1], sys.argv[2]
with open(schema_path, encoding="utf-8") as stream:
    schema = json.load(stream)
jsonschema.Draft202012Validator.check_schema(schema)
validator = jsonschema.Draft202012Validator(schema)
with open(example_path, encoding="utf-8") as stream:
    example = yaml.safe_load(stream)

failures: list[str] = []


def require_valid(label: str, document: object) -> None:
    errors = sorted(validator.iter_errors(document), key=str)
    if errors:
        failures.append(f"{label}: unexpectedly rejected: {errors[0].message}")


def require_invalid(label: str, document: object) -> None:
    if not sorted(validator.iter_errors(document), key=str):
        failures.append(f"{label}: unexpectedly accepted")


require_valid("tracked expectations", example)

# An InfiniBand fabric with no RDMA expectations would leave rdma-link-check with
# nothing to compare, so it must not validate.
missing_rdma = copy.deepcopy(example)
del missing_rdma["rdma"]
require_invalid("infiniband without rdma", missing_rdma)

# A RoCE fabric likewise needs the endpoint tuple.
roce_without_endpoint = copy.deepcopy(example)
roce_without_endpoint["fabric"] = "roce"
del roce_without_endpoint["roce"]
require_invalid("roce without endpoint", roce_without_endpoint)

# Counter deltas are non-negative: a negative tolerance is meaningless.
negative_counter = copy.deepcopy(example)
negative_counter["rdma"]["hcas"][0]["ports"][0]["max_counter_delta"]["symbol_error"] = -1
require_invalid("negative counter tolerance", negative_counter)

# Zero benchmark edges would silently disable the bounded benchmark rather than
# bound it.
zero_edges = copy.deepcopy(example)
zero_edges["rdma"]["max_benchmark_edges"] = 0
require_invalid("zero benchmark edges", zero_edges)

# NVLS exists only behind NVSwitch.
nvls_on_pcie = copy.deepcopy(example)
nvls_on_pcie["gpu"]["interconnect"] = "pcie"
require_invalid("nvls on pcie", nvls_on_pcie)

# A GID type other than RoCEv2 cannot be pinned by rocev2-pairwise.
wrong_gid = copy.deepcopy(example)
wrong_gid["roce"]["endpoint"]["gid_type"] = "RoCE v1"
require_invalid("non-v2 gid type", wrong_gid)

# VLAN 0 is not a VLAN.
bad_vlan = copy.deepcopy(example)
bad_vlan["roce"]["endpoint"]["vlan_id"] = 0
require_invalid("vlan id zero", bad_vlan)

# Unknown keys are refused, so a typo cannot become a silently ignored
# expectation.
unknown_key = copy.deepcopy(example)
unknown_key["unexpected"] = True
require_invalid("unknown top-level key", unknown_key)
unknown_nested = copy.deepcopy(example)
unknown_nested["gpu"]["unexpected"] = True
require_invalid("unknown gpu key", unknown_nested)

# A CPU-only Ethernet cluster is a legitimate shape: no rdma, no roce, no GPU.
cpu_only = {
    "fabric": "ethernet",
    "cpu": {"platform": "generic", "vendor": "generic", "numa_nodes": 1, "pci_devices": 0},
    "node": {"expected_cpus": 16, "expected_gpus": 0, "expected_ib_nics": 0},
    "gpu": {"gpus_per_node": 0, "accelerator": {"kind": "none"}},
}
require_valid("cpu-only ethernet cluster", cpu_only)

# A Grace platform cannot claim a non-NVIDIA vendor.
grace_wrong_vendor = copy.deepcopy(cpu_only)
grace_wrong_vendor["cpu"] = {"platform": "nvidia-grace", "vendor": "amd"}
require_invalid("grace with wrong vendor", grace_wrong_vendor)

if failures:
    for failure in failures:
        print(f"ERROR: {failure}", file=sys.stderr)
    raise SystemExit(1)
print(
    "capability expectations: tracked and CPU-only shapes accepted; "
    "fail-closed mutations rejected"
)
PY
