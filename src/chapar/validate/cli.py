"""`chapar validate` subcommands."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path

from chapar.validate.analyze import SUITES


def register(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    validate = subparsers.add_parser(
        "validate", help="plan release-bound validation and analyze suite results"
    )
    commands = validate.add_subparsers(dest="command", metavar="COMMAND", required=True)

    plan = commands.add_parser(
        "plan",
        help="render the validation plan for one immutable release directory",
        description="Verifies a release directory (metadata digests, identity, target facts), "
        "derives the module tree and expected root inventory from the release itself, and "
        "renders the plan. Site settings supply CHAPAR_VALIDATION_ROOT and CHAPAR_SLURM_*.",
    )
    plan.add_argument("--release-dir", type=Path, required=True, help="immutable release directory")
    plan.add_argument("--test", default="", help="validation suite name (validation/tests/<name>.sbatch)")
    plan.add_argument(
        "--format", choices=("plan", "shell", "checks"), default="plan",
        help="plan: JSON; shell: tab-separated identity/paths; checks: per-root module checks",
    )
    plan.add_argument(
        "--run-id", default="",
        help="validation-run id namespacing the results root (default: generated manual-<utc>)",
    )
    plan.add_argument(
        "--results-root", type=Path,
        help="results directory (default: $CHAPAR_VALIDATION_ROOT/<set>/<target>/<release-id>/<run-id>)",
    )
    plan.add_argument(
        "--seal-dir", type=Path,
        help="write read-only copies of metadata.json and spack.lock here as submission evidence",
    )
    plan.set_defaults(handler=_run_plan)

    analyze = commands.add_parser(
        "analyze", help="MAD-based outlier analysis of a suite's results directory"
    )
    analyze.add_argument("--suite", required=True, choices=SUITES, help="validation suite to analyze")
    analyze.add_argument("--threshold", type=float, default=2.0, help="robust z-score threshold (default: 2.0)")
    analyze.add_argument("--results-dir", required=True, help="path to per-suite results directory")
    analyze.add_argument("--prometheus", action="store_true", help="output metrics in Prometheus exposition format")
    analyze.set_defaults(handler=_run_analyze)


def _run_plan(arguments: argparse.Namespace) -> int:
    from chapar.validate.plan import build_plan

    plan = build_plan(
        arguments.release_dir,
        test=arguments.test,
        run_id=arguments.run_id,
        results_root=arguments.results_root,
        seal_dir=arguments.seal_dir,
    )
    if arguments.format == "plan":
        print(json.dumps(asdict(plan), sort_keys=True))
    elif arguments.format == "checks":
        for check in plan.checks:
            print(f"{check.module}\t{check.command}\t{check.description}")
    else:
        values = (
            plan.software_set, plan.target, plan.release_id, plan.release_run_id,
            plan.module_path, plan.results_root,
        )
        print("\t".join(values))
    return 0


def _run_analyze(arguments: argparse.Namespace) -> int:
    from chapar.validate.analyze import analyze

    return analyze(arguments.suite, arguments.threshold, arguments.results_dir, arguments.prometheus)
