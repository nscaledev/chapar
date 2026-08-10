"""Unit tests for the MAD-based outlier detector (`chapar validate analyze`)."""

from __future__ import annotations

import dataclasses
import json
import unittest

from chapar.validate.analyze import (
    Metric,
    _robust_zscore,
    compute_flags,
    flags_to_dicts,
)
from tests.conftest import run_chapar


class TestMetricDataclass(unittest.TestCase):
    """Test that Metric dataclass normalises from raw input correctly."""

    def test_basic_metric_creation(self):
        m = Metric(node="node01", metric_name="latency", value=12.5, unit="us")
        self.assertEqual(m.node, "node01")
        self.assertEqual(m.metric_name, "latency")
        self.assertEqual(m.value, 12.5)
        self.assertEqual(m.unit, "us")
        self.assertIsNone(m.gpu_index)
        self.assertIsNone(m.peer_node)
        self.assertIsNone(m.peer_gpu_index)

    def test_metric_with_gpu_index(self):
        m = Metric(
            node="node01",
            metric_name="memtest_errors",
            value=0.0,
            unit="count",
            gpu_index=3,
        )
        self.assertEqual(m.gpu_index, 3)
        self.assertIsNone(m.peer_node)

    def test_metric_with_peer(self):
        m = Metric(
            node="node01",
            metric_name="nvbandwidth_p2p",
            value=50.0,
            unit="GB/s",
            gpu_index=0,
            peer_node="node02",
            peer_gpu_index=1,
        )
        self.assertEqual(m.peer_node, "node02")
        self.assertEqual(m.peer_gpu_index, 1)

    def test_metric_is_frozen(self):
        m = Metric(node="n", metric_name="x", value=1.0, unit="u")
        with self.assertRaises(dataclasses.FrozenInstanceError):
            m.value = 2.0  # type: ignore[misc]


class TestOsuLatencyOutlier(unittest.TestCase):
    """30-row synthetic OSU latency: one row at ~5σ robust z-score."""

    def setUp(self):
        # 30 metrics for a single metric_name/unit group.
        # 29 cluster around 2.0 usec, 1 extreme outlier at 200.0 usec.
        self.metrics = []
        for i in range(29):
            base = 2.0 + 0.1 * (i % 10)  # small jitter: 2.0-2.9
            self.metrics.append(
                Metric(
                    node=f"node{i:02d}",
                    metric_name="osu_latency",
                    value=base,
                    unit="us",
                )
            )
        # Outlier: node29 at 200 usec
        self.metrics.append(
            Metric(
                node="node29",
                metric_name="osu_latency",
                value=200.0,
                unit="us",
            )
        )

    def test_exactly_one_flag_at_threshold_2(self):
        flags, summary = compute_flags(self.metrics, threshold=2.0)
        self.assertEqual(
            len(flags), 1,
            f"Expected exactly 1 flag, got {len(flags)}: {flags}"
        )
        self.assertEqual(flags[0].node, "node29")
        self.assertEqual(flags[0].metric_name, "osu_latency")
        self.assertEqual(flags[0].value, 200.0)
        # Robust z-score should be well above 2.0
        self.assertGreater(abs(flags[0].zscore), 2.0)
        self.assertEqual(summary["flags_total"], 1)
        self.assertGreater(summary["nodes_total"], 0)

    def test_no_flags_at_very_high_threshold(self):
        # The recorded outlier scores a robust z of ~533, so "very high" must
        # sit above that. (The pre-move copy of this test used 50.0 and had
        # always failed; it was never wired into a runner.)
        flags, _ = compute_flags(self.metrics, threshold=1000.0)
        self.assertEqual(len(flags), 0)

    def test_multiple_flags_at_low_threshold(self):
        # At threshold=0.1, even small jitter triggers flags
        flags, _ = compute_flags(self.metrics, threshold=0.1)
        self.assertGreater(len(flags), 1)


class TestNvbandwidthP2PPerGpu(unittest.TestCase):
    """4-node × 8-GPU nvbandwidth p2p matrix: one cell at 5σ."""

    def setUp(self):
        # nvbandwidth runs on one node, tests P2P between its GPUs.
        # So 4 nodes × (8×8=64 pairs) = 256 metrics total.
        self.metrics = []
        # Baseline bandwidth: ~20 GB/s with small deterministic noise
        for node_idx in range(4):
            node_name = f"node{node_idx:02d}"
            for gpu in range(8):
                for peer in range(8):
                    # Self-loop and small jitter
                    bw = 20.0 + 0.5 * ((gpu * 7 + peer * 3) % 10) / 10.0
                    self.metrics.append(
                        Metric(
                            node=node_name,
                            metric_name="nvbandwidth_p2p",
                            value=bw,
                            unit="GB/s",
                            gpu_index=gpu,
                            peer_gpu_index=peer,
                        )
                    )
        # One outlier: node02, gpu_index=3, peer_gpu_index=5 → 200 GB/s
        self.metrics.append(
            Metric(
                node="node02",
                metric_name="nvbandwidth_p2p",
                value=200.0,
                unit="GB/s",
                gpu_index=3,
                peer_gpu_index=5,
            )
        )

    def test_flags_pinpoint_gpu_index_3_and_peer_gpu_index_populated(self):
        flags, _summary = compute_flags(self.metrics, threshold=2.0)
        self.assertEqual(
            len(flags), 1,
            f"Expected exactly 1 flag, got {len(flags)}: {flags}"
        )
        f = flags[0]
        self.assertEqual(f.node, "node02")
        self.assertEqual(f.gpu_index, 3)
        self.assertIsNotNone(f.peer_gpu_index)
        self.assertEqual(f.peer_gpu_index, 5)
        self.assertEqual(f.metric_name, "nvbandwidth_p2p")
        self.assertEqual(f.value, 200.0)
        self.assertGreater(abs(f.zscore), 2.0)

    def test_flags_to_dicts_includes_gpu_and_peer(self):
        flags, _ = compute_flags(self.metrics, threshold=2.0)
        dicts = flags_to_dicts(flags)
        self.assertEqual(len(dicts), 1)
        d = dicts[0]
        self.assertIn("gpu_index", d)
        self.assertIn("peer_gpu_index", d)
        self.assertEqual(d["gpu_index"], 3)
        self.assertEqual(d["peer_gpu_index"], 5)


class TestAllEqualNoDivideByZero(unittest.TestCase):
    """All-equal dataset: no divide-by-zero (MAD fallback)."""

    def test_all_equal_produces_no_flags_and_no_crash(self):
        metrics = [
            Metric(node="node01", metric_name="latency", value=5.0, unit="us")
            for _ in range(50)
        ]
        flags, summary = compute_flags(metrics, threshold=2.0)
        # All equal → median==value → zscore=0 → no flags
        self.assertEqual(len(flags), 0)
        # Should not have crashed
        self.assertEqual(summary["flags_total"], 0)

    def test_robust_zscore_zero_mad_fallback(self):
        # When MAD=0, the fallback 1e-9 is used
        zs = _robust_zscore(5.0, 5.0, 0.0)
        # (5.0 - 5.0) / 1e-9 * 0.6745 = 0
        self.assertEqual(zs, 0.0)

    def test_all_single_value_no_error(self):
        # Single-element group also has MAD=0
        metrics = [Metric(node="x", metric_name="m", value=1.0, unit="u")]
        flags, _ = compute_flags(metrics, threshold=2.0)
        self.assertEqual(len(flags), 0)


class TestJsonOutputWellFormed(unittest.TestCase):
    """Verify JSON output is well-formed."""

    def test_flags_to_dicts_produces_valid_json(self):
        flags, summary = compute_flags(
            [
                Metric(node="n1", metric_name="latency", value=10.0, unit="us"),
                Metric(node="n2", metric_name="latency", value=11.0, unit="us"),
                Metric(node="n3", metric_name="latency", value=9.0, unit="us"),
            ],
            threshold=2.0,
        )
        dicts = flags_to_dicts(flags)
        output = {"flags": dicts, "summary": summary}
        json_str = json.dumps(output)
        # Verify it parses back
        parsed = json.loads(json_str)
        self.assertIn("flags", parsed)
        self.assertIn("summary", parsed)
        self.assertIn("flags_total", parsed["summary"])
        self.assertIn("nodes_total", parsed["summary"])

    def test_empty_metrics_produces_valid_json(self):
        flags, summary = compute_flags([], threshold=2.0)
        dicts = flags_to_dicts(flags)
        output = {"flags": dicts, "summary": summary}
        json_str = json.dumps(output)
        parsed = json.loads(json_str)
        self.assertEqual(parsed["summary"]["flags_total"], 0)
        self.assertEqual(parsed["summary"]["nodes_total"], 0)


class TestRobustZscoreEdgeCases(unittest.TestCase):
    """Edge cases for the robust z-score computation."""

    def test_positive_zscore(self):
        zs = _robust_zscore(100.0, 50.0, 10.0)
        expected = 0.6745 * (100.0 - 50.0) / 10.0
        self.assertAlmostEqual(zs, expected, places=6)

    def test_negative_zscore(self):
        zs = _robust_zscore(0.0, 50.0, 10.0)
        expected = 0.6745 * (0.0 - 50.0) / 10.0
        self.assertAlmostEqual(zs, expected, places=6)

    def test_value_at_median(self):
        zs = _robust_zscore(50.0, 50.0, 10.0)
        self.assertEqual(zs, 0.0)

    def test_very_small_mad(self):
        zs = _robust_zscore(50.0001, 50.0, 1e-10)
        self.assertGreater(abs(zs), 100.0)  # huge z-score for tiny MAD


class TestMultiGroupAggregation(unittest.TestCase):
    """Multiple metric groups are analyzed independently."""

    def test_different_metric_names_not_grouped_together(self):
        metrics = [
            # latency group: all equal
            Metric(node="n1", metric_name="latency", value=10.0, unit="us"),
            Metric(node="n2", metric_name="latency", value=10.0, unit="us"),
            Metric(node="n3", metric_name="latency", value=10.0, unit="us"),
            # bandwidth group: one outlier
            Metric(node="n1", metric_name="bw", value=100.0, unit="MB/s"),
            Metric(node="n2", metric_name="bw", value=100.0, unit="MB/s"),
            Metric(node="n3", metric_name="bw", value=9000.0, unit="MB/s"),
        ]
        flags, summary = compute_flags(metrics, threshold=2.0)
        # Only the bandwidth outlier should be flagged
        self.assertEqual(len(flags), 1)
        self.assertEqual(flags[0].metric_name, "bw")
        self.assertEqual(flags[0].node, "n3")
        self.assertGreater(summary["groups_analyzed"], 1)

    def test_different_units_not_grouped(self):
        metrics = [
            Metric(node="n1", metric_name="bw", value=100.0, unit="MB/s"),
            Metric(node="n2", metric_name="bw", value=100.0, unit="GB/s"),
        ]
        flags, summary = compute_flags(metrics, threshold=2.0)
        # Each is its own group with 1 element → MAD=0 → no flags
        self.assertEqual(len(flags), 0)
        self.assertEqual(summary["groups_analyzed"], 2)


class TestAnalyzeCli(unittest.TestCase):
    """The `chapar validate analyze` surface keeps the outliers.py contract."""

    def test_missing_results_dir_reports_and_exits_zero(self):
        # "No results yet" must not fail a collector that runs unconditionally.
        result = run_chapar(
            "validate", "analyze", "--suite", "node-smoke", "--results-dir", "/nonexistent/results"
        )
        self.assertEqual(result.exit_code, 0, result.stderr)
        self.assertIn("results directory not found", result.stderr)

    def test_empty_results_dir_produces_warning_json(self):
        import tempfile

        with tempfile.TemporaryDirectory() as results_dir:
            result = run_chapar(
                "validate", "analyze", "--suite", "transport", "--results-dir", results_dir
            )
            self.assertEqual(result.exit_code, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["flags"], [])
            self.assertIn("warning", report["summary"])

    def test_prometheus_format_emits_gauges(self):
        import tempfile

        with tempfile.TemporaryDirectory() as results_dir:
            result = run_chapar(
                "validate", "analyze", "--suite", "io", "--results-dir", results_dir, "--prometheus"
            )
            self.assertEqual(result.exit_code, 0, result.stderr)
            self.assertIn('chapar_outlier_count{suite="io"', result.stdout)


if __name__ == "__main__":
    unittest.main()
