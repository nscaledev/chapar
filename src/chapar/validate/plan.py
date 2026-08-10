"""Release-bound validation planning.

Validation binds to one immutable release directory, exactly as image
injection does. Identity, target facts, and paths come from the verified
metadata.json; the expected root inventory comes from the release-local
spack.lock (the roots that were actually built, not what a catalog promised);
the module tree is the release's own generated modulefiles. Site settings
contribute only what is not a release fact: the results root
(CHAPAR_VALIDATION_ROOT) and Slurm placement (CHAPAR_SLURM_*), both exported
by etc/chapar-defaults.sh in the shells that call this. Stdlib only.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

from chapar.common.jsonio import fail
from chapar.common.release import IDENTIFIER, Release, lock_roots, verify_release
from chapar.validate.checks import RootCheck, root_checks

#: plan field -> site variable; empty placement means "no explicit flag".
SLURM_VARIABLES: Final = (
    ("partition", "CHAPAR_SLURM_PARTITION"),
    ("constraint", "CHAPAR_SLURM_CONSTRAINT"),
    ("account", "CHAPAR_SLURM_ACCOUNT"),
    ("qos", "CHAPAR_SLURM_QOS"),
)


@dataclass(frozen=True, slots=True)
class ValidationPlan:
    action: str
    test: str
    software_set: str
    target: str
    release_id: str
    release_run_id: str
    release_dir: str
    release_lock_sha256: str
    module_path: str
    validation_run_id: str
    results_root: str
    partition: str
    constraint: str
    account: str
    qos: str
    root_count: int
    checks: tuple[RootCheck, ...]


def known_tests() -> tuple[str, ...]:
    tests_dir = Path(__file__).resolve().parents[3] / "validation" / "tests"
    return tuple(sorted(path.stem for path in tests_dir.glob("*.sbatch")))


def module_arch_path(release: Release) -> Path:
    """The release's own module tree: exactly one architecture directory.

    Spack writes modules to <tcl root>/<platform-os-target>/<name>/<version>,
    so every `module use` target is the architecture directory, not its
    parent — the same rule release.sh publishes with (release_module_arch).
    """
    modules = release.directory / "modulefiles"
    if not modules.is_dir():
        fail(f"release has no generated modulefiles: {modules}")
    arch_dirs = sorted(path for path in modules.iterdir() if path.is_dir())
    if len(arch_dirs) != 1:
        fail(f"release must contain exactly one module architecture, found {len(arch_dirs)}")
    return arch_dirs[0]


def generated_run_id() -> str:
    """A manual validation-run id; a runner passes its own instead."""
    return datetime.now(UTC).strftime("manual-%Y%m%d-%H%M%S")


def default_results_root(release: Release, validation_run_id: str) -> Path:
    root = os.environ.get("CHAPAR_VALIDATION_ROOT", "")
    if not root:
        fail("CHAPAR_VALIDATION_ROOT is not set; source etc/chapar-defaults.sh or pass --results-root")
    if not root.startswith("/"):
        fail(f"CHAPAR_VALIDATION_ROOT must be an absolute path: {root}")
    return Path(root) / release.software_set / release.target / release.release_id / validation_run_id


def seal_release(release: Release, seal_dir: Path) -> None:
    """Write read-only copies of the release's self-description into seal_dir.

    Jobs bind to the immutable release directory itself (verified by name, so
    a promotion pointer is refused); the sealed copies are submission-time
    evidence of exactly what was verified.
    """
    if seal_dir.is_symlink() or not seal_dir.is_dir():
        fail("seal directory must be a real directory")
    for name in ("metadata.json", "spack.lock"):
        payload = (release.directory / name).read_bytes()
        destination = seal_dir / name
        try:
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        except OSError as error:
            fail(f"cannot seal {name}: {error}")
        with os.fdopen(descriptor, "wb") as stream:
            _ = stream.write(payload)


def build_plan(
    release_dir: Path,
    *,
    test: str = "",
    run_id: str = "",
    results_root: Path | None = None,
    seal_dir: Path | None = None,
) -> ValidationPlan:
    if test and test not in known_tests():
        fail(f"unknown validation test: {test}")
    release = verify_release(release_dir)
    validation_run_id = run_id or generated_run_id()
    if not IDENTIFIER.fullmatch(validation_run_id):
        fail(f"invalid validation run id: {validation_run_id}")
    module_path = module_arch_path(release)
    resolved_results = results_root if results_root is not None else default_results_root(release, validation_run_id)
    checks = root_checks(lock_roots(release.lock_path))
    if seal_dir is not None:
        seal_release(release, seal_dir)
    placement = {label: os.environ.get(variable, "") for label, variable in SLURM_VARIABLES}
    return ValidationPlan(
        action="dry-run",
        test=test,
        software_set=release.software_set,
        target=release.target,
        release_id=release.release_id,
        release_run_id=release.run_id,
        release_dir=str(release.directory),
        release_lock_sha256=release.lock_sha256,
        module_path=str(module_path),
        validation_run_id=validation_run_id,
        results_root=str(resolved_results),
        partition=placement["partition"],
        constraint=placement["constraint"],
        account=placement["account"],
        qos=placement["qos"],
        root_count=len(checks),
        checks=checks,
    )
