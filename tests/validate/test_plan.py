"""`chapar validate plan` and validation/run bind to one immutable release."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT, make_release_dir, run_chapar

MODULE_ARCH = "linux-ubuntu24.04-x86_64"


@pytest.fixture
def validation_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Site settings as the shell callers would export them."""
    root = tmp_path / "validation-results"
    monkeypatch.setenv("CHAPAR_VALIDATION_ROOT", str(root))
    monkeypatch.setenv("CHAPAR_SLURM_PARTITION", "gpu")
    monkeypatch.setenv("CHAPAR_SLURM_CONSTRAINT", "h100")
    monkeypatch.setenv("CHAPAR_SLURM_ACCOUNT", "hpc")
    monkeypatch.setenv("CHAPAR_SLURM_QOS", "normal")
    return root


def test_plan_renders_release_facts(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(
        tmp_path, roots=[("ucx", "1.20.1", "b" * 32), ("openmpi", "5.0.8", "c" * 32)]
    )
    result = run_chapar(
        "validate", "plan", "--release-dir", str(release_dir), "--test", "module-smoke", "--run-id", "run-v1"
    )
    assert result.exit_code == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["action"] == "dry-run"
    assert plan["test"] == "module-smoke"
    assert plan["software_set"] == "vlad"
    assert plan["target"] == "linux-x86_64-v4"
    assert plan["release_id"] == "rel-1"
    assert plan["release_run_id"] == "run-1"
    assert plan["release_dir"] == str(release_dir)
    assert plan["module_path"] == str(release_dir / "modulefiles" / MODULE_ARCH)
    assert plan["results_root"] == str(validation_root / "vlad/linux-x86_64-v4/rel-1/run-v1")
    assert (plan["partition"], plan["constraint"], plan["account"], plan["qos"]) == ("gpu", "h100", "hpc", "normal")
    assert plan["root_count"] == 2
    assert {check["module"] for check in plan["checks"]} == {"ucx", "openmpi"}
    assert len(plan["release_lock_sha256"]) == 64


def test_shell_and_checks_formats(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(
        tmp_path, roots=[("ucx", "1.20.1", "b" * 32), ("libvips", "8.15.2", "d" * 32)]
    )
    shell = run_chapar(
        "validate", "plan", "--format", "shell",
        "--release-dir", str(release_dir), "--test", "integrity-test", "--run-id", "run-v1",
    )
    assert shell.exit_code == 0, shell.stderr
    fields = shell.stdout.rstrip("\n").split("\t")
    assert fields == [
        "vlad",
        "linux-x86_64-v4",
        "rel-1",
        "run-1",
        str(release_dir / "modulefiles" / MODULE_ARCH),
        str(validation_root / "vlad/linux-x86_64-v4/rel-1/run-v1"),
    ]

    checks = run_chapar(
        "validate", "plan", "--format", "checks", "--release-dir", str(release_dir), "--run-id", "run-v1"
    )
    assert checks.exit_code == 0, checks.stderr
    lines = checks.stdout.rstrip("\n").split("\n")
    # Known roots get a root-specific command; unknown ones fall back to module show.
    assert lines[0] == "ucx\tucx_info -v\tucx_info runs"
    assert lines[1] == "libvips\tmodule show libvips\tlibvips module"


def test_results_root_override_wins_without_site_settings(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("CHAPAR_VALIDATION_ROOT", raising=False)
    release_dir = make_release_dir(tmp_path)
    override = tmp_path / "elsewhere"
    result = run_chapar(
        "validate", "plan", "--release-dir", str(release_dir),
        "--results-root", str(override), "--run-id", "run-v1",
    )
    assert result.exit_code == 0, result.stderr
    assert json.loads(result.stdout)["results_root"] == str(override)


def test_missing_validation_root_is_refused(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CHAPAR_VALIDATION_ROOT", raising=False)
    release_dir = make_release_dir(tmp_path)
    result = run_chapar("validate", "plan", "--release-dir", str(release_dir))
    assert result.exit_code != 0
    assert "CHAPAR_VALIDATION_ROOT" in result.stderr


def test_tampered_release_is_refused(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    (release_dir / "spack.lock").write_text('{"roots": [], "concrete_specs": {}}')
    result = run_chapar("validate", "plan", "--release-dir", str(release_dir))
    assert result.exit_code != 0
    assert "release_local_lock_sha256" in result.stderr


def test_promotion_pointer_is_refused(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    renamed = release_dir.with_name("current")
    release_dir.rename(renamed)
    result = run_chapar("validate", "plan", "--release-dir", str(renamed))
    assert result.exit_code != 0
    assert "pointer" in result.stderr


@pytest.mark.parametrize("shape", ["none", "two"])
def test_release_without_one_module_arch_is_refused(
    tmp_path: Path, validation_root: Path, shape: str
) -> None:
    release_dir = make_release_dir(tmp_path)
    if shape == "none":
        (release_dir / "modulefiles" / MODULE_ARCH).rmdir()
    else:
        (release_dir / "modulefiles" / "linux-ubuntu24.04-aarch64").mkdir()
    result = run_chapar("validate", "plan", "--release-dir", str(release_dir))
    assert result.exit_code != 0
    assert "exactly one module architecture" in result.stderr


def test_unknown_test_name_is_refused(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    result = run_chapar("validate", "plan", "--release-dir", str(release_dir), "--test", "no-such-suite")
    assert result.exit_code != 0
    assert "unknown validation test" in result.stderr


def test_seal_dir_records_read_only_evidence(tmp_path: Path, validation_root: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    seal = tmp_path / "sealed"
    seal.mkdir()
    result = run_chapar(
        "validate", "plan", "--release-dir", str(release_dir), "--run-id", "run-v1", "--seal-dir", str(seal)
    )
    assert result.exit_code == 0, result.stderr
    for name in ("metadata.json", "spack.lock"):
        sealed = seal / name
        assert sealed.read_bytes() == (release_dir / name).read_bytes()
        assert (sealed.stat().st_mode & 0o777) == 0o400
    # Sealing is O_EXCL: an existing copy is never silently replaced.
    again = run_chapar(
        "validate", "plan", "--release-dir", str(release_dir), "--run-id", "run-v1", "--seal-dir", str(seal)
    )
    assert again.exit_code != 0
    assert "seal" in again.stderr


# ---------------------------------------------------------------- validation/run --


def run_dispatcher(release_dir: Path, tmp_path: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run ./validation/run hermetically: no site file, poisoned scheduler PATH."""
    poison = tmp_path / "poison-bin"
    poison.mkdir(exist_ok=True)
    marker = tmp_path / "invoked"
    for name in ("sbatch", "srun", "module", "spack"):
        script = poison / name
        script.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 97\n", encoding="utf-8")
        script.chmod(0o755)
    site_config = tmp_path / "site.env"
    site_config.touch()
    env = {
        **os.environ,
        "CHAPAR_DRY_RUN": "1",
        "CHAPAR_SITE_CONFIG": str(site_config),
        "CHAPAR_VALIDATION_ROOT": str(tmp_path / "validation-results"),
        "PATH": f"{poison}:{os.environ['PATH']}",
    }
    return subprocess.run(
        [str(REPO_ROOT / "validation/run"), "--release-dir", str(release_dir), *arguments],
        cwd=REPO_ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=300,
    )


def test_run_dry_run_all_plans_every_suite_without_a_scheduler(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    result = run_dispatcher(release_dir, tmp_path, "all")
    assert result.returncode == 0, result.stderr
    for suite in sorted(path.stem for path in (REPO_ROOT / "validation/tests").glob("*.sbatch")):
        assert f"=== {suite} ===" in result.stdout
        assert f'"test": "{suite}"' in result.stdout
    assert not (tmp_path / "invoked").exists()


def test_run_dry_run_single_test_renders_the_plan(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    result = run_dispatcher(release_dir, tmp_path, "module-smoke")
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["test"] == "module-smoke"
    assert plan["release_dir"] == str(release_dir)
    assert not (tmp_path / "invoked").exists()


def test_run_resolves_a_current_pointer_to_the_release(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    pointer = tmp_path / "current"
    pointer.symlink_to(release_dir)
    result = run_dispatcher(pointer, tmp_path, "module-smoke")
    assert result.returncode == 0, result.stderr
    # The plan binds to the concrete immutable release, never the pointer.
    assert json.loads(result.stdout)["release_dir"] == str(release_dir)


def test_run_refuses_unknown_test_and_obsolete_env_name(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    unknown = run_dispatcher(release_dir, tmp_path, "no-such-suite")
    assert unknown.returncode == 2
    assert "Unknown test" in unknown.stderr

    site_config = tmp_path / "site.env"
    site_config.touch()
    poisoned = subprocess.run(
        [str(REPO_ROOT / "validation/run"), "--release-dir", str(release_dir), "module-smoke"],
        cwd=REPO_ROOT,
        env={**os.environ, "CHAPAR_DRY_RUN": "1", "CHAPAR_SITE_CONFIG": str(site_config), "ENV_NAME": "poison"},
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert poisoned.returncode == 2
    assert "ENV_NAME" in poisoned.stderr


def test_run_dry_run_refuses_a_tampered_release(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    (release_dir / "spack.lock").write_text('{"roots": [], "concrete_specs": {}}')
    result = run_dispatcher(release_dir, tmp_path, "module-smoke")
    assert result.returncode != 0
    assert "release_local_lock_sha256" in result.stderr
