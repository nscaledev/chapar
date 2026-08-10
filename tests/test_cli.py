"""The CLI must be discoverable: --help works at every level."""

from __future__ import annotations

import pytest

from tests.conftest import run_chapar


@pytest.mark.parametrize(
    "arguments",
    [
        ("--help",),
        ("catalog", "--help"),
        ("catalog", "list", "--help"),
        ("catalog", "readme", "--help"),
        ("catalog", "inventory", "--help"),
        ("target", "--help"),
        ("target", "scope", "--help"),
        ("target", "list", "--help"),
    ],
)
def test_help_everywhere(arguments: tuple[str, ...]) -> None:
    result = run_chapar(*arguments)
    assert result.exit_code == 0, f"{arguments}: {result.stderr}"
    assert "usage:" in result.stdout


def test_version() -> None:
    result = run_chapar("--version")
    assert result.exit_code == 0
    assert result.stdout.startswith("chapar ")
