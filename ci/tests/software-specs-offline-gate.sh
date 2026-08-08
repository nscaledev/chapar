#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OUTPUT_DIR="${1:-}"

pure_python_loc() {
  awk '!/^[[:space:]]*$/ && !/^[[:space:]]*#/' "$1" | wc -l | tr -d ' '
}

loc_gate() {
  local file pure_loc failed=0
  local -a files=("$@")
  if (( ${#files[@]} == 0 )); then
    mapfile -t files < <(changed_paths '\.py$')
  fi
  for file in "${files[@]}"; do
    pure_loc="$(pure_python_loc "${file}")"
    printf '%s\t%s\n' "${pure_loc}" "${file}"
    if (( pure_loc > 250 )); then
      printf 'ERROR: Python module exceeds 250 pure LOC: %s (%s)\n' "${file}" "${pure_loc}" >&2
      failed=1
    fi
  done
  return "${failed}"
}

python_quality_self_test() {
  local fixture_root healthy oversized
  fixture_root="$(mktemp -d "${TMPDIR:-/private/tmp}/chapar-python-quality.XXXXXX")"
  trap 'rm -rf "${fixture_root}"' RETURN
  healthy="${fixture_root}/healthy.py"
  oversized="${fixture_root}/oversized.py"
  awk 'BEGIN { for (i = 1; i <= 250; i++) print "value_" i " = " i }' > "${healthy}"
  awk 'BEGIN { for (i = 1; i <= 251; i++) print "value_" i " = " i }' > "${oversized}"
  loc_gate "${healthy}"
  if loc_gate "${oversized}" >/dev/null 2>&1; then
    echo "ERROR: oversized Python fixture passed LOC enforcement" >&2
    return 1
  fi
  ! rg -n "grep -v '\^ci/cve-checker\\.py\$'" "${BASH_SOURCE[0]}" >/dev/null
}

if [[ "${OUTPUT_DIR}" == "--self-test-python-quality" ]]; then
  python_quality_self_test
  exit
fi

if [[ -z "${OUTPUT_DIR}" || "${OUTPUT_DIR}" != /* || -e "${OUTPUT_DIR}" ]]; then
  echo "usage: $0 ABSENT_ABSOLUTE_OUTPUT_DIRECTORY" >&2
  exit 2
fi

mkdir -p "${OUTPUT_DIR}/cases"
COMMAND_LOG="${OUTPUT_DIR}/commands.tsv"
RESULTS_LOG="${OUTPUT_DIR}/results.tsv"
SUMMARY="${OUTPUT_DIR}/summary.json"
TEMP_PARENT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || printf '%s\n' "${TMPDIR:-/private/tmp}")"
TEMP_PARENT="$(cd "${TEMP_PARENT}" && pwd -P)"
TEMP_ROOT="$(mktemp -d "${TEMP_PARENT}/chapar-offline-gate.XXXXXX")"
MARKER_LOG="${TEMP_ROOT}/forbidden-command-markers.log"
POISON_BIN="${TEMP_ROOT}/poison-bin"
mkdir -p "${POISON_BIN}"
trap 'rm -rf "${TEMP_ROOT}"' EXIT INT TERM

for command_name in spack sbatch srun module enroot enroot-mksquashfs docker systemctl apt-get gh; do
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$(basename "$0")" >> "${CHAPAR_FORBIDDEN_MARKER:?}"' \
    'exit 97' > "${POISON_BIN}/${command_name}"
  chmod +x "${POISON_BIN}/${command_name}"
done

export CHAPAR_FORBIDDEN_MARKER="${MARKER_LOG}"
export PATH="${POISON_BIN}:/opt/homebrew/bin:/usr/bin:/bin"
export TMPDIR="${TEMP_ROOT}/tmp"
mkdir -p "${TMPDIR}"
cd "${ROOT}" || exit 2

printf 'sequence\tcase\tcommand\texit\tlog_sha256\n' > "${COMMAND_LOG}"
printf 'sequence\tcase\texit\tlog\n' > "${RESULTS_LOG}"
case_count=0
failure_count=0

run_case() {
  local name="$1"
  shift
  case_count=$((case_count + 1))
  local sequence
  sequence="$(printf '%02d' "${case_count}")"
  local log="${OUTPUT_DIR}/cases/${sequence}-${name}.log"
  local rendered=""
  printf -v rendered '%q ' "$@"
  printf 'CASE %s: %s\nCOMMAND: %s\n' "${sequence}" "${name}" "${rendered}" | tee "${log}"
  "$@" >> "${log}" 2>&1
  local status=$?
  local digest
  digest="$(shasum -a 256 "${log}" | awk '{print $1}')"
  printf 'EXIT: %d\n' "${status}" | tee -a "${log}"
  printf '%s\t%s\t%s\t%d\t%s\n' "${sequence}" "${name}" "${rendered}" "${status}" "${digest}" >> "${COMMAND_LOG}"
  printf '%s\t%s\t%d\t%s\n' "${sequence}" "${name}" "${status}" "${log#"${ROOT}"/}" >> "${RESULTS_LOG}"
  if (( status != 0 )); then
    failure_count=$((failure_count + 1))
  fi
}

changed_paths() {
  local suffix="$1"
  git status --porcelain=v1 --untracked-files=all \
    | awk -v suffix="${suffix}" '$1 != "D" && $2 ~ suffix && $2 !~ /__pycache__/ {print $2}' \
    | sort -u
}

json_syntax_gate() {
  local file
  for file in \
    containers/images/targets.json containers/images/targets.schema.json \
    containers/images/containers.json containers/images/containers.schema.json \
    containers/images/sources-lock.json containers/images/site-contract.schema.json \
    containers/images/site-contract.example.json datacenters/schemas/datacenter.schema.json \
    datacenters/schemas/target-contract.schema.json cookiecutter/chapar-datacenter/cookiecutter.json \
    envs/software/tests/fixtures/historical-root-inventory.json \
    envs/software/tests/fixtures/protected-state.json \
    envs/software/tests/fixtures/release-plan-selection.json; do
    python3 -I -E -m json.tool "${file}" >/dev/null || return
  done
}

yaml_syntax_gate() {
  ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false) }' \
    envs/software/spack.yaml etc/user/base/config.yaml etc/user/base/modules.yaml \
    etc/system/base/mirrors.yaml etc/system/ubuntu24.04/mirrors.yaml
}

python_compile_gate() {
  python3 -I -E - "$@" <<'PY'
from pathlib import Path
import sys

for filename in sys.argv[1:]:
    source = Path(filename).read_text(encoding="utf-8")
    compile(source, filename, "exec")
PY
}

skill_gate() {
  local skill
  for skill in \
    chapar-spack-env-change chapar-spack-solve-debug chapar-release-helper \
    chapar-buildcache chapar-vlad-image chapar-validation \
    chapar-config-scope-change chapar-cuda-gdr-transport chapar-cve-checker \
    chapar-ci-artifact-watch chapar-commit chapar-harness-wiring; do
    python3 .agents/skills/skill-creator/scripts/quick_validate.py ".agents/skills/${skill}" || return
  done
}

protected_state_gate() {
  local expected_head="b09f431a4eb329474689e8fbe8eb7b0797a3f28b"
  local path
  test "$(git rev-parse HEAD)" = "${expected_head}" || return
  for path in envs/hpcsim/spack.lock containers/images/sources-lock.json; do
    test "$(git hash-object "${path}")" = "$(git rev-parse "HEAD:${path}")" || return
    git diff --exit-code -- "${path}" || return
  done
  python3 -I -E -c 'import json; from pathlib import Path; assert json.loads(Path("containers/images/sources-lock.json").read_text())["status"] == "blocked"'
  git diff --cached --quiet
}

workflow_gate() {
  [[ ! -d .github/workflows ]] || [[ -z "$(find .github/workflows -type f -print -quit)" ]]
}

marker_gate() {
  [[ ! -s "${MARKER_LOG}" ]]
}

command_boundary_gate() {
  ! cut -f3 "${COMMAND_LOG}" | rg -n '/resources|(^|[[:space:]])(spack|sbatch|srun|module|enroot|docker|systemctl|apt-get|gh)([[:space:]]|$)' >/dev/null
}

mapfile -t python_files < <(changed_paths '\.py$')
mapfile -t shell_files < <(changed_paths '\.(sh|sbatch)$')
strict_python_files=("${python_files[@]}")
mapfile -t root_type_files < <(
  printf '%s\n' "${python_files[@]}" \
    | grep -v '^containers/images/\(registry\|release_contract\|selection_contract\)\.py$'
)
no_excuse_checker="/Users/mrez/.codex/plugins/cache/sisyphuslabs/omo/4.19.4/skills/programming/scripts/python/check-no-excuse-rules.py"

run_case inventory python3 -I -E envs/software/tests/test_inventory.py
run_case catalog uv run --offline envs/software/tests/test_catalog.py
run_case cookiecutter uv run --offline cookiecutter/chapar-datacenter/tests/test_template.py
run_case resolver-validation uv run --offline --with 'cookiecutter>=2,<3' --with 'jsonschema>=4,<5' --with 'pydantic>=2,<3' --with 'pytest>=8,<9' --with 'PyYAML>=6,<7' pytest -q tools/chapar_config/tests validation/tests/test_selection_consumers.py validation/tests/test_validation_authority.py ci/tests/test_cve_checker.py
run_case validation-manifest bash validation/lib/test-result-manifest.sh
run_case validation-fixture-mode bash validation/lib/test-fixture-mode.sh
run_case validation-capability bash validation/config/test-capability.sh
run_case validation-cpu-fixtures bash validation/tests/test-cpu-fixtures.sh
run_case validation-gpu-fixtures bash validation/tests/test-gpu-fixtures.sh
run_case validation-transport-fixtures bash validation/tests/test-transport-fixtures.sh
run_case validation-storage-fixtures bash validation/tests/test-storage-fixtures.sh
run_case validation-container-fixtures bash validation/tests/test-container-fixtures.sh
run_case release-plan bash envs/software/tests/release-helper-plan-test.sh
run_case cache-module-plan bash etc/tests/selection-config-test.sh
run_case ci-plan bash ci/tests/submit-env-build-test.sh
run_case registries bash containers/images/tests/registry-test.sh
run_case source-lock bash containers/images/tests/validate-locks.sh --self-test
run_case image-plan bash containers/images/tests/build-image-plan-test.sh
run_case preflight-plan bash containers/images/tests/preflight-selection-test.sh
run_case preflight-custody bash containers/images/tests/preflight-test.sh
run_case installer-runner bash ci/tests/vlad-image-provisioning-test.sh
run_case receipts python3 -I -E ci/verify-vlad-source-approval.py --self-test
run_case direct-install-self python3 -I -E ci/tests/no-direct-install-surface-test.py --self-test
run_case direct-install-full python3 -I -E ci/tests/no-direct-install-surface-test.py
run_case documentation-fence bash ci/tests/documentation-contract-fence-test.sh
run_case documentation uv run --offline ci/tests/documentation-contract-test.py
run_case runbook-self uv run --offline ci/tests/nscale-vlad-runbook-test.py --self-test
run_case runbook uv run --offline ci/tests/nscale-vlad-runbook-test.py
run_case python-quality-self bash ci/tests/software-specs-python-quality-test.sh
run_case json-syntax json_syntax_gate
run_case yaml-syntax yaml_syntax_gate
run_case shell-syntax bash -n "${shell_files[@]}"
run_case shellcheck shellcheck --severity=warning --exclude=SC1090 "${shell_files[@]}"
run_case python-compile python_compile_gate "${python_files[@]}"
run_case ruff uv run --offline --with 'ruff>=0.12,<1' ruff check "${python_files[@]}"
run_case basedpyright-root uv run --offline --with 'basedpyright>=1,<2' --with 'cookiecutter>=2,<3' --with 'jsonschema>=4,<5' --with 'pydantic>=2,<3' --with 'pytest>=8,<9' --with 'PyYAML>=6,<7' basedpyright --level error "${root_type_files[@]}"
run_case basedpyright-images bash -c "cd containers/images && uv run --offline --with 'basedpyright>=1,<2' basedpyright --level error registry.py release_contract.py selection_contract.py"
run_case no-excuse python3 "${no_excuse_checker}" "${strict_python_files[@]}"
run_case pure-loc loc_gate
run_case skills skill_gate
run_case diff-check git diff --check
run_case protected-state protected_state_gate
run_case workflows workflow_gate
run_case forbidden-markers marker_gate
run_case command-boundary command_boundary_gate

python3 -I -E - "${RESULTS_LOG}" "${COMMAND_LOG}" "${SUMMARY}" "${case_count}" "${failure_count}" <<'PY'
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import sys

results_path, commands_path, summary_path = map(Path, sys.argv[1:4])
cases: list[dict[str, str | int]] = []
with results_path.open(encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        log = Path(row["log"])
        cases.append({
            "sequence": row["sequence"],
            "case": row["case"],
            "exit": int(row["exit"]),
            "log": row["log"],
            "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
        })
summary = {
    "format": "chapar-task-12-offline-gate-v1",
    "case_count": int(sys.argv[4]),
    "passed": int(sys.argv[4]) - int(sys.argv[5]),
    "failed": int(sys.argv[5]),
    "commands_sha256": hashlib.sha256(commands_path.read_bytes()).hexdigest(),
    "cases": cases,
}
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

printf 'OFFLINE_GATE cases=%d passed=%d failed=%d\n' "${case_count}" "$((case_count - failure_count))" "${failure_count}"
printf 'SUMMARY %s\n' "${SUMMARY}"
exit "${failure_count}"
