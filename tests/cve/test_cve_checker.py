"""Tests for `chapar cve scan` bound to a verified release directory."""

from __future__ import annotations

import json
from pathlib import Path

from chapar.cve.github_issues import issue_marker
from chapar.cve.inventory import load_release_inventory, with_config_aliases
from chapar.cve.models import Finding, Package
from tests.conftest import make_release_dir, run_chapar


def test_issue_marker_binds_package_and_cve_for_deduplication() -> None:
    # given
    finding = Finding(
        package=Package("openmpi", "5"),
        source="NVD",
        cve_id="CVE-2026-0001",
        severity="HIGH",
        score=8.1,
        published=None,
        modified=None,
        summary="fixture",
        url="https://example.invalid/CVE-2026-0001",
        references=(),
        evidence="fixture",
    )
    # when
    marker = issue_marker(finding)

    # then
    assert marker == "chapar-cve-checker:v1 package=openmpi cve=CVE-2026-0001"


def test_release_inventory_deduplicates_names_per_distinct_version(tmp_path: Path) -> None:
    release_dir = make_release_dir(
        tmp_path,
        roots=[
            ("openmpi", "5.0.8", "a" * 32),
            ("openmpi", "5.0.8", "b" * 32),
            ("openmpi", "5.0.7", "c" * 32),
            ("ucx", "1.20.1", "d" * 32),
        ],
    )
    packages, policy = load_release_inventory(release_dir)
    assert [(package.name, package.version) for package in packages] == [
        ("openmpi", "5.0.7"),
        ("openmpi", "5.0.8"),
        ("ucx", "1.20.1"),
    ]
    assert policy.as_json() == {
        "software_set": "vlad",
        "target": "linux-x86_64-v4",
        "release_id": "rel-1",
        "run_id": "run-1",
    }


def test_scan_plan_prints_verified_inventory_offline(tmp_path: Path) -> None:
    release_dir = make_release_dir(
        tmp_path,
        roots=[("openmpi", "5.0.8", "a" * 32), ("ucx", "1.20.1", "b" * 32)],
    )
    result = run_chapar("cve", "scan", "--plan", "--release-dir", str(release_dir))
    assert result.exit_code == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["package_count"] == 2
    assert plan["packages"] == ["openmpi@5.0.8", "ucx@1.20.1"]
    assert plan["policy"] == {
        "software_set": "vlad",
        "target": "linux-x86_64-v4",
        "release_id": "rel-1",
        "run_id": "run-1",
    }


def test_scan_refuses_a_tampered_release(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    (release_dir / "spack.lock").write_text(
        json.dumps(
            {
                "_meta": {"file-type": "spack-lockfile", "lockfile-version": 5},
                "roots": [{"hash": "f" * 32, "spec": "forged-package@99"}],
                "concrete_specs": {"f" * 32: {"name": "forged-package", "version": "99"}},
            }
        )
    )
    result = run_chapar("cve", "scan", "--plan", "--release-dir", str(release_dir))
    assert result.exit_code == 2
    assert "release_local_lock_sha256" in result.stderr
    assert "forged-package" not in result.stdout


def test_scan_refuses_a_release_pointer_directory(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    pointer = release_dir.with_name("current")
    release_dir.rename(pointer)
    result = run_chapar("cve", "scan", "--plan", "--release-dir", str(pointer))
    assert result.exit_code == 2
    assert "immutable release, not a pointer" in result.stderr


def test_config_aliases_and_skips_shape_the_scanned_packages() -> None:
    config = {
        "packages": {
            "openmpi": {"aliases": ["Open MPI", "OpenMPI"]},
            "stream": {"skip": True, "reason": "too generic for keyword matching"},
        }
    }
    packages = with_config_aliases(
        [Package("openmpi", "5.0.8", "openmpi@5.0.8"), Package("stream", "5.10", "stream@5.10")],
        config,
    )
    assert [package.name for package in packages] == ["openmpi"]
    assert packages[0].aliases == ("openmpi", "Open MPI", "OpenMPI")
