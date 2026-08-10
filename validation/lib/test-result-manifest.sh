#!/usr/bin/env bash
set -euo pipefail

# Offline contract test: no Slurm, no hardware, no network. It proves that runner
# evidence is strict, that manual evidence cannot masquerade as authoritative, and
# that the pre-contract summary shape is rejected rather than tolerated.

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${lib_dir}/fixtures/result-manifest"
# shellcheck source=validation/lib/verdict.sh
source "${lib_dir}/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${lib_dir}/result-manifest.sh"

expect_valid() {
    validation_result_validate_manifest "$1"
}

expect_runner_valid() {
    validation_result_validate_runner_manifest "$1"
}

expect_invalid() {
    if validation_result_validate_manifest "$1" 2>/dev/null; then
        printf 'unexpectedly accepted: %s\n' "$1" >&2
        return 1
    fi
}

expect_invalid_runner() {
    if validation_result_validate_runner_manifest "$1" 2>/dev/null; then
        printf 'unexpectedly accepted as runner evidence: %s\n' "$1" >&2
        return 1
    fi
}

# The shape every suite used before this contract existed.
expect_invalid "${fixtures}/legacy-node-smoke-summary.json"
expect_runner_valid "${fixtures}/pass.json"
expect_valid "${fixtures}/warn.json"
# Evidence may name the immutable release it ran against, but never half of
# one: a release block missing any identity field is refused.
expect_invalid "${fixtures}/partial-release-identity.json"
expect_valid "${fixtures}/threshold-fail.json"
expect_valid "${fixtures}/optional-skip.json"
expect_valid "${fixtures}/mandatory-unavailable.json"
expect_invalid "${fixtures}/unknown-schema.json"
expect_invalid "${fixtures}/missing-manifest.json"
expect_valid "${fixtures}/manual.json"
# Schema-valid, yet must not be selectable as CI evidence.
expect_invalid_runner "${fixtures}/manual.json"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/chapar-result-manifest.XXXXXX")"
cleanup() { rm -rf -- "${temporary}"; }
trap cleanup EXIT

VALIDATION_RESULT_MODE=runner
VALIDATION_RUN_ID="fixture-stale-001"
VALIDATION_RUN_ISSUED_AT="$(python3 - "${fixtures}/stale-run-id.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["run_issued_at"])
PY
)"
if validation_result_init rocev2-pairwise "${temporary}" node01 2>/dev/null; then
    printf 'stale run ID was unexpectedly accepted\n' >&2
    exit 1
fi

# A timestamp without a timezone is ambiguous, so it is refused rather than
# assumed to be UTC.
VALIDATION_RUN_ID="fixture-naive-001"
VALIDATION_RUN_ISSUED_AT="2026-07-30T12:00:00"
if validation_result_init rocev2-pairwise "${temporary}" node01 2>/dev/null; then
    printf 'timezone-less run timestamp was unexpectedly accepted\n' >&2
    exit 1
fi

unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
if validation_result_init node-admission "${temporary}" node01 2>/dev/null; then
    printf 'missing run ID was unexpectedly accepted\n' >&2
    exit 1
fi

# A suite absent from the bound list must be refused, so the allowlist and the
# schema enum cannot drift apart unnoticed.
(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    if validation_result_init integrity-test "${temporary}" node01 2>/dev/null; then
        printf 'unbound suite was unexpectedly accepted\n' >&2
        exit 1
    fi
)

(
    VALIDATION_RESULT_MODE=runner
    VALIDATION_RUN_ID="fixture-duplicate-001"
    VALIDATION_RUN_ISSUED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    validation_result_init node-admission "${temporary}" node01
    trap - EXIT
    # Same suite and same run id: the guard is keyed on <suite>/<run_id>, so
    # re-running a different suite under one runner id is legitimate and only a
    # genuine re-use of the pair is refused.
    if validation_result_init node-admission "${temporary}" node01 2>/dev/null; then
        printf 'duplicate run ID was unexpectedly accepted\n' >&2
        exit 1
    fi
)

(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    validation_result_init node-admission "${temporary}" node01
    case "${VALIDATION_RUN_ID}" in manual-*) ;; *) exit 1 ;; esac
    [ "${VALIDATION_CI_AUTHORITATIVE}" = false ]
    trap - EXIT
)

# Finalize end to end: a suite that records nothing and exits 0 must produce a
# schema-valid PASS manifest, its Prometheus gauge, and exit 0.
(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    validation_result_init cpu-platform "${temporary}" node01
    run_dir="${VALIDATION_RUN_DIR}"
    printf '%s\n' "${run_dir}" > "${temporary}/finalize-run-dir"
    trap - EXIT
    validation_result_finalize 0
) || { printf 'finalize of a clean run did not exit 0\n' >&2; exit 1; }
finalize_dir="$(cat "${temporary}/finalize-run-dir")"
validation_result_validate_manifest "${finalize_dir}/suite-manifest.json"
grep -Fq 'chapar_validation_suite_verdict{suite="cpu-platform"' "${finalize_dir}/suite.prom"
grep -Fq 'verdict="PASS"} 0' "${finalize_dir}/suite.prom"
python3 - "${finalize_dir}/summary.json" <<'PY'
import json
import sys
document = json.load(open(sys.argv[1]))
assert document["verdict"] == "PASS", document
assert document["command_exit_code"] == 0, document
assert document["provenance"] == {"mode": "manual", "ci_authoritative": False}, document
PY

# A suite handed a release directory records its identity: metadata tuple plus
# the run-time digest of the release-local lock bytes.
release_fixture="${temporary}/release/rel-fixture-001"
mkdir -p "${release_fixture}"
printf '{"roots": []}\n' > "${release_fixture}/spack.lock"
python3 - "${release_fixture}" <<'PY'
import json
import sys
from pathlib import Path

release = Path(sys.argv[1])
metadata = {
    "identity": {
        "software_set": "vlad",
        "target": "linux-x86_64-v4",
        "release_id": "rel-fixture-001",
        "run_id": "run-001",
    },
}
(release / "metadata.json").write_text(json.dumps(metadata) + "\n", encoding="utf-8")
PY
(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    CHAPAR_RELEASE_DIR="${release_fixture}"
    validation_result_init gpu-topology "${temporary}" node01
    printf '%s\n' "${VALIDATION_RUN_DIR}" > "${temporary}/release-run-dir"
    trap - EXIT
    validation_result_finalize 0
) || { printf 'finalize with a release directory did not exit 0\n' >&2; exit 1; }
release_dir="$(cat "${temporary}/release-run-dir")"
validation_result_validate_manifest "${release_dir}/suite-manifest.json"
python3 - "${release_dir}/suite-manifest.json" "${release_fixture}/spack.lock" <<'PY'
import hashlib
import json
import sys
document = json.load(open(sys.argv[1]))
release = document["release"]
assert release["software_set"] == "vlad", document
assert release["target"] == "linux-x86_64-v4", document
assert release["release_id"] == "rel-fixture-001", document
assert release["run_id"] == "run-001", document
expected = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert release["release_lock_sha256"] == expected, document
PY

# A release directory that cannot be described is a broken handshake, never a
# silent omission.
(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    CHAPAR_RELEASE_DIR="${temporary}/no-such-release"
    if validation_result_init gpu-topology "${temporary}" node01 2>/dev/null; then
        printf 'an undescribable release directory was unexpectedly accepted\n' >&2
        exit 1
    fi
)

# A suite that exits 77 without recording a verdict is SKIP, not PASS.
(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    validation_result_init vast "${temporary}" node01
    printf '%s\n' "${VALIDATION_RUN_DIR}" > "${temporary}/skip-run-dir"
    trap - EXIT
    validation_result_finalize 77
) && { printf 'finalize of a 77 run did not exit 77\n' >&2; exit 1; }
skip_dir="$(cat "${temporary}/skip-run-dir")"
python3 - "${skip_dir}/suite-manifest.json" <<'PY'
import json
import sys
document = json.load(open(sys.argv[1]))
assert document["verdict"] == "SKIP", document
assert document["reason"] == "suite exited 77", document
PY

printf 'result manifest contract: runner evidence is strict; manual initialization is non-authoritative\n'
