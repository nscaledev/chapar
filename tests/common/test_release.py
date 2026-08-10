"""Tests for the release-directory model and verification."""

from __future__ import annotations

from pathlib import Path

import pytest

from chapar.common.jsonio import ChaparError
from chapar.common.release import load_release, lock_roots, verify_release
from tests.conftest import make_release_dir


def test_verify_valid_release(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path, deliver=["modules", "container"])
    release = verify_release(release_dir)
    assert release.software_set == "vlad"
    assert release.target == "linux-x86_64-v4"
    assert release.deliver == ("modules", "container")
    assert release.target_facts["spack_target"] == "x86_64_v4"


def test_tampered_lock_is_rejected(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    (release_dir / "spack.lock").write_text("{}")
    with pytest.raises(ChaparError, match="release_local_lock_sha256"):
        verify_release(release_dir)


def test_pointer_named_directory_is_rejected(tmp_path: Path) -> None:
    release_dir = make_release_dir(tmp_path)
    renamed = release_dir.with_name("current")
    release_dir.rename(renamed)
    with pytest.raises(ChaparError, match="immutable release, not a pointer"):
        verify_release(renamed)


def test_diverged_target_facts_are_rejected(tmp_path: Path) -> None:
    release_dir = make_release_dir(
        tmp_path, metadata_overrides={"target_facts.cuda_arch": ["75"]}
    )
    with pytest.raises(ChaparError, match="target facts diverge"):
        verify_release(release_dir)


def test_unknown_schema_is_rejected(tmp_path: Path) -> None:
    release_dir = make_release_dir(
        tmp_path, metadata_overrides={"schema_version": 1}
    )
    with pytest.raises(ChaparError, match="unsupported release metadata schema"):
        load_release(release_dir)


def test_lock_roots_reports_concrete_roots(tmp_path: Path) -> None:
    release_dir = make_release_dir(
        tmp_path,
        roots=[("ucx", "1.20.1", "b" * 32), ("openmpi", "5.0.8", "c" * 32)],
    )
    roots = lock_roots(release_dir / "spack.lock")
    assert roots == (("ucx", "1.20.1", "b" * 32), ("openmpi", "5.0.8", "c" * 32))
