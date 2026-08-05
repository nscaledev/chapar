from __future__ import annotations

from pathlib import Path
from typing import Final

import yaml

type YamlValue = None | bool | int | float | str | list["YamlValue"] | dict[str, "YamlValue"]
EXPECTED_REQUIRE: Final = [
    {"spec": "target=x86_64_v4", "when": "target=x86_64"},
    {"spec": "target=aarch64", "when": "target=aarch64"},
]


class PolicyError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PolicyError(message)


def load_yaml(path: Path) -> YamlValue:
    try:
        value: YamlValue = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise PolicyError(f"malformed YAML: {path}: {error}") from error
    require(value is not None, f"malformed YAML: {path}: empty document")
    return value


def as_mapping(value: YamlValue, label: str) -> dict[str, YamlValue]:
    require(isinstance(value, dict), f"{label} must be a mapping")
    return value


def as_list(value: YamlValue, label: str) -> list[YamlValue]:
    require(isinstance(value, list), f"{label} must be a list")
    return value


def validate_structure(yaml_path: Path, targets_path: Path) -> dict[str, YamlValue]:
    root = as_mapping(load_yaml(yaml_path), "document")
    spack = as_mapping(root.get("spack"), "spack")
    packages = as_mapping(spack.get("packages"), "spack.packages")
    all_policy = as_mapping(packages.get("all"), "spack.packages.all")
    require("target" not in all_policy, "unconditional Vlad target remains")
    requirements = as_list(all_policy.get("require"), "spack.packages.all.require")
    require(requirements == EXPECTED_REQUIRE, "architecture requirements do not match exact policy")
    registry = as_mapping(load_yaml(targets_path), "target registry")
    targets = as_mapping(registry.get("targets"), "target registry targets")
    x86 = as_mapping(targets.get("linux-x86_64-v4"), "x86 target")
    arm = as_mapping(targets.get("linux-aarch64-gb300"), "arm target")
    require(x86.get("native_arch") == "x86_64" and x86.get("spack_target") == "x86_64_v4", "x86 target registry mismatch")
    require(arm.get("native_arch") == "aarch64" and arm.get("spack_target") == "aarch64", "arm target registry mismatch")
    return packages


def concrete_targets(value: YamlValue) -> list[str]:
    matches: list[str] = []
    if isinstance(value, dict):  # noqa: IF_VARIANT_OK - recursive YAML union boundary
        target = value.get("target")
        if isinstance(target, str):
            matches.append(target)
        elif isinstance(target, dict) and isinstance(target.get("name"), str):
            matches.append(target["name"])
        for child in value.values():
            matches.extend(concrete_targets(child))
    elif isinstance(value, list):
        for child in value:
            matches.extend(concrete_targets(child))
    return matches


def concrete_target(value: YamlValue) -> str:
    root = as_mapping(value, "concrete YAML")
    require(set(root) == {"spec"}, "concrete YAML structure mismatch")
    spec = as_mapping(root["spec"], "concrete YAML spec")
    require(set(spec) in ({"nodes"}, {"_meta", "nodes"}), "concrete YAML structure mismatch")
    nodes = as_list(spec["nodes"], "concrete YAML nodes")
    require(bool(nodes), "concrete YAML target absent")
    targets: list[str] = []
    for value_node in nodes:
        node = as_mapping(value_node, "concrete YAML node")
        direct = node.get("target")
        if direct is not None:
            selected = as_mapping(direct, "concrete YAML node target").get("name")
        else:
            require(node.get("arch") is not None, "concrete YAML target absent")
            selected = as_mapping(node["arch"], "concrete YAML node arch").get("target")
        require(isinstance(selected, str), "concrete YAML target malformed")
        require(concrete_targets(node) == [selected], "concrete YAML target ambiguity")
        targets.append(selected)
    require(len(set(targets)) == 1, "concrete YAML target ambiguity")
    return targets[0]
