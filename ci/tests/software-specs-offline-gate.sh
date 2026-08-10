#!/usr/bin/env bash
# The offline gate: everything that must pass on any machine, with no Spack,
# no Slurm, no hardware, and no site file. The pytest suite (make test) owns
# almost all of it; the cases below are the repo-level checks pytest does not
# cover. Target-platform behavior is an operator gate, never proven here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT}" || exit 2
export PATH="${HOME}/.local/bin:${PATH}"

case_count=0
failure_count=0

run_case() {
  local name="$1"
  shift
  case_count=$((case_count + 1))
  printf 'CASE %02d: %s\n' "${case_count}" "${name}"
  "$@"
  local status=$?
  printf 'EXIT %02d: %s -> %d\n' "${case_count}" "${name}" "${status}"
  if (( status != 0 )); then
    failure_count=$((failure_count + 1))
  fi
}

# Shell files that exist in the worktree: tracked plus untracked-but-not-
# ignored, excluding linked worktrees and harness state.
shell_files() {
  local file
  git ls-files -co --exclude-standard -- '*.sh' '*.sbatch' \
      ':!:.claude/**' ':!:foobar/**' \
    | while IFS= read -r file; do
        [ -f "${file}" ] && printf '%s\n' "${file}"
      done
}

shell_syntax_gate() {
  local -a files
  mapfile -t files < <(shell_files)
  bash -n "${files[@]}"
}

# Registry JSON not already parsed by the pytest suite (the schemas and the
# source-custody lock) plus the registries themselves, as pure syntax.
json_syntax_gate() {
  local file
  for file in \
    containers/images/targets.json containers/images/targets.schema.json \
    containers/images/containers.json containers/images/containers.schema.json \
    containers/images/sources-lock.json; do
    python3 -I -E -m json.tool "${file}" >/dev/null || return
  done
}

# Every skill carries valid frontmatter; the validator itself is vendored.
skill_gate() {
  local skill
  for skill in .agents/skills/*/; do
    python3 -I .agents/skills/skill-creator/scripts/quick_validate.py "${skill%/}" || return
  done
}

# Source custody: no real image build until the lock is complete and approved.
source_lock_gate() {
  python3 -I -E -c 'import json; from pathlib import Path; assert json.loads(Path("containers/images/sources-lock.json").read_text())["status"] == "blocked"'
}

# CI automation is a recorded follow-up decision; no workflow may appear.
workflow_gate() {
  [[ ! -d .github/workflows ]] || [[ -z "$(find .github/workflows -type f -print -quit)" ]]
}

run_case pytest make test
run_case lint make lint
run_case direct-install-self python3 -I ci/tests/no-direct-install-surface-test.py --self-test
run_case direct-install-audit python3 -I ci/tests/no-direct-install-surface-test.py
run_case shell-syntax shell_syntax_gate
run_case json-syntax json_syntax_gate
run_case skills skill_gate
run_case source-lock source_lock_gate
run_case workflows workflow_gate
run_case diff-check git diff --check

printf 'OFFLINE_GATE cases=%d passed=%d failed=%d\n' \
  "${case_count}" "$((case_count - failure_count))" "${failure_count}"
exit "${failure_count}"
