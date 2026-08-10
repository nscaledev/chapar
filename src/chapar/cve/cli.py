"""`chapar cve` subcommands."""

from __future__ import annotations

import argparse
from pathlib import Path

from chapar.cve.models import SEVERITY_ORDER


def _repo_default(relative: str) -> Path:
    return Path(__file__).resolve().parents[3] / relative


def register(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    cve = subparsers.add_parser(
        "cve", help="scan a release's package inventory for CVEs"
    )
    commands = cve.add_subparsers(dest="command", metavar="COMMAND", required=True)

    scan_parser = commands.add_parser(
        "scan", help="check a verified release's concrete roots against NVD and OSV"
    )
    scan_parser.add_argument(
        "--release-dir", type=Path, required=True,
        help="immutable release directory (metadata.json + spack.lock) whose roots are scanned",
    )
    scan_parser.add_argument(
        "--config", type=Path, default=_repo_default("ci/cve-checker-config.json"),
        help="checker configuration (default: ci/cve-checker-config.json)",
    )
    scan_parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/chapar-cve-checker"))
    scan_parser.add_argument("--github-repo", help="Override GitHub repo owner/name")
    scan_parser.add_argument("--package", action="append", default=[], help="Limit scan to one package name; repeatable")
    scan_parser.add_argument("--max-packages", type=int, default=0, help="Limit number of packages for smoke testing")
    scan_parser.add_argument("--lookback-days", type=int, help="Only query CVEs published within this many days")
    scan_parser.add_argument("--severity-threshold", choices=sorted(SEVERITY_ORDER), help="Minimum severity to report")
    scan_parser.add_argument("--nvd-delay", type=float, help="Delay between NVD requests")
    scan_parser.add_argument("--dry-run", action="store_true", help="Do not create GitHub issues")
    scan_parser.add_argument("--plan", action="store_true", help="Print the verified offline inventory plan")
    scan_parser.add_argument("--live", action="store_true", help="Create GitHub issues")
    scan_parser.add_argument("--no-nemotron", action="store_true", help="Do not call Nemotron for summaries")
    scan_parser.add_argument("--no-osv", action="store_true", help="Skip optional OSV queries")
    scan_parser.set_defaults(handler=_run_scan)


def _run_scan(arguments: argparse.Namespace) -> int:
    from chapar.cve.scan import run

    return run(arguments)
