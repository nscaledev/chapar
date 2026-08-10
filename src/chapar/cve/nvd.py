"""NVD keyword queries and deterministic package matching. Stdlib only."""

from __future__ import annotations

import datetime as dt
import re
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Final

from chapar.common.jsonio import JsonObject, JsonValue
from chapar.cve.http_client import urlopen_json
from chapar.cve.models import SEVERITY_ORDER, Finding, Package

NVD_API: Final = "https://services.nvd.nist.gov/rest/json/cves/2.0"


@dataclass(frozen=True, slots=True)
class NvdQueryOptions:
    threshold: str
    lookback_days: int
    delay_seconds: float
    api_key: str | None


def nvd_query_terms(package: Package, config: JsonObject) -> list[str]:
    packages = config.get("packages", {})
    package_config = packages.get(package.name, {}) if isinstance(packages, dict) else {}
    configured = package_config.get("nvd_keywords", []) if isinstance(package_config, dict) else []
    terms: list[str] = []
    if isinstance(configured, list) and configured:
        for template in configured:
            term = str(template).format(name=package.name, version=package.version or "").strip()
            if term and term not in terms:
                terms.append(term)
        return terms
    for alias in package.aliases or (package.name,):
        term = f"{alias} {package.version}" if package.version else alias
        if term not in terms:
            terms.append(term)
    return terms[:3]


def nvd_reference_items(cve: JsonObject) -> list[JsonObject]:
    references = cve.get("references", [])
    if isinstance(references, dict):
        candidate_items = references.get("referenceData", [])
        raw_items = candidate_items if isinstance(candidate_items, list) else []
    else:
        raw_items = references if isinstance(references, list) else []
    return [item for item in raw_items if isinstance(item, dict)]


def cve_text(cve: JsonObject) -> str:
    parts: list[str] = []
    descriptions = cve.get("descriptions", [])
    if isinstance(descriptions, list):
        for description in descriptions:
            if isinstance(description, dict) and description.get("value"):
                parts.append(str(description["value"]))
    for reference in nvd_reference_items(cve):
        if reference.get("url"):
            parts.append(str(reference["url"]))

    def walk_config(node: JsonValue) -> None:
        if isinstance(node, dict):
            criteria = node.get("criteria")
            if criteria:
                parts.append(str(criteria))
            for value in node.values():
                walk_config(value)
            return
        if isinstance(node, list):
            for value in node:
                walk_config(value)

    walk_config(cve.get("configurations", []))
    return "\n".join(parts)


def candidate_matches_package(package: Package, cve: JsonObject) -> bool:
    text = cve_text(cve).lower()
    for alias in package.aliases or (package.name,):
        normalized = re.escape(alias.lower()).replace(r"\ ", r"[\s_.-]+")
        if re.search(rf"(?<![a-z0-9]){normalized}(?![a-z0-9])", text):
            return True
    return False


def extract_summary(cve: JsonObject) -> str:
    descriptions = cve.get("descriptions", [])
    if not isinstance(descriptions, list):
        return "No NVD English description was provided."
    for description in descriptions:
        if isinstance(description, dict) and description.get("lang") == "en" and description.get("value"):
            return str(description["value"])
    for description in descriptions:
        if isinstance(description, dict) and description.get("value"):
            return str(description["value"])
    return "No NVD English description was provided."


def extract_severity(cve: JsonObject) -> tuple[str, float | None]:
    metrics = cve.get("metrics", {})
    if not isinstance(metrics, dict):
        return "NONE", None
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30", "cvssMetricV2"):
        entries = metrics.get(key, [])
        if not isinstance(entries, list) or not entries:
            continue
        primary = next(
            (entry for entry in entries if isinstance(entry, dict) and entry.get("type") == "Primary"),
            entries[0],
        )
        if not isinstance(primary, dict):
            continue
        raw_cvss = primary.get("cvssData", {})
        cvss = raw_cvss if isinstance(raw_cvss, dict) else {}
        severity = cvss.get("baseSeverity") or primary.get("baseSeverity") or "NONE"
        score = cvss.get("baseScore")
        if isinstance(score, (str, int, float)) and not isinstance(score, bool):
            try:
                score_value = float(score)
            except ValueError:
                score_value = None
        else:
            score_value = None
        return str(severity).upper(), score_value
    return "NONE", None


def severity_allowed(severity: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(severity.upper(), 0) >= SEVERITY_ORDER.get(threshold.upper(), 3)


def extract_references(cve: JsonObject) -> tuple[str, ...]:
    references: list[str] = []
    for reference in nvd_reference_items(cve):
        url = reference.get("url")
        if url and url not in references:
            references.append(str(url))
    return tuple(references[:10])


def fetch_nvd_findings(
    package: Package,
    config: JsonObject,
    options: NvdQueryOptions,
) -> list[Finding]:
    findings: dict[str, Finding] = {}
    now = dt.datetime.now(dt.UTC).replace(tzinfo=None)
    params_base = {"resultsPerPage": str(config.get("max_results_per_query", 100))}
    if options.lookback_days > 0:
        start = now - dt.timedelta(days=options.lookback_days)
        params_base["pubStartDate"] = start.strftime("%Y-%m-%dT%H:%M:%S.000")
        params_base["pubEndDate"] = now.strftime("%Y-%m-%dT%H:%M:%S.000")
    for term in nvd_query_terms(package, config):
        params = {**params_base, "keywordSearch": term}
        url = f"{NVD_API}?{urllib.parse.urlencode(params)}"
        headers = {"User-Agent": "chapar-cve-checker/1.0"}
        if options.api_key:
            headers["apiKey"] = options.api_key
        data = urlopen_json(urllib.request.Request(url, headers=headers))
        vulnerabilities = data.get("vulnerabilities", [])
        if not isinstance(vulnerabilities, list):
            continue
        for item in vulnerabilities:
            cve = item.get("cve", {}) if isinstance(item, dict) else {}
            if not isinstance(cve, dict):
                continue
            cve_id = str(cve.get("id", "")).strip()
            if not cve_id or cve_id in findings or not candidate_matches_package(package, cve):
                continue
            severity, score = extract_severity(cve)
            if not severity_allowed(severity, options.threshold):
                continue
            findings[cve_id] = Finding(
                package, "NVD", cve_id, severity, score,
                str(cve.get("published")) if cve.get("published") else None,
                str(cve.get("lastModified")) if cve.get("lastModified") else None,
                extract_summary(cve), f"https://nvd.nist.gov/vuln/detail/{cve_id}",
                extract_references(cve), f"NVD keyword query: {term}",
            )
        if options.delay_seconds > 0:
            time.sleep(options.delay_seconds)
    return list(findings.values())
