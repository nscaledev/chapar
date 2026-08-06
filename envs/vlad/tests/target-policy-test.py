#!/usr/bin/env python3
# noqa: SIZE_OK - one self-contained security boundary exercises Git and pinned Spack sources
from __future__ import annotations

import argparse
from collections.abc import Mapping
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Final, NamedTuple

from target_policy_yaml import (
    EXPECTED_LLVM_REQUIRE,
    EXPECTED_REQUIRE,
    PolicyError,
    YamlValue,
    concrete_target,
    load_yaml,
    require,
    validate_structure,
)

SPACK_COMMIT: Final = "fff95dd9aed0af7c7a8252adbef5623fcd4187f7"
PACKAGES_COMMIT: Final = "65f3228ea2533e8413c17661a3a0db3636269631"
EXPECTED_RULES: Final = [("zlib", "one_of", "REQUIRE_YAML", ("target=x86_64_v4",), "target=x86_64", "DEFAULT", None), ("zlib", "one_of", "REQUIRE_YAML", ("target=aarch64",), "target=aarch64", "DEFAULT", None)]
EXPECTED_LLVM_RULES: Final = [
    ("llvm", "one_of", "REQUIRE_YAML", ("@21",), "", "PACKAGE", None),
    ("llvm", "one_of", "REQUIRE_YAML", ("+clang~flang~ipo+lld~lldb~polly build_system=cmake targets=nvptx,x86",), "target=x86_64", "PACKAGE", None),
    ("llvm", "one_of", "REQUIRE_YAML", ("+clang~flang~ipo+lld~lldb~polly build_system=cmake targets=aarch64,nvptx",), "target=aarch64", "PACKAGE", None),
]
type RuleView = tuple[str, str, str, tuple[str, ...], str, str, str | None]


class PinnedSources(NamedTuple):
    spack: Path
    packages: Path


SKIPPED_STATUS: Final = "TARGET_POLICY_SEMANTIC_VALIDATION=SKIPPED reason=source-inputs-not-supplied"
PASSED_STATUS: Final = f"TARGET_POLICY_SEMANTIC_VALIDATION=PASSED spack_commit={SPACK_COMMIT} spack_packages_commit={PACKAGES_COMMIT}"
TRUSTED_GIT: Final = "/usr/bin/git"
TRUSTED_GIT_OPTIONS: Final = (
    "--no-pager",
    "--no-replace-objects",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.untrackedCache=false",
)


def pinned_sources(
    spack_source: Path | None,
    spack_packages_source: Path | None,
) -> PinnedSources | None:
    require((spack_source is None) == (spack_packages_source is None), "both pinned source paths are required together")
    if spack_source is None:
        return None
    return PinnedSources(spack_source, spack_packages_source)


def semantic_self_test_outcome(sources: PinnedSources | None) -> str:
    return SKIPPED_STATUS if sources is None else PASSED_STATUS


def has_exact_probe_output(output: str, expected: str) -> bool:
    return [line for line in output.splitlines() if line.startswith("TARGET_POLICY_SEMANTIC_VALIDATION=")] == [expected]


def trusted_git_environment() -> Mapping[str, str]:
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_MASTER": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
    }


def trusted_git_command(path: Path, *arguments: str) -> list[str]:
    return [TRUSTED_GIT, *TRUSTED_GIT_OPTIONS, "-C", str(path), *arguments]


def git_head(path: Path) -> str:
    result = subprocess.run(trusted_git_command(path, "rev-parse", "HEAD"), check=False, capture_output=True, text=True, timeout=10, env=trusted_git_environment())
    require(result.returncode == 0, f"source is not an exact Git checkout: {path}")
    return result.stdout.strip()


def git_repository_root(path: Path) -> str:
    result = subprocess.run(trusted_git_command(path, "rev-parse", "--show-toplevel"), check=False, capture_output=True, text=True, timeout=10, env=trusted_git_environment())
    require(result.returncode == 0, f"source is not an exact Git checkout: {path}")
    return result.stdout.strip()


def git_status(path: Path) -> bytes:
    result = subprocess.run(trusted_git_command(path, "status", "--porcelain=v2", "-z", "--untracked-files=all"), check=False, capture_output=True, timeout=10, env=trusted_git_environment())
    require(result.returncode == 0, f"source is not an exact Git checkout: {path}")
    return result.stdout


def validate_source_identity(path: Path, expected_commit: str, source: str) -> None:
    require(path.is_absolute() and path == Path(os.path.realpath(path)), "source path must be a canonical absolute repository root")
    require(git_repository_root(path) == str(path), "source path is not a repository root")
    require(git_head(path) == expected_commit, f"wrong {source} source commit")
    require(git_status(path) == b"", f"{source} source worktree is not clean")


def validate_pinned_sources(sources: PinnedSources) -> None:
    validate_source_identity(sources.spack, SPACK_COMMIT, "Spack")
    validate_source_identity(sources.packages, PACKAGES_COMMIT, "spack-packages")


def inject_failure(point: str) -> None:
    if os.environ.get("TARGET_POLICY_TEST_INJECT") == point:
        raise PolicyError(f"injected {point} failure")


def validate_with_spack(yaml_path: Path, packages: dict[str, YamlValue], sources: PinnedSources) -> None:
    validate_pinned_sources(sources)
    previous_sys_path = tuple(sys.path)
    previous_local_config = os.environ.get("SPACK_DISABLE_LOCAL_CONFIG")
    previous_dont_write_bytecode = sys.dont_write_bytecode

    def deny_network(event: str, _arguments: tuple[str | int | bytes | None, ...]) -> None:
        if event in {"socket.connect", "socket.connect_ex", "socket.getaddrinfo"}:
            raise PolicyError(f"network access attempted: {event}")

    try:
        exact_packages_path = sources.packages / "repos" / "spack_repo" / "builtin"
        require((exact_packages_path / "repo.yaml").is_file(), "pinned package repository is malformed")
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(sources.spack / "lib" / "spack"))
        os.environ["SPACK_DISABLE_LOCAL_CONFIG"] = "true"
        sys.addaudithook(deny_network)
        import spack.config
        import spack.repo
        import spack.spec
        import spack.util.spack_yaml as syaml
        from spack.solver.requirements import RequirementParser

        with yaml_path.open(encoding="utf-8") as stream:
            actual = syaml.load_config(stream)
        require(actual["spack"]["packages"]["all"]["require"] == EXPECTED_REQUIRE, "Spack YAML loader saw different requirements")
        require(actual["spack"]["packages"]["llvm"]["require"] == EXPECTED_LLVM_REQUIRE, "Spack YAML loader saw different LLVM requirements")
        bootstrap_scope = spack.config.InternalConfigScope(
            "target-policy-offline", data={"bootstrap": {"enable": False, "sources": []}}
        )
        packages_dict = copy.deepcopy(packages)
        previous_path = spack.repo.PATH
        previous_scopes = tuple(spack.config.CONFIG.scopes.items())
        config_identity = id(spack.config.CONFIG)
        try:
            spack.repo.enable_repo(spack.repo.RepoPath())
            with spack.config.CONFIG.override(bootstrap_scope):
                inject_failure("setup")
                with spack.config.CONFIG.override("packages", packages_dict), spack.repo.use_repositories(str(exact_packages_path), override=True):
                    package_class = spack.repo.PATH.get_pkg_class("zlib")
                    package = package_class(spack.spec.Spec("zlib"))
                    parsed = RequirementParser(spack.config.CONFIG).rules_from_require(package)
                    rules: list[RuleView] = [(rule.pkg_name, rule.policy, rule.origin.name, tuple(str(item) for item in rule.requirements), str(rule.condition), rule.kind.name, rule.message) for rule in parsed]
                    require(rules == EXPECTED_RULES, "malformed RequirementRule output")
                    llvm_class = spack.repo.PATH.get_pkg_class("llvm")
                    llvm_package = llvm_class(spack.spec.Spec("llvm"))
                    llvm_parsed = RequirementParser(spack.config.CONFIG).rules_from_require(llvm_package)
                    llvm_rules: list[RuleView] = [(rule.pkg_name, rule.policy, rule.origin.name, tuple(str(item) for item in rule.requirements), str(rule.condition), rule.kind.name, rule.message) for rule in llvm_parsed]
                    require(llvm_rules == EXPECTED_LLVM_RULES, "malformed LLVM RequirementRule output")
                    inject_failure("parser")
        finally:
            spack.repo.PATH.disable()
            spack.repo.PATH = previous_path
            require(
                id(spack.config.CONFIG) == config_identity
                and tuple(spack.config.CONFIG.scopes.items()) == previous_scopes
                and spack.repo.PATH is previous_path,
                "Spack global state was not restored",
            )
    finally:
        sys.path[:] = previous_sys_path
        sys.dont_write_bytecode = previous_dont_write_bytecode
        if previous_local_config is None:
            os.environ.pop("SPACK_DISABLE_LOCAL_CONFIG", None)
        else:
            os.environ["SPACK_DISABLE_LOCAL_CONFIG"] = previous_local_config
        validate_pinned_sources(sources)


def run_status_probe(yaml_path: Path, targets_path: Path, sources: PinnedSources | None) -> str:
    packages = validate_structure(yaml_path, targets_path)
    if sources is not None:
        with tempfile.TemporaryDirectory(prefix="vlad-spack-cache-") as cache:
            os.environ["SPACK_USER_CACHE_PATH"] = cache
            validate_with_spack(yaml_path, packages, sources)
    return semantic_self_test_outcome(sources)


def run_self_test(sources: PinnedSources | None) -> str:
    script = Path(__file__).resolve()
    source = script.read_text(encoding="utf-8")
    existing_pythonpath = os.environ.get("PYTHONPATH")
    child_pythonpath = str(script.parent) if not existing_pythonpath else f"{script.parent}{os.pathsep}{existing_pythonpath}"
    child_environment = os.environ | {"PYTHONPATH": child_pythonpath}
    solver_tokens = ("spack." + "concretize", "concretize" + "_one")
    remaining_solver_tokens = [token for token in solver_tokens if token in source]
    require(not remaining_solver_tokens, f"forbidden solver token remains: {', '.join(remaining_solver_tokens)}")
    require("REFERENCE" + "_ROOT" not in source, "hidden pinned-source default remains")
    with tempfile.TemporaryDirectory(prefix="vlad-target-policy-") as directory:
        root = Path(directory).resolve()
        identity_clean = root / "identity-clean"
        identity_clean.mkdir()
        subprocess.run(["git", "-C", str(identity_clean), "init", "--quiet"], check=True, timeout=10)
        tracked = identity_clean / "tracked.txt"
        tracked.write_text("clean\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(identity_clean), "add", "tracked.txt"], check=True, timeout=10)
        subprocess.run(["git", "-C", str(identity_clean), "-c", "commit.gpgsign=false", "-c", "user.name=target-policy", "-c", "user.email=target-policy@example.invalid", "commit", "--quiet", "-m", "initial"], check=True, timeout=10)
        identity_commit = git_head(identity_clean)
        validate_source_identity(identity_clean, identity_commit, "fixture")
        identity_subdirectory = identity_clean / "subdirectory"
        identity_subdirectory.mkdir()
        identity_staged = root / "identity-staged"
        identity_unstaged = root / "identity-unstaged"
        identity_untracked = root / "identity-untracked"
        for identity_path in (identity_staged, identity_unstaged, identity_untracked):
            subprocess.run(["git", "clone", "--quiet", str(identity_clean), str(identity_path)], check=True, timeout=10)
        (identity_staged / "tracked.txt").write_text("staged\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(identity_staged), "add", "tracked.txt"], check=True, timeout=10)
        (identity_unstaged / "tracked.txt").write_text("unstaged\n", encoding="utf-8")
        (identity_untracked / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        identity_alias = root / "identity-alias"
        identity_alias.symlink_to(identity_clean, target_is_directory=True)
        fsmonitor_marker = root / "fsmonitor-executed"
        fsmonitor_hook = root / "fsmonitor-hook.sh"
        fsmonitor_hook.write_text(f"#!/bin/sh\nprintf executed >{fsmonitor_marker}\n", encoding="utf-8")
        fsmonitor_hook.chmod(0o755)
        subprocess.run(["git", "-C", str(identity_clean), "config", "core.fsmonitor", str(fsmonitor_hook)], check=True, timeout=10)
        validate_source_identity(identity_clean, identity_commit, "fixture")
        require(not fsmonitor_marker.exists(), "source identity validation executed repository-local fsmonitor code")
        identity_cases = (
            (identity_subdirectory, identity_commit, "repository root"),
            (identity_staged, identity_commit, "worktree is not clean"),
            (identity_unstaged, identity_commit, "worktree is not clean"),
            (identity_untracked, identity_commit, "worktree is not clean"),
            (identity_clean, "0" * 40, "wrong fixture source commit"),
            (identity_alias, identity_commit, "canonical absolute repository root"),
        )
        for identity_path, expected_commit, expected in identity_cases:
            try:
                validate_source_identity(identity_path, expected_commit, "fixture")
            except PolicyError as error:
                require(expected in str(error), f"identity fixture did not reject {expected}")
            else:
                require(False, f"identity fixture accepted {identity_path}")
        targets = root / "targets.json"
        targets.write_text(json.dumps({"targets": {"linux-x86_64-v4": {"native_arch": "x86_64", "spack_target": "x86_64_v4"}, "linux-aarch64-gb300": {"native_arch": "aarch64", "spack_target": "aarch64"}}}), encoding="utf-8")
        malformed, wrong, missing, mutated, valid = (root / name for name in ("malformed.yaml", "wrong.yaml", "missing.yaml", "mutated.yaml", "valid.yaml"))
        llvm_policy = "    llvm:\n      require:\n      - '@21'\n      - spec: +clang+lld~lldb~flang~polly~ipo build_system=cmake targets=x86,nvptx\n        when: target=x86_64\n      - spec: +clang+lld~lldb~flang~polly~ipo build_system=cmake targets=aarch64,nvptx\n        when: target=aarch64\n"
        for path, content in ((malformed, "spack: [\n"), (wrong, "spack:\n  packages:\n    all:\n      target: [x86_64_v4]\n"), (missing, "spack:\n  packages:\n    all: {}\n"), (mutated, "spack:\n  packages:\n    all:\n      require:\n      - spec: target=x86_64\n        when: target=x86_64\n      - spec: target=aarch64\n        when: target=aarch64\n" + llvm_policy), (valid, "spack:\n  packages:\n    all:\n      require:\n      - spec: target=x86_64_v4\n        when: target=x86_64\n      - spec: target=aarch64\n        when: target=aarch64\n" + llvm_policy)):
            path.write_text(content, encoding="utf-8")
        wrong_llvm = root / "wrong-llvm.yaml"
        wrong_llvm.write_text(valid.read_text(encoding="utf-8").replace("targets=aarch64,nvptx", "targets=x86,nvptx"), encoding="utf-8")
        wrong_targets = root / "wrong-targets.json"
        wrong_targets.write_text(json.dumps({"targets": {"linux-x86_64-v4": {"native_arch": "x86_64", "spack_target": "x86_64"}, "linux-aarch64-gb300": {"native_arch": "aarch64", "spack_target": "aarch64"}}}), encoding="utf-8")
        concrete: dict[str, Path] = {}
        for name, content in (("exact", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n"), ("ambiguous", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n  - {name: dependency, target: {name: aarch64}}\n"), ("conflicting", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}, arch: {target: aarch64}}\n"), ("absent", "spec:\n  nodes:\n  - {name: zlib}\n"), ("malformed-target", "spec:\n  nodes:\n  - {name: zlib, target: {name: 7}}\n"), ("wrong-target", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64}}\n"), ("unrelated", "target: {name: x86_64_v4}\nspec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n")):
            concrete[name] = root / f"concrete-{name}.yaml"
            concrete[name].write_text(content, encoding="utf-8")
        cases = [
            ([str(malformed), str(targets)], "malformed YAML", {}),
            ([str(wrong), str(targets)], "unconditional Vlad target remains", {}),
            ([str(missing), str(targets)], "spack.packages.all.require must be a list", {}),
            ([str(mutated), str(targets)], "architecture requirements do not match exact policy", {}),
            ([str(wrong_llvm), str(targets)], "LLVM architecture requirements do not match exact policy", {}),
            ([str(valid), str(wrong_targets)], "x86 target registry mismatch", {}),
            (["--internal-case", "malformed-rule"], "malformed RequirementRule output", {}),
            (["--spack-source", str(root), "--spack-packages-source", str(root), str(valid), str(targets)], "source is not an exact Git checkout", {}),
            (["--spack-source", str(script.parents[3]), "--spack-packages-source", str(script.parents[3]), str(valid), str(targets)], "wrong Spack source commit", {}),
            (["--assert-concrete-yaml", str(concrete["ambiguous"]), "--expected-target", "x86_64_v4"], "concrete YAML target ambiguity", {}),
            *[(["--assert-concrete-yaml", str(concrete[name]), "--expected-target", "x86_64_v4"], reason, {}) for name, reason in (("conflicting", "concrete YAML target ambiguity"), ("absent", "concrete YAML target absent"), ("malformed-target", "concrete YAML target malformed"), ("wrong-target", "concrete YAML target mismatch"), ("unrelated", "concrete YAML structure mismatch"))],
        ]
        if sources is not None:
            semantic = ["--spack-source", str(sources.spack), "--spack-packages-source", str(sources.packages), str(valid), str(targets)]
            cases.extend(((semantic, "injected setup failure", {"TARGET_POLICY_TEST_INJECT": "setup"}), (semantic, "injected parser failure", {"TARGET_POLICY_TEST_INJECT": "parser"})))
        for arguments, expected, overrides in cases:
            child = subprocess.run([sys.executable, str(script), *arguments], check=False, capture_output=True, text=True, timeout=120, env=os.environ | overrides)
            require(child.returncode != 0 and expected in child.stderr, f"self-test child did not reject {expected}")
        solver_mutant = root / "target-policy-solver-token.py"
        solver_mutant.write_text(script.read_text(encoding="utf-8") + f"\n# {solver_tokens[0]}\n", encoding="utf-8")
        solver_child = subprocess.run([sys.executable, str(solver_mutant), "--self-test"], check=False, capture_output=True, text=True, timeout=30, env=child_environment)
        require(solver_child.returncode != 0 and "forbidden solver token remains" in solver_child.stderr, "self-test child did not reject forbidden solver token")
        source_default_mutant = root / "target-policy-source-default.py"
        source_default_mutant.write_text(script.read_text(encoding="utf-8") + "\nREFERENCE" + "_ROOT = None\n", encoding="utf-8")
        source_default_child = subprocess.run([sys.executable, str(source_default_mutant), "--self-test"], check=False, capture_output=True, text=True, timeout=30, env=child_environment)
        require(source_default_child.returncode != 0 and "hidden pinned-source default remains" in source_default_child.stderr, "self-test child did not reject hidden pinned-source default")
        exact_child = subprocess.run([sys.executable, str(script), "--assert-concrete-yaml", str(concrete["exact"]), "--expected-target", "x86_64_v4"], check=False, capture_output=True, text=True, timeout=30)
        require(exact_child.returncode == 0 and "concrete target: x86_64_v4" in exact_child.stdout, "self-test exact concrete target failed")
        expected_skipped = "TARGET_POLICY_SEMANTIC_VALIDATION=SKIPPED reason=source-inputs-not-supplied"
        expected_passed = "TARGET_POLICY_SEMANTIC_VALIDATION=PASSED spack_commit=fff95dd9aed0af7c7a8252adbef5623fcd4187f7 spack_packages_commit=65f3228ea2533e8413c17661a3a0db3636269631"
        probes = [(["--status-probe", str(valid), str(targets)], expected_skipped)]
        if sources is not None:
            probes.append(
                (
                    [
                        "--status-probe",
                        "--spack-source",
                        str(sources.spack),
                        "--spack-packages-source",
                        str(sources.packages),
                        str(valid),
                        str(targets),
                    ],
                    expected_passed,
                )
            )
        selected = expected_skipped
        for arguments, expected in probes:
            probe = subprocess.run([sys.executable, str(script), *arguments], check=False, capture_output=True, text=True, timeout=120)
            require(
                probe.returncode == 0 and has_exact_probe_output(probe.stdout, expected),
                "self-test status probe failed",
            )
            selected = expected
        normal_child = subprocess.run([sys.executable, str(script), str(valid), str(targets)], check=False, capture_output=True, text=True, timeout=30)
        require(normal_child.returncode == 0 and "Vlad target policy structural validation" in normal_child.stdout, "self-test normal structural child failed")
        mutants = (
            (expected_passed,),
            (expected_skipped, expected_skipped),
            (expected_skipped.replace("SKIPPED", "ALTERED"),),
            (expected_skipped, "TARGET_POLICY_SEMANTIC_VALIDATION=FORGED"),
            (expected_passed, expected_skipped),
        )
        for observed in mutants:
            require(not has_exact_probe_output("\n".join(observed), expected_skipped), "self-test property mutant was accepted")
        if sources is not None:
            require(not has_exact_probe_output(expected_skipped, expected_passed), "self-test wrong-direction semantic line was accepted")
            failed_probe = subprocess.run([sys.executable, str(script), *probes[-1][0]], check=False, capture_output=True, text=True, timeout=120, env=os.environ | {"TARGET_POLICY_TEST_INJECT": "setup"})
            require(failed_probe.returncode != 0 and "TARGET_POLICY_SEMANTIC_VALIDATION=" not in failed_probe.stdout, "self-test clean semantic failure mutant was accepted")
    print(f"self-test passed: {len(cases) + 2} rejected; 1 accepted")
    return selected


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spack-source", type=Path)
    parser.add_argument("--spack-packages-source", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--status-probe", action="store_true")
    parser.add_argument("--assert-concrete-yaml", type=Path)
    parser.add_argument("--expected-target")
    parser.add_argument("--internal-case", choices=("malformed-rule",))
    parser.add_argument("yaml", type=Path, nargs="?")
    parser.add_argument("targets", type=Path, nargs="?")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        sources = pinned_sources(args.spack_source, args.spack_packages_source)
        if args.self_test:
            print(run_self_test(sources))
        elif args.status_probe:
            require(args.yaml is not None and args.targets is not None, "YAML and target registry paths are required")
            print(run_status_probe(args.yaml, args.targets, sources))
        elif args.internal_case == "malformed-rule":  # noqa: IF_VARIANT_OK - argparse mode dispatch
            require(sources is None, "pinned source paths are not valid for internal cases")
            require(False, "malformed RequirementRule output")
        elif args.assert_concrete_yaml:
            require(sources is None, "pinned source paths are not valid for concrete YAML assertions")
            require(bool(args.expected_target), "--expected-target is required")
            require(args.expected_target == concrete_target(load_yaml(args.assert_concrete_yaml)), "concrete YAML target mismatch")
            print(f"concrete target: {args.expected_target}")
        else:
            require(args.yaml is not None and args.targets is not None, "YAML and target registry paths are required")
            packages = validate_structure(args.yaml, args.targets)
            if sources is not None:
                with tempfile.TemporaryDirectory(prefix="vlad-spack-cache-") as cache:
                    os.environ["SPACK_USER_CACHE_PATH"] = cache
                    validate_with_spack(args.yaml, packages, sources)
                print(f"Vlad target policy semantic validation: Spack={SPACK_COMMIT}; spack-packages={PACKAGES_COMMIT}")
            else:
                print("Vlad target policy structural validation: x86_64 -> x86_64_v4; aarch64 -> aarch64")
        return 0
    except PolicyError as error:
        print(f"target-policy-test: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
