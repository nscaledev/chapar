"""Root argument parser.

Every subcommand group registers here and gets --help for free. Group modules
defer their heavy imports (PyYAML, network, ELF parsing) into the command
functions so `chapar --help` and the stdlib-only image pipeline stay importable
on a bare builder with system python3.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from chapar import __version__


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="chapar",
        description="Chapar operator tools: catalog inspection, per-target Spack scopes, "
        "container image pipeline, validation planning, and CVE scanning.",
    )
    parser.add_argument("--version", action="version", version=f"chapar {__version__}")
    subparsers = parser.add_subparsers(dest="group", metavar="GROUP", required=True)

    from chapar.catalog.cli import register as register_catalog
    from chapar.target.cli import register as register_target

    register_catalog(subparsers)
    register_target(subparsers)
    # marker:image-group
    # marker:validate-group
    # marker:cve-group
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    from chapar.common.jsonio import ChaparError

    parser = build_parser()
    arguments = parser.parse_args(argv if argv is not None else sys.argv[1:])
    handler = getattr(arguments, "handler", None)
    if handler is None:
        parser.error("no command selected")
    try:
        result = handler(arguments)
    except ChaparError as error:
        print(f"chapar error: {error}", file=sys.stderr)
        return 2
    return int(result)
