#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pydantic>=2,<3",
# ]
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run ci/tests/documentation-contract-test.py
# 3. Or make executable and run:
#      chmod +x ci/tests/documentation-contract-test.py && ./ci/tests/documentation-contract-test.py
# ───────────────────

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Final

from pydantic import JsonValue, TypeAdapter

ROOT: Final = Path(__file__).resolve().parents[2]
JSON_OBJECT: Final = TypeAdapter(dict[str, JsonValue])
ACTIVE_DOCS: Final = (
    "AGENTS.md",
    "README.md",
    "TODO.md",
    ".agents/README.md",
    "etc/README.md",
    "docs/buildcache.md",
    "docs/ci-github-actions.md",
    "docs/container-injection.md",
    "docs/nscale-vlad-manual-build.md",
    "docs/cve-checker.md",
    "containers/README.md",
    "validation/ARCHITECTURE.md",
    ".agents/skills/chapar-spack-env-change/SKILL.md",
    ".agents/skills/chapar-spack-solve-debug/SKILL.md",
    ".agents/skills/chapar-release-helper/SKILL.md",
    ".agents/skills/chapar-buildcache/SKILL.md",
    ".agents/skills/chapar-vlad-image/SKILL.md",
    ".agents/skills/chapar-validation/SKILL.md",
    ".agents/skills/chapar-config-scope-change/SKILL.md",
    ".agents/skills/chapar-cuda-gdr-transport/SKILL.md",
    ".agents/skills/chapar-commit/SKILL.md",
    ".agents/skills/chapar-ci-artifact-watch/SKILL.md",
    ".agents/skills/chapar-cve-checker/SKILL.md",
    ".agents/skills/chapar-harness-wiring/SKILL.md",
)
FORBIDDEN_ACTIVE_COMMANDS: Final = (
    re.compile(r"^\s*(?:export\s+)?CHAPAR_TARGET_PROFILE=", re.MULTILINE),
    re.compile(r"^\s*ENV_NAME=", re.MULTILINE),
    re.compile(r"^\s*spack\s+-e\s+envs/(?:hpcsim|vlad)\b", re.MULTILINE),
    re.compile(r"^\s*(?:bash\s+)?envs/(?:hpcsim|vlad)/release\.sh\b", re.MULTILINE),
    re.compile(r"^\s*spack\s+install\b", re.MULTILINE),
    re.compile(r"hpcsim-site\.env"),
)
REQUIRED_RESOLVER_FLAGS: Final = {
    "--catalog",
    "--targets",
    "--containers",
    "--datacenter",
    "--contract",
    "--datacenter-id",
    "--software-set",
    "--target",
    "--release-id",
    "--run-id",
    "--output-dir",
}


def load_json(relative: str) -> dict[str, JsonValue]:
    return JSON_OBJECT.validate_json((ROOT / relative).read_bytes())


def mapping(value: JsonValue) -> dict[str, JsonValue]:
    assert isinstance(value, dict)
    return value


def text(value: JsonValue) -> str:
    assert isinstance(value, str)
    return value


def inventory_summary() -> dict[str, JsonValue]:
    completed = subprocess.run(
        (
            sys.executable,
            "envs/software/tests/inventory.py",
            "envs/software/tests/fixtures/historical-root-inventory.json",
        ),
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    report = JSON_OBJECT.validate_json(completed.stdout)
    return JSON_OBJECT.validate_python(
        {
            "counts": report["counts"],
            "package_name_differences": report["package_name_differences"],
            "variant_difference_packages": sorted(mapping(report["variant_differences"])),
        }
    )


def documented_inventory() -> dict[str, JsonValue]:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    match = re.search(
        r"<!-- software-inventory:begin -->\s*```json\s*(.*?)\s*```\s*<!-- software-inventory:end -->",
        readme,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("README lacks the machine-checked software inventory block")
    return JSON_OBJECT.validate_json(match.group(1))


def test_cli_registry_and_schema_contract() -> None:
    resolver = (ROOT / "tools/chapar_resolve.py").read_text(encoding="utf-8")
    actual_flags = set(re.findall(r'"(--[a-z-]+)"', resolver))
    assert REQUIRED_RESOLVER_FLAGS <= actual_flags
    targets = load_json("containers/images/targets.json")
    containers = load_json("containers/images/containers.json")
    assert set(mapping(targets["targets"])) == {
        "linux-aarch64-gb300",
        "linux-aarch64-generic",
        "linux-x86_64-generic",
        "linux-x86_64-v4",
    }
    assert set(mapping(containers["containers"])) == {"nvidia-vlad", "ubuntu-hpcsim"}
    assert text(load_json("datacenters/schemas/datacenter.schema.json")["$id"]).endswith("/datacenter/v1")
    assert text(load_json("datacenters/schemas/target-contract.schema.json")["$id"]).endswith("/target-contract/v1")


def test_documented_inventory_matches_source() -> None:
    assert documented_inventory() == inventory_summary()


def test_active_docs_use_selection_authority() -> None:
    combined = "\n".join((ROOT / relative).read_text(encoding="utf-8") for relative in ACTIVE_DOCS)
    for pattern in FORBIDDEN_ACTIVE_COMMANDS:
        assert pattern.search(combined) is None, f"active legacy command: {pattern.pattern}"
    assert re.search(
        r"^(?:Co-authored-by|Signed-off-by|Assisted-by):|^.*Generated with",
        combined,
        re.MULTILINE,
    ) is None


def test_forbidden_command_patterns_detect_regressions() -> None:
    regressions = (
        "export CHAPAR_TARGET_PROFILE=vlad",
        "ENV_NAME=hpcsim ./validation/run integrity-test",
        "spack -e envs/hpcsim concretize -f",
        "bash envs/vlad/release.sh build old",
        "spack install example",
        "copy hpcsim-site.env before building",
    )
    for pattern, regression in zip(FORBIDDEN_ACTIVE_COMMANDS, regressions, strict=True):
        assert pattern.search(regression) is not None


def test_harness_and_protected_state() -> None:
    # One rules file and one skill directory, reached by every harness.
    # Codex and OpenCode discover .agents/skills natively; Claude Code reads
    # only CLAUDE.md and .claude/skills, so both are symlinks to the canonical
    # copy rather than second copies that could drift.
    assert (ROOT / "CLAUDE.md").is_symlink()
    assert (ROOT / "CLAUDE.md").resolve() == (ROOT / "AGENTS.md").resolve()
    assert (ROOT / ".claude/skills").resolve() == (ROOT / ".agents/skills").resolve()
    assert (ROOT / ".agents/skills/chapar-commit/SKILL.md").is_file()
    opencode = load_json("opencode.json")
    # No harness declares skills any more; opencode.json is permissions only.
    assert "skills" not in opencode
    assert set(opencode) == {"$schema", "permission"}
    protected = load_json("envs/software/tests/fixtures/protected-state.json")
    assert protected["legacy_deployment_roots"] == [
        "/resources/chapar/vlad",
        "/resources/chapar/hpcsim",
    ]
    assert not (ROOT / ".github/workflows").exists() or not any((ROOT / ".github/workflows").iterdir())
    for datacenter in (ROOT / "datacenters").glob("*/datacenter.json"):
        assert load_json(str(datacenter.relative_to(ROOT)))["status"] == "example"


def test_canonical_fence_failure_and_cleanup() -> None:
    _ = subprocess.run(
        ("bash", "ci/tests/documentation-contract-fence-test.sh"),
        cwd=ROOT,
        check=True,
    )


def main() -> int:
    test_cli_registry_and_schema_contract()
    test_documented_inventory_matches_source()
    test_active_docs_use_selection_authority()
    test_forbidden_command_patterns_detect_regressions()
    test_harness_and_protected_state()
    test_canonical_fence_failure_and_cleanup()
    print("documentation contract valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
