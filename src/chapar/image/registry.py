"""Strict, side-effect-free parsers for the Chapar target/container registries.

targets.json owns architecture facts, containers.json owns injection
compatibility, and sources-lock.json owns digest-pinned source custody. Every
parser rejects unknown fields, duplicate keys, and identity drift instead of
guessing. Stdlib only.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from chapar.common.jsonio import JsonObject, JsonValue, fail, unique_object

TARGET_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/vlad-image-targets/v1"
CONTAINER_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/vlad-image-containers/v1"
IDENTITY: Final = re.compile(r"^[a-z0-9][a-z0-9-]{0,127}$")
TARGET_ID: Final = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
CATEGORY: Final = re.compile(r"^[a-z][a-z0-9_]{0,127}$")
BASE_IMAGE: Final = re.compile(r"^[a-z0-9][a-z0-9./-]{0,255}$")
CUDA_ARCH: Final = re.compile(r"^[0-9]+a?$")
OCI_DIGEST: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_HEX: Final = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT: Final = re.compile(r"^[0-9a-f]{40}$")

# Injection and runtime policy is code, not registry data: containers.json used
# to restate these as per-entry requirement blocks that the parser rejected on
# any deviation, so they were assertions that the registry matched the code.
# They now live here as the single statement of that contract:
# - the injected closure is the explicit roots plus link/run dependencies
#   (closure.RUNTIME_DEPTYPES walks exactly that);
# - injection is additive and preserves the base image's own environment
#   (rootfs.assert_base_undisturbed proves it per build);
# - prefixes are copied to their build-time absolute paths because Spack embeds
#   absolute RPATHs (enroot.inject);
# - activation is module-use opt-in, never a PATH/LD_LIBRARY_PATH prepend
#   (enroot.inject's profile script and rootfs.assert_modules_are_opt_in).
INJECTION_POLICY: Final[JsonObject] = {
    "closure_deptypes": ["link", "run"],
    "preserve_base_environment": True,
    "prefix_policy": "build-time-absolute",
    "activation": "module-use-opt-in",
}

#: The closed category set a complete source lock must resolve. Mirrors the
#: lock's own contract.required_categories; a lock that weakens its contract is
#: rejected rather than trusted about itself.
FIXED_LOCK_CATEGORIES: Final = (
    "nvidia_hpc_benchmarks_oci",
    "ubuntu_base_oci",
    "spack_repositories",
    "ubuntu_snapshot",
    "ubuntu_archive_key",
    "ubuntu_builder_packages",
    "ubuntu_final_packages",
    "builder_tools",
    "actions_runner_archives",
    "github_actions",
)
#: Reference names that must never appear where an immutable value is required.
FLOATING_REFS: Final = frozenset({"latest", "main", "master", "develop", "development", "stable", "head", "trunk"})


@dataclass(frozen=True, slots=True)
class Target:
    """Architecture facts owned exclusively by targets.json."""

    identity: str
    oci_platform: str
    native_arch: str
    spack_target: str
    llvm_targets: tuple[str, ...]
    cuda_arch: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Container:
    """Injection compatibility owned exclusively by containers.json."""

    identity: str
    base_image: str
    source_lock_category: str
    accepted_software_sets: tuple[str, ...]
    allowed_targets: tuple[str, ...]
    module_destination: str


@dataclass(frozen=True, slots=True)
class Sources:
    """The lock categories and any resolved OCI descriptor chains."""

    status: str
    categories: frozenset[str]
    verified: dict[str, JsonValue]


def default_registry_dir() -> Path:
    """The committed registry directory: <repo>/containers/images."""
    return Path(__file__).resolve().parents[3] / "containers/images"


def document(source: Path | bytes, label: str) -> JsonObject:
    try:
        payload = source.read_bytes() if isinstance(source, Path) else source
        value: JsonValue = json.loads(payload, object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def exact(value: JsonValue, fields: frozenset[str], label: str) -> JsonObject:
    if not isinstance(value, dict) or frozenset(value) != fields:
        fail(f"{label} must contain exactly: {','.join(sorted(fields))}")
    return value


def string(value: JsonValue, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a nonempty string")
    return value


def strings(value: JsonValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a nonempty string array")
    result = tuple(item for item in value if isinstance(item, str))
    if len(result) != len(set(result)):
        fail(f"{label} must not contain duplicates")
    return result


def identity(value: str, label: str) -> str:
    if IDENTITY.fullmatch(value) is None:
        fail(f"{label} is malformed")
    return value


def target_identity(value: str, label: str) -> str:
    if TARGET_ID.fullmatch(value) is None:
        fail(f"{label} is malformed")
    return value


def category(value: str, label: str) -> str:
    if CATEGORY.fullmatch(value) is None:
        fail(f"{label} is malformed")
    return value


def parse_targets(source: Path | bytes) -> dict[str, Target]:
    root = exact(
        document(source, "target registry"), frozenset({"schema", "schema_version", "targets"}), "target registry"
    )
    if root["schema"] != TARGET_SCHEMA or root["schema_version"] != 1:
        fail("target registry schema identity is unsupported")
    raw_targets = root["targets"]
    if not isinstance(raw_targets, dict) or not raw_targets:
        fail("target registry targets must be a nonempty object")
    parsed: dict[str, Target] = {}
    fields = frozenset({"oci_platform", "native_arch", "spack_target", "llvm_targets", "cuda_arch"})
    for raw_identity, raw_target in raw_targets.items():
        target_id = target_identity(raw_identity, "target ID")
        entry = exact(raw_target, fields, f"target {target_id}")
        oci_platform = string(entry["oci_platform"], f"target {target_id} oci_platform")
        native_arch = string(entry["native_arch"], f"target {target_id} native_arch")
        spack_target = string(entry["spack_target"], f"target {target_id} spack_target")
        llvm_targets = strings(entry["llvm_targets"], f"target {target_id} llvm_targets")
        cuda_arch = strings(entry["cuda_arch"], f"target {target_id} cuda_arch")
        if oci_platform not in {"linux/amd64", "linux/arm64"} or native_arch not in {"x86_64", "aarch64"}:
            fail(f"target {target_id} has unsupported architecture facts")
        if (native_arch, oci_platform) not in {("x86_64", "linux/amd64"), ("aarch64", "linux/arm64")}:
            fail(f"target {target_id} native and OCI architecture disagree")
        if not all(CUDA_ARCH.fullmatch(item) for item in cuda_arch):
            fail(f"target {target_id} CUDA architectures are malformed")
        parsed[target_id] = Target(target_id, oci_platform, native_arch, spack_target, llvm_targets, cuda_arch)
    return parsed


def parse_sources(source: Path | bytes) -> Sources:
    root = document(source, "source lock")
    status = string(root.get("status"), "source lock status")
    verified_raw = root.get("verified")
    unresolved_raw = root.get("unresolved")
    if not isinstance(verified_raw, dict) or not isinstance(unresolved_raw, list):
        fail("source lock must expose verified and unresolved categories")
    categories = set(verified_raw)
    for raw_entry in unresolved_raw:
        if not isinstance(raw_entry, dict):
            fail("source lock unresolved entry must be an object")
        categories.add(
            category(string(raw_entry.get("category"), "source lock unresolved category"), "source lock unresolved category")
        )
    verified: dict[str, JsonValue] = {}
    for raw_category, raw_entry in verified_raw.items():
        verified[category(raw_category, "source lock verified category")] = raw_entry
    return Sources(status, frozenset(categories), verified)


def parse_containers(source: Path | bytes, targets: dict[str, Target], sources: Sources) -> dict[str, Container]:
    root = exact(
        document(source, "container registry"),
        frozenset({"schema", "schema_version", "containers"}),
        "container registry",
    )
    if root["schema"] != CONTAINER_SCHEMA or root["schema_version"] != 1:
        fail("container registry schema identity is unsupported")
    raw_containers = root["containers"]
    if not isinstance(raw_containers, dict) or not raw_containers:
        fail("container registry containers must be a nonempty object")
    parsed: dict[str, Container] = {}
    fields = frozenset(
        {"base_image", "source_lock_category", "accepted_software_sets", "allowed_targets", "module_destination"}
    )
    for raw_identity, raw_container in raw_containers.items():
        container_id = identity(raw_identity, "container ID")
        entry = exact(raw_container, fields, f"container {container_id}")
        base_image = string(entry["base_image"], f"container {container_id} base_image")
        category_id = category(
            string(entry["source_lock_category"], f"container {container_id} source_lock_category"),
            f"container {container_id} source_lock_category",
        )
        software_sets = strings(entry["accepted_software_sets"], f"container {container_id} accepted_software_sets")
        allowed_targets = strings(entry["allowed_targets"], f"container {container_id} allowed_targets")
        module_destination = string(entry["module_destination"], f"container {container_id} module_destination")
        if BASE_IMAGE.fullmatch(base_image) is None or ":" in base_image or "@" in base_image:
            fail(f"container {container_id} base_image must be an untagged registry identity")
        if category_id not in sources.categories:
            fail(f"container {container_id} source lock category is unknown: {category_id}")
        if any(item not in {"vlad", "hpcsim", "all"} for item in software_sets):
            fail(f"container {container_id} has an unknown software set")
        if any(item not in targets for item in allowed_targets):
            fail(f"container {container_id} references an unknown target")
        if not module_destination.startswith("/") or ".." in Path(module_destination).parts:
            fail(f"container {container_id} module destination is not an absolute normalized path")
        parsed[container_id] = Container(
            container_id, base_image, category_id, software_sets, allowed_targets, module_destination
        )
    return parsed


def validate_oci_chains(sources: Sources, targets: dict[str, Target]) -> None:
    for category_id, entry in sources.verified.items():
        if not isinstance(entry, dict):
            continue
        platforms = entry.get("platforms")
        if platforms is None:
            continue
        if not isinstance(platforms, dict):
            fail(f"source lock category {category_id} platforms must be an object")
        chains: dict[str, tuple[str, str]] = {}
        for target_id, raw_platform in platforms.items():
            target = targets.get(target_id)
            if target is None:
                fail(f"source lock category {category_id} references an unknown target: {target_id}")
            platform = exact(
                raw_platform,
                frozenset({"oci_platform", "descriptor_digest", "config_digest"}),
                f"source lock category {category_id} platform {target_id}",
            )
            oci_platform = string(platform["oci_platform"], f"source lock category {category_id} OCI platform")
            descriptor = string(platform["descriptor_digest"], f"source lock category {category_id} descriptor digest")
            config = string(platform["config_digest"], f"source lock category {category_id} config digest")
            if (
                oci_platform != target.oci_platform
                or OCI_DIGEST.fullmatch(descriptor) is None
                or OCI_DIGEST.fullmatch(config) is None
            ):
                fail(f"source lock category {category_id} has an inconsistent OCI descriptor chain")
            existing = chains.get(oci_platform)
            if existing is None:
                chains[oci_platform] = (descriptor, config)
            elif existing != (descriptor, config):
                fail(f"source lock category {category_id} has inconsistent descriptors for OCI platform {oci_platform}")


def _check_lock_integrity(value: JsonValue, path: str) -> None:
    """Reject non-immutable values wherever the lock promises immutability.

    Every `sha256`/`*_sha256` field must be a full lowercase digest, every OCI
    digest field a `sha256:` digest, and every `commit` an exact 40-hex object
    name — never a tag, branch, or abbreviation (floating_input_rule).
    """
    if isinstance(value, dict):
        for key, item in value.items():
            label = f"{path}.{key}"
            if key == "sha256" or key.endswith("_sha256"):
                if not isinstance(item, str) or SHA256_HEX.fullmatch(item) is None:
                    fail(f"source lock {label} must be a full lowercase SHA-256")
            elif key in {"descriptor_digest", "config_digest", "index_digest"}:
                if not isinstance(item, str) or OCI_DIGEST.fullmatch(item) is None:
                    fail(f"source lock {label} must be an immutable sha256 OCI digest")
            elif key == "commit":
                if not isinstance(item, str) or GIT_COMMIT.fullmatch(item) is None or item.lower() in FLOATING_REFS:
                    fail(f"source lock {label} must be an exact 40-hex commit")
            else:
                _check_lock_integrity(item, label)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _check_lock_integrity(item, f"{path}[{index}]")


def require_complete_lock(lock: JsonObject) -> None:
    """Fail unless the source lock is complete, closed, and internally immutable.

    A production image host must reject anything less: status complete, no
    unresolved requirement, the lock's own contract still naming the fixed
    closed category set, every fixed category verified, and every digest or
    commit in the verified payload an immutable value.
    """
    if lock.get("status") != "complete" or lock.get("unresolved"):
        fail("source lock is blocked or incomplete")
    contract = lock.get("contract")
    if not isinstance(contract, dict) or contract.get("required_categories") != list(FIXED_LOCK_CATEGORIES):
        fail("source lock required categories are not the fixed closed set")
    verified = lock.get("verified")
    if not isinstance(verified, dict) or set(verified) != set(FIXED_LOCK_CATEGORIES):
        fail("complete source lock must verify exactly the fixed categories")
    _check_lock_integrity(verified, "verified")


def resolve(
    container_id: str,
    software_set: str,
    target_id: str,
    targets: dict[str, Target],
    containers: dict[str, Container],
    sources: Sources,
) -> JsonObject:
    container = containers.get(container_id)
    target = targets.get(target_id)
    if container is None:
        fail(f"unknown container: {container_id}")
    if target is None:
        fail(f"unknown target: {target_id}")
    if software_set not in container.accepted_software_sets:
        fail(f"container {container_id} does not accept software set: {software_set}")
    if target_id not in container.allowed_targets:
        fail(f"container {container_id} does not allow target: {target_id}")
    state = "verified" if container.source_lock_category in sources.verified else "unresolved"
    return {
        "container": {
            "id": container.identity,
            "base_image": container.base_image,
            "source_lock_category": container.source_lock_category,
            "module_destination": container.module_destination,
        },
        "injection_policy": dict(INJECTION_POLICY),
        "software_set": software_set,
        "source_lock": {"status": sources.status, "category_state": state},
        "target": {
            "id": target.identity,
            "oci_platform": target.oci_platform,
            "native_arch": target.native_arch,
            "spack_target": target.spack_target,
            "llvm_targets": list(target.llvm_targets),
            "cuda_arch": list(target.cuda_arch),
        },
    }
