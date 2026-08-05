#!/usr/bin/env python3
# noqa: SIZE_OK - Todo 6 permits only one runbook test module; its mutation matrix is part of the required self-test contract.
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final, assert_never


REPO_ROOT: Final = Path(__file__).resolve().parents[2]
RUNBOOK: Final = REPO_ROOT / "docs/nscale-vlad-manual-build.md"
RECEIPT_TOOL: Final = REPO_ROOT / "ci/verify-vlad-source-approval.py"
INSTALLER: Final = REPO_ROOT / "ci/install-validated-sqsh.py"
PREFLIGHT_TEST: Final = REPO_ROOT / "containers/images/tests/preflight-test.sh"
CATALOG_PATHS: Final = (
    Path("agents/skills/chapar-vlad-image/SKILL.md"),
    Path("AGENTS.md"),
    Path("containers/README.md"),
    Path("envs/vlad/README.md"),
)
CANONICAL_RUNBOOK: Final = Path("docs/nscale-vlad-manual-build.md")
SCHEMAS: Final = {
    "chapar-vlad-source-approval/v1": frozenset(
        {
            "schema", "approved_by", "approved_at", "change_ticket",
            "chapar_remote", "chapar_commit", "source_lock_path",
            "source_lock_sha256",
        }
    ),
    "chapar-vlad-release-binding/v1": frozenset(
        {
            "schema", "release_dir", "release_id", "chapar_commit",
            "source_lock_sha256", "target", "metadata_path",
            "metadata_sha256", "spack_lock_path", "spack_lock_sha256", "status",
        }
    ),
    "chapar-vlad-builder-handoff/v1": frozenset(
        {
            "schema", "build_root", "chapar_commit", "source_lock_sha256",
            "release_binding", "release_binding_sha256", "target", "image_id",
            "image_path", "image_sha256", "image_size", "validation_root",
        }
    ),
    "chapar-vlad-runtime-receipt/v1": frozenset(
        {
            "schema", "builder_handoff_sha256", "release_binding_sha256",
            "target", "image_path", "image_sha256", "validator_root",
            "validator_image_root", "runtime_receipt_path",
            "runtime_preflight_sha256", "smoke_output_sha256", "status",
        }
    ),
}
REQUIRED_BLOCK_ANCHORS: Final = (
    ': "${CHAPAR_COMMIT:?}" "${SOURCE_APPROVAL_RECEIPT:?}"',
    'bash envs/vlad/release.sh build "$RELEASE_ID"',
    'SOURCE_CLONE_ROOT=/home/hpcadmin/chapar-sources/$CHAPAR_COMMIT-$TARGET',
    'grep -Fx "release_id: $RELEASE_ID" "$RELEASE_DIR/metadata.txt"',
    'MODULE_PATH="$RELEASE_DIR/modulefiles" ENV_NAME=vlad ./validation/run integrity-test',
    'bash envs/vlad/release.sh promote "$RELEASE_ID"',
    '--write-builder-handoff "$BUILDER_HANDOFF"',
    'test "$PYXIS_JOB_APPROVED" = yes',
    '--write-runtime-receipt "$RUNTIME_RECEIPT"',
    '--verify-runtime-receipt "$RUNTIME_RECEIPT"',
    '--mode publisher --base nvidia-vlad',
    'test "$PUBLISHER_CODE_ROOT" = "/vast/chapar-publisher-code/$CHAPAR_COMMIT"',
    'install-validated-sqsh.py" --source "$IMAGE_PATH"',
)
PROTECTED_GATE_ANCHORS: Final = (
    'result = libc.syscall(439, fd, ctypes.c_char_p(b""), os.W_OK, 0x1000 | 0x200)',
    'os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW',
    '"GIT_CONFIG_NOSYSTEM":"1"',
    '"GIT_CONFIG_GLOBAL":"/dev/null"',
    '"--no-replace-objects"',
    'f"safe.directory={root}"',
    '"core.fsmonitor=false"',
    '"core.hooksPath=/dev/null"',
    "info.st_uid == 0",
    "not (info.st_mode & 0o022)",
    "result == -1 and error in (errno.EACCES, errno.EROFS)",
    "(before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)",
    "actual == expected",
)


class ContractError(Exception):
    __slots__ = ("detail",)

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True, slots=True)
class DefaultCheck:
    runbook: Path


@dataclass(frozen=True, slots=True)
class SelfTest:
    pass


@dataclass(frozen=True, slots=True)
class LinkCheck:
    runbook: Path


@dataclass(frozen=True, slots=True)
class MatrixCheck:
    runbook: Path
    ci_document: Path
    builder: Path


@dataclass(frozen=True, slots=True)
class BaseSelection:
    base_id: str
    environment: str
    targets: tuple[str, ...]


Command = DefaultCheck | SelfTest | LinkCheck | MatrixCheck


def shell_blocks(text: str) -> tuple[str, ...]:
    return tuple(re.findall(r"(?ms)^```bash\n(.*?)^```$", text))


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise ContractError(detail)


def validate_runbook(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    blocks = shell_blocks(text)
    require(len(blocks) == 4, "runbook must contain exactly four runnable bash fences")
    require(text.count("OPERATOR GATE - NOT EXECUTED BY REPOSITORY QA") == 3,
            "each live role must be labeled as an unexecuted operator gate")
    require(text.count("Prerequisites:") >= 3, "each role needs prerequisites")
    require(text.count("Evidence:") >= 3, "each role needs evidence")
    require(text.count("Stop conditions:") >= 3, "each role needs stop conditions")
    for anchor in REQUIRED_BLOCK_ANCHORS:
        require(text.count(anchor) == 1, f"missing or duplicate normative anchor: {anchor}")
    validator, publisher = blocks[2], blocks[3]
    for anchor in PROTECTED_GATE_ANCHORS:
        require(validator.count(anchor) == 1, f"validator protected gate drift: {anchor}")
        require(publisher.count(anchor) == 1, f"publisher protected gate drift: {anchor}")
    for block, role in ((validator, "validator"), (publisher, "publisher")):
        require("env -i PATH=/usr/bin:/bin" in block, f"{role} Git environment is not empty")
        require("core.untrackedCache=false" in block, f"{role} untracked cache is not disabled")
        require("safe.directory=*" not in block, f"{role} uses wildcard safe.directory")
    require(text.index("Builder operator gates") < text.index("Validator operator gate")
            < text.index("Publisher operator gate"), "role stage order drift")
    require("source lock remains blocked and is not modified by this runbook" in text.lower(),
            "blocked source-lock warning is absent")
    for schema, keys in SCHEMAS.items():
        declaration = f"`{schema}`: `{','.join(sorted(keys))}`"
        require(declaration in text, f"exact receipt declaration missing: {schema}")


def resolve_required(path: Path, label: str) -> Path:
    require(path.is_file(), f"setup error: missing {label}: {path}")
    return path.resolve()


def markdown_links(text: str) -> tuple[str, ...]:
    return tuple(re.findall(r"\[[^\]]+\]\(([^)\s#]+)(?:#[^)]*)?\)", text))


def validate_links(runbook: Path) -> None:
    canonical = resolve_required(runbook, "runbook")
    root = canonical.parent.parent
    require(canonical == (root / CANONICAL_RUNBOOK).resolve(), f"runbook path must be {CANONICAL_RUNBOOK}")
    canonical_blocks = frozenset(shell_blocks(canonical.read_text(encoding="utf-8")))
    selections = parse_builder_selections(root / "containers/images/build-image.sh")
    selected_bases = {selection.base_id for selection in selections}
    selected_targets = {target for selection in selections for target in selection.targets}
    for relative in CATALOG_PATHS:
        catalog = root / relative
        resolve_required(catalog, f"catalog {relative}")
        text = catalog.read_text(encoding="utf-8")
        require("containers/envs/vlad/image" not in text, f"stale image path in {relative}")
        require(re.search(r"--base\s+(?:hpl|nemo)\b", text) is None, f"legacy base id in {relative}")
        claimed_bases = set(re.findall(r"--base\s+([a-z0-9-]+)", text))
        require(claimed_bases <= selected_bases, f"catalog base id differs from builder source: {relative}")
        claimed_targets = set(re.findall(r"\blinux-(?:x86_64|aarch64)-[a-z0-9-]+\b", text))
        require(claimed_targets <= selected_targets, f"catalog target differs from builder source: {relative}")
        resolved_links = tuple((catalog.parent / target).resolve() for target in markdown_links(text))
        require(canonical in resolved_links, f"broken or missing canonical runbook link in {relative}")
        duplicates = canonical_blocks.intersection(shell_blocks(text))
        require(not duplicates, f"duplicate runnable command block outside canonical runbook: {relative}")
    skill = (root / CATALOG_PATHS[0]).read_text(encoding="utf-8")
    frontmatter = skill.split("---", 2)
    require(len(frontmatter) == 3, "skill frontmatter is malformed")
    description = frontmatter[1].lower()
    for token in ("manual", "nscale", "vlad", "source", ".sqsh"):
        require(token in description, f"skill description does not trigger on {token}")


def ast_string(node: ast.expr, label: str) -> str:
    if type(node) is not ast.Constant or type(node.value) is not str:
        raise ContractError(f"builder {label} must be a literal string")
    return node.value


def ast_targets(node: ast.expr) -> tuple[str, ...]:
    if type(node) is not ast.Tuple:
        raise ContractError("builder targets must be a literal tuple")
    targets = tuple(ast_string(element, "target") for element in node.elts)
    require(targets, "builder target allowlist must not be empty")
    return targets


def parse_builder_selections(path: Path) -> tuple[BaseSelection, ...]:
    source = resolve_required(path, "builder source").read_text(encoding="utf-8")
    match = re.search(r"(?ms)^BASES: Final = (\{.*?^\})$", source)
    require(match is not None, "builder BASES literal is missing")
    module = ast.parse("BASES = " + match.group(1))
    if len(module.body) != 1 or type(module.body[0]) is not ast.Assign or type(module.body[0].value) is not ast.Dict:
        raise ContractError("builder BASES assignment is malformed")
    base_dict = module.body[0].value
    selections: list[BaseSelection] = []
    for base_key, base_value in zip(base_dict.keys, base_dict.values, strict=True):
        require(base_key is not None, "builder base key is missing")
        base_id = ast_string(base_key, "base id")
        if type(base_value) is not ast.Dict:
            raise ContractError(f"builder base {base_id} must be a literal dictionary")
        fields = {
            ast_string(field_key, "field name"): field_value
            for field_key, field_value in zip(base_value.keys, base_value.values, strict=True)
            if field_key is not None
        }
        require(set(fields) >= {"env", "targets"}, f"builder base {base_id} omits env or targets")
        selections.append(BaseSelection(base_id, ast_string(fields["env"], "environment"), ast_targets(fields["targets"])))
    require(selections, "builder BASES must not be empty")
    return tuple(selections)


def validate_target_registry(builder: Path, selections: tuple[BaseSelection, ...]) -> None:
    registry_path = builder.parent / "targets.json"
    resolve_required(registry_path, "target registry")
    try:
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        registered = registry["targets"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise ContractError(f"target registry is malformed: {error}") from error
    require(type(registered) is dict, "target registry targets must be an object")
    selected_targets = {target for selection in selections for target in selection.targets}
    require(selected_targets <= set(registered), "builder selects a target absent from targets.json")


def parse_matrix_table(text: str) -> dict[str, tuple[str, ...]]:
    rows: dict[str, tuple[str, ...]] = {}
    for line in text.splitlines():
        match = re.match(r"^\|\s*`([^`]+)`\s*\|[^|]*\|\s*([^|]+)\|\s*([^|]+)\|", line)
        if match is None:
            continue
        base_id = match.group(1)
        targets = tuple(re.findall(r"`(linux-[^`]+)`", match.group(3)))
        if targets:
            rows[base_id] = targets
    return rows


def validate_matrix(runbook: Path, ci_document: Path, builder: Path) -> None:
    canonical = resolve_required(runbook, "runbook")
    ci_path = resolve_required(ci_document, "CI proposal")
    selections = parse_builder_selections(builder)
    validate_target_registry(builder, selections)
    counts: dict[str, int] = {}
    for selection in selections:
        counts[selection.environment] = counts.get(selection.environment, 0) + len(selection.targets)
    require(counts == {"vlad": 2, "hpcsim": 1}, f"builder-derived environment matrix mismatch: {counts}")
    require(sum(counts.values()) == 3, "builder-derived repository matrix must total 3")
    text = ci_path.read_text(encoding="utf-8")
    first_section = text.split("##", 1)[0]
    resolved_links = tuple((ci_path.parent / target).resolve() for target in markdown_links(first_section))
    require(canonical in resolved_links, "CI proposal first section lacks canonical runbook link")
    rows = parse_matrix_table(text)
    expected_rows = {selection.base_id: selection.targets for selection in selections}
    require(rows == expected_rows, f"CI matrix table differs from builder source: {rows}")
    require(re.search(r"(?i)\b(?:four|4)\s+(?:builds?|jobs?)\b", text) is None, "CI proposal contains a four-build claim")
    require(re.search(r"(?i)\b(?:three|3)\s+builds?\s+total\b", text) is not None, "CI proposal omits repository total of 3 builds")
    require(re.search(r"(?i)vlad[^\n]{0,60}(?:×\s*2|\bx\s*2|\btwo\b)", text) is not None, "CI proposal omits Vlad=2")
    require(re.search(r"(?i)hpcsim[^\n]{0,60}(?:×\s*1|\bx\s*1|\bone\b)", text) is not None, "CI proposal omits hpcsim=1")


def expect_contract_failure(text: str, label: str, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="nscale-runbook-negative-") as temp:
        fixture = Path(temp) / "runbook.md"
        fixture.write_text(text, encoding="utf-8")
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), str(fixture)],
            check=False, capture_output=True, text=True,
        )
    output = completed.stderr + completed.stdout
    require(completed.returncode == 1, f"{label} child status was {completed.returncode}, expected 1")
    require(expected in output, f"{label} failed for the wrong reason: {output}")


def expect_shell_failure(label: str, gate: str, environment: dict[str, str]) -> None:
    marker = f"INTENDED:{label}"
    script = f'if {gate}; then exit 0; else printf "%s\\n" "{marker}" >&2; exit 42; fi'
    completed = subprocess.run(
        ["bash", "-c", script], check=False, capture_output=True, text=True,
        env={"PATH": environment["PATH"], **environment},
    )
    require(completed.returncode == 42, f"{label} child status was {completed.returncode}, expected 42")
    require(completed.stderr.strip() == marker, f"{label} failed for the wrong reason: {completed.stderr}")


def run_shell_matrix() -> tuple[str, ...]:
    for tool in ("bash", "cut", "find", "sha256sum"):
        require(shutil.which(tool) is not None, f"setup error: missing required tool: {tool}")
    labels: list[str] = []
    with tempfile.TemporaryDirectory(prefix="nscale-runbook-shell-") as temp:
        root = Path(temp).resolve()
        generated = root / "spack.lock"
        generated.write_text("generated\n", encoding="utf-8")
        stale = "0" * 64
        cases: tuple[tuple[str, str, dict[str, str]], ...] = (
            ("stale-generated-lock", 'test "$(sha256sum "$LOCK" | cut -d" " -f1)" = "$EXPECTED"', {"LOCK": str(generated), "EXPECTED": stale}),
            ("missing-release", 'mapfile -d "" RELEASES < <(find "$ROOT" -type f -path "*/releases/$ID/metadata.txt" -print0); test "${#RELEASES[@]}" -eq 1', {"ROOT": str(root), "ID": "missing"}),
            ("target-qualified-source-clone-collision", 'test ! -e "$SOURCE_CLONE_ROOT"', {"SOURCE_CLONE_ROOT": str(generated)}),
            ("existing-candidate", 'test ! -e "$QUALIFIED_CANDIDATE"', {"QUALIFIED_CANDIDATE": str(generated)}),
            ("existing-artifact", 'test ! -e "$FINAL_PATH"', {"FINAL_PATH": str(generated)}),
        )
        base_environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        for label, gate, values in cases:
            expect_shell_failure(label, gate, {**base_environment, **values})
            labels.append(label)
        release_a = root / "a/releases/duplicate"
        release_b = root / "b/releases/duplicate"
        release_a.mkdir(parents=True)
        release_b.mkdir(parents=True)
        (release_a / "metadata.txt").write_text("release_id: duplicate\n", encoding="utf-8")
        (release_b / "metadata.txt").write_text("release_id: duplicate\n", encoding="utf-8")
        expect_shell_failure(
            "ambiguous-release",
            'mapfile -d "" RELEASES < <(find "$ROOT" -type f -path "*/releases/$ID/metadata.txt" -print0); test "${#RELEASES[@]}" -eq 1',
            {**base_environment, "ROOT": str(root), "ID": "duplicate"},
        )
        labels.append("ambiguous-release")
        metadata = root / "metadata.txt"
        metadata.write_text("release_id=wrong\n", encoding="utf-8")
        expect_shell_failure("wrong-metadata-delimiter", 'grep -Fx "release_id: expected" "$METADATA" >/dev/null', {**base_environment, "METADATA": str(metadata)})
        labels.append("wrong-metadata-delimiter")
        checksum_root = root / "checksum"
        wrong_cwd = root / "wrong-cwd"
        checksum_root.mkdir()
        wrong_cwd.mkdir()
        artifact = checksum_root / "image.sqsh"
        artifact.write_bytes(b"image")
        checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
        (checksum_root / "image.sqsh.sha256").write_text(f"{checksum}  image.sqsh\n", encoding="ascii")
        expect_shell_failure("checksum-cwd-mismatch", '(cd "$WRONG_CWD" && sha256sum -c "$MANIFEST" >/dev/null 2>&1)', {**base_environment, "WRONG_CWD": str(wrong_cwd), "MANIFEST": str(checksum_root / "image.sqsh.sha256")})
        labels.append("checksum-cwd-mismatch")
        validation = root / "validation"
        validation.write_text('#!/usr/bin/env bash\ntest "$MODULE_PATH" = "$EXPECTED_MODULE_PATH"\n', encoding="utf-8")
        validation.chmod(0o755)
        expect_shell_failure("wrong-module-path", 'MODULE_PATH=/wrong EXPECTED_MODULE_PATH=/release/modulefiles "$VALIDATION"', {**base_environment, "VALIDATION": str(validation)})
        labels.append("wrong-module-path")
    return tuple(labels)


def expect_mode_failure(arguments: tuple[str, ...], label: str, expected: str) -> None:
    completed = subprocess.run(
        [sys.executable, str(Path(__file__).resolve()), *arguments],
        check=False, capture_output=True, text=True,
    )
    output = completed.stderr + completed.stdout
    require(completed.returncode == 1, f"{label} child status was {completed.returncode}, expected 1")
    require(expected in output, f"{label} failed for the wrong reason: {output}")


def run_downstream_mode_self_tests() -> tuple[str, ...]:
    labels: list[str] = []
    with tempfile.TemporaryDirectory(prefix="nscale-downstream-modes-") as temp:
        root = Path(temp).resolve()
        runbook = root / CANONICAL_RUNBOOK
        runbook.parent.mkdir(parents=True)
        normative_block = "set -euo pipefail\nprintf 'canonical\\n'\n"
        runbook.write_text(f"# Fixture runbook\n\n```bash\n{normative_block}```\n", encoding="utf-8")
        catalog_original: dict[Path, str] = {}
        for relative in CATALOG_PATHS:
            catalog = root / relative
            catalog.parent.mkdir(parents=True, exist_ok=True)
            target = os.path.relpath(runbook, catalog.parent)
            prefix = "---\nname: fixture\ndescription: Manual nscale Vlad source and .sqsh operations.\n---\n" if relative == CATALOG_PATHS[0] else ""
            content = f"{prefix}Canonical nvidia-vlad summary. [Manual runbook]({target})\n"
            catalog.write_text(content, encoding="utf-8")
            catalog_original[relative] = content
        builder = root / "containers/images/build-image.sh"
        targets = builder.parent / "targets.json"
        builder.parent.mkdir(parents=True, exist_ok=True)
        builder.write_text(
            "BASES: Final = {\n"
            '    "nvidia-vlad": {"env": "vlad", "targets": ("linux-x86_64-v4", "linux-aarch64-gb300")},\n'
            '    "ubuntu-hpcsim": {"env": "hpcsim", "targets": ("linux-x86_64-generic",)},\n'
            "}\n",
            encoding="utf-8",
        )
        validate_links(runbook)
        labels.append("links-happy")
        link_mutations = (
            ("stale-catalog-path", CATALOG_PATHS[1], "containers/envs/vlad/image", "stale image path"),
            ("legacy-base-id", CATALOG_PATHS[2], "--base hpl", "legacy base id"),
            ("broken-runbook-link", CATALOG_PATHS[3], "[Manual runbook](missing.md)", "broken or missing canonical runbook link"),
            ("duplicate-runnable-block", CATALOG_PATHS[1], f"```bash\n{normative_block}```", "duplicate runnable command block"),
        )
        for label, relative, addition, expected in link_mutations:
            catalog = root / relative
            mutated_content = catalog_original[relative] + "\n" + addition + "\n"
            if label == "broken-runbook-link":
                canonical_target = os.path.relpath(runbook, catalog.parent)
                mutated_content = catalog_original[relative].replace(canonical_target, "missing.md")
            catalog.write_text(mutated_content, encoding="utf-8")
            expect_mode_failure(("--check-links", str(runbook)), label, expected)
            catalog.write_text(catalog_original[relative], encoding="utf-8")
            labels.append(label)
        targets.write_text(json.dumps({"targets": {target: {} for target in ("linux-x86_64-v4", "linux-aarch64-gb300", "linux-x86_64-generic")}}), encoding="utf-8")
        ci_document = root / "docs/ci-github-actions.md"
        ci_document.write_text(
            "# Proposal\n\nStatus: proposal; no workflow exists. [Manual runbook](nscale-vlad-manual-build.md)\n\n"
            "## Matrix\n\nTwo selected containers, three builds total. Vlad ×2; hpcsim ×1.\n\n"
            "| Base id | Base image | Environment | Targets |\n|---|---|---|---|\n"
            "| `nvidia-vlad` | NVIDIA | vlad | `linux-x86_64-v4`, `linux-aarch64-gb300` |\n"
            "| `ubuntu-hpcsim` | Ubuntu | hpcsim | `linux-x86_64-generic` |\n",
            encoding="utf-8",
        )
        validate_matrix(runbook, ci_document, builder)
        labels.append("matrix-happy")
        ci_document.write_text(ci_document.read_text(encoding="utf-8").replace("three builds total", "four builds total"), encoding="utf-8")
        expect_mode_failure(("--check-matrix", str(runbook), str(ci_document), str(builder)), "four-build-claim", "four-build claim")
        labels.append("four-build-claim")
    return tuple(labels)


def run_self_test() -> None:
    for required_path in (RUNBOOK, RECEIPT_TOOL, INSTALLER, PREFLIGHT_TEST):
        require(required_path.is_file(), f"setup error: missing required test/tool file: {required_path}")
    text = RUNBOOK.read_text(encoding="utf-8")
    validate_runbook(RUNBOOK)
    mutations = {
        "missing-runtime-verification": (text.replace('--verify-runtime-receipt "$RUNTIME_RECEIPT"', "--runtime-receipt-missing", 1), "missing or duplicate normative anchor"),
        "unsanitized-fsmonitor": (text.replace('"core.fsmonitor=false"', '"core.fsmonitor=true"', 1), "validator protected gate drift"),
        "wildcard-safe-directory": (text.replace('f"safe.directory={root}"', '"safe.directory=*"', 1), "validator protected gate drift"),
        "missing-safe-directory": (text.replace(', "-c", f"safe.directory={root}"', "", 1), "validator protected gate drift"),
        "wrong-safe-directory": (text.replace('f"safe.directory={root}"', '"safe.directory=/wrong"', 1), "validator protected gate drift"),
        "wrong-executed-file-owner": (text.replace("info.st_uid == 0", "info.st_uid == 1", 1), "validator protected gate drift"),
        "wrong-executed-file-mode": (text.replace("not (info.st_mode & 0o022)", "bool(info.st_mode & 0o022)", 1), "validator protected gate drift"),
        "wrong-executed-file-blob": (text.replace("actual == expected", "actual != expected", 1), "validator protected gate drift"),
        "writable-acl-ancestor": (text.replace("result == -1 and error in", "result == 0 or error in", 1), "validator protected gate drift"),
        "component-replacement-race": (text.replace("before.st_mtime_ns) == (after.st_dev", "before.st_mtime_ns) != (after.st_dev", 1), "validator protected gate drift"),
        "executable-system-git-config": (text.replace('"GIT_CONFIG_NOSYSTEM":"1"', '"GIT_CONFIG_NOSYSTEM":"0"', 1), "validator protected gate drift"),
        "executable-global-git-config": (text.replace('"GIT_CONFIG_GLOBAL":"/dev/null"', '"GIT_CONFIG_GLOBAL":"/tmp/global"', 1), "validator protected gate drift"),
        "executable-local-git-config": (text.replace('"core.hooksPath=/dev/null"', '"core.hooksPath=.git/hooks"', 1), "validator protected gate drift"),
        "missing-protected-gate": (text.replace("result = libc.syscall(439", "result = libc.syscall(440", 1), "validator protected gate drift"),
        "builder-writable-publisher-root": (text.replace('test "$PUBLISHER_CODE_ROOT" = "/vast/chapar-publisher-code/$CHAPAR_COMMIT"', 'test "$PUBLISHER_CODE_ROOT" = "/vast/chapar-builder-writable/$CHAPAR_COMMIT"', 1), "missing or duplicate normative anchor"),
        "promoted-before-integrity": text.replace(
            'MODULE_PATH="$RELEASE_DIR/modulefiles" ENV_NAME=vlad ./validation/run integrity-test',
            'bash envs/vlad/release.sh promote "$RELEASE_ID"', 1),
    }
    mutations["promoted-before-integrity"] = (mutations["promoted-before-integrity"], "missing or duplicate normative anchor")
    for label, (mutation, expected) in mutations.items():
        expect_contract_failure(mutation, label, expected)
    shell_cases = run_shell_matrix()
    downstream_cases = run_downstream_mode_self_tests()
    for executable in (RECEIPT_TOOL, INSTALLER):
        completed = subprocess.run(
            [sys.executable, str(executable), "--self-test"],
            check=False, capture_output=True, text=True,
        )
        require(completed.returncode == 0,
                f"{executable.name} self-test failed: {completed.stderr}{completed.stdout}")
    print("nscale Vlad runbook self-test passed: " + ",".join((*mutations, *shell_cases, *downstream_cases)))


def parse_args() -> Command:
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--self-test", action="store_true")
    modes.add_argument("--check-links", action="store_true")
    modes.add_argument("--check-matrix", action="store_true")
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    if args.self_test:
        require(not args.paths, "--self-test accepts no paths")
        return SelfTest()
    if args.check_links:
        require(len(args.paths) == 1, "--check-links requires exactly one runbook path")
        return LinkCheck(args.paths[0])
    if args.check_matrix:
        require(len(args.paths) == 3, "--check-matrix requires runbook, CI proposal, and builder paths")
        return MatrixCheck(args.paths[0], args.paths[1], args.paths[2])
    require(len(args.paths) <= 1, "default mode accepts at most one runbook path")
    return DefaultCheck(args.paths[0] if args.paths else RUNBOOK)


def main() -> int:
    try:
        command = parse_args()
        match command:
            case SelfTest():
                run_self_test()
            case LinkCheck(runbook=runbook):
                validate_links(runbook)
                print("nscale Vlad catalog links passed")
            case MatrixCheck(runbook=runbook, ci_document=ci_document, builder=builder):
                validate_matrix(runbook, ci_document, builder)
                print("nscale Vlad CI matrix passed")
            case DefaultCheck(runbook=runbook):
                validate_runbook(runbook)
                print("nscale Vlad runbook contract passed")
            case unreachable:
                assert_never(unreachable)
    except (ContractError, OSError) as error:
        print(f"nscale Vlad runbook contract failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
