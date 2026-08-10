"""Optional OSV batch queries for explicitly configured ecosystems. Stdlib only."""

from __future__ import annotations

import json
import urllib.request
from typing import Final

from chapar.common.jsonio import JsonObject
from chapar.cve.http_client import urlopen_json
from chapar.cve.models import Finding, Package
from chapar.cve.nvd import severity_allowed

OSV_BATCH_API: Final = "https://api.osv.dev/v1/querybatch"


def fetch_osv_findings(
    packages: list[Package], config: JsonObject, threshold: str
) -> list[Finding]:
    raw_package_config = config.get("packages", {})
    package_config = raw_package_config if isinstance(raw_package_config, dict) else {}
    queries: list[JsonObject] = []
    query_packages: list[Package] = []
    for package in packages:
        osv = package_config.get(package.name, {})
        if not isinstance(osv, dict):
            continue
        raw_osv = osv.get("osv")
        if not isinstance(raw_osv, dict) or not raw_osv.get("ecosystem"):
            continue
        query: JsonObject = {
            "package": {
                "name": raw_osv.get("name", package.name),
                "ecosystem": raw_osv["ecosystem"],
            }
        }
        if package.version:
            query["version"] = package.version
        queries.append(query)
        query_packages.append(package)
    if not queries:
        return []

    request = urllib.request.Request(
        OSV_BATCH_API,
        data=json.dumps({"queries": queries}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "chapar-cve-checker/1.0"},
        method="POST",
    )
    data = urlopen_json(request)
    results = data.get("results", [])
    if not isinstance(results, list):
        return []
    findings: list[Finding] = []
    for package, result in zip(query_packages, results, strict=False):
        vulns = result.get("vulns", []) if isinstance(result, dict) else []
        if not isinstance(vulns, list):
            continue
        for vuln in vulns:
            if not isinstance(vuln, dict):
                continue
            aliases = vuln.get("aliases", [])
            alias_values = aliases if isinstance(aliases, list) else []
            cve_id = next(
                (str(alias) for alias in alias_values if str(alias).startswith("CVE-")),
                str(vuln.get("id", "")),
            )
            severity = "HIGH"
            if not severity_allowed(severity, threshold):
                continue
            raw_references = vuln.get("references", [])
            references = raw_references if isinstance(raw_references, list) else []
            urls = tuple(
                str(reference["url"])
                for reference in references[:10]
                if isinstance(reference, dict) and reference.get("url")
            )
            database_specific = vuln.get("database_specific", {})
            source_url = database_specific.get("url") if isinstance(database_specific, dict) else None
            findings.append(Finding(
                package, "OSV", cve_id, severity, None,
                str(vuln.get("published")) if vuln.get("published") else None,
                str(vuln.get("modified")) if vuln.get("modified") else None,
                str(vuln.get("summary") or vuln.get("details") or "No OSV summary was provided."),
                str(source_url or f"https://osv.dev/vulnerability/{vuln.get('id')}"),
                urls, "OSV package query",
            ))
    return findings
