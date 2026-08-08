#!/usr/bin/env bash

# HCA selection shared by the transport suites.
#
# Selection is by pattern from the tracked expectations rather than "whatever
# sysfs lists first": a node can present management or storage HCAs alongside the
# compute fabric, and benchmarking the wrong one reports a healthy number for a
# path nobody uses.
#
# VALIDATION_RDMA_HCAS remains an explicit operator override for a single
# invocation; it is intersected with what actually exists, never trusted blindly.

rdma_selected_hcas() {
    local capability="${VALIDATION_CAPABILITY_CONFIG:-}"
    if [ -n "${VALIDATION_RDMA_HCAS:-}" ]; then
        local entry
        for entry in ${VALIDATION_RDMA_HCAS//,/ }; do
            [ -e "/sys/class/infiniband/${entry}" ] && printf '%s\n' "${entry}"
        done
        return 0
    fi
    python3 - "${capability}" <<'PY'
import pathlib
import re
import sys

import yaml

capability = sys.argv[1]
patterns = []
if capability:
    document = yaml.safe_load(pathlib.Path(capability).read_text(encoding="utf-8")) or {}
    rdma = document.get("rdma", {}) or {}
    patterns = [str(entry.get("name_pattern", "")) for entry in rdma.get("hcas", []) if entry.get("name_pattern")]
root = pathlib.Path("/sys/class/infiniband")
for device in sorted(root.glob("*")) if root.is_dir() else []:
    name = device.name
    # No configured pattern means no opinion, so every present device qualifies.
    if not patterns or any(re.fullmatch(pattern, name) for pattern in patterns):
        print(name)
PY
}

rdma_selected_hca() {
    local first
    first="$(rdma_selected_hcas | sort | head -n 1)"
    [ -n "${first}" ] || return 1
    printf '%s\n' "${first}"
}

rdma_benchmark_edge_limit() {
    local fallback="${RDMA_BENCHMARK_MAX_EDGES:-1}"
    local capability="${VALIDATION_CAPABILITY_CONFIG:-}"
    if [ -z "${capability}" ]; then
        printf '%s\n' "${fallback}"
        return 0
    fi
    python3 - "${capability}" "${fallback}" <<'PY'
import pathlib
import sys

import yaml

document = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
rdma = document.get("rdma", {}) or {}
print(rdma.get("max_benchmark_edges", int(sys.argv[2])))
PY
}
