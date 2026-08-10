"""Release-directory model and verification.

An immutable release directory is the unit every downstream consumer (image
injection, validation, CVE scanning) binds to. Its self-description is
metadata.json (schema v2) plus the release-local spack.lock; verification here
is release-local: bytes on disk against the digests the build recorded, and
recorded target facts against the committed registry. Stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from chapar.common.jsonio import JsonObject, fail, load_json, mapping, string, strings

METADATA_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/release-metadata/v2"
IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SOFTWARE_SETS: Final = ("vlad", "hpcsim", "all")
ROOT_KEYS: Final = (
    "release_root",
    "release_final",
    "release_staging",
    "modulefiles",
    "install_tree",
    "writable_buildcache",
    "ccache",
    "spack_build_stage",
)
DIGEST_KEYS: Final = (
    "software_catalog_sha256",
    "target_registry_sha256",
    "target_scope_sha256",
    "release_local_lock_sha256",
)
_DIGEST_RE: Final = re.compile(r"^[0-9a-f]{64}$")

#: release file whose bytes each digest key must match
DIGEST_FILES: Final = {
    "software_catalog_sha256": "spack.yaml",
    "target_scope_sha256": "target-scope.yaml",
    "release_local_lock_sha256": "spack.lock",
}


@dataclass(frozen=True, slots=True)
class Release:
    directory: Path
    software_set: str
    target: str
    release_id: str
    run_id: str
    target_facts: JsonObject
    roots: dict[str, str]
    digests: dict[str, str]
    deliver: tuple[str, ...]
    module_systems: tuple[str, ...]
    publish_buildcache: bool
    lock_sha256: str

    @property
    def lock_path(self) -> Path:
        return self.directory / "spack.lock"

    @property
    def metadata_path(self) -> Path:
        return self.directory / "metadata.json"


def sha256_file(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        fail(f"cannot read {path}: {error}")


def load_release(directory: Path) -> Release:
    """Parse and structurally validate a release directory's metadata."""
    directory = directory.resolve()
    metadata_path = directory / "metadata.json"
    if not metadata_path.is_file():
        fail(f"release has no metadata.json: {directory}")
    document = load_json(metadata_path)
    if document.get("schema") != METADATA_SCHEMA or document.get("schema_version") != 2:
        fail(f"unsupported release metadata schema: {document.get('schema')}")

    identity = mapping(document.get("identity"), "metadata.identity")
    software_set = string(identity.get("software_set"), "identity.software_set")
    target = string(identity.get("target"), "identity.target")
    release_id = string(identity.get("release_id"), "identity.release_id")
    run_id = string(identity.get("run_id"), "identity.run_id")
    if software_set not in SOFTWARE_SETS:
        fail(f"unknown software set: {software_set}")
    for label, value in (("target", target), ("release_id", release_id), ("run_id", run_id)):
        if not IDENTIFIER.fullmatch(value):
            fail(f"invalid identity.{label}: {value}")

    roots_raw = mapping(document.get("roots"), "metadata.roots")
    if set(roots_raw) != set(ROOT_KEYS):
        fail("metadata.roots has missing or unknown fields")
    roots = {key: string(value, f"roots.{key}") for key, value in roots_raw.items()}

    digests_raw = mapping(document.get("digests"), "metadata.digests")
    if set(digests_raw) != set(DIGEST_KEYS):
        fail("metadata.digests has missing or unknown fields")
    digests = {key: string(value, f"digests.{key}") for key, value in digests_raw.items()}
    for key, value in digests.items():
        if not _DIGEST_RE.fullmatch(value):
            fail(f"invalid digest: {key}")

    policy = mapping(document.get("policy"), "metadata.policy")
    deliver = strings(policy.get("deliver"), "policy.deliver")
    module_systems = strings(policy.get("module_systems"), "policy.module_systems")
    publish_buildcache = policy.get("publish_buildcache")
    if not isinstance(publish_buildcache, bool):
        fail("policy.publish_buildcache must be a boolean")

    return Release(
        directory=directory,
        software_set=software_set,
        target=target,
        release_id=release_id,
        run_id=run_id,
        target_facts=mapping(document.get("target_facts"), "metadata.target_facts"),
        roots=roots,
        digests=digests,
        deliver=deliver,
        module_systems=module_systems,
        publish_buildcache=publish_buildcache,
        lock_sha256=digests["release_local_lock_sha256"],
    )


def verify_release(directory: Path, *, targets_registry: Path | None = None) -> Release:
    """Full release-local verification.

    Checks: file bytes against every recorded digest, directory identity (the
    verified directory is the immutable release, not a mutable pointer), and
    recorded target facts against the committed registry.
    """
    from chapar.target.scope import default_targets_path, load_targets

    release = load_release(directory)
    if release.directory.name != release.release_id:
        fail(
            "release directory name does not match its recorded release_id "
            f"({release.directory.name} != {release.release_id}); verify the "
            "immutable release, not a pointer"
        )
    for digest_key, file_name in DIGEST_FILES.items():
        path = release.directory / file_name
        if not path.is_file():
            fail(f"release is missing {file_name}")
        actual = sha256_file(path)
        if actual != release.digests[digest_key]:
            fail(f"release {file_name} does not match recorded {digest_key}")

    # The registry may legitimately move ahead of an old release, so its digest
    # is recorded but not enforced; the facts equality check below is binding.
    registry_path = targets_registry if targets_registry is not None else default_targets_path()
    targets = load_targets(registry_path)
    facts = targets.get(release.target)
    if facts is None:
        fail(f"release target is no longer registered: {release.target}")
    recorded = release.target_facts
    current = {
        "oci_platform": facts.oci_platform,
        "native_arch": facts.native_arch,
        "spack_target": facts.spack_target,
        "llvm_targets": list(facts.llvm_targets),
        "cuda_arch": list(facts.cuda_arch),
    }
    if recorded != current:
        fail(f"release target facts diverge from the registry for {release.target}")
    return release


def lock_roots(lock_path: Path) -> tuple[tuple[str, str, str], ...]:
    """(name, version, hash) for each concrete root in a spack.lock."""
    try:
        document = json.loads(lock_path.read_bytes())
    except OSError as error:
        fail(f"cannot read {lock_path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"malformed spack.lock: {error.msg}")
    if not isinstance(document, dict):
        fail("spack.lock must be an object")
    concrete = document.get("concrete_specs")
    roots = document.get("roots")
    if not isinstance(concrete, dict) or not isinstance(roots, list):
        fail("spack.lock has no concrete roots")
    result: list[tuple[str, str, str]] = []
    for root in roots:
        if not isinstance(root, dict):
            fail("spack.lock root entries must be objects")
        digest = root.get("hash")
        if not isinstance(digest, str) or not digest:
            fail("spack.lock root entry has no hash")
        node = concrete.get(digest)
        if not isinstance(node, dict):
            fail(f"spack.lock root hash has no concrete spec: {digest}")
        name = node.get("name")
        version = node.get("version")
        if not isinstance(name, str) or not isinstance(version, str):
            fail(f"spack.lock concrete spec has no name/version: {digest}")
        result.append((name, version, digest))
    if not result:
        fail("spack.lock has no concrete roots")
    return tuple(result)
