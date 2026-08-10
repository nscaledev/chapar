from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True, slots=True)
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str


def run_chapar(*arguments: str, timeout: int = 30) -> CommandResult:
    """Run the installed CLI exactly as an operator would."""
    completed = subprocess.run(
        [sys.executable, "-m", "chapar", *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=REPO_ROOT,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


@pytest.fixture
def repo_root() -> Path:
    return REPO_ROOT


def make_release_dir(
    parent: Path,
    *,
    software_set: str = "vlad",
    target: str = "linux-x86_64-v4",
    release_id: str = "rel-1",
    run_id: str = "run-1",
    roots: list[tuple[str, str, str]] | None = None,
    deliver: list[str] | None = None,
    metadata_overrides: dict | None = None,
) -> Path:
    """Create a structurally valid release directory with consistent digests.

    `roots` entries are (name, version, hash) concrete roots for the synthetic
    spack.lock. Digest fields are computed from the bytes actually written, so
    verification passes unless a test tampers afterwards.
    """
    import hashlib
    import json

    directory = parent / release_id
    directory.mkdir(parents=True)
    lock_roots = roots or [("zlib-ng", "2.2.1", "a" * 32)]
    lock = {
        "_meta": {"file-type": "spack-lockfile", "lockfile-version": 5},
        "roots": [{"hash": digest, "spec": f"{name}@{version}"} for name, version, digest in lock_roots],
        "concrete_specs": {
            digest: {"name": name, "version": version, "arch": {"platform": "linux"}}
            for name, version, digest in lock_roots
        },
    }
    lock_bytes = json.dumps(lock, indent=2).encode()
    (directory / "spack.lock").write_bytes(lock_bytes)
    catalog_bytes = b"spack:\n  specs: []\n"
    (directory / "spack.yaml").write_bytes(catalog_bytes)
    scope_bytes = b"packages:\n  all:\n    require:\n    - \"target=x86_64_v4\"\n"
    (directory / "target-scope.yaml").write_bytes(scope_bytes)

    registry = json.loads((REPO_ROOT / "containers/images/targets.json").read_text())
    facts = registry["targets"][target]
    env_root = str(parent)
    metadata = {
        "schema": "https://nscaledev.github.io/chapar/schemas/release-metadata/v2",
        "schema_version": 2,
        "identity": {
            "software_set": software_set,
            "target": target,
            "release_id": release_id,
            "run_id": run_id,
        },
        "target_facts": facts,
        "roots": {
            "release_root": env_root,
            "release_final": str(directory),
            "release_staging": f"{env_root}/.staging/{release_id}.{run_id}",
            "modulefiles": f"{env_root}/modulefiles/{software_set}/{target}/{release_id}",
            "install_tree": f"{env_root}/store",
            "writable_buildcache": f"{env_root}/cache/buildcache/{target}",
            "ccache": f"{env_root}/cache/ccache/{target}",
            "spack_build_stage": f"/tmp/chapar-stage/{software_set}/{target}/{release_id}.{run_id}",
        },
        "digests": {
            "software_catalog_sha256": hashlib.sha256(catalog_bytes).hexdigest(),
            "target_registry_sha256": hashlib.sha256(
                (REPO_ROOT / "containers/images/targets.json").read_bytes()
            ).hexdigest(),
            "target_scope_sha256": hashlib.sha256(scope_bytes).hexdigest(),
            "release_local_lock_sha256": hashlib.sha256(lock_bytes).hexdigest(),
        },
        "policy": {
            "publish_buildcache": False,
            "buildcache_signed": False,
            "buildcache_autopush": False,
            "deliver": deliver or ["modules"],
            "module_systems": ["tcl"],
        },
    }
    if metadata_overrides:
        for key, value in metadata_overrides.items():
            node = metadata
            parts = key.split(".")
            for part in parts[:-1]:
                node = node[part]
            node[parts[-1]] = value
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    # A generated module tree with exactly one architecture directory.
    (directory / "modulefiles" / "linux-ubuntu24.04-x86_64").mkdir(parents=True)
    return directory
