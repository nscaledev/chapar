"""MAD-based outlier detector for HPC/AI cluster validation results.

Public CLI:
    chapar validate analyze --suite <name> --threshold 2.0 --results-dir <path>

Supported suites: node-smoke, ib-pairwise, mpi-collective, hpc-challenge,
io, profiling, gpu-stress, transport, frameworks. Stdlib only.
"""

from __future__ import annotations

import csv
import json
import os
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final


def _median(values: list[float]) -> float:
    return statistics.median(values)


# ── Data model ──────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Metric:
    """A single measurement point for outlier analysis."""

    node: str
    metric_name: str
    value: float
    unit: str
    gpu_index: int | None = None
    peer_node: str | None = None
    peer_gpu_index: int | None = None


@dataclass
class Flag:
    """A flagged outlier record."""

    node: str
    metric_name: str
    value: float
    unit: str
    zscore: float
    median: float
    mad: float
    gpu_index: int | None = None
    peer_node: str | None = None
    peer_gpu_index: int | None = None


# ── Aggregation ─────────────────────────────────────────────────────────────


def _robust_zscore(value: float, median: float, mad: float) -> float:
    """Compute robust z-score: 0.6745 * (value - median) / mad."""
    if mad == 0.0:
        mad = 1e-9
    return 0.6745 * (value - median) / mad


def compute_flags(metrics: list[Metric], threshold: float = 2.0) -> tuple[list[Flag], dict[str, float | int]]:
    """Aggregate metrics by (metric_name, unit) and flag outliers.

    For each group, compute median and MAD (median absolute deviation),
    then flag any metric whose |robust z-score| > threshold.

    Returns (flags, summary_dict).
    """
    groups: dict[tuple[str, str], list[Metric]] = {}
    for m in metrics:
        key = (m.metric_name, m.unit)
        groups.setdefault(key, []).append(m)

    all_flags: list[Flag] = []
    nodes_seen: set[str] = set()
    for m in metrics:
        nodes_seen.add(m.node)

    for (_metric_name, _unit), group in sorted(groups.items()):
        values = [m.value for m in group]
        median = _median(values)
        abs_devs = [abs(v - median) for v in values]
        mad = _median(abs_devs)

        for m in group:
            zs = _robust_zscore(m.value, median, mad)
            if abs(zs) > threshold:
                all_flags.append(
                    Flag(
                        node=m.node,
                        metric_name=m.metric_name,
                        value=m.value,
                        unit=m.unit,
                        zscore=round(zs, 4),
                        median=round(median, 4),
                        mad=round(mad, 6),
                        gpu_index=m.gpu_index,
                        peer_node=m.peer_node,
                        peer_gpu_index=m.peer_gpu_index,
                    )
                )

    summary: dict[str, float | int] = {
        "nodes_total": len(nodes_seen),
        "flags_total": len(all_flags),
        "threshold": threshold,
        "groups_analyzed": len(groups),
    }
    return all_flags, summary


def flags_to_dicts(flags: list[Flag]) -> list[dict[str, object]]:
    """Convert Flag objects to JSON-serializable dicts."""
    result: list[dict[str, object]] = []
    for f in flags:
        d: dict[str, object] = {
            "node": f.node,
            "metric_name": f.metric_name,
            "value": f.value,
            "unit": f.unit,
            "zscore": f.zscore,
            "median": f.median,
            "mad": f.mad,
        }
        if f.gpu_index is not None:
            d["gpu_index"] = f.gpu_index
        if f.peer_node is not None:
            d["peer_node"] = f.peer_node
        if f.peer_gpu_index is not None:
            d["peer_gpu_index"] = f.peer_gpu_index
        result.append(d)
    return result


# ── Per-suite parsers ───────────────────────────────────────────────────────


def _extract_osu_metrics(path: str, node: str) -> list[Metric]:
    """Parse OSU benchmark output: lines like '# Size  Bandwidth (MB/s)'."""
    metrics: list[Metric] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                try:
                    int(parts[0])  # first column must be a message size
                    bw = float(parts[1])
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name=f"osu_{os.path.basename(path).replace('.log', '')}",
                        value=bw,
                        unit="MB/s",
                    )
                )
    return metrics


def _extract_ior_metrics(path: str, node: str) -> list[Metric]:
    """Parse IOR CSV (-O) output: access,block,xfer,open,wr/rd,close columns."""
    metrics: list[Metric] = []
    with open(path) as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            access = row.get("access", "unknown").strip()
            op = row.get("wr/rd", row.get("operation", "")).strip() or "unknown"
            try:
                bw = float(row.get("bw", row.get("Max Write", row.get("Max Read", "0"))).strip() or "0")
            except (ValueError, TypeError):
                continue
            metrics.append(
                Metric(
                    node=node,
                    metric_name=f"ior_{access}_{op}_bw",
                    value=bw,
                    unit="MiB/s",
                )
            )
    return metrics


def _extract_nccl_metrics(path: str, node: str) -> list[Metric]:
    """Parse nccl-tests output: header '# size  count  time  algbw  busbw'."""
    metrics: list[Metric] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 5:
                try:
                    algbw = float(parts[3])
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="nccl_algbw",
                        value=algbw,
                        unit="GB/s",
                    )
                )
    return metrics


def _extract_nvbandwidth_p2p(path: str, node: str) -> list[Metric]:
    """Parse nvbandwidth p2p matrix CSV with row/col GPU indices."""
    metrics: list[Metric] = []
    with open(path) as fh:
        reader = csv.reader(fh)
        header = next(reader, [])
        # Header: first col is row label, remaining are col GPU indices
        if len(header) < 2:
            return metrics
        col_gpus: list[int] = []
        for h in header[1:]:
            try:
                col_gpus.append(int(h.strip()))
            except ValueError:
                col_gpus.append(-1)

        for row in reader:
            if not row:
                continue
            try:
                row_gpu = int(row[0].strip())
            except (ValueError, IndexError):
                continue
            for ci, val_str in enumerate(row[1:]):
                if ci >= len(col_gpus):
                    break
                try:
                    val = float(val_str.strip())
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="nvbandwidth_p2p",
                        value=val,
                        unit="GB/s",
                        gpu_index=row_gpu,
                        peer_gpu_index=col_gpus[ci] if col_gpus[ci] >= 0 else None,
                    )
                )
    return metrics


def _extract_nvbandwidth_memcpy(path: str, node: str) -> list[Metric]:
    """Parse nvbandwidth memcpy CSV."""
    metrics: list[Metric] = []
    with open(path) as fh:
        reader = csv.reader(fh)
        header = next(reader, [])
        gpu_indices: list[int] = []
        for h in header[1:]:
            try:
                gpu_indices.append(int(h.strip()))
            except ValueError:
                gpu_indices.append(-1)

        for row in reader:
            if not row:
                continue
            for ci, val_str in enumerate(row[1:]):
                if ci >= len(gpu_indices):
                    break
                try:
                    val = float(val_str.strip())
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="nvbandwidth_memcpy",
                        value=val,
                        unit="GB/s",
                        gpu_index=gpu_indices[ci] if gpu_indices[ci] >= 0 else None,
                    )
                )
    return metrics


def _extract_likwid_metrics(path: str, node: str) -> list[Metric]:
    """Parse likwid-perfctr -O CSV."""
    metrics: list[Metric] = []
    with open(path) as fh:
        reader = csv.reader(fh)
        header = next(reader, [])
        if not header:
            return metrics
        # Find metric columns
        for row in reader:
            if not row:
                continue
            for ci, val_str in enumerate(row):
                if ci >= len(header):
                    break
                try:
                    val = float(val_str.strip())
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name=f"likwid_{header[ci].strip()}",
                        value=val,
                        unit="count",
                    )
                )
    return metrics


def _extract_hpl_metrics(path: str, node: str) -> list[Metric]:
    """Parse HPL stdout: grep 'T/V' for effective Gflops."""
    metrics: list[Metric] = []
    tv_re = re.compile(r"T/V\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)")
    wr_re = re.compile(r"WR00C2R2\s+\S+\s+(\S+)")
    with open(path) as fh:
        for line in fh:
            m = tv_re.search(line)
            if m:
                try:
                    gflops = float(m.group(1))
                except ValueError:
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="hpl_effective_gflops",
                        value=gflops,
                        unit="Gflops",
                    )
                )
            m2 = wr_re.search(line)
            if m2:
                try:
                    gflops = float(m2.group(1))
                except ValueError:
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="hpl_wr_gflops",
                        value=gflops,
                        unit="Gflops",
                    )
                )
    return metrics


def _extract_hpcg_metrics(path: str, node: str) -> list[Metric]:
    """Parse HPCG stdout: grep 'VALID' for rating."""
    metrics: list[Metric] = []
    valid_re = re.compile(r"VALID\s+\S+\s+(\S+)")
    with open(path) as fh:
        for line in fh:
            m = valid_re.search(line)
            if m:
                try:
                    gflops = float(m.group(1))
                except ValueError:
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="hpcg_valid_gflops",
                        value=gflops,
                        unit="Gflops",
                    )
                )
    return metrics


def _extract_cuda_memtest(path: str, node: str, gpu_index: int) -> list[Metric]:
    """Parse cuda-memtest per-GPU log: grep ERROR or PASS."""
    metrics: list[Metric] = []
    pass_count = 0
    error_count = 0
    with open(path) as fh:
        for line in fh:
            if "ERROR" in line.upper():
                error_count += 1
            if "PASS" in line.upper():
                pass_count += 1
    metrics.append(
        Metric(
            node=node,
            metric_name="cuda_memtest_errors",
            value=float(error_count),
            unit="count",
            gpu_index=gpu_index,
        )
    )
    metrics.append(
        Metric(
            node=node,
            metric_name="cuda_memtest_passes",
            value=float(pass_count),
            unit="count",
            gpu_index=gpu_index,
        )
    )
    return metrics


def _extract_transport_info(path: str, node: str, metric_name: str) -> list[Metric]:
    """Parse transport info files (ucx_info, ompi_info, fi_info): count transport lines."""
    line_count = 0
    with open(path) as fh:
        for _line in fh:
            line_count += 1
    return [
        Metric(
            node=node,
            metric_name=metric_name,
            value=float(line_count),
            unit="lines",
        )
    ]


def _extract_torch_distributed(path: str, node: str) -> list[Metric]:
    """Parse torch.distributed framework-comm output: parse wall_time_s from JSON."""
    metrics: list[Metric] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or not line.startswith("result "):
                continue
            # Strip "result " prefix
            json_str = line[len("result "):]
            try:
                data = json.loads(json_str)
            except json.JSONDecodeError:
                continue
            wall_s = data.get("wall_time_s")
            gpu_index = data.get("gpu_index")
            if wall_s is not None:
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="torch_allreduce_wall_time",
                        value=float(wall_s),
                        unit="s",
                        gpu_index=gpu_index,
                    )
                )
    return metrics


# ── Suite dispatcher ────────────────────────────────────────────────────────

SUITES: Final = (
    "node-smoke",
    "ib-pairwise",
    "mpi-collective",
    "hpc-challenge",
    "io",
    "profiling",
    "gpu-stress",
    "transport",
    "frameworks",
)


def _parse_node_smoke(results_dir: str) -> list[Metric]:
    """Parse per-node smoke test results."""
    metrics: list[Metric] = []
    for node_dir in sorted(Path(results_dir).iterdir()):
        if not node_dir.is_dir():
            continue
        node = node_dir.name

        # likwid CSV
        likwid_path = node_dir / "likwid_mem.csv"
        if likwid_path.is_file():
            metrics.extend(_extract_likwid_metrics(str(likwid_path), node))

        # nvbandwidth memcpy and p2p
        nvbw_path = node_dir / "nvbw.csv"
        if nvbw_path.is_file():
            metrics.extend(_extract_nvbandwidth_memcpy(str(nvbw_path), node))
            metrics.extend(_extract_nvbandwidth_p2p(str(nvbw_path), node))

        # per-GPU cuda-memtest
        for gpu_log in sorted(node_dir.glob("cuda_memtest_gpu*.log")):
            m = re.search(r"gpu(\d+)", gpu_log.name)
            gpu_idx = int(m.group(1)) if m else 0
            metrics.extend(_extract_cuda_memtest(str(gpu_log), node, gpu_idx))

    return metrics


def _parse_ib_pairwise(results_dir: str) -> list[Metric]:
    """Parse InfiniBand pairwise results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_pair = run_dir.name  # e.g., "node01,node02"

        for log_file in sorted(run_dir.glob("*.log")):
            suite_name = log_file.stem
            if suite_name.startswith("osu_"):
                metrics.extend(_extract_osu_metrics(str(log_file), node_pair))
            elif suite_name == "qperf":
                pass  # qperf parsing is verbatim; skip for now
            elif suite_name == "ib_write_bw":
                _extract_ib_bw(str(log_file), node_pair, metrics)
            else:
                metrics.extend(
                    _extract_transport_info(str(log_file), node_pair, suite_name)
                )
    return metrics


def _extract_ib_bw(path: str, node: str, metrics: list[Metric]) -> None:
    """Extract bandwidth from ib_write_bw output."""
    with open(path) as fh:
        for line in fh:
            m = re.search(r"(\d+(?:\.\d+)?)\s*Gb/s", line)
            if m:
                try:
                    bw = float(m.group(1))
                except ValueError:
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name="ib_write_bw",
                        value=bw,
                        unit="Gb/s",
                    )
                )
                break


def _parse_mpi_collective(results_dir: str) -> list[Metric]:
    """Parse MPI collective benchmark results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_list = run_dir.name

        for log_file in sorted(run_dir.glob("*.log")):
            fname = log_file.stem
            if fname.startswith("osu_"):
                metrics.extend(_extract_osu_metrics(str(log_file), node_list))
            elif fname.startswith("nccl_"):
                metrics.extend(_extract_nccl_metrics(str(log_file), node_list))
            elif fname.startswith("imb_"):
                _extract_imb(str(log_file), node_list, metrics)
            else:
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, fname)
                )
    return metrics


def _extract_imb(path: str, node: str, metrics: list[Metric]) -> None:
    """Extract IMB benchmark times from stdout."""
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    int(parts[0])  # first column must be a message size
                    t = float(parts[1])
                except (ValueError, IndexError):
                    continue
                metrics.append(
                    Metric(
                        node=node,
                        metric_name=f"imb_{os.path.basename(path).replace('.log', '')}",
                        value=t,
                        unit="usec",
                    )
                )


def _parse_hpc_challenge(results_dir: str) -> list[Metric]:
    """Parse HPC challenge (HPL, HPCG, STREAM, HPL-AI) results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_list = run_dir.name

        for log_file in sorted(run_dir.glob("*.log")):
            fname = log_file.stem
            if fname.startswith("hpl") and "ai" not in fname.lower():
                metrics.extend(_extract_hpl_metrics(str(log_file), node_list))
            elif fname.startswith("hpcg"):
                metrics.extend(_extract_hpcg_metrics(str(log_file), node_list))
            elif fname.startswith("hpl_ai") or "ai" in fname.lower():
                _extract_stream_gflops(str(log_file), node_list, "hpl_ai", metrics)
            elif "stream" in fname.lower():
                _extract_stream_gflops(str(log_file), node_list, "stream", metrics)
            else:
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, fname)
                )
    return metrics


def _extract_stream_gflops(
    path: str, node: str, prefix: str, metrics: list[Metric]
) -> None:
    """Extract Gflops or GB/s from STREAM/HPL-AI output."""
    with open(path) as fh:
        for line in fh:
            m = re.search(r"(\d+(?:\.\d+)?)\s*(Gflops|GB/s|GFLOPS)", line, re.IGNORECASE)
            if m:
                try:
                    val = float(m.group(1))
                except ValueError:
                    continue
                unit = m.group(2).replace("GFLOPS", "Gflops")
                metrics.append(
                    Metric(
                        node=node,
                        metric_name=f"{prefix}_bw",
                        value=val,
                        unit=unit,
                    )
                )


def _parse_io(results_dir: str) -> list[Metric]:
    """Parse I/O benchmark results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_list = run_dir.name

        for log_file in sorted(run_dir.glob("*.log")):
            fname = log_file.stem
            if fname.startswith("ior"):
                metrics.extend(_extract_ior_metrics(str(log_file), node_list))
            else:
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, fname)
                )
    return metrics


def _parse_profiling(results_dir: str) -> list[Metric]:
    """Profiling suite is excluded from outlier analysis.
    Profiler overhead and trace sizes are not hardware-deviation signals.
    """
    return []


def _parse_gpu_stress(results_dir: str) -> list[Metric]:
    """Parse GPU stress test results."""
    metrics: list[Metric] = []
    for node_dir in sorted(Path(results_dir).iterdir()):
        if not node_dir.is_dir():
            continue
        node = node_dir.name

        for gpu_log in sorted(node_dir.glob("cuda_memtest_gpu*.log")):
            m = re.search(r"gpu(\d+)", gpu_log.name)
            gpu_idx = int(m.group(1)) if m else 0
            metrics.extend(_extract_cuda_memtest(str(gpu_log), node, gpu_idx))

    return metrics


def _parse_transport(results_dir: str) -> list[Metric]:
    """Parse transport-layer probe results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_list = run_dir.name

        for log_file in sorted(run_dir.glob("*.txt")):
            fname = log_file.stem
            if fname == "ompi_params":
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, "ompi_params_lines")
                )
            elif fname == "ucx_devices":
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, "ucx_devices_lines")
                )
            elif fname == "ucx_tls":
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, "ucx_tls_lines")
                )
            elif fname == "libfabric_providers":
                metrics.extend(
                    _extract_transport_info(str(log_file), node_list, "libfabric_providers_lines")
                )

        for log_file in sorted(run_dir.glob("*.log")):
            fname = log_file.stem
            if fname == "nccl_transport":
                metrics.extend(_extract_nccl_metrics(str(log_file), node_list))

    return metrics


def _parse_frameworks(results_dir: str) -> list[Metric]:
    """Parse framework-comm validation results."""
    metrics: list[Metric] = []
    for run_dir in sorted(Path(results_dir).iterdir()):
        if not run_dir.is_dir():
            continue
        node_list = run_dir.name

        for log_file in sorted(run_dir.glob("framework_comm_check.log")):
            metrics.extend(_extract_torch_distributed(str(log_file), node_list))

    return metrics


_PARSERS: Final = {
    "node-smoke": _parse_node_smoke,
    "ib-pairwise": _parse_ib_pairwise,
    "mpi-collective": _parse_mpi_collective,
    "hpc-challenge": _parse_hpc_challenge,
    "io": _parse_io,
    "profiling": _parse_profiling,
    "gpu-stress": _parse_gpu_stress,
    "transport": _parse_transport,
    "frameworks": _parse_frameworks,
}


# ── Output ──────────────────────────────────────────────────────────────────


def output_prometheus(
    flags: list[Flag],
    suite: str,
    threshold: float,
    nodes_total: int = 0,
    groups_analyzed: int = 0,
) -> None:
    lines: list[str] = []

    lines.append("# HELP chapar_outlier_zscore Robust z-score of flagged metric (|z| > threshold = outlier)")
    lines.append("# TYPE chapar_outlier_zscore gauge")
    for f in flags:
        labels = f'node="{f.node}",metric="{f.metric_name}",unit="{f.unit}"'
        if f.gpu_index is not None:
            labels += f',gpu="{f.gpu_index}"'
        if f.peer_node is not None:
            labels += f',peer_node="{f.peer_node}"'
        if f.peer_gpu_index is not None:
            labels += f',peer_gpu="{f.peer_gpu_index}"'
        lines.append(f"chapar_outlier_zscore{{{labels}}} {f.zscore}")

    lines.append("")
    lines.append("# HELP chapar_outlier_count Total number of flagged outliers")
    lines.append("# TYPE chapar_outlier_count gauge")
    lines.append(f'chapar_outlier_count{{suite="{suite}",threshold="{threshold}"}} {len(flags)}')

    lines.append("# HELP chapar_outlier_nodes_total Number of nodes analyzed")
    lines.append("# TYPE chapar_outlier_nodes_total gauge")
    lines.append(f'chapar_outlier_nodes_total{{suite="{suite}"}} {nodes_total}')

    lines.append("# HELP chapar_outlier_groups_analyzed Number of metric groups analyzed")
    lines.append("# TYPE chapar_outlier_groups_analyzed gauge")
    lines.append(f'chapar_outlier_groups_analyzed{{suite="{suite}"}} {groups_analyzed}')

    _ = sys.stdout.write("\n".join(lines))
    _ = sys.stdout.write("\n")


def analyze(suite: str, threshold: float, results_dir: str, prometheus: bool = False) -> int:
    """Analyze one suite's results directory and print the report.

    A missing results directory is "no results yet", not an analysis failure:
    it reports on stderr and still exits 0 so a collector can run the analyzer
    unconditionally after every suite.
    """
    if not os.path.isdir(results_dir):
        print(f"ERROR: results directory not found: {results_dir}", file=sys.stderr)
        return 0

    metrics = _PARSERS[suite](results_dir)

    if not metrics:
        if prometheus:
            output_prometheus([], suite, threshold)
        else:
            output: dict[str, object] = {
                "flags": [],
                "summary": {
                    "nodes_total": 0,
                    "flags_total": 0,
                    "threshold": threshold,
                    "groups_analyzed": 0,
                    "warning": "no metrics extracted from results directory",
                },
            }
            json.dump(output, sys.stdout, indent=2)
            _ = sys.stdout.write("\n")
    else:
        flags, summary = compute_flags(metrics, threshold=threshold)
        if prometheus:
            output_prometheus(
                flags,
                suite,
                threshold,
                nodes_total=int(summary.get("nodes_total", 0)),
                groups_analyzed=int(summary.get("groups_analyzed", 0)),
            )
        else:
            json.dump({"flags": flags_to_dicts(flags), "summary": summary}, sys.stdout, indent=2)
            _ = sys.stdout.write("\n")
    return 0
