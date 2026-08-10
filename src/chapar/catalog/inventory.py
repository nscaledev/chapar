"""Reporting over the frozen historical root inventory.

The historical inventory (tests/fixtures/historical-root-inventory.json) is a
frozen record of the pre-catalog vlad/hpcsim root specs. The report it renders
is what the catalog's composition is reviewed against; the protected-state
policy pins the two files whose bytes must never change silently.
"""

from __future__ import annotations

import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypedDict

from chapar.common.jsonio import JsonValue, fail, load_json, mapping, string, strings

ORIGIN_SOURCES: Final = {
    "shared": ("hpcsim", "vlad"),
    "vlad-only": ("vlad",),
    "hpcsim-only": ("hpcsim",),
}
PACKAGE_NAME: Final = re.compile(r"^([a-z0-9][a-z0-9-]*)")
ROOT_FORMAT: Final = "chapar-historical-root-inventory-v1"
POLICY_FORMAT: Final = "chapar-protected-state-v1"


class InventoryCounts(TypedDict):
    vlad: int
    hpcsim: int
    shared: int
    vlad_only: int
    hpcsim_only: int
    variant_difference_packages: int


class SpecDifferences(TypedDict):
    shared: list[str]
    vlad_only: list[str]
    hpcsim_only: list[str]


class PackageDifferences(TypedDict):
    vlad_only: list[str]
    hpcsim_only: list[str]


class VariantDifference(TypedDict):
    vlad: list[str]
    hpcsim: list[str]


class InventoryReport(TypedDict):
    counts: InventoryCounts
    exact_spec_differences: SpecDifferences
    package_name_differences: PackageDifferences
    variant_differences: dict[str, VariantDifference]


@dataclass(frozen=True, slots=True)
class HistoricalRoot:
    identifier: str
    spec: str
    origin: str
    sources: tuple[str, ...]
    package: str


def _normalized_spec(value: JsonValue, label: str) -> tuple[str, str]:
    specification = string(value, label)
    normalized = " ".join(specification.split())
    if specification != normalized:
        fail(f"{label} is not normalized")
    name = PACKAGE_NAME.match(normalized)
    if name is None:
        fail(f"{label} has no package name")
    return normalized, name.group(1)


def load_historical_roots(path: Path) -> tuple[HistoricalRoot, ...]:
    document = load_json(path)
    if document.get("format") != ROOT_FORMAT:
        fail("unsupported inventory format")
    raw_roots = document.get("roots")
    if not isinstance(raw_roots, list) or not raw_roots:
        fail("roots must be a non-empty list")
    roots: list[HistoricalRoot] = []
    identifiers: set[str] = set()
    specifications: set[str] = set()
    package_shared_specs: dict[str, set[str]] = defaultdict(set)
    for position, raw_root in enumerate(raw_roots):
        root = mapping(raw_root, f"roots[{position}]")
        identifier = string(root.get("id"), f"roots[{position}].id")
        if identifier in identifiers:
            fail(f"duplicate root id: {identifier}")
        identifiers.add(identifier)
        spec, package = _normalized_spec(root.get("spec"), f"roots[{position}].spec")
        if spec in specifications:
            fail(f"duplicate root spec: {spec}")
        specifications.add(spec)
        origin = root.get("origin")
        if origin is None:
            fail(f"missing origin: roots[{position}]")
        origin_name = string(origin, f"roots[{position}].origin")
        expected_sources = ORIGIN_SOURCES.get(origin_name)
        if expected_sources is None:
            fail(f"unsupported origin: {origin_name}")
        sources = tuple(sorted(strings(root.get("historical_sources"), f"roots[{position}].historical_sources")))
        if sources != expected_sources:
            fail(f"origin/source mismatch for {identifier}")
        if origin_name == "shared":
            package_shared_specs[package].add(spec)
        roots.append(HistoricalRoot(identifier, spec, origin_name, sources, package))
    for package, specs in package_shared_specs.items():
        if len(specs) > 1:
            fail(f"shared provenance forbids variants of package: {package}")
    return tuple(roots)


def report(roots: tuple[HistoricalRoot, ...]) -> InventoryReport:
    by_origin: dict[str, list[HistoricalRoot]] = defaultdict(list)
    by_package: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for root in roots:
        by_origin[root.origin].append(root)
        for source in root.sources:
            by_package[root.package][source].add(root.spec)
    package_only = PackageDifferences(vlad_only=[], hpcsim_only=[])
    variants: dict[str, VariantDifference] = {}
    for package, source_specs in sorted(by_package.items()):
        vlad_specs = source_specs.get("vlad", set())
        hpcsim_specs = source_specs.get("hpcsim", set())
        if not hpcsim_specs:
            package_only["vlad_only"].append(package)
        elif not vlad_specs:
            package_only["hpcsim_only"].append(package)
        elif vlad_specs != hpcsim_specs:
            variants[package] = {"vlad": sorted(vlad_specs), "hpcsim": sorted(hpcsim_specs)}

    def specs(origin: str) -> list[str]:
        return sorted(root.spec for root in by_origin[origin])

    return {
        "counts": {
            "vlad": sum("vlad" in root.sources for root in roots),
            "hpcsim": sum("hpcsim" in root.sources for root in roots),
            "shared": len(by_origin["shared"]),
            "vlad_only": len(by_origin["vlad-only"]),
            "hpcsim_only": len(by_origin["hpcsim-only"]),
            "variant_difference_packages": len(variants),
        },
        "exact_spec_differences": {
            "shared": specs("shared"),
            "vlad_only": specs("vlad-only"),
            "hpcsim_only": specs("hpcsim-only"),
        },
        "package_name_differences": package_only,
        "variant_differences": variants,
    }


def validate_protected_policy(path: Path) -> None:
    document = load_json(path)
    if document.get("format") != POLICY_FORMAT:
        fail("unsupported protected-state format")
    roots = tuple(sorted(strings(document.get("legacy_deployment_roots"), "legacy_deployment_roots")))
    if roots != ("/resources/chapar/hpcsim", "/resources/chapar/vlad"):
        fail("protected legacy roots must be exact")
    # The retired hpcsim legacy lock left the tree with envs/hpcsim/; its bytes
    # stay reachable from git history. The source lock is the one protected
    # file that still gates behavior (image builds).
    files = document.get("tracked_files")
    if not isinstance(files, list) or len(files) != 1:
        fail("tracked_files must contain exactly the protected source lock")
    expected_paths = {"containers/images/sources-lock.json"}
    actual_paths = {string(mapping(item, "tracked_files item").get("path"), "tracked_files path") for item in files}
    if actual_paths != expected_paths:
        fail("tracked_files paths must be exact")
    for item in files:
        value = mapping(item, "tracked_files item")
        string(value.get("head_blob"), "tracked_files head_blob")
        string(value.get("sha256"), "tracked_files sha256")
