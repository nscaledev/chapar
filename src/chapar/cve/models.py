"""Data model for the CVE checker. Stdlib only."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final

SEVERITY_ORDER: Final = {
    "NONE": 0,
    "LOW": 1,
    "MEDIUM": 2,
    "HIGH": 3,
    "CRITICAL": 4,
}


@dataclass(frozen=True, slots=True)
class Package:
    name: str
    version: str | None = None
    spec: str | None = None
    aliases: tuple[str, ...] = field(default_factory=tuple)

    @property
    def label(self) -> str:
        return f"{self.name}@{self.version}" if self.version else self.name


@dataclass(frozen=True, slots=True)
class ReleasePolicy:
    """Identity of the verified release the scanned inventory came from."""

    software_set: str
    target: str
    release_id: str
    run_id: str

    def as_json(self) -> dict[str, str]:
        return {
            "software_set": self.software_set,
            "target": self.target,
            "release_id": self.release_id,
            "run_id": self.run_id,
        }


@dataclass(frozen=True, slots=True)
class Finding:
    package: Package
    source: str
    cve_id: str
    severity: str
    score: float | None
    published: str | None
    modified: str | None
    summary: str
    url: str
    references: tuple[str, ...]
    evidence: str
    nemotron_summary: str | None = None
