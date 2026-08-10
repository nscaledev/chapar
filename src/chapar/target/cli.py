"""`chapar target` subcommands."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path


def register(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    target = subparsers.add_parser(
        "target", help="inspect target facts and render per-target Spack scopes"
    )
    commands = target.add_subparsers(dest="command", metavar="COMMAND", required=True)

    scope = commands.add_parser(
        "scope",
        help="render the packages.yaml requirements scope for one target",
        description="Renders target facts (Spack target, LLVM targets, CUDA architectures) "
        "as Spack package requirements. release.sh copies this file into its "
        "command-line scope so the requirements bind transitive packages too.",
    )
    scope.add_argument("--target", required=True, help="target id from the registry")
    scope.add_argument("--targets", type=Path, default=None, help="registry path (default: containers/images/targets.json)")
    scope.add_argument("--output", type=Path, help="directory to write packages.yaml into (default: stdout)")
    scope.set_defaults(handler=_run_scope)

    list_parser = commands.add_parser("list", help="list registered targets and their facts as JSON")
    list_parser.add_argument("--targets", type=Path, default=None)
    list_parser.set_defaults(handler=_run_list)


def _run_scope(arguments: argparse.Namespace) -> int:
    from chapar.target.scope import default_targets_path, render_packages_yaml, resolve_target

    registry = arguments.targets if arguments.targets is not None else default_targets_path()
    facts = resolve_target(registry, arguments.target)
    rendered = render_packages_yaml(facts)
    if arguments.output is None:
        print(rendered, end="")
        return 0
    arguments.output.mkdir(parents=True, exist_ok=True)
    (arguments.output / "packages.yaml").write_text(rendered, encoding="utf-8")
    return 0


def _run_list(arguments: argparse.Namespace) -> int:
    from chapar.target.scope import default_targets_path, load_targets

    registry = arguments.targets if arguments.targets is not None else default_targets_path()
    targets = load_targets(registry)
    print(json.dumps({name: asdict(facts) for name, facts in sorted(targets.items())}, indent=2))
    return 0
