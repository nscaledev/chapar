#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TARGETS_PATH="${ROOT_DIR}/containers/images/targets.json"
SOURCES_PATH="${SOURCES_PATH_OVERRIDE:-${ROOT_DIR}/containers/images/sources-lock.json}"
REPOS_PATH="${ROOT_DIR}/etc/system/base/repos.yaml"

python3 - "${TARGETS_PATH}" "${SOURCES_PATH}" "${REPOS_PATH}" "${1:-}" <<'PY'
from __future__ import annotations

import copy
import datetime
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import Final
from urllib.parse import urlsplit

targets_path = Path(sys.argv[1])
sources_path = Path(sys.argv[2])
repos_path = Path(sys.argv[3])
mode = sys.argv[4]
commit_pattern: Final = re.compile(r"^[0-9a-f]{40}$")
digest_pattern: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
sha256_pattern: Final = re.compile(r"^[0-9a-f]{64}$")
date_pattern: Final = re.compile(r"^20[0-9]{2}-[01][0-9]-[0-3][0-9]$")
fingerprint_pattern: Final = re.compile(r"^[0-9A-F]{40}$")
version_pattern: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+:~_-]*$")
fixed_categories: Final = (
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
# Which selected-container base each OCI-locked category is for, and which of
# the registered targets that base actually builds. Kept in sync with
# containers/images/build-image.sh's BASES dict.
oci_bases: Final = {
    "nvidia_hpc_benchmarks_oci": {
        "image": "nvcr.io/nvidia/hpc-benchmarks",
        "tag": "26.02",
        "targets": (
            "linux-x86_64-generic",
            "linux-x86_64-v4",
            "linux-aarch64-generic",
            "linux-aarch64-gb300",
        ),
    },
    "ubuntu_base_oci": {
        "image": "ubuntu",
        "tag": "24.04",
        "targets": ("linux-x86_64-generic",),
    },
}
approved_spack: Final = {
    "spack-core": ("https://github.com/spack/spack.git", "fff95dd9aed0af7c7a8252adbef5623fcd4187f7"),
    "spack-packages": ("https://github.com/spack/spack-packages.git", "65f3228ea2533e8413c17661a3a0db3636269631"),
}
approved_actions: Final = {
    "actions-checkout-v4": ("https://github.com/actions/checkout.git", "11d5960a326750d5838078e36cf38b85af677262", ["actions/checkout"]),
    "actions-checkout-v5": ("https://github.com/actions/checkout.git", "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09", ["actions/checkout"]),
    "github-codeql-action-v4": ("https://github.com/github/codeql-action.git", "bce182f857edf1feab116e9795a3393d21977282", ["github/codeql-action/init", "github/codeql-action/analyze"]),
}
required_tool_binaries: Final = {
    "docker-buildx": {"docker", "docker-buildx"},
    "buildkit": {"buildctl"},
    "enroot": {"enroot"},
    "squashfs-tools": {"mksquashfs", "unsquashfs"},
    "zstd": {"zstd"},
    "syft": {"syft"},
    "jq": {"jq"},
    "skopeo": {"skopeo"},
}
approved_tool_url_prefixes: Final = {
    "docker-buildx": "https://github.com/docker/buildx/",
    "buildkit": "https://github.com/moby/buildkit/",
    "enroot": "https://github.com/NVIDIA/enroot/",
    "squashfs-tools": "https://snapshot.ubuntu.com/ubuntu/",
    "zstd": "https://snapshot.ubuntu.com/ubuntu/",
    "syft": "https://github.com/anchore/syft/",
    "jq": "https://github.com/jqlang/jq/",
    "skopeo": "https://github.com/containers/skopeo/",
}


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, object]:
    loaded = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(loaded, dict):
        raise ValueError(f"top-level JSON value must be an object: {path}")
    return loaded


def exact_object(value: object, fields: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError(f"{label} must contain exactly: {','.join(sorted(fields))}")
    return value


def exact_version(value: object, label: str) -> str:
    floating = {"latest", "main", "master", "develop", "development", "stable", "head", "trunk"}
    if not isinstance(value, str) or version_pattern.fullmatch(value) is None or value.lower() in floating:
        raise ValueError(f"{label} must be an exact non-floating version")
    return value


def iso_date(value: object, label: str) -> str:
    if not isinstance(value, str) or date_pattern.fullmatch(value) is None:
        raise ValueError(f"{label} must be an ISO calendar date")
    try:
        datetime.date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"{label} must be an ISO calendar date") from error
    return value


def immutable_url(value: object, hosts: set[str], label: str, version: str | None = None) -> str:
    if not isinstance(value, str) or "latest" in value.lower():
        raise ValueError(f"{label} must be an immutable HTTPS URL")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.hostname not in hosts or parsed.username or parsed.password or parsed.fragment:
        raise ValueError(f"{label} is not an approved canonical HTTPS URL")
    if version is not None:
        tokens = (f"/{version}/", f"/v{version}/", f"-{version}-", f"-{version}.", f"_{version}_")
        if not any(token in parsed.path for token in tokens) and not parsed.path.endswith(f"/{version}"):
            raise ValueError(f"{label} does not bind the exact version")
    return value


def full_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or sha256_pattern.fullmatch(value) is None:
        raise ValueError(f"{label} must be a full lowercase SHA-256")
    return value


def validation_record(value: object, label: str, require_result: bool) -> None:
    fields = {"method", "retrieved_on"} | ({"result"} if require_result else set())
    record = exact_object(value, fields, label)
    if not isinstance(record["method"], str) or not record["method"]:
        raise ValueError(f"{label} method must be nonempty")
    iso_date(record["retrieved_on"], f"{label} retrieved_on")
    if require_result and record["result"] != "commit object":
        raise ValueError(f"{label} result must prove a commit object")


# Must equal containers/images/targets.json exactly. This copy had drifted: it
# still carried the retired cuda_arch=75 entry that the registry dropped, so
# validate_targets below failed for every invocation regardless of the lock
# under test.
CUDA_ARCH_FULL: Final = ["80", "86", "87", "89", "90", "90a", "100", "103", "110", "120", "121"]
expected_targets: Final = {
    "linux-x86_64-generic": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64",
        "llvm_targets": ["x86", "nvptx"],
        "cuda_arch": CUDA_ARCH_FULL,
    },
    "linux-x86_64-v4": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64_v4",
        "llvm_targets": ["x86", "nvptx"],
        "cuda_arch": CUDA_ARCH_FULL,
    },
    "linux-aarch64-generic": {
        "oci_platform": "linux/arm64",
        "native_arch": "aarch64",
        "spack_target": "aarch64",
        "llvm_targets": ["aarch64", "nvptx"],
        "cuda_arch": CUDA_ARCH_FULL,
    },
    "linux-aarch64-gb300": {
        "oci_platform": "linux/arm64",
        "native_arch": "aarch64",
        "spack_target": "aarch64",
        "llvm_targets": ["aarch64", "nvptx"],
        "cuda_arch": ["103"],
    },
}


def validate_targets(document: dict[str, object]) -> None:
    if set(document) != {"schema", "schema_version", "targets"} or document.get("schema_version") != 1:
        raise ValueError("targets has unknown fields or unsupported schema")
    if document.get("targets") != expected_targets:
        raise ValueError("target registry differs from the two approved mappings")


def validate_spack(value: object) -> None:
    if not isinstance(value, list) or len(value) != len(approved_spack):
        raise ValueError("Spack repositories must contain exactly the approved identities")
    seen: set[str] = set()
    for raw in value:
        entry = exact_object(raw, {"id", "repository", "commit", "verification"}, "Spack repository")
        identity = entry["id"]
        if not isinstance(identity, str) or identity in seen or identity not in approved_spack:
            raise ValueError("unknown or duplicate Spack repository identity")
        seen.add(identity)
        if (entry["repository"], entry["commit"]) != approved_spack[identity]:
            raise ValueError(f"Spack repository identity/URL/commit mismatch: {identity}")
        validation_record(entry["verification"], f"Spack verification {identity}", True)


def validate_actions(value: object) -> None:
    if not isinstance(value, list) or len(value) != len(approved_actions):
        raise ValueError("GitHub Actions must contain exactly the approved identities")
    seen: set[str] = set()
    for raw in value:
        entry = exact_object(raw, {"id", "repository", "commit", "resolved_from", "workflow_uses", "verification"}, "GitHub Action")
        identity = entry["id"]
        if not isinstance(identity, str) or identity in seen or identity not in approved_actions:
            raise ValueError("unknown or duplicate GitHub Action identity")
        seen.add(identity)
        repository, commit, uses = approved_actions[identity]
        if entry["repository"] != repository or entry["commit"] != commit or entry["workflow_uses"] != uses:
            raise ValueError(f"GitHub Action identity/URL/commit/use mismatch: {identity}")
        if not isinstance(entry["resolved_from"], str) or not entry["resolved_from"].startswith("refs/tags/"):
            raise ValueError(f"GitHub Action mutable provenance is malformed: {identity}")
        validation_record(entry["verification"], f"GitHub Action verification {identity}", False)


def make_oci_validator(category: str):
    base = oci_bases[category]
    allowed_targets = {name: expected_targets[name] for name in base["targets"]}
    label = category.replace("_", " ")

    def validate(value: object) -> None:
        oci = exact_object(value, {"image", "tag", "index_digest", "platforms", "resolved_on"}, f"{label} lock")
        if oci["image"] != base["image"] or oci["tag"] != base["tag"]:
            raise ValueError(f"{label} identity/tag must be the approved {base['tag']} source")
        if not isinstance(oci["index_digest"], str) or digest_pattern.fullmatch(oci["index_digest"]) is None:
            raise ValueError(f"{label} index digest is not immutable")
        iso_date(oci["resolved_on"], f"{label} resolved_on")
        platforms = exact_object(oci["platforms"], set(allowed_targets), f"{label} platforms")
        # Chapar targets map many-to-one onto the base image's OCI platforms:
        # linux-x86_64-generic and linux-x86_64-v4 both consume the single
        # linux/amd64 descriptor of a base's index and differ only in the
        # Spack tree layered on top (when a base supports both -- ubuntu_base
        # currently supports only the generic target). So the invariant is
        # the one the contract's oci_chain_rule actually states -- exactly
        # one descriptor per approved OCI platform -- rather than one per
        # target: every target on a platform must name that platform's
        # descriptor, and two distinct platforms must never resolve to the
        # same descriptor.
        chains: dict[str, tuple[str, str]] = {}
        for target_name, expected_target in allowed_targets.items():
            platform = exact_object(platforms[target_name], {"oci_platform", "descriptor_digest", "config_digest"}, f"{label} platform {target_name}")
            if platform["oci_platform"] != expected_target["oci_platform"]:
                raise ValueError(f"{label} platform mismatch for {target_name}")
            for key in ("descriptor_digest", "config_digest"):
                if not isinstance(platform[key], str) or digest_pattern.fullmatch(platform[key]) is None:
                    raise ValueError(f"invalid {label} {key} for {target_name}")
            oci_platform = str(platform["oci_platform"])
            descriptor = str(platform["descriptor_digest"])
            config = str(platform["config_digest"])
            locked = chains.get(oci_platform)
            if locked is None:
                if descriptor in {chain[0] for chain in chains.values()}:
                    raise ValueError(f"distinct {label} platforms cannot share a platform descriptor")
                chains[oci_platform] = (descriptor, config)
            elif locked[0] != descriptor:
                raise ValueError(f"{label} targets on {oci_platform} must name one platform descriptor")
            elif locked[1] != config:
                raise ValueError(f"{label} targets sharing a platform descriptor must name one config digest")

    return validate


def validate_snapshot(value: object) -> None:
    snapshot = exact_object(value, {"release", "snapshot_url", "pockets", "archive_key_fingerprint", "resolved_on"}, "Ubuntu snapshot")
    if snapshot["release"] != "24.04":
        raise ValueError("Ubuntu snapshot release must be 24.04")
    immutable_url(snapshot["snapshot_url"], {"snapshot.ubuntu.com"}, "Ubuntu snapshot URL")
    if fingerprint_pattern.fullmatch(str(snapshot["archive_key_fingerprint"])) is None:
        raise ValueError("Ubuntu snapshot key fingerprint is invalid")
    iso_date(snapshot["resolved_on"], "Ubuntu snapshot resolved_on")
    pockets = snapshot["pockets"]
    if not isinstance(pockets, list) or not pockets:
        raise ValueError("Ubuntu snapshot must lock at least one pocket")
    seen: set[str] = set()
    for raw in pockets:
        pocket = exact_object(raw, {"id", "inrelease_url", "inrelease_sha256", "package_indexes"}, "Ubuntu pocket")
        identity = exact_version(pocket["id"], "Ubuntu pocket identity")
        if identity in seen:
            raise ValueError(f"duplicate Ubuntu pocket: {identity}")
        seen.add(identity)
        immutable_url(pocket["inrelease_url"], {"snapshot.ubuntu.com"}, "Ubuntu InRelease URL")
        full_sha256(pocket["inrelease_sha256"], "Ubuntu InRelease SHA-256")
        indexes = pocket["package_indexes"]
        if not isinstance(indexes, list) or len(indexes) != 2:
            raise ValueError("Ubuntu pocket must lock exactly amd64 and arm64 package indexes")
        index_architectures: set[str] = set()
        for raw_index in indexes:
            index = exact_object(raw_index, {"architecture", "url", "sha256"}, "Ubuntu package index")
            architecture = index["architecture"]
            if architecture not in {"amd64", "arm64"} or architecture in index_architectures:
                raise ValueError("Ubuntu package index architecture is unknown or duplicate")
            index_architectures.add(str(architecture))
            immutable_url(index["url"], {"snapshot.ubuntu.com"}, "Ubuntu Packages URL")
            full_sha256(index["sha256"], "Ubuntu Packages SHA-256")


def validate_archive_key(value: object) -> None:
    key = exact_object(value, {"fingerprint", "source_url", "key_sha256", "resolved_on"}, "Ubuntu archive key")
    if fingerprint_pattern.fullmatch(str(key["fingerprint"])) is None:
        raise ValueError("Ubuntu archive key fingerprint is invalid")
    immutable_url(key["source_url"], {"git.launchpad.net", "keyserver.ubuntu.com"}, "Ubuntu archive key URL")
    full_sha256(key["key_sha256"], "Ubuntu archive key SHA-256")
    iso_date(key["resolved_on"], "Ubuntu archive key resolved_on")


def validate_packages(value: object, label: str) -> None:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{label} must be a nonempty package array")
    seen: set[tuple[str, str]] = set()
    architectures: set[str] = set()
    for raw in value:
        package = exact_object(raw, {"name", "version", "architecture", "url", "sha256"}, label)
        name = exact_version(package["name"], f"{label} package name")
        version = exact_version(package["version"], f"{label} package version")
        architecture = package["architecture"]
        if architecture not in {"amd64", "arm64", "all"}:
            raise ValueError(f"{label} package architecture is unsupported")
        if (name, architecture) in seen:
            raise ValueError(f"duplicate {label} package identity: {name}/{architecture}")
        seen.add((name, architecture))
        architectures.add(str(architecture))
        package_url = immutable_url(package["url"], {"snapshot.ubuntu.com"}, f"{label} package URL", version)
        if f"_{version}_" not in urlsplit(package_url).path:
            raise ValueError(f"{label} package URL does not bind the exact archive version")
        full_sha256(package["sha256"], f"{label} package SHA-256")
    if not {"amd64", "arm64"}.issubset(architectures):
        raise ValueError(f"{label} must lock packages for amd64 and arm64")


def validate_tools(value: object) -> None:
    if not isinstance(value, list) or len(value) != len(required_tool_binaries):
        raise ValueError("builder tools must contain exactly the approved identities")
    seen: set[str] = set()
    for raw in value:
        tool = exact_object(raw, {"id", "version", "source_url", "release_sha256", "assets"}, "builder tool")
        identity = tool["id"]
        if not isinstance(identity, str) or identity in seen or identity not in required_tool_binaries:
            raise ValueError("unknown or duplicate builder tool identity")
        seen.add(identity)
        version = exact_version(tool["version"], f"builder tool version {identity}")
        source_url = immutable_url(tool["source_url"], {"github.com", "snapshot.ubuntu.com"}, f"builder tool URL {identity}", version)
        if not source_url.startswith(approved_tool_url_prefixes[identity]):
            raise ValueError(f"builder tool URL identity mismatch: {identity}")
        full_sha256(tool["release_sha256"], f"builder tool release SHA-256 {identity}")
        platforms = exact_object(tool["assets"], {"x86_64", "aarch64"}, f"builder tool assets {identity}")
        for architecture, raw_asset in platforms.items():
            asset = exact_object(raw_asset, {"url", "sha256", "binaries"}, f"builder tool asset {identity}/{architecture}")
            asset_url = immutable_url(asset["url"], {"github.com", "snapshot.ubuntu.com"}, f"builder tool asset URL {identity}/{architecture}", version)
            if not asset_url.startswith(approved_tool_url_prefixes[identity]):
                raise ValueError(f"builder tool asset URL identity mismatch: {identity}/{architecture}")
            full_sha256(asset["sha256"], f"builder tool asset SHA-256 {identity}/{architecture}")
            raw_binaries = asset["binaries"]
            if not isinstance(raw_binaries, list) or not raw_binaries:
                raise ValueError(f"builder tool {identity}/{architecture} has no binaries")
            names: set[str] = set()
            for raw_binary in raw_binaries:
                binary = exact_object(raw_binary, {"name", "sha256"}, f"builder tool binary {identity}/{architecture}")
                name = binary["name"]
                if not isinstance(name, str) or name in names:
                    raise ValueError(f"invalid or duplicate builder binary for {identity}/{architecture}")
                names.add(name)
                full_sha256(binary["sha256"], f"builder binary SHA-256 {identity}/{name}")
            if names != required_tool_binaries[identity]:
                raise ValueError(f"builder tool binary identities mismatch: {identity}/{architecture}")


def validate_runner_archives(value: object) -> None:
    expected = {"linux-x64": "x64", "linux-arm64": "arm64"}
    if not isinstance(value, list) or len(value) != len(expected):
        raise ValueError("Actions runner archives must contain exactly x64 and arm64")
    seen: set[str] = set()
    for raw in value:
        archive = exact_object(raw, {"id", "architecture", "version", "url", "sha256"}, "Actions runner archive")
        identity = archive["id"]
        if not isinstance(identity, str) or identity in seen or identity not in expected or archive["architecture"] != expected[identity]:
            raise ValueError("unknown, duplicate, or mismatched Actions runner archive")
        seen.add(identity)
        version = exact_version(archive["version"], f"Actions runner version {identity}")
        archive_url = immutable_url(archive["url"], {"github.com"}, f"Actions runner URL {identity}", version)
        if not archive_url.startswith("https://github.com/actions/runner/releases/download/"):
            raise ValueError(f"Actions runner URL identity mismatch: {identity}")
        full_sha256(archive["sha256"], f"Actions runner SHA-256 {identity}")


def validate_unresolved(value: object, verified: dict[str, object], status: str) -> None:
    if not isinstance(value, list):
        raise ValueError("unresolved must be an array")
    if status == "complete":
        if value:
            raise ValueError("complete source lock cannot contain unresolved requirements")
        return
    category_expansion = {
        category: {category} for category in fixed_categories
    }
    category_expansion["ubuntu_packages"] = {"ubuntu_builder_packages", "ubuntu_final_packages"}
    covered: set[str] = set()
    for raw in value:
        if not isinstance(raw, dict):
            raise ValueError("unresolved entry must be an object")
        allowed_fields = {"category", "official_urls", "required_values", "blocker", "observed_on", "requested_source"}
        required_fields = allowed_fields - {"requested_source"}
        if not required_fields.issubset(raw) or not set(raw).issubset(allowed_fields):
            raise ValueError("unresolved entry has missing or unknown fields")
        category = raw["category"]
        if not isinstance(category, str) or category not in category_expansion:
            raise ValueError("unresolved entry has an unknown category")
        expansion = category_expansion[category]
        if covered.intersection(expansion):
            raise ValueError(f"duplicate unresolved category coverage: {category}")
        covered.update(expansion)
        urls = raw["official_urls"]
        if not isinstance(urls, list) or not urls:
            raise ValueError(f"unresolved category has no official URLs: {category}")
        for url in urls:
            immutable_url(url, {"nvcr.io", "catalog.ngc.nvidia.com", "snapshot.ubuntu.com", "archive.ubuntu.com", "security.ubuntu.com", "git.launchpad.net", "keyserver.ubuntu.com", "github.com", "packages.ubuntu.com"}, f"unresolved official URL {category}")
        requirements = raw["required_values"]
        if not isinstance(requirements, list) or not requirements or not all(isinstance(item, str) and item for item in requirements):
            raise ValueError(f"unresolved category required_values is malformed: {category}")
        if not isinstance(raw["blocker"], str) or not raw["blocker"]:
            raise ValueError(f"unresolved category blocker is empty: {category}")
        iso_date(raw["observed_on"], f"unresolved observed_on {category}")
        if "requested_source" in raw and (not isinstance(raw["requested_source"], str) or not raw["requested_source"]):
            raise ValueError(f"unresolved requested_source is malformed: {category}")
    missing = set(fixed_categories) - set(verified)
    if covered != missing:
        raise ValueError("blocked source lock unresolved coverage does not exactly match missing fixed categories")


category_validators: Final = {
    "nvidia_hpc_benchmarks_oci": make_oci_validator("nvidia_hpc_benchmarks_oci"),
    "ubuntu_base_oci": make_oci_validator("ubuntu_base_oci"),
    "spack_repositories": validate_spack,
    "ubuntu_snapshot": validate_snapshot,
    "ubuntu_archive_key": validate_archive_key,
    "ubuntu_builder_packages": lambda value: validate_packages(value, "Ubuntu builder package"),
    "ubuntu_final_packages": lambda value: validate_packages(value, "Ubuntu final package"),
    "builder_tools": validate_tools,
    "actions_runner_archives": validate_runner_archives,
    "github_actions": validate_actions,
}


def validate_source_shape(document: dict[str, object], require_complete: bool) -> None:
    expected_top = {"schema", "schema_version", "status", "resolved_on", "retrieval_time_precision", "contract", "verified", "unresolved"}
    if set(document) != expected_top or document.get("schema_version") != 1:
        raise ValueError("source-lock has unknown fields or unsupported schema")
    if document.get("schema") != "https://nscaledev.github.io/chapar/schemas/vlad-image-sources-lock/v1":
        raise ValueError("source-lock schema identity is unsupported")
    iso_date(document.get("resolved_on"), "source-lock resolved_on")
    if not isinstance(document.get("retrieval_time_precision"), str) or not document["retrieval_time_precision"]:
        raise ValueError("source-lock retrieval_time_precision must be nonempty")
    status = document.get("status")
    if status not in {"blocked", "complete"}:
        raise ValueError("source-lock status must be blocked or complete")
    verified = document.get("verified")
    unresolved = document.get("unresolved")
    if not isinstance(verified, dict) or not isinstance(unresolved, list):
        raise ValueError("verified must be an object and unresolved must be an array")
    contract = exact_object(document.get("contract"), {"complete_status", "production_rule", "required_categories", "immutable_git_ref", "immutable_digest", "uniqueness_rule", "oci_chain_rule", "floating_input_rule"}, "source-lock contract")
    if contract["complete_status"] != "complete" or contract["required_categories"] != list(fixed_categories):
        raise ValueError("source-lock required categories are not the fixed closed set")
    if not set(verified).issubset(set(fixed_categories)):
        raise ValueError("source-lock verified contains an unknown category")
    for category, value in verified.items():
        category_validators[category](value)
    validate_unresolved(unresolved, verified, status)
    if "ubuntu_snapshot" in verified and "ubuntu_archive_key" in verified:
        if verified["ubuntu_snapshot"]["archive_key_fingerprint"] != verified["ubuntu_archive_key"]["fingerprint"]:
            raise ValueError("Ubuntu snapshot and archive-key fingerprints do not match")
    if "ubuntu_snapshot" in verified:
        snapshot_url = verified["ubuntu_snapshot"]["snapshot_url"]
        for category in ("ubuntu_builder_packages", "ubuntu_final_packages"):
            for package in verified.get(category, []):
                if not package["url"].startswith(snapshot_url):
                    raise ValueError(f"{category} URL is outside the locked Ubuntu snapshot")
    if status == "complete":
        if set(verified) != set(fixed_categories):
            raise ValueError("complete source lock must contain exactly the fixed verified categories")
    if require_complete and status != "complete":
        raise ValueError("source lock is blocked and must fail closed for production use")


def validate_repos_config(path: Path, document: dict[str, object]) -> None:
    entries = document.get("verified", {}).get("spack_repositories", [])
    expected_commit = next(
        (entry.get("commit") for entry in entries if isinstance(entry, dict) and entry.get("id") == "spack-packages"),
        None,
    )
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("  builtin:") + 1
    except ValueError as error:
        raise ValueError("repos config has no builtin repository") from error
    fields: dict[str, str] = {}
    for line in lines[start:]:
        if line and not line.startswith("    "):
            break
        match = re.fullmatch(r"    ([a-z_]+):\s+(.+)", line)
        if match is None or match.group(1) in fields:
            raise ValueError("builtin repository config is malformed")
        fields[match.group(1)] = match.group(2)
    if fields != {
        "git": "https://github.com/spack/spack-packages.git",
        "commit": expected_commit,
    }:
        raise ValueError("builtin repository must use the exact source-lock spack-packages commit without branch or tag")


def synthetic_complete_sources(template: dict[str, object]) -> dict[str, object]:
    document = copy.deepcopy(template)

    def digest(number: int) -> str:
        return f"sha256:{number:064x}"

    snapshot_url = "https://snapshot.ubuntu.com/ubuntu/20260805T000000Z"
    document["status"] = "complete"
    document["resolved_on"] = "2026-08-05"
    document["unresolved"] = []
    verified = document["verified"]
    verified["nvidia_hpc_benchmarks_oci"] = {
        "image": "nvcr.io/nvidia/hpc-benchmarks",
        "tag": "26.02",
        "index_digest": digest(1),
        # Derived from oci_bases rather than listed, so registering a target
        # cannot leave the synthetic complete lock behind. Targets sharing an OCI
        # platform must name the same descriptor/config pair -- that is the
        # invariant validate() enforces -- so key the digests on the platform.
        "platforms": {
            target: {
                "oci_platform": expected_targets[target]["oci_platform"],
                "descriptor_digest": digest(2 if expected_targets[target]["oci_platform"] == "linux/amd64" else 4),
                "config_digest": digest(3 if expected_targets[target]["oci_platform"] == "linux/amd64" else 5),
            }
            for target in oci_bases["nvidia_hpc_benchmarks_oci"]["targets"]
        },
        "resolved_on": "2026-08-05",
    }
    verified["ubuntu_snapshot"] = {
        "release": "24.04",
        "snapshot_url": snapshot_url,
        "pockets": [{
            "id": "noble",
            "inrelease_url": f"{snapshot_url}/dists/noble/InRelease",
            "inrelease_sha256": f"{10:064x}",
            "package_indexes": [
                {"architecture": "amd64", "url": f"{snapshot_url}/dists/noble/main/binary-amd64/Packages.xz", "sha256": f"{11:064x}"},
                {"architecture": "arm64", "url": f"{snapshot_url}/dists/noble/main/binary-arm64/Packages.xz", "sha256": f"{12:064x}"},
            ],
        }],
        "archive_key_fingerprint": "A" * 40,
        "resolved_on": "2026-08-05",
    }
    verified["ubuntu_archive_key"] = {
        "fingerprint": "A" * 40,
        "source_url": "https://keyserver.ubuntu.com/pks/lookup?op=get&search=synthetic",
        "key_sha256": f"{13:064x}",
        "resolved_on": "2026-08-05",
    }

    def packages(name: str, first_hash: int) -> list[dict[str, str]]:
        return [
            {"name": name, "version": "1.0", "architecture": architecture,
             "url": f"{snapshot_url}/pool/main/{name[0]}/{name}/{name}_1.0_{architecture}.deb",
             "sha256": f"{first_hash + offset:064x}"}
            for offset, architecture in enumerate(("amd64", "arm64"))
        ]

    verified["ubuntu_builder_packages"] = packages("builder", 20)
    verified["ubuntu_final_packages"] = packages("runtime", 30)

    tool_projects = {
        "docker-buildx": ("https://github.com/docker/buildx", ("docker", "docker-buildx")),
        "buildkit": ("https://github.com/moby/buildkit", ("buildctl",)),
        "enroot": ("https://github.com/NVIDIA/enroot", ("enroot",)),
        "squashfs-tools": (snapshot_url, ("mksquashfs", "unsquashfs")),
        "zstd": (snapshot_url, ("zstd",)),
        "syft": ("https://github.com/anchore/syft", ("syft",)),
        "jq": ("https://github.com/jqlang/jq", ("jq",)),
        "skopeo": ("https://github.com/containers/skopeo", ("skopeo",)),
    }
    tools = []
    for tool_offset, (identity, (prefix, binaries)) in enumerate(tool_projects.items(), start=40):
        base_url = f"{prefix}/releases/download/v1.0/{identity}-1.0"
        assets = {}
        for arch_offset, architecture in enumerate(("x86_64", "aarch64")):
            assets[architecture] = {
                "url": f"{base_url}-{architecture}.tar.gz",
                "sha256": f"{tool_offset + arch_offset:064x}",
                "binaries": [
                    {"name": binary, "sha256": f"{tool_offset + arch_offset + binary_offset + 100:064x}"}
                    for binary_offset, binary in enumerate(binaries)
                ],
            }
        tools.append({
            "id": identity,
            "version": "1.0",
            "source_url": f"{base_url}-source.tar.gz",
            "release_sha256": f"{tool_offset + 200:064x}",
            "assets": assets,
        })
    verified["builder_tools"] = tools
    verified["actions_runner_archives"] = [
        {"id": identity, "architecture": architecture, "version": "1.0",
         "url": f"https://github.com/actions/runner/releases/download/v1.0/actions-runner-{identity}-1.0.tar.gz",
         "sha256": f"{300 + offset:064x}"}
        for offset, (identity, architecture) in enumerate((("linux-x64", "x64"), ("linux-arm64", "arm64")))
    ]
    return document


targets = load_json(targets_path)
sources = load_json(sources_path)
validate_targets(targets)
validate_source_shape(sources, mode == "--require-complete")
validate_repos_config(repos_path, sources)

if mode == "--self-test":
    complete = synthetic_complete_sources(sources)
    validate_source_shape(complete, True)
    invalid_cases: list[tuple[str, dict[str, object], bool]] = []
    duplicate_target = copy.deepcopy(targets)
    duplicate_target["targets"]["linux-aarch64-gb300"] = copy.deepcopy(expected_targets["linux-x86_64-generic"])
    invalid_cases.append(("wrong target mapping", duplicate_target, False))
    abbreviated = copy.deepcopy(complete)
    abbreviated["verified"]["spack_repositories"][0]["commit"] = "fff95dd9"
    invalid_cases.append(("abbreviated commit", abbreviated, False))
    tag_only = copy.deepcopy(complete)
    tag_only["verified"]["github_actions"][0]["commit"] = "v4"
    invalid_cases.append(("tag-only action", tag_only, False))
    floating = copy.deepcopy(sources)
    floating["status"] = "complete"
    invalid_cases.append(("floating incomplete lock", floating, False))
    weakened = copy.deepcopy(complete)
    weakened["contract"]["required_categories"] = ["spack_repositories", "github_actions"]
    invalid_cases.append(("weakened required categories", weakened, False))
    globally_blocked = copy.deepcopy(complete)
    globally_blocked["status"] = "blocked"
    invalid_cases.append(("globally blocked complete-content lock", globally_blocked, True))
    wrong_platform = copy.deepcopy(complete)
    wrong_platform["verified"]["nvidia_hpc_benchmarks_oci"]["platforms"]["linux-x86_64-v4"]["oci_platform"] = "linux/arm64"
    invalid_cases.append(("wrong OCI platform", wrong_platform, False))
    divergent_descriptor = copy.deepcopy(complete)
    divergent_descriptor["verified"]["nvidia_hpc_benchmarks_oci"]["platforms"]["linux-x86_64-v4"]["descriptor_digest"] = f"sha256:{400:064x}"
    invalid_cases.append(("divergent same-platform descriptors", divergent_descriptor, False))
    reused_descriptor = copy.deepcopy(complete)
    reused_descriptor["verified"]["nvidia_hpc_benchmarks_oci"]["platforms"]["linux-aarch64-gb300"]["descriptor_digest"] = f"sha256:{2:064x}"
    invalid_cases.append(("cross-platform descriptor reuse", reused_descriptor, False))
    divergent_config = copy.deepcopy(complete)
    divergent_config["verified"]["nvidia_hpc_benchmarks_oci"]["platforms"]["linux-x86_64-v4"]["config_digest"] = f"sha256:{401:064x}"
    invalid_cases.append(("descriptor/config chain mismatch", divergent_config, False))
    malformed_config = copy.deepcopy(complete)
    malformed_config["verified"]["nvidia_hpc_benchmarks_oci"]["platforms"]["linux-aarch64-gb300"]["config_digest"] = "sha256:not-a-digest"
    invalid_cases.append(("malformed config digest", malformed_config, False))
    missing_category = copy.deepcopy(complete)
    del missing_category["verified"]["builder_tools"]
    invalid_cases.append(("missing category", missing_category, False))
    with tempfile.TemporaryDirectory(prefix="chapar-image-lock-test-") as directory:
        for name, invalid_document, require_complete in invalid_cases:
            fixture = Path(directory) / f"{re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')}.json"
            fixture.write_text(json.dumps(invalid_document), encoding="utf-8")
            try:
                if name == "wrong target mapping":
                    validate_targets(load_json(fixture))
                else:
                    validate_source_shape(load_json(fixture), require_complete)
            except ValueError as error:
                print(f"self-test case: rejected {name}: {error}")
                continue
            raise AssertionError(f"invalid fixture was accepted: {name}")
    try:
        json.loads('{"duplicate": 1, "duplicate": 2}', object_pairs_hook=unique_object)
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate JSON key fixture was accepted")
    print("self-test case: rejected duplicate JSON keys")
    print("self-test: accepted synthetic complete lock with shared linux/amd64 and distinct linux/arm64 OCI chains")

print("base category | target | OCI platform | index digest | platform descriptor | config digest")
for category, base in oci_bases.items():
    oci = sources["verified"].get(category, {})
    index_digest = oci.get("index_digest", "UNRESOLVED")
    platforms = oci.get("platforms", {})
    for target_name in base["targets"]:
        target = targets["targets"][target_name]
        platform = platforms.get(target_name, {})
        print(
            f"{category} | {target_name} | {target['oci_platform']} | {index_digest} | "
            f"{platform.get('descriptor_digest', 'UNRESOLVED')} | {platform.get('config_digest', 'UNRESOLVED')}"
        )
print("target | native | Spack | LLVM | CUDA")
for target_name, target in targets["targets"].items():
    print(f"{target_name} | {target['native_arch']} | {target['spack_target']} | {','.join(target['llvm_targets'])} | {','.join(target['cuda_arch'])}")
print(f"source lock status: {sources['status']} ({len(sources['unresolved'])} unresolved categories)")
PY
