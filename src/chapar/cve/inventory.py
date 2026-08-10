"""Package inventory for the CVE scan, bound to a release directory.

The packages to scan are the concrete roots of the release-local spack.lock,
accepted only after full release verification (bytes on disk against the
digests the build recorded in metadata.json). This replaces the selection-era
inventory: there is no ambient selection, digest file, or catalog authority.
Stdlib only.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

from chapar.common.jsonio import JsonObject, JsonValue, fail, unique_object
from chapar.common.release import lock_roots, verify_release
from chapar.cve.models import Package, ReleasePolicy


def read_regular_once(path: Path, label: str) -> bytes:
    """Hardened single read: regular file only, no symlink following."""
    if not path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be absolute without traversal")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot read {label}: {error}")
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            fail(f"{label} must be a regular file")
        return stream.read()


def load_config(path: Path) -> JsonObject:
    """Load the checker configuration through the hardened read path."""
    import json

    payload = read_regular_once(path.resolve(), str(path))
    try:
        data = json.loads(payload, object_pairs_hook=unique_object)
    except json.JSONDecodeError as error:
        fail(f"malformed JSON: {path}: {error.msg}")
    if not isinstance(data, dict):
        fail(f"expected JSON object in {path}")
    return data


def load_release_inventory(release_dir: Path) -> tuple[list[Package], ReleasePolicy]:
    """Verified (packages, identity) for a release directory.

    Root names are deduplicated per distinct version: several concrete roots of
    the same name and version collapse into one scanned package, while the same
    name at different versions is scanned once per version.
    """
    release = verify_release(release_dir)
    policy = ReleasePolicy(
        software_set=release.software_set,
        target=release.target,
        release_id=release.release_id,
        run_id=release.run_id,
    )
    seen: set[tuple[str, str]] = set()
    packages: list[Package] = []
    for name, version, _digest in lock_roots(release.lock_path):
        if (name, version) in seen:
            continue
        seen.add((name, version))
        packages.append(Package(name=name, version=version, spec=f"{name}@{version}"))
    return sorted(packages, key=lambda package: (package.name, package.version or "")), policy


def with_config_aliases(packages: list[Package], config: JsonObject) -> list[Package]:
    package_config: JsonValue = config.get("packages", {})
    if not isinstance(package_config, dict):
        fail("config packages must be an object")
    result: list[Package] = []
    for package in packages:
        raw_settings = package_config.get(package.name, {})
        settings = raw_settings if isinstance(raw_settings, dict) else {}
        if settings.get("skip") is True:
            reason = settings.get("reason", "no reason configured")
            print(f"Skipping {package.label}: {reason}", flush=True)
            continue
        raw_aliases = settings.get("aliases", [])
        aliases = tuple(str(alias) for alias in raw_aliases) if isinstance(raw_aliases, list) else ()
        if package.name not in aliases:
            aliases = (package.name, *aliases)
        result.append(Package(package.name, package.version, package.spec, aliases))
    return result
