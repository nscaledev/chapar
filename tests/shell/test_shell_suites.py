"""Wrappers so `make test` runs the shell suites that test shell."""

from __future__ import annotations

import subprocess

import pytest

from tests.conftest import REPO_ROOT

SUITES = [
    "etc/tests/site-env-test.sh",
    "envs/software/tests/release-helper-plan-test.sh",
    # Validation library contracts and fixture-mode suites: offline, no Slurm,
    # no hardware, no release directory required.
    "validation/lib/test-result-manifest.sh",
    "validation/lib/test-fixture-mode.sh",
    "validation/tests/test-container-fixtures.sh",
    "validation/tests/test-cpu-fixtures.sh",
    "validation/tests/test-gpu-fixtures.sh",
    "validation/tests/test-storage-fixtures.sh",
    "validation/tests/test-transport-fixtures.sh",
]


@pytest.mark.parametrize("suite", SUITES)
def test_shell_suite(suite: str) -> None:
    completed = subprocess.run(
        ["bash", str(REPO_ROOT / suite)],
        check=False,
        capture_output=True,
        text=True,
        timeout=300,
        cwd=REPO_ROOT,
    )
    assert completed.returncode == 0, f"{suite} failed:\n{completed.stdout}\n{completed.stderr}"
