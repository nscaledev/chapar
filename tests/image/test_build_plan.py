"""`chapar image build --plan-only` semantics, ported from build-image-plan-test.sh.

Plan mode is pure reads: every case asserts the fixture tree is byte-identical
afterwards and that no external tool was invoked (there are none on PATH that
could hide it: the plan path never shells out).
"""

from __future__ import annotations

import json
from pathlib import Path

from tests.conftest import CommandResult, run_chapar
from tests.image.helpers import ImageFixture, make_image_release, make_registry_dir


def plan(fixture: ImageFixture, registry: Path, *, base: str, target: str, extra: list[str] | None = None) -> CommandResult:
    return run_chapar(
        "image",
        "build",
        "--base",
        base,
        "--target",
        target,
        "--release-dir",
        str(fixture.release_dir),
        "--image-id",
        "fixture-image",
        "--registry-dir",
        str(registry),
        "--plan-only",
        *(extra or []),
    )


def snapshot(root: Path) -> list[tuple[str, float, int]]:
    return sorted((str(p.relative_to(root)), p.lstat().st_mtime, p.lstat().st_size) for p in root.rglob("*"))


def test_plan_nvidia_x86(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    before = snapshot(tmp_path)
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    assert snapshot(tmp_path) == before
    assert "release lock:" in result.stdout
    assert "base:          nvcr.io/nvidia/hpc-benchmarks@sha256:" in result.stdout
    assert "closure:       3 runtime prefixes of 3 closure specs" in result.stdout
    assert "deliver:       modules container" in result.stdout
    assert "artifact:      nvidia-vlad+26.02-linux-x86_64-v4.sqsh" in result.stdout
    # The build-only dependency is excluded from the injection list.
    assert "build-1.0-eeeeffff" not in result.stdout
    assert "gcc-runtime-15.1.0-11112222" in result.stdout


def test_plan_nvidia_arm(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(
        tmp_path, software_set="vlad", target="linux-aarch64-gb300", arch="linux-ubuntu24.04-aarch64"
    )
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-aarch64-gb300")
    assert result.exit_code == 0, result.stderr


def test_plan_ubuntu_generic(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(
        tmp_path, software_set="hpcsim", target="linux-x86_64-generic", arch="linux-ubuntu24.04-x86_64"
    )
    result = plan(fixture, registry, base="ubuntu-hpcsim", target="linux-x86_64-generic")
    assert result.exit_code == 0, result.stderr


def test_wrong_target_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)  # built for linux-x86_64-v4
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-aarch64-gb300")
    assert result.exit_code == 2
    assert "release target does not match" in result.stderr


def test_unaccepted_set_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(
        tmp_path, software_set="hpcsim", target="linux-x86_64-v4", arch="linux-ubuntu24.04-x86_64_v4"
    )
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "software set is not accepted" in result.stderr


def test_union_set_does_not_masquerade(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path, software_set="all")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "software set is not accepted" in result.stderr


def test_tampered_lock_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    with (fixture.release_dir / "spack.lock").open("a") as stream:
        stream.write("tamper\n")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "release_local_lock_sha256" in result.stderr


def test_blocked_committed_lock_refused(tmp_path: Path) -> None:
    """Without --registry-dir the committed, honestly blocked lock applies."""
    fixture = make_image_release(tmp_path)
    result = run_chapar(
        "image",
        "build",
        "--base",
        "nvidia-vlad",
        "--target",
        "linux-x86_64-v4",
        "--release-dir",
        str(fixture.release_dir),
        "--image-id",
        "fixture-image",
        "--plan-only",
    )
    assert result.exit_code == 2
    assert "source lock is not usable" in result.stderr


def test_deliver_gate_refuses_modules_only_release(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path, deliver=["modules"])
    # Plan mode reports the policy without gating on it.
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    assert "deliver:       modules" in result.stdout
    # A real build is gated: refusal happens before any tool or output-path use.
    refused = run_chapar(
        "image",
        "build",
        "--base",
        "nvidia-vlad",
        "--target",
        "linux-x86_64-v4",
        "--release-dir",
        str(fixture.release_dir),
        "--image-id",
        "fixture-image",
        "--registry-dir",
        str(registry),
    )
    assert refused.exit_code == 2
    assert "delivery policy does not include container" in refused.stderr
    assert "--force" in refused.stderr


def test_missing_prefix_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.prefix("runtime-1.0-ccccdddd").rmdir()
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "runtime closure are not installed" in result.stderr


def test_duplicate_prefix_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.prefix("runtime-copy-ccccdddd").mkdir()
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "multiple prefixes" in result.stderr


def test_symlinked_prefix_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.prefix("foreign-ccccdddd").symlink_to(tmp_path)
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "symlinked prefix" in result.stderr


def test_over_deep_prefix_is_incomplete_release(tmp_path: Path) -> None:
    """A prefix buried below the bounded projection search must fail as an
    incomplete release rather than silently resolving zero prefixes."""
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    buried = fixture.store_prefix_dir / "a" / "b" / "c" / "d"
    buried.mkdir(parents=True)
    fixture.prefix("runtime-1.0-ccccdddd").rename(buried / "runtime-1.0-ccccdddd")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "runtime closure are not installed" in result.stderr


def test_missing_gcc_runtime_refused(tmp_path: Path) -> None:
    """Compiler runtime must travel with the release, or libstdc++/libgomp
    resolve against the base image's own -- older than the release's gcc."""
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.prefix("gcc-runtime-15.1.0-11112222").rename(fixture.prefix("other-1.0-11112222"))
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "no gcc-runtime prefix" in result.stderr


def test_elf_clean_reports_audit(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("plain")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    assert "elf audit:     1 dynamic objects" in result.stdout
    assert "requires:      GLIBC_2.38 or newer" in result.stdout


def test_elf_driver_dependency_allowed(tmp_path: Path) -> None:
    """The CUDA driver and NVML are injected at run time by nvidia-container-cli,
    so needing them is correct rather than a broken closure."""
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("driver")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr


def test_elf_closure_resolved_dependency_allowed(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    library = fixture.prefix("runtime-1.0-ccccdddd") / "lib"
    library.mkdir(parents=True)
    (library / "libbar.so.1").touch()
    fixture.add_elf("closure")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr


def test_elf_stub_search_path_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("stubs")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "CUDA stub directory" in result.stderr


def test_elf_runpath_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("runpath")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "DT_RUNPATH instead of DT_RPATH" in result.stderr


def test_elf_unresolved_soname_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("unresolved")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "neither in the closure nor" in result.stderr


def test_elf_glibc_requirement_read_from_release(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.add_elf("newglibc")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    assert "requires:      GLIBC_2.41 or newer" in result.stdout


def test_module_forbidden_variables_refused(tmp_path: Path) -> None:
    """Loading a Chapar module must change the caller's environment and nothing
    else: a process-wide loader or interpreter variable fails closed."""
    registry = make_registry_dir(tmp_path)
    for forbidden in ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME"):
        fixture = make_image_release(tmp_path / forbidden.lower())
        with fixture.module_file().open("a") as stream:
            stream.write(f"prepend-path {forbidden} /opt/chapar/store/lib\n")
        result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
        assert result.exit_code == 2, forbidden
        assert "applies process-wide" in result.stderr


def test_module_comment_is_not_a_setting(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    with fixture.module_file().open("a") as stream:
        stream.write("-- deliberately does not touch LD_LIBRARY_PATH\n")
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    assert "files, opt-in via module load" in result.stdout


def test_empty_module_tree_refused(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    fixture = make_image_release(tmp_path)
    fixture.module_file().unlink()
    result = plan(fixture, registry, base="nvidia-vlad", target="linux-x86_64-v4")
    assert result.exit_code == 2
    assert "no modulefiles" in result.stderr


def test_verify_release_subcommand(tmp_path: Path) -> None:
    fixture = make_image_release(tmp_path)
    result = run_chapar("image", "verify-release", "--release-dir", str(fixture.release_dir))
    assert result.exit_code == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["software_set"] == "vlad"
    assert report["target"] == "linux-x86_64-v4"
    assert report["release_id"] == "rel-1"
    assert report["deliver"] == ["modules", "container"]
