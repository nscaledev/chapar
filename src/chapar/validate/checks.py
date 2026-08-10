"""Per-root module checks for the integrity suites.

The expected inventory is the release-local spack.lock: the concrete roots the
build actually produced, not what a catalog promised. Each root gets a module
load plus one root-specific command; a root without a dedicated command falls
back to `module show`, which still proves the module exists and parses.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

CHECK_COMMANDS: Final = {
    "babelstream": ("module show babelstream", "babelstream module"), "caliper": ("cali-query --help", "caliper tool runs"), "cmake": ("cmake --version", "cmake runs"),
    "cuda": ("nvcc --version", "nvcc --version"), "cuda-memtest": ("command -v cuda_memtest", "cuda_memtest on PATH"), "fio": ("fio --version", "fio runs"),
    "gcc": ("gcc --version", "compiler runs"), "hpcg": ("command -v hpcg || command -v xhpcg", "hpcg binary"), "hpctoolkit": ("command -v hpcrun", "hpctoolkit on PATH"),
    "hwloc": ("lstopo --version || hwloc-info --version", "hwloc runs"), "ior": ("ior --version", "ior runs"), "libfabric": ("fi_info --version", "libfabric available"),
    "likwid": ("likwid-perfctr --version", "likwid on PATH"), "mdtest": ("command -v mdtest", "mdtest on PATH"), "meson": ("meson --version", "meson runs"),
    "nccl": ("module show nccl", "nccl module"), "ninja": ("ninja --version", "ninja runs"), "numactl": ("numactl --show", "numactl runs"),
    "openmpi": ("mpirun --version", "mpirun --version"), "osu-micro-benchmarks": ("command -v osu_latency", "osu_latency on PATH"),
    "papi": ("command -v papi_command_line", "papi on PATH"), "pmix": ("pmi_info --version || pmi_info --help", "pmix available"),
    "py-mpi4py": ("python3 -c 'import mpi4py'", "mpi4py importable"), "python": ("python3 --version", "python3 --version"),
    "qperf": ("qperf --help", "qperf runs"), "scalasca": ("command -v scalasca || command -v scout", "scalasca on PATH"),
    "stream": ("command -v stream_c.exe", "stream on PATH"), "tau": ("command -v tau_exec", "tau on PATH"), "ucx": ("ucx_info -v", "ucx_info runs"),
}


@dataclass(frozen=True, slots=True)
class RootCheck:
    module: str
    command: str
    description: str


def root_checks(roots: Iterable[tuple[str, str, str]]) -> tuple[RootCheck, ...]:
    """One check per concrete (name, version, hash) root from a spack.lock."""
    checks: list[RootCheck] = []
    for name, _version, _digest in roots:
        command, description = CHECK_COMMANDS.get(name, (f"module show {name}", f"{name} module"))
        checks.append(RootCheck(name, command, description))
    return tuple(checks)
