"""Offline checks for the transport classification parsers.

These parsers decide whether a cluster is reported as running RoCEv2,
InfiniBand, or NVLink, and whether the built stack is capable of efficient
RDMA at all. They are embedded in Slurm batch scripts that cannot run here, so
the parser bodies are extracted from the shipped `.sbatch` files and exercised
against recorded probe output. Extracting rather than copying keeps the test
honest: an edit to the batch script that breaks classification fails here.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT

TESTS = REPO_ROOT / "validation" / "tests"
NCCL_CHECK = TESTS / "nccl-transport-check.sbatch"
TRANSPORT = TESTS / "transport.sbatch"

# ---------------------------------------------------------------- fixtures --

ACCELERATED_UCX = """\
#      Transport: rc_verbs
#      Transport: rc_mlx5
#      Transport: dc_mlx5
#      Transport: ud_mlx5
#      Transport: cuda_copy
#      Transport: cuda_ipc
#      Transport: gdr_copy
"""
# What a ~mlx5_dv build produces: --without-mlx5 leaves only generic verbs, and
# dc_mlx5 disappears, which is what made `+dc` inert before this was fixed.
GENERIC_VERBS_UCX = """\
#      Transport: rc_verbs
#      Transport: ud_verbs
#      Transport: cuda_copy
#      Transport: cuda_ipc
#      Transport: gdr_copy
"""
PROVIDERS_WITH_SHM = "provider: verbs;ofi_rxm\n    fabric: IB-0xfe80\nprovider: shm\n    fabric: shm\n"
# fabrics=mlx,rxm,verbs replaces libfabric's sockets,tcp,udp default, so before
# shm was added there was no node-local provider at all.
PROVIDERS_WITHOUT_SHM = "provider: verbs;ofi_rxm\n    fabric: IB-0xfe80\n"
NCCL_ROCE = "NCCL INFO NET/IB : Using [0]mlx5_0:1/RoCE [1]mlx5_1:1/RoCE ; OOB eth0:10.0.0.1<0>\n"
NCCL_SOCKET = "NCCL INFO NET/Socket : Using [0]eth0:10.0.0.1<0>\n"
TOPOLOGY_NVLINK = "\tGPU0\tGPU1\tCPU Affinity\nGPU0\t X \tNV18\t0-51\nGPU1\tNV18\t X \t0-51\n"
TOPOLOGY_ONE_GPU = "\tGPU0\tCPU Affinity\nGPU0\t X \t0-51\n"


def _extract(source: Path, start: str) -> str:
    """Return the python heredoc body that begins on the line matching `start`."""
    lines = source.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if re.search(start, line):
            end = lines.index("PYEOF", index)
            return "\n".join(lines[index + 1 : end]) + "\n"
    raise AssertionError(f"no heredoc matching {start!r} in {source}")


def _run(body: str, results: Path) -> str:
    script = results / "_parser.py"
    _ = script.write_text(body, encoding="utf-8")
    completed = subprocess.run(
        [sys.executable, str(script), str(results)],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return completed.stdout.strip()


def _nccl_verdict(tmp_path: Path, debug_log: str) -> str:
    _ = (tmp_path / "nccl_debug.log").write_text(debug_log, encoding="utf-8")
    _ = (tmp_path / "python_stderr.log").write_text("", encoding="utf-8")
    return _run(_extract(NCCL_CHECK, r"^SELECTED_TRANSPORT=.*python3"), tmp_path)


def _capability(tmp_path: Path, ucx: str, providers: str, nccl: str, topology: str) -> dict[str, object]:
    for name, payload in (
        ("ucx_devices.txt", ucx),
        ("ucx_build.txt", ""),
        ("libfabric_providers.txt", providers),
        ("libfabric_provider_list.txt", ""),
        ("nccl_transport.txt", nccl),
        ("gpu_topology.txt", topology),
    ):
        _ = (tmp_path / name).write_text(payload, encoding="utf-8")
    body = _extract(TRANSPORT, r"^python3 - .*transport_capability\.json")
    return json.loads(_run(body, tmp_path))


# ------------------------------------------------------------------- tests --


@pytest.mark.parametrize(
    ("name", "debug_log", "expected"),
    [
        # RoCEv2 and InfiniBand both arrive as NET/IB; only the per-device link
        # layer separates them, which is why matching /(IB|Socket)/ was wrong.
        ("roce", NCCL_ROCE, "RoCE"),
        ("infiniband", "NCCL INFO NET/IB : Using [0]mlx5_0:1/IB ; OOB ib0:10.0.0.1<0>\n", "IB"),
        ("socket", NCCL_SOCKET, "Socket"),
        ("mixed", "NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/RoCE ; OOB eth0\n", "Mixed"),
        ("nvlink", "NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/IPC\n", "NVLink"),
        ("rdma_without_device_list", "NCCL INFO Using network IB\n", "IBverbs"),
        ("nothing_observed", "", ""),
    ],
)
def test_nccl_transport_classification(tmp_path: Path, name: str, debug_log: str, expected: str) -> None:
    # Given recorded NCCL debug output; When the shipped parser runs; Then the fabric class is exact.
    assert _nccl_verdict(tmp_path, debug_log) == expected, name


def test_capability_gate_passes_on_an_accelerated_stack(tmp_path: Path) -> None:
    # Given mlx5 transports, GPU paths, and a shm provider; When the gate runs; Then it passes.
    document = _capability(tmp_path, ACCELERATED_UCX, PROVIDERS_WITH_SHM, NCCL_ROCE, TOPOLOGY_NVLINK)
    assert document["verdict"] == "PASS"
    assert document["observed_fabric"] == "RoCE"


@pytest.mark.parametrize(
    ("name", "ucx", "providers", "nccl", "failing_check"),
    [
        ("ucx_without_mlx5_dv", GENERIC_VERBS_UCX, PROVIDERS_WITH_SHM, NCCL_ROCE, "ucx_mlx5_accelerated_transports"),
        ("libfabric_without_shm", ACCELERATED_UCX, PROVIDERS_WITHOUT_SHM, NCCL_ROCE, "libfabric_shm_provider"),
        ("nccl_on_tcp", ACCELERATED_UCX, PROVIDERS_WITH_SHM, NCCL_SOCKET, "nccl_rdma_link_layer"),
    ],
)
def test_capability_gate_fails_a_degraded_stack(
    tmp_path: Path, name: str, ucx: str, providers: str, nccl: str, failing_check: str
) -> None:
    # Given a stack missing one efficient-RDMA path; When the gate runs; Then it fails and names it.
    document = _capability(tmp_path, ucx, providers, nccl, TOPOLOGY_NVLINK)
    assert document["verdict"] == "FAIL", name
    failed = {item["check"] for item in document["checks"] if not item["ok"]}
    assert failing_check in failed, f"{name}: {failed}"


def test_missing_nvlink_is_only_fatal_with_more_than_one_gpu(tmp_path: Path) -> None:
    # Given a single-GPU node; When no NVLink edge exists; Then that is not a failure.
    document = _capability(tmp_path, ACCELERATED_UCX, PROVIDERS_WITH_SHM, NCCL_ROCE, TOPOLOGY_ONE_GPU)
    assert document["verdict"] == "PASS"
    nvlink = next(item for item in document["checks"] if item["check"] == "nvlink_present")
    assert nvlink["fatal"] is False
