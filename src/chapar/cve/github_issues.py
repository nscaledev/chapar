"""GitHub issue creation with marker-based deduplication. Stdlib only."""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass

from chapar.common.jsonio import JsonObject, JsonValue
from chapar.cve.http_client import HttpRequestError, urlopen_json
from chapar.cve.models import Finding, ReleasePolicy


@dataclass(frozen=True, slots=True)
class GitHubIssueTarget:
    repo: str
    token: str
    policy: ReleasePolicy
    base_labels: tuple[str, ...]


def github_request(
    method: str, path: str, token: str, body: JsonObject | None = None
) -> JsonObject:
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": "chapar-cve-checker/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    request = urllib.request.Request(
        f"https://api.github.com{path}", data=data, headers=headers, method=method
    )
    return urlopen_json(request)


def issue_marker(finding: Finding) -> str:
    return f"chapar-cve-checker:v1 package={finding.package.name} cve={finding.cve_id}"


def github_issue_exists(repo: str, token: str, finding: Finding) -> bool:
    query = f"repo:{repo} is:issue in:body {issue_marker(finding)}"
    data = github_request("GET", f"/search/issues?{urllib.parse.urlencode({'q': query})}", token)
    total_count = data.get("total_count", 0)
    if not isinstance(total_count, (str, int, float)) or isinstance(total_count, bool):
        return False
    return int(total_count) > 0


def issue_title(finding: Finding) -> str:
    return f"[CVE checker] {finding.package.label}: {finding.cve_id} {finding.severity}"


def issue_body(finding: Finding, policy: ReleasePolicy) -> str:
    references = "\n".join(f"- {reference}" for reference in finding.references) or "- None listed by source"
    nemotron = finding.nemotron_summary or "Nemotron summary was not configured or failed; see source evidence below."
    score = "unknown" if finding.score is None else str(finding.score)
    return f"""<!-- {issue_marker(finding)} -->
## Summary
{nemotron}

## Release
- Software set: `{policy.software_set}`
- Target: `{policy.target}`
- Release: `{policy.release_id}`
- Run: `{policy.run_id}`

## Package
- Package: `{finding.package.name}`
- Version: `{finding.package.version or 'unknown'}`
- Spack spec: `{finding.package.spec or finding.package.label}`

## CVE Evidence
- CVE: `{finding.cve_id}`
- Source: `{finding.source}`
- Severity: `{finding.severity}`
- CVSS score: `{score}`
- Published: `{finding.published or 'unknown'}`
- Last modified: `{finding.modified or 'unknown'}`
- Source URL: {finding.url}
- Match evidence: {finding.evidence}

## Source Description
{finding.summary}

## References
{references}

## Recommended Handling
Review whether `{policy.software_set}` on `{policy.target}` builds an affected version/configuration, then update the canonical Spack spec constraint, apply a package patch, or document why this CVE is not applicable.
"""


def create_github_issue(
    finding: Finding,
    target: GitHubIssueTarget,
) -> str:
    labels = [*target.base_labels, f"package:{finding.package.name}", f"severity:{finding.severity.lower()}"]
    label_values: list[JsonValue] = [*labels]
    body: JsonObject = {
        "title": issue_title(finding),
        "body": issue_body(finding, target.policy),
        "labels": label_values,
    }
    try:
        data = github_request("POST", f"/repos/{target.repo}/issues", target.token, body)
    except HttpRequestError as error:
        if "Validation Failed" not in str(error) and "labels" not in str(error).lower():
            raise
        fallback = {"title": body["title"], "body": body["body"]}
        data = github_request("POST", f"/repos/{target.repo}/issues", target.token, fallback)
    return str(data.get("html_url", ""))
