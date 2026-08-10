"""`chapar cve scan` behavior: verified inventory, NVD/OSV queries, issue publication.

Stdlib only. `--plan` stays fully offline: it prints the verified release
inventory and returns before any configuration or network access.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from dataclasses import dataclass, replace
from pathlib import Path

from chapar.common.jsonio import JsonObject, fail
from chapar.cve.github_issues import (
    GitHubIssueTarget,
    create_github_issue,
    github_issue_exists,
    issue_title,
)
from chapar.cve.http_client import HttpRequestError
from chapar.cve.inventory import load_config, load_release_inventory, with_config_aliases
from chapar.cve.models import SEVERITY_ORDER, Finding, Package
from chapar.cve.nemotron import summarize_with_nemotron
from chapar.cve.nvd import NvdQueryOptions, fetch_nvd_findings
from chapar.cve.osv import fetch_osv_findings


@dataclass(frozen=True, slots=True)
class ScanPlan:
    packages: tuple[Package, ...]
    config: JsonObject
    nvd: NvdQueryOptions
    include_osv: bool


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    return default if raw is None else raw.strip().lower() in {"1", "true", "yes", "on"}


def require_proxy_if_requested() -> None:
    if env_bool("CHAPAR_CVE_REQUIRE_PROXY", False) and not (
        os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    ):
        fail("CHAPAR_CVE_REQUIRE_PROXY=true but HTTPS_PROXY is not set")


def write_state(state_dir: Path, findings: list[Finding]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "last_run_utc": dt.datetime.now(dt.UTC).isoformat(),
        "findings": [
            {
                "package": finding.package.label,
                "cve": finding.cve_id,
                "severity": finding.severity,
                "source": finding.source,
                "url": finding.url,
            }
            for finding in findings
        ],
    }
    (state_dir / "last-run.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def scan_packages(plan: ScanPlan) -> list[Finding]:
    all_findings: dict[tuple[str, str], Finding] = {}
    for package in plan.packages:
        print(f"Checking {package.label}", flush=True)
        try:
            findings = fetch_nvd_findings(package, plan.config, plan.nvd)
        except HttpRequestError as error:
            print(f"WARNING: NVD query failed for {package.label}: {error}", flush=True)
            continue
        for finding in findings:
            all_findings[(finding.package.name, finding.cve_id)] = finding
    if plan.include_osv:
        try:
            for finding in fetch_osv_findings(
                list(plan.packages), plan.config, plan.nvd.threshold
            ):
                all_findings[(finding.package.name, finding.cve_id)] = finding
        except HttpRequestError as error:
            print(f"WARNING: OSV query failed: {error}", flush=True)
    return sorted(all_findings.values(), key=lambda item: (item.package.name, item.cve_id))


def publish_findings(
    findings: list[Finding], target: GitHubIssueTarget
) -> None:
    for finding in findings:
        if github_issue_exists(target.repo, target.token, finding):
            print(f"Issue already exists for {finding.package.label} {finding.cve_id}", flush=True)
            continue
        issue_url = create_github_issue(finding, target)
        print(f"Created issue for {finding.package.label} {finding.cve_id}: {issue_url}", flush=True)


def run(args: argparse.Namespace) -> int:
    packages, policy = load_release_inventory(args.release_dir)
    if args.plan:
        print(json.dumps({
            "policy": policy.as_json(),
            "package_count": len(packages),
            "packages": [package.label for package in packages],
        }, sort_keys=True))
        return 0
    require_proxy_if_requested()
    config = load_config(args.config)
    if args.package:
        packages = [package for package in packages if package.name in set(args.package)]
    packages = with_config_aliases(packages, config)
    if args.max_packages > 0:
        packages = packages[:args.max_packages]
    if not packages:
        fail("package inventory is empty")

    threshold = args.severity_threshold or str(config.get("severity_threshold", "HIGH")).upper()
    if threshold not in SEVERITY_ORDER:
        fail(f"unsupported severity threshold: {threshold}")
    raw_lookback_days = config.get("lookback_days", 30)
    if args.lookback_days is not None:
        lookback_days = args.lookback_days
    elif isinstance(raw_lookback_days, (str, int, float)) and not isinstance(raw_lookback_days, bool):
        lookback_days = int(raw_lookback_days)
    else:
        fail("config lookback_days must be an integer")
    if lookback_days > 120:
        fail("NVD date windows must be 120 days or less; use --lookback-days 0 to omit date filtering")
    nvd_api_key = os.environ.get("NVD_API_KEY", "").strip() or None
    delay = args.nvd_delay if args.nvd_delay is not None else (0.7 if nvd_api_key else 6.1)
    dry_run = False if args.live else env_bool("CHAPAR_CVE_DRY_RUN", True) or args.dry_run
    print(
        f"Scanning {len(packages)} release packages; threshold={threshold}; "
        f"lookback_days={lookback_days}; dry_run={dry_run}",
        flush=True,
    )
    findings = scan_packages(ScanPlan(
        packages=tuple(packages),
        config=config,
        nvd=NvdQueryOptions(threshold, lookback_days, delay, nvd_api_key),
        include_osv=not args.no_osv,
    ))
    print(f"Matched {len(findings)} reportable CVE findings", flush=True)
    if not args.no_nemotron:
        findings = [
            replace(finding, nemotron_summary=summarize_with_nemotron(finding))
            for finding in findings
        ]
    write_state(args.state_dir, findings)
    if dry_run:
        for finding in findings:
            print(f"DRY-RUN {issue_title(finding)} {finding.url}", flush=True)
        return 0

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        fail("GITHUB_TOKEN is required when --live is used")
    repo = args.github_repo or str(config.get("github_repo", "")).strip()
    if not repo or "/" not in repo:
        fail("github_repo must be configured as owner/name")
    raw_labels = config.get("issue_labels", [])
    labels = [str(label) for label in raw_labels] if isinstance(raw_labels, list) else []
    publish_findings(
        findings,
        GitHubIssueTarget(repo, token, policy, tuple(labels)),
    )
    return 0
