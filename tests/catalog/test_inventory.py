"""Black-box tests for `chapar catalog inventory` over the frozen history."""

from __future__ import annotations

from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT, run_chapar

FIXTURES = REPO_ROOT / "envs/software/tests/fixtures"


@pytest.mark.parametrize(
    ("fixture_name", "expected_error"),
    [
        ("duplicate-id.json", "duplicate root id"),
        ("missing-origin.json", "missing origin"),
        ("same-package-different-variant-invalid-shared.json", "shared provenance"),
        ("duplicate-spec.json", "duplicate root spec"),
        ("malformed.json", "malformed JSON"),
    ],
)
def test_failure_preserves_output(tmp_path: Path, fixture_name: str, expected_error: str) -> None:
    output = tmp_path / "report.json"
    sentinel = "must-not-be-replaced\n"
    output.write_text(sentinel, encoding="utf-8")
    result = run_chapar("catalog", "inventory", str(FIXTURES / fixture_name), "--output", str(output))
    assert result.exit_code != 0, f"{fixture_name} unexpectedly succeeded"
    assert expected_error in result.stderr, f"{fixture_name} did not report {expected_error!r}: {result.stderr!r}"
    assert output.read_text(encoding="utf-8") == sentinel, f"{fixture_name} mutated output before rejection"


def test_happy_report_replaces_stale_artifact(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    output.write_text("stale generated artifact\n", encoding="utf-8")
    result = run_chapar(
        "catalog", "inventory", str(FIXTURES / "historical-root-inventory.json"), "--output", str(output)
    )
    assert result.exit_code == 0, f"baseline inventory failed: {result.stderr}"
    rendered = output.read_text(encoding="utf-8")
    assert "stale generated artifact" not in rendered
    assert '"vlad": 42' in rendered and '"hpcsim": 75' in rendered, "historical source counts drifted"
    assert '"ucx"' in rendered, "same-package variant diagnostics disappeared"


def test_protected_policy() -> None:
    result = run_chapar(
        "catalog", "inventory", "--validate-protected-policy", str(FIXTURES / "protected-state.json")
    )
    assert result.exit_code == 0, f"protected policy failed: {result.stderr}"
    assert result.stdout == "protected-state policy valid\n"
