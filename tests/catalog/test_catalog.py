"""Black-box tests for `chapar catalog list|readme` against the live catalog."""

from __future__ import annotations

import json
import re
from pathlib import Path

from tests.conftest import REPO_ROOT, run_chapar

MANIFEST = REPO_ROOT / "envs/software/spack.yaml"
README = REPO_ROOT / "envs/software/README.md"
HISTORICAL_INVENTORY = REPO_ROOT / "envs/software/tests/fixtures/historical-root-inventory.json"
TARGET_FACT = re.compile(r"(?:cuda_arch=|(?:^|\s)target=|(?:^|\s)targets=)")
CUDA_ARCH_VALUE = re.compile(r"\s*cuda_arch=[0-9a,]+")


def replace_once(content: str, needle: str, replacement: str) -> str:
    assert needle in content, f"missing fixture anchor: {needle!r}"
    return content.replace(needle, replacement, 1)


def composition(manifest: Path, software_set: str, arch: str = "x86_64") -> dict:
    result = run_chapar(
        "catalog", "list", "--spack-yaml", str(manifest), "--set", software_set, "--arch", arch
    )
    assert result.exit_code == 0, f"{software_set}/{arch} failed: {result.stderr}"
    return json.loads(result.stdout)


def test_compositions_are_stable() -> None:
    # ccache moved from vlad-only to shared historically, so hpcsim gained it
    # and the vlad/all totals are unchanged.
    expected = {"vlad": 42, "hpcsim": 76, "all": 81}
    for software_set, expected_count in expected.items():
        assert composition(MANIFEST, software_set)["root_count"] == expected_count

    arm = composition(MANIFEST, "hpcsim", "aarch64")
    assert arm["root_count"] == 74, "aarch64 did not exclude x86-only roots"
    assert {root["identifier"] for root in arm["exclusions"]} == {
        "root-f660baf70174",
        "root-f5060d194d19",
    }, "aarch64 exclusions lost the Intel roots"
    assert composition(MANIFEST, "all", "aarch64")["root_count"] == 79
    assert composition(MANIFEST, "vlad", "aarch64")["root_count"] == 42


def test_vlad_never_gains_the_x86_only_roots() -> None:
    # The Intel MPI roots belong to hpcsim and the union, never to vlad — even
    # on an x86 target. This is the membership rule most easily lost in edits.
    vlad = composition(MANIFEST, "vlad", "x86_64")
    assert all(root["origin"] != "architecture-limited" for root in vlad["roots"])
    assert vlad["exclusions"] == []


def test_catalog_preserves_frozen_historical_root_strings() -> None:
    historical = json.loads(HISTORICAL_INVENTORY.read_text(encoding="utf-8"))
    expected = {" ".join(CUDA_ARCH_VALUE.sub("", root["spec"]).split()) for root in historical["roots"]}
    actual = {root["specification"] for root in composition(MANIFEST, "all")["roots"]}
    assert actual == expected, "catalog root strings drifted from normalized frozen history"


def test_catalog_contains_no_target_facts() -> None:
    # Registry-owned target facts stay out of the catalog source. The `when:`
    # selection conditions mention CHAPAR_TARGET but never a concrete
    # target=/targets=/cuda_arch= value.
    assert TARGET_FACT.search(MANIFEST.read_text(encoding="utf-8")) is None


def test_generated_readme_is_current() -> None:
    result = run_chapar("catalog", "readme", "--check", str(README))
    assert result.exit_code == 0, f"generated README drifted: {result.stderr}"
    assert result.stdout == "catalog README is current\n"


def test_rejections_preserve_output(tmp_path: Path) -> None:
    original = MANIFEST.read_text(encoding="utf-8")
    cases = {
        "duplicate-spec": replace_once(original, "  - autoconf", "  - autoconf\n    - autoconf"),
        "condition-drift": replace_once(
            original, 'in ("vlad", "all")', 'in ("vlad", "hpcsim", "all")'
        ),
        "unknown-list": replace_once(original, "- vlad_roots:", "- vlad_extras:"),
        "specs-drift": replace_once(original, "  - $vlad_roots\n", ""),
        "malformed-yaml": "spack: [\n",
    }
    expected_errors = {
        "duplicate-spec": "duplicate root spec",
        "condition-drift": "selection condition drifted",
        "unknown-list": "unknown definition list",
        "specs-drift": "spack.specs must reference every root list",
        "malformed-yaml": "malformed YAML",
    }
    for name, content in cases.items():
        manifest = tmp_path / f"{name}.yaml"
        output = tmp_path / f"{name}.json"
        manifest.write_text(content, encoding="utf-8")
        output.write_text("must-not-change\n", encoding="utf-8")
        result = run_chapar("catalog", "list", "--spack-yaml", str(manifest), "--output", str(output))
        assert result.exit_code != 0, f"{name} unexpectedly succeeded"
        assert expected_errors[name] in result.stderr, f"{name} error changed: {result.stderr!r}"
        assert output.read_text(encoding="utf-8") == "must-not-change\n", f"{name} mutated output"


def test_stale_readme_is_rejected(tmp_path: Path) -> None:
    readme = tmp_path / "README.md"
    stale = README.read_text(encoding="utf-8").replace("HPCSim-not-Vlad", "HPCSim-not-Vlad (stale)", 1)
    readme.write_text(stale, encoding="utf-8")
    result = run_chapar("catalog", "readme", "--check", str(readme))
    assert result.exit_code != 0
    assert "generated README is stale" in result.stderr
    assert readme.read_text(encoding="utf-8") == stale, "stale README was mutated"
