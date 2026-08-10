"""Tests for `chapar target scope|list` and the requirements-scope renderer."""

from __future__ import annotations

import json
from pathlib import Path

import yaml

from tests.conftest import run_chapar

ALL_CUDA = "80,86,87,89,90,90a,100,103,110,120,121"


def registry(tmp_path: Path, targets: dict) -> Path:
    path = tmp_path / "targets.json"
    path.write_text(
        json.dumps(
            {
                "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-targets/v1",
                "schema_version": 1,
                "targets": targets,
            }
        ),
        encoding="utf-8",
    )
    return path


def test_scope_renders_committed_registry_targets() -> None:
    result = run_chapar("target", "scope", "--target", "linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    document = yaml.safe_load(result.stdout)
    packages = document["packages"]
    assert packages["all"]["require"] == ["target=x86_64_v4"]
    assert packages["llvm"]["require"] == ["targets=x86,nvptx"]
    # Bare requirement for unconditional CUDA packages; the transitive binding
    # (gdrcopy under ucx) is the whole reason this is a requirement scope.
    assert packages["gdrcopy"]["require"] == [f"cuda_arch={ALL_CUDA}"]
    # Conditional requirement for optional-CUDA packages.
    assert packages["ucx"]["require"] == [{"spec": f"cuda_arch={ALL_CUDA}", "when": "+cuda"}]


def test_scope_gb300_narrows_cuda_arch() -> None:
    result = run_chapar("target", "scope", "--target", "linux-aarch64-gb300")
    assert result.exit_code == 0, result.stderr
    document = yaml.safe_load(result.stdout)
    assert document["packages"]["all"]["require"] == ["target=aarch64"]
    assert document["packages"]["nccl"]["require"] == ["cuda_arch=103"]


def test_scope_writes_output_directory(tmp_path: Path) -> None:
    output = tmp_path / "scope"
    result = run_chapar("target", "scope", "--target", "linux-aarch64-generic", "--output", str(output))
    assert result.exit_code == 0, result.stderr
    rendered = (output / "packages.yaml").read_text(encoding="utf-8")
    assert yaml.safe_load(rendered)["packages"]["all"]["require"] == ["target=aarch64"]


def test_unknown_target_is_rejected() -> None:
    result = run_chapar("target", "scope", "--target", "linux-riscv64-generic")
    assert result.exit_code != 0
    assert "unknown target" in result.stderr
    assert "linux-x86_64-v4" in result.stderr, "error should list registered targets"


def test_unknown_registry_field_is_rejected(tmp_path: Path) -> None:
    path = registry(
        tmp_path,
        {
            "linux-x86_64-generic": {
                "oci_platform": "linux/amd64",
                "native_arch": "x86_64",
                "spack_target": "x86_64",
                "llvm_targets": ["x86"],
                "cuda_arch": ["90"],
                "surprise": True,
            }
        },
    )
    result = run_chapar("target", "scope", "--target", "linux-x86_64-generic", "--targets", str(path))
    assert result.exit_code != 0
    assert "unknown fields" in result.stderr


def test_target_list_reports_all_registered_targets() -> None:
    result = run_chapar("target", "list")
    assert result.exit_code == 0, result.stderr
    targets = json.loads(result.stdout)
    assert sorted(targets) == [
        "linux-aarch64-gb300",
        "linux-aarch64-generic",
        "linux-x86_64-generic",
        "linux-x86_64-v4",
    ]
    assert targets["linux-aarch64-gb300"]["cuda_arch"] == ["103"]
