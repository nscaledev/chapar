"""Registry parsing/resolution semantics, ported from registry-test.sh, and the
committed-lock validation that replaced validate-locks.sh."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from chapar.common.jsonio import ChaparError
from chapar.image.registry import (
    default_registry_dir,
    parse_containers,
    parse_sources,
    parse_targets,
    require_complete_lock,
    validate_oci_chains,
)
from tests.conftest import REPO_ROOT, run_chapar
from tests.image.helpers import REGISTRY_DIR, make_registry_dir


def resolve_cli(container: str, software_set: str, target: str, registry_dir: Path | None = None):
    arguments = ["image", "resolve", "--container", container, "--software-set", software_set, "--target", target]
    if registry_dir is not None:
        arguments += ["--registry-dir", str(registry_dir)]
    return run_chapar(*arguments)


def test_default_registry_dir_is_committed_registry() -> None:
    assert default_registry_dir() == REPO_ROOT / "containers/images"


def test_resolve_known_tuples(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    expected = {
        ("nvidia-vlad", "vlad", "linux-x86_64-v4"),
        ("nvidia-vlad", "vlad", "linux-aarch64-gb300"),
        ("ubuntu-hpcsim", "hpcsim", "linux-x86_64-generic"),
    }
    for container, software_set, target in expected:
        result = resolve_cli(container, software_set, target, registry)
        assert result.exit_code == 0, result.stderr
        report = json.loads(result.stdout)
        assert report["container"]["id"] == container
        assert report["target"]["id"] == target
        assert report["software_set"] == software_set
        assert report["container"]["source_lock_category"]
        assert report["injection_policy"]["closure_deptypes"] == ["link", "run"]
        assert report["injection_policy"]["prefix_policy"] == "build-time-absolute"
        assert report["injection_policy"]["activation"] == "module-use-opt-in"


def test_resolve_is_deterministic(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    first = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    second = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert first.exit_code == second.exit_code == 0
    assert first.stdout == second.stdout


def test_resolve_works_against_committed_blocked_lock() -> None:
    """Resolution is a registry fact, not a build: the blocked lock is reported,
    not fatal."""
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4")
    assert result.exit_code == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["source_lock"]["status"] == "blocked"
    assert report["source_lock"]["category_state"] == "unresolved"


def _mutate(path: Path, destination: Path, mutate) -> Path:
    document = json.loads(path.read_text())
    mutate(document)
    destination.write_text(json.dumps(document))
    return destination


def test_unknown_target_field_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    _mutate(registry / "targets.json", registry / "targets.json", lambda doc: doc.update(unexpected=True))
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2
    assert not result.stdout


def test_unknown_container_field_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    _mutate(
        registry / "containers.json",
        registry / "containers.json",
        lambda doc: doc["containers"]["nvidia-vlad"].update(unexpected=True),
    )
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_legacy_injection_requirement_blocks_rejected(tmp_path: Path) -> None:
    """The retired per-entry requirement blocks are now unknown fields."""
    registry = make_registry_dir(tmp_path)
    _mutate(
        registry / "containers.json",
        registry / "containers.json",
        lambda doc: doc["containers"]["nvidia-vlad"].update(
            injection_requirements={"closure_deptypes": ["link", "run"]}
        ),
    )
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_duplicate_target_id_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    text = (registry / "targets.json").read_text()
    text = text.replace('"targets": {', '"targets": {\n    "linux-x86_64-v4": {},\n    "linux-x86_64-v4": {},', 1)
    (registry / "targets.json").write_text(text)
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_duplicate_container_id_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    text = (registry / "containers.json").read_text()
    text = text.replace('"containers": {', '"containers": {\n    "nvidia-vlad": {},\n    "nvidia-vlad": {},', 1)
    (registry / "containers.json").write_text(text)
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_unknown_allowed_target_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    _mutate(
        registry / "containers.json",
        registry / "containers.json",
        lambda doc: doc["containers"]["nvidia-vlad"]["allowed_targets"].append("linux-not-real"),
    )
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_unknown_source_category_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    _mutate(
        registry / "containers.json",
        registry / "containers.json",
        lambda doc: doc["containers"]["nvidia-vlad"].update(source_lock_category="not_a_category"),
    )
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-v4", registry)
    assert result.exit_code == 2


def test_floating_base_identity_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    _mutate(
        registry / "containers.json",
        registry / "containers.json",
        lambda doc: doc["containers"]["ubuntu-hpcsim"].update(base_image="ubuntu:latest"),
    )
    result = resolve_cli("ubuntu-hpcsim", "hpcsim", "linux-x86_64-generic", registry)
    assert result.exit_code == 2


def test_unaccepted_software_set_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    result = resolve_cli("nvidia-vlad", "hpcsim", "linux-x86_64-v4", registry)
    assert result.exit_code == 2
    assert "does not accept software set" in result.stderr


def test_no_auto_selection_without_container(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    result = run_chapar(
        "image", "resolve", "--registry-dir", str(registry), "--software-set", "all", "--target", "linux-x86_64-generic"
    )
    assert result.exit_code == 2


def test_inconsistent_oci_descriptor_rejected(tmp_path: Path) -> None:
    registry = make_registry_dir(tmp_path)
    sources = json.loads((registry / "sources-lock.json").read_text())
    sources["verified"]["nvidia_hpc_benchmarks_oci"] = {
        "image": "nvcr.io/nvidia/hpc-benchmarks",
        "tag": "26.02",
        "index_digest": "sha256:" + "1" * 64,
        "platforms": {
            "linux-x86_64-generic": {
                "oci_platform": "linux/amd64",
                "descriptor_digest": "sha256:" + "2" * 64,
                "config_digest": "sha256:" + "3" * 64,
            },
            "linux-x86_64-v4": {
                "oci_platform": "linux/amd64",
                "descriptor_digest": "sha256:" + "4" * 64,
                "config_digest": "sha256:" + "3" * 64,
            },
        },
        "resolved_on": "2026-08-07",
    }
    (registry / "sources-lock.json").write_text(json.dumps(sources))
    result = resolve_cli("nvidia-vlad", "vlad", "linux-x86_64-generic", registry)
    assert result.exit_code == 2
    assert "inconsistent descriptors" in result.stderr


# --- committed registry files (replaces validate-locks.sh's registry coverage) ---


def test_committed_registries_parse_and_chain() -> None:
    targets = parse_targets(REGISTRY_DIR / "targets.json")
    sources = parse_sources(REGISTRY_DIR / "sources-lock.json")
    containers = parse_containers(REGISTRY_DIR / "containers.json", targets, sources)
    validate_oci_chains(sources, targets)
    assert set(containers) == {"nvidia-vlad", "ubuntu-hpcsim"}
    assert set(targets) == {
        "linux-x86_64-generic",
        "linux-x86_64-v4",
        "linux-aarch64-generic",
        "linux-aarch64-gb300",
    }


def test_committed_lock_is_not_complete() -> None:
    """The committed lock is honestly blocked; a build must fail closed on it."""
    lock = json.loads((REGISTRY_DIR / "sources-lock.json").read_text())
    with pytest.raises(ChaparError, match="blocked or incomplete"):
        require_complete_lock(lock)


def test_committed_lock_contract_names_fixed_categories() -> None:
    lock = json.loads((REGISTRY_DIR / "sources-lock.json").read_text())
    from chapar.image.registry import FIXED_LOCK_CATEGORIES

    assert lock["contract"]["required_categories"] == list(FIXED_LOCK_CATEGORIES)


def test_committed_lock_verified_values_are_immutable() -> None:
    from chapar.image.registry import _check_lock_integrity

    lock = json.loads((REGISTRY_DIR / "sources-lock.json").read_text())
    _check_lock_integrity(lock["verified"], "verified")


def test_target_schema_pattern_accepts_registered_ids() -> None:
    targets = json.loads((REGISTRY_DIR / "targets.json").read_text())
    schema = json.loads((REGISTRY_DIR / "targets.schema.json").read_text())
    pattern = schema["properties"]["targets"]["propertyNames"]["pattern"]
    assert pattern == "^[a-z0-9][a-z0-9_-]{0,127}$"
    assert all(re.fullmatch(pattern, target_id) for target_id in targets["targets"])


def test_containers_schema_matches_simplified_entries() -> None:
    schema = json.loads((REGISTRY_DIR / "containers.schema.json").read_text())
    required = schema["$defs"]["container"]["required"]
    assert set(required) == {
        "base_image",
        "source_lock_category",
        "accepted_software_sets",
        "allowed_targets",
        "module_destination",
    }
    assert schema["$defs"]["container"]["additionalProperties"] is False
