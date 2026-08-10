"""Runtime closure of a release lock and its mapping onto installed prefixes.

Read from the release's own spack.lock rather than by shelling out to spack:
the image builder is not necessarily the host that built the release, and the
lock is the immutable record of what was actually installed. Stdlib only.
"""

from __future__ import annotations

from pathlib import Path
from typing import Final

from chapar.common.jsonio import fail, load_json

#: Dependency types that must travel into the image; build-only edges are
#: excluded (registry.INJECTION_POLICY states this as the container contract).
RUNTIME_DEPTYPES: Final = frozenset({"link", "run"})

# The install-tree projection is owned by etc/user/base/config.yaml and rendered
# identically by release.sh. It is currently upstream Spack's default,
# `{architecture.platform}-{architecture.target}/{name}-{version}-{hash}`, so a
# prefix sits one directory below the (placeholder-padded) store root rather than
# directly in it. Search a bounded depth instead of hard-coding that number, so a
# later projection change cannot silently resolve zero prefixes -- which would
# surface as "the release is incomplete for imaging" rather than as a
# configuration mismatch.
PROJECTION_MAX_DEPTH: Final = 4


def runtime_closure(release_dir: Path) -> list[str]:
    """Return the dag hashes of the explicit roots plus their link/run closure."""
    lock = load_json(release_dir / "spack.lock")
    concrete = lock.get("concrete_specs")
    if not isinstance(concrete, dict) or not concrete:
        fail("release spack.lock has no concrete_specs")
    roots = lock.get("roots")
    if not isinstance(roots, list) or not roots:
        fail("release spack.lock has no roots")

    root_hashes: list[str] = []
    for root in roots:
        digest = root.get("hash") if isinstance(root, dict) else None
        if not isinstance(digest, str) or digest not in concrete:
            fail("release spack.lock root does not name a concrete spec")
        root_hashes.append(digest)

    selected: list[str] = []
    seen: set[str] = set()
    queue = list(root_hashes)
    while queue:
        digest = queue.pop()
        if digest in seen:
            continue
        seen.add(digest)
        selected.append(digest)
        node = concrete.get(digest)
        if not isinstance(node, dict):
            fail(f"release spack.lock references an unknown spec hash: {digest}")
        dependencies = node.get("dependencies") or []
        if not isinstance(dependencies, list):
            fail(f"release spack.lock dependencies must be a list: {digest}")
        for edge in dependencies:
            if not isinstance(edge, dict):
                continue
            # Spack has spelled this key both "type" and "deptypes"/"parameters"
            # across versions; accept whichever the lock carries.
            parameters = edge.get("parameters")
            raw = (
                edge.get("type")
                or edge.get("deptypes")
                or (parameters.get("deptypes") if isinstance(parameters, dict) else None)
                or []
            )
            deptypes = {raw} if isinstance(raw, str) else set(raw) if isinstance(raw, list) else set()
            if not deptypes:
                fail(f"release spack.lock dependency edge has no deptype: {digest}")
            if deptypes & RUNTIME_DEPTYPES:
                child = edge.get("hash") or edge.get("id")
                if isinstance(child, str):
                    queue.append(child)
    return selected


def resolve_prefixes(store: Path, hashes: list[str]) -> list[Path]:
    """Map dag hashes to installed prefixes by hash suffix.

    Matching on the hash suffix keeps this projection-agnostic and needs no spack
    invocation. A hash that matches nothing, or more than one prefix, is fatal
    rather than skipped.
    """
    if not store.is_dir():
        fail(f"release store root is not a directory: {store}")
    if store.resolve() != store:
        fail(f"release store root contains a symlink component: {store}")
    # Padded install trees (release.sh detect_padded_length) nest the real
    # prefixes under a chain of __spack_path_placeholder__ directories; the
    # metadata's store field records the unpadded root. Descend to the deepest
    # placeholder before searching, mirroring release.sh.
    while (store / "__spack_path_placeholder__").is_dir():
        store = store / "__spack_path_placeholder__"
    wanted = set(hashes)
    index: dict[str, list[Path]] = {}
    queue: list[tuple[Path, int]] = [(store, 0)]
    while queue:
        parent, depth = queue.pop()
        for entry in sorted(parent.iterdir()):
            if entry.is_symlink():
                fail(f"release store contains a symlinked prefix: {entry}")
            if not entry.is_dir():
                continue
            suffix = entry.name.rsplit("-", 1)[-1]
            if suffix in wanted:
                # A matched prefix is a package installation, never a projection
                # directory: index it and do not walk into it.
                index.setdefault(suffix, []).append(entry)
                continue
            if depth + 1 < PROJECTION_MAX_DEPTH:
                queue.append((entry, depth + 1))
    prefixes: list[Path] = []
    missing: list[str] = []
    for digest in hashes:
        matches = index.get(digest, [])
        if len(matches) > 1:
            fail(f"store has multiple prefixes for hash {digest}")
        if not matches:
            missing.append(digest)
            continue
        prefixes.append(matches[0])
    if missing:
        fail(
            f"{len(missing)} spec(s) in the runtime closure are not installed in "
            f"{store} (first: {missing[0]}). The release is incomplete for imaging."
        )
    return sorted(prefixes)
