#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "basedpyright>=1,<2",
#   "cookiecutter>=2,<3",
#   "jsonschema>=4,<5",
#   "pydantic>=2,<3",
#   "pytest>=8,<9",
#   "PyYAML>=6,<7",
#   "ruff>=0.12,<1",
# ]
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run cookiecutter/chapar-datacenter/tests/test_template.py
# 3. Or make executable and run:
#      chmod +x cookiecutter/chapar-datacenter/tests/test_template.py && ./cookiecutter/chapar-datacenter/tests/test_template.py
# ─────────────────

from __future__ import annotations

import hashlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, assert_never

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tools.chapar_datacenter_artifacts import DatacenterArtifact

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "tools/chapar_datacenter_template.py"
TEMPLATE = ROOT / "cookiecutter/chapar-datacenter"
EXAMPLE = TEMPLATE / "examples/example-context.yaml"
SCHEMAS = ROOT / "datacenters/schemas"
type Mutation = Literal[
    "placeholder",
    "relative-path",
    "missing-temp-root",
    "secret-field",
    "unknown-target",
    "unknown-container",
    "active-status",
    "traversal",
]


@dataclass(frozen=True, slots=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def run_tool(*arguments: str) -> CommandResult:
    completed = subprocess.run(
        [sys.executable, str(RUNNER), *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def tree_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for item in sorted(
        candidate for candidate in path.rglob("*") if candidate.is_file()
    ):
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(item.read_bytes())
    return digest.hexdigest()


def test_render_is_deterministic_and_schema_valid() -> None:
    # Given one complete example context; When two fresh roots are rendered;
    # Then the resulting generated trees are byte-identical and validate.
    with tempfile.TemporaryDirectory(prefix="chapar-template-test-") as temporary:
        root = Path(temporary)
        first = root / "first"
        second = root / "second"
        one = run_tool("render", str(EXAMPLE), "--output-root", str(first))
        two = run_tool("render", str(EXAMPLE), "--output-root", str(second))
        assert one.returncode == 0, one.stderr
        assert two.returncode == 0, two.stderr
        assert tree_digest(first) == tree_digest(second)
        generated = first / "datacenters/example-lab"
        checked = run_tool("validate-tree", str(generated))
        assert checked.returncode == 0, checked.stderr
        datacenter = DatacenterArtifact.model_validate_json(
            (generated / "datacenter.json").read_text(encoding="utf-8")
        )
        assert datacenter.status == "example"
        assert datacenter.targets == (
            "linux-aarch64-gb300",
            "linux-aarch64-generic",
            "linux-x86_64-generic",
            "linux-x86_64-v4",
        )
        provenance = datacenter.provenance
        assert provenance.template.name == "chapar-datacenter"
        assert provenance.tool.name == "chapar_datacenter_template"
        assert set(provenance.tool.dependencies) == {
            "PyYAML",
            "cookiecutter",
            "jsonschema",
            "pydantic",
        }
        digests = (
            provenance.template.sha256,
            provenance.context_sha256,
            provenance.tool.sha256,
            *provenance.authority_sha256.model_dump().values(),
        )
        assert all(len(digest) == 64 for digest in digests)
        assert "cookiecutter" in one.stdout.lower()


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("placeholder", "placeholder"),
        ("relative-path", "absolute"),
        ("missing-temp-root", "temporary"),
        ("secret-field", "secret"),
        ("unknown-target", "unknown target"),
        ("unknown-container", "unknown container"),
        ("active-status", "example"),
        ("traversal", "traversal"),
    ],
)
def test_invalid_context_fails_without_output(
    mutation: Mutation, expected: str
) -> None:
    # Given one adversarial boundary mutation; When render is requested;
    # Then it fails before creating or replacing the data-center directory.
    with tempfile.TemporaryDirectory(prefix="chapar-template-negative-") as temporary:
        root = Path(temporary)
        context_text = EXAMPLE.read_text(encoding="utf-8")
        match mutation:
            case "placeholder":
                context_text = context_text.replace(
                    "/tmp/chapar-example/example-lab/linux-aarch64-gb300/releases",
                    "/tmp/REPLACE_WITH_RELEASES",
                    1,
                )
            case "relative-path":
                context_text = context_text.replace(
                    "/tmp/chapar-example/example-lab/linux-aarch64-gb300/releases",
                    "relative/releases",
                    1,
                )
            case "missing-temp-root":
                context_text = context_text.replace(
                    "        resolver_work: /tmp/chapar-example/example-lab/linux-aarch64-gb300/work/resolver\n",
                    "",
                    1,
                )
            case "secret-field":
                context_text += "credential_secret: forbidden\n"
            case "unknown-target":
                context_text = context_text.replace(
                    "target: linux-aarch64-gb300", "target: linux-unknown", 1
                )
            case "unknown-container":
                context_text = context_text.replace(
                    "container: nvidia-vlad", "container: unknown-image", 1
                )
            case "active-status":
                context_text = context_text.replace(
                    "status: example", "status: active", 1
                )
            case "traversal":
                context_text = context_text.replace(
                    "/tmp/chapar-example/example-lab/linux-aarch64-gb300/work/resolver",
                    "/tmp/chapar-example/../escape",
                    1,
                )
            case unreachable:
                assert_never(unreachable)
        context = root / "context.yaml"
        output = root / "output"
        _ = context.write_text(context_text, encoding="utf-8")
        result = run_tool("render", str(context), "--output-root", str(output))
        assert result.returncode != 0
        assert expected in result.stderr.lower()
        assert not (output / "datacenters/example-lab").exists()


def test_existing_datacenter_and_symlink_output_are_rejected() -> None:
    # Given an existing destination or ambiguous symlink root; When render runs;
    # Then neither path is followed or overwritten.
    with tempfile.TemporaryDirectory(prefix="chapar-template-overwrite-") as temporary:
        root = Path(temporary)
        output = root / "output"
        existing = output / "datacenters/example-lab"
        existing.mkdir(parents=True)
        sentinel = existing / "sentinel"
        _ = sentinel.write_text("keep\n", encoding="utf-8")
        overwrite = run_tool("render", str(EXAMPLE), "--output-root", str(output))
        assert overwrite.returncode != 0
        assert sentinel.read_text(encoding="utf-8") == "keep\n"
        link = root / "linked-output"
        link.symlink_to(output, target_is_directory=True)
        ambiguous = run_tool("render", str(EXAMPLE), "--output-root", str(link))
        assert ambiguous.returncode != 0
        assert "symlink" in ambiguous.stderr.lower()


def test_symlinked_datacenters_component_has_no_external_write() -> None:
    # Given a regular output root whose datacenters child redirects externally;
    # When render runs; Then it rejects the component before writing through it.
    with tempfile.TemporaryDirectory(
        prefix="chapar-template-component-link-"
    ) as temporary:
        root = Path(temporary)
        output = root / "output"
        external = root / "external"
        output.mkdir()
        external.mkdir()
        (output / "datacenters").symlink_to(external, target_is_directory=True)
        result = run_tool("render", str(EXAMPLE), "--output-root", str(output))
        assert result.returncode != 0
        assert "symlink" in result.stderr.lower()
        assert not (external / "example-lab").exists()


def test_validate_tree_rejects_active_generated_status() -> None:
    # Given an otherwise valid generated tree with active status injected;
    # When validate-tree runs; Then offline example policy rejects it.
    with tempfile.TemporaryDirectory(
        prefix="chapar-template-active-tree-"
    ) as temporary:
        root = Path(temporary)
        rendered = run_tool("render", str(EXAMPLE), "--output-root", str(root))
        assert rendered.returncode == 0, rendered.stderr
        generated = root / "datacenters/example-lab"
        datacenter = generated / "datacenter.json"
        active = datacenter.read_text(encoding="utf-8").replace(
            '"status": "example"', '"status": "active"', 1
        )
        _ = datacenter.write_text(active, encoding="utf-8")
        result = run_tool("validate-tree", str(generated))
        assert result.returncode != 0
        assert "example" in result.stderr.lower()


@pytest.mark.parametrize(
    "pattern",
    [
        r'("context_sha256": ")[a-f0-9]{64}"',
        r'("template": \{.*?"sha256": ")[a-f0-9]{64}"',
        r'("tool": \{.*?"sha256": ")[a-f0-9]{64}"',
    ],
)
def test_validate_tree_recomputes_provenance_digests(pattern: str) -> None:
    # Given every document carries the same schema-valid forged provenance digest;
    # When validate-tree runs; Then recomputation rejects the forged provenance.
    with tempfile.TemporaryDirectory(
        prefix="chapar-template-forged-digest-"
    ) as temporary:
        root = Path(temporary)
        rendered = run_tool("render", str(EXAMPLE), "--output-root", str(root))
        assert rendered.returncode == 0, rendered.stderr
        generated = root / "datacenters/example-lab"
        for artifact in sorted(generated.rglob("*.json")):
            content = artifact.read_text(encoding="utf-8")
            forged, replacements = re.subn(
                pattern,
                lambda match: f'{match.group(1)}{"0" * 64}"',
                content,
                count=1,
                flags=re.DOTALL,
            )
            assert replacements == 1
            _ = artifact.write_text(forged, encoding="utf-8")
        result = run_tool("validate-tree", str(generated))
        assert result.returncode != 0
        assert "digest" in result.stderr.lower()


def test_validation_rejects_stale_or_misleading_generated_artifacts() -> None:
    # Given a valid render later polluted or announced incompletely; When validated;
    # Then stale artifacts and misleading success are observable failures.
    with tempfile.TemporaryDirectory(prefix="chapar-template-stale-") as temporary:
        root = Path(temporary)
        rendered = run_tool("render", str(EXAMPLE), "--output-root", str(root))
        assert rendered.returncode == 0, rendered.stderr
        generated = root / "datacenters/example-lab"
        _ = (generated / "stale.json").write_text("{}\n", encoding="utf-8")
        result = run_tool("validate-tree", str(generated))
        assert result.returncode != 0
        assert "unexpected generated artifact" in result.stderr.lower()
        assert "valid" not in result.stdout.lower()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
