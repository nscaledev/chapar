from __future__ import annotations

import re
from pathlib import Path, PurePosixPath
from typing import Final

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.models import InvocationIdentity, PolicyIdentity
from tools.chapar_datacenter_artifacts import TargetArtifact
from tools.chapar_datacenter_models import SharedPathClass

IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
PROTECTED: Final = PurePosixPath("/resources/chapar")
# Container injection copies each installed store prefix into the image at its
# identical absolute path (containers.json declares
# injection_requirements.prefix_policy: build-time-absolute), so the store root is
# simultaneously a builder path and an in-image path. Confining it to one reserved
# namespace is what makes that safe: /opt/chapar cannot collide with a base
# image's distribution content, and it keeps the path free of site identity, so
# the same release is byte-identical on the builder and inside the .sqsh. A
# contract that selects no container is unconstrained.
CONTAINER_PREFIX: Final = PurePosixPath("/opt/chapar")


def validated_identity(value: str, label: str) -> str:
    if IDENTIFIER.fullmatch(value) is None or value in {".", ".."}:
        raise ResolverError(f"invalid {label}: {value}")
    return value


def relation(left: PurePosixPath, right: PurePosixPath) -> bool:
    return left == right or left in right.parents or right in left.parents


def validate_output_path(path: Path) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise ResolverError("output destination must be absolute without traversal")
    if relation(PurePosixPath(path.as_posix()), PROTECTED):
        raise ResolverError("output destination overlaps protected legacy root")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ResolverError(f"output destination has symlink ambiguity: {current}")
    if path.exists() or path.is_symlink():
        raise ResolverError(f"output destination already exists: {path}")


def _writable_roots(contract: TargetArtifact) -> tuple[tuple[str, str], ...]:
    durable = contract.paths.durable_writable
    temporary = contract.paths.temporary
    return (
        ("install_tree", durable.install_tree),
        ("releases", durable.releases),
        ("modulefiles", durable.modulefiles),
        ("writable_buildcache", durable.writable_buildcache),
        ("ccache", durable.ccache),
        ("container_outputs", durable.container_outputs),
        ("receipts", durable.receipts),
        ("evidence", durable.evidence),
        ("release_staging", temporary.release_staging),
        ("spack_build_stage", temporary.spack_build_stage),
        ("image_staging", temporary.image_staging),
        ("validation_work", temporary.validation_work),
        ("resolver_work", temporary.resolver_work),
    )


def validate_contract_paths(
    contract: TargetArtifact, peers: tuple[TargetArtifact, ...]
) -> None:
    roots = _writable_roots(contract)
    for name, value in roots:
        path = PurePosixPath(value)
        if relation(path, PROTECTED):
            raise ResolverError(f"{name} overlaps protected legacy root")
    releases = PurePosixPath(contract.paths.durable_writable.releases)
    staging = PurePosixPath(contract.paths.temporary.release_staging)
    if staging.parent != releases or staging.name != ".staging":
        raise ResolverError("release staging must be the adjacent .staging child")
    current = dict(roots)
    shared = {item.value for item in contract.sharing.shared_path_classes}
    for peer in peers:
        if peer.target == contract.target:
            continue
        for peer_name, peer_value in _writable_roots(peer):
            for name, value in current.items():
                if not relation(PurePosixPath(value), PurePosixPath(peer_value)):
                    continue
                permitted = (
                    name == peer_name
                    and value == peer_value
                    and name in shared
                    and SharedPathClass(name) in peer.sharing.shared_path_classes
                    and contract.sharing.share_across_targets
                    and peer.sharing.share_across_targets
                )
                if not permitted:
                    raise ResolverError(
                        f"cross-target writable path collision: {name}/{peer_name}"
                    )
    if not contract.sharing.seed_mirrors_read_only:
        raise ResolverError("seed mirrors must remain read-only and cannot publish")
    if contract.container_selections:
        install_tree = PurePosixPath(contract.paths.durable_writable.install_tree)
        if CONTAINER_PREFIX != install_tree and CONTAINER_PREFIX not in install_tree.parents:
            raise ResolverError(
                "a contract selecting a container must place install_tree under "
                f"{CONTAINER_PREFIX}: the store prefix is injected into the image at "
                "its identical absolute path"
            )


def resolved_paths(
    contract: TargetArtifact,
    policy: PolicyIdentity,
    invocation: InvocationIdentity,
) -> tuple[tuple[str, str], ...]:
    namespace = PurePosixPath(
        policy.datacenter, policy.software_set.value, policy.target
    )
    shared_components = [str(policy.datacenter)]
    if not contract.sharing.share_across_software_sets:
        shared_components.append(policy.software_set.value)
    if not contract.sharing.share_across_targets:
        shared_components.append(str(policy.target))
    shared_namespace = PurePosixPath(*shared_components)
    release_id = validated_identity(invocation.release_id, "release ID")
    run_id = validated_identity(invocation.run_id, "run ID")
    durable = contract.paths.durable_writable
    temporary = contract.paths.temporary
    paths = (
        ("release_root", str(PurePosixPath(durable.releases) / namespace)),
        ("release_final", str(PurePosixPath(durable.releases) / namespace / release_id)),
        ("release_staging", str(PurePosixPath(temporary.release_staging) / namespace / f"{release_id}.{run_id}")),
        ("modulefiles", str(PurePosixPath(durable.modulefiles) / namespace / release_id)),
        ("install_tree", str(PurePosixPath(durable.install_tree) / shared_namespace)),
        ("writable_buildcache", str(PurePosixPath(durable.writable_buildcache) / shared_namespace)),
        ("ccache", str(PurePosixPath(durable.ccache) / shared_namespace)),
        ("container_outputs", str(PurePosixPath(durable.container_outputs) / namespace / release_id)),
        ("receipts", str(PurePosixPath(durable.receipts) / namespace / release_id)),
        ("evidence", str(PurePosixPath(durable.evidence) / namespace / run_id)),
        ("spack_build_stage", str(PurePosixPath(temporary.spack_build_stage) / namespace / run_id)),
        ("image_staging", str(PurePosixPath(temporary.image_staging) / namespace / run_id)),
        ("validation_work", str(PurePosixPath(temporary.validation_work) / namespace / run_id)),
        ("resolver_work", str(PurePosixPath(temporary.resolver_work) / namespace / run_id)),
    )
    for name, value in paths:
        base_name = name if name in dict(_writable_roots(contract)) else name.split("_final")[0]
        if name == "release_root" or name == "release_final":
            base_name = "releases"
        base = dict(_writable_roots(contract)).get(base_name)
        if base is not None and PurePosixPath(base) not in PurePosixPath(value).parents:
            raise ResolverError(f"derived {name} escapes its declared root")
    return paths
