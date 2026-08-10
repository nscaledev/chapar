"""`chapar catalog` subcommands."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path


def _repo_default(relative: str) -> Path:
    return Path(__file__).resolve().parents[3] / relative


def register(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    catalog = subparsers.add_parser(
        "catalog", help="inspect the software catalog and its frozen history"
    )
    commands = catalog.add_subparsers(dest="command", metavar="COMMAND", required=True)

    list_parser = commands.add_parser(
        "list", help="render one software-set composition as JSON"
    )
    list_parser.add_argument(
        "--spack-yaml", type=Path, default=_repo_default("envs/software/spack.yaml"),
        help="catalog path (default: envs/software/spack.yaml)",
    )
    list_parser.add_argument("--set", dest="software_set", choices=("vlad", "hpcsim", "all"), default="all")
    list_parser.add_argument("--arch", choices=("x86_64", "aarch64"), default="x86_64")
    list_parser.add_argument("--output", type=Path, help="write the JSON report here instead of stdout")
    list_parser.set_defaults(handler=_run_list)

    readme_parser = commands.add_parser(
        "readme", help="render or check the generated envs/software/README.md"
    )
    readme_parser.add_argument(
        "--spack-yaml", type=Path, default=_repo_default("envs/software/spack.yaml")
    )
    group = readme_parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--render", action="store_true", help="print the generated README to stdout")
    group.add_argument("--check", type=Path, metavar="README", help="fail if README differs from the render")
    readme_parser.set_defaults(handler=_run_readme)

    inventory_parser = commands.add_parser(
        "inventory", help="report on the frozen historical root inventory"
    )
    inventory_parser.add_argument(
        "inventory", type=Path, nargs="?",
        default=_repo_default("envs/software/tests/fixtures/historical-root-inventory.json"),
    )
    inventory_parser.add_argument("--output", type=Path, help="write the JSON report here instead of stdout")
    inventory_parser.add_argument(
        "--validate-protected-policy", type=Path, metavar="POLICY",
        help="validate a protected-state policy file instead of reporting",
    )
    inventory_parser.set_defaults(handler=_run_inventory)


def _run_list(arguments: argparse.Namespace) -> int:
    from chapar.catalog.model import load_roots, selected

    roots = load_roots(arguments.spack_yaml)
    selected_roots, exclusions = selected(roots, arguments.software_set, arguments.arch)
    rendered = (
        json.dumps(
            {
                "architecture": arguments.arch,
                "exclusions": [asdict(root) for root in exclusions],
                "root_count": len(selected_roots),
                "roots": [asdict(root) for root in selected_roots],
                "software_set": arguments.software_set,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    if arguments.output is None:
        print(rendered, end="")
    else:
        arguments.output.write_text(rendered, encoding="utf-8")
    return 0


def _run_readme(arguments: argparse.Namespace) -> int:
    from chapar.catalog.model import load_roots
    from chapar.catalog.readme import render_readme

    rendered = render_readme(load_roots(arguments.spack_yaml))
    if arguments.render:
        print(rendered, end="")
        return 0
    if arguments.check.read_text(encoding="utf-8") != rendered:
        print("catalog error: generated README is stale", file=sys.stderr)
        return 2
    print("catalog README is current")
    return 0


def _run_inventory(arguments: argparse.Namespace) -> int:
    from chapar.catalog.inventory import load_historical_roots, report, validate_protected_policy

    if arguments.validate_protected_policy is not None:
        validate_protected_policy(arguments.validate_protected_policy)
        print("protected-state policy valid")
        return 0
    rendered = json.dumps(report(load_historical_roots(arguments.inventory)), indent=2, sort_keys=True) + "\n"
    if arguments.output is None:
        print(rendered, end="")
    else:
        arguments.output.write_text(rendered, encoding="utf-8")
    return 0
