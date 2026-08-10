"""Parser and set model for the software catalog (envs/software/spack.yaml).

The catalog carries four named root lists whose membership semantics live in
`when:` conditions on CHAPAR_SOFTWARE_SET and CHAPAR_TARGET. This module is the
offline mirror of those semantics: it validates that the conditions in the file
are exactly the canonical ones, so the catalog cannot silently drift from what
this tool (and the docs) claim about set composition.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import yaml

from chapar.common.jsonio import ChaparError, fail

type YamlScalar = str | int | float | bool | None
type YamlValue = YamlScalar | list[YamlValue] | dict[str, YamlValue]

_SET_CONDITION: Final = 'env.get("CHAPAR_SOFTWARE_SET", "all") in ({sets})'
_X86_CONDITION: Final = ' and env.get("CHAPAR_TARGET", "").startswith("linux-x86_64-")'

#: definition name -> (origin label, member sets, architecture tags, exact when condition)
DEFINITIONS: Final[dict[str, tuple[str, tuple[str, ...], tuple[str, ...], str | None]]] = {
    "shared_roots": ("shared", ("vlad", "hpcsim"), (), None),
    "vlad_roots": ("vlad-only", ("vlad",), (), _SET_CONDITION.format(sets='"vlad", "all"')),
    "hpcsim_roots": ("hpcsim-only", ("hpcsim",), (), _SET_CONDITION.format(sets='"hpcsim", "all"')),
    "hpcsim_x86_only_roots": (
        "architecture-limited",
        ("hpcsim",),
        ("x86_64",),
        _SET_CONDITION.format(sets='"hpcsim", "all"') + _X86_CONDITION,
    ),
}
SETS: Final = ("vlad", "hpcsim", "all")
ARCHITECTURES: Final = ("x86_64", "aarch64")


@dataclass(frozen=True, slots=True)
class Root:
    identifier: str
    specification: str
    origin: str
    sets: tuple[str, ...]
    architectures: tuple[str, ...]


class CatalogLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader: CatalogLoader, node: yaml.MappingNode, deep: bool = False) -> dict[str, YamlValue]:
    """Reject duplicate keys before PyYAML silently overwrites them."""
    result: dict[str, YamlValue] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str):
            fail("YAML mapping key must be a string")
        if key in result:
            fail(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


CatalogLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def _mapping(value: YamlValue, label: str) -> dict[str, YamlValue]:
    if not isinstance(value, dict):
        fail(f"{label} must be a mapping")
    return value


def _specifications(value: YamlValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a non-empty string list")
    return tuple(item for item in value if isinstance(item, str))


def load_document(path: Path) -> dict[str, YamlValue]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ChaparError(f"cannot read {path}: {error}") from error
    try:
        loaded = yaml.load(raw, Loader=CatalogLoader)
    except (yaml.YAMLError, ChaparError) as error:
        raise ChaparError(f"malformed YAML: {error}") from error
    return _mapping(loaded, "catalog document")


def load_roots(path: Path) -> tuple[Root, ...]:
    document = load_document(path)
    spack = _mapping(document.get("spack"), "spack")
    definitions = spack.get("definitions")
    if not isinstance(definitions, list):
        fail("spack.definitions must be a list")

    expected_specs = [f"${name}" for name in DEFINITIONS]
    if spack.get("specs") != expected_specs:
        fail(f"spack.specs must reference every root list: {expected_specs}")

    seen: dict[str, tuple[str, ...]] = {}
    for index, raw_definition in enumerate(definitions):
        definition = _mapping(raw_definition, f"definitions[{index}]")
        names = [key for key in definition if key != "when"]
        if len(names) != 1:
            fail(f"definitions[{index}] must have one list name")
        name = names[0]
        if name not in DEFINITIONS:
            fail(f"unknown definition list: {name}")
        if name in seen:
            fail(f"duplicate definition list: {name}")
        expected_condition = DEFINITIONS[name][3]
        if definition.get("when") != expected_condition:
            fail(f"selection condition drifted for {name}: expected {expected_condition!r}")
        seen[name] = _specifications(definition.get(name), name)

    missing = [name for name in DEFINITIONS if name not in seen]
    if missing:
        fail(f"catalog is missing root lists: {', '.join(missing)}")

    roots: list[Root] = []
    specifications: set[str] = set()
    for name, (origin, sets, architectures, _) in DEFINITIONS.items():
        for specification in seen[name]:
            if specification != " ".join(specification.split()):
                fail(f"root spec is not normalized: {specification}")
            if specification in specifications:
                fail(f"duplicate root spec: {specification}")
            specifications.add(specification)
            identifier = f"root-{hashlib.sha256(specification.encode()).hexdigest()[:12]}"
            roots.append(Root(identifier, specification, origin, sets, architectures))
    return tuple(sorted(roots, key=lambda root: root.specification))


def selected(
    roots: tuple[Root, ...], software_set: str, architecture: str
) -> tuple[tuple[Root, ...], tuple[Root, ...]]:
    """Mirror of the catalog `when:` conditions for one (set, architecture)."""
    if software_set not in SETS:
        fail(f"unsupported software set: {software_set}")
    if architecture not in ARCHITECTURES:
        fail(f"unsupported architecture tag: {architecture}")
    selected_roots: list[Root] = []
    exclusions: list[Root] = []
    for root in roots:
        included = software_set == "all" or software_set in root.sets
        compatible = not root.architectures or architecture in root.architectures
        if included and compatible:
            selected_roots.append(root)
        elif included and root.architectures:
            exclusions.append(root)
    return tuple(selected_roots), tuple(exclusions)


def source_report(roots: tuple[Root, ...]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {"shared": [], "vlad-only": [], "hpcsim-only": [], "architecture-limited": []}
    for root in roots:
        grouped[root.origin].append(root.specification)
    return grouped


def variant_differences(roots: tuple[Root, ...]) -> dict[str, dict[str, list[str]]]:
    by_package: dict[str, dict[str, list[str]]] = {}
    for root in roots:
        package = root.specification.split("@", 1)[0].split("+", 1)[0].split("~", 1)[0].split(" ", 1)[0]
        entry = by_package.setdefault(package, {"vlad": [], "hpcsim": []})
        for software_set in root.sets:
            entry[software_set].append(root.specification)
    return {
        package: values
        for package, values in sorted(by_package.items())
        if values["vlad"] and values["hpcsim"] and values["vlad"] != values["hpcsim"]
    }
