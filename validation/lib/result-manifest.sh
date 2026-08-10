#!/usr/bin/env bash

# Suite manifests are evidence, not scheduler authority.  A post-job collector
# must consume sacct state, ExitCode, and TRES to create any tier manifest.
#
# A suite calls validation_result_init once, records outcomes through verdict.sh,
# and exits normally; the EXIT trap installed here persists summary.json,
# suite.prom, and the schema-checked suite-manifest.json, then converts the
# verdict into the process exit code (PASS/WARN 0, FAIL 1, SKIP 77).

# Suites bound to this contract.  This list must stay equal to the `suite` enum in
# result-manifest.schema.json -- the schema is what rejects a manifest, this case
# is what rejects the call, and a suite missing from either is a silent gap.
validation_result_suite_is_bound() {
    case "$1" in
        container-smoke|cpu-platform|gpu-topology|node-admission|nvlink-p2p) return 0 ;;
        rdma-link-check|rocev2-pairwise|slurm-placement|storage-burnin|vast) return 0 ;;
    esac
    return 1
}

validation_result_init() {
    local suite="$1"
    local results_root="$2"
    local node="$3"
    local manual_identity

    validation_verdict_init || return
    if ! validation_result_suite_is_bound "${suite}"; then
        printf 'suite is not bound to the result-manifest contract: %s\n' "${suite}" >&2
        return 2
    fi
    VALIDATION_RESULT_MODE="${VALIDATION_RESULT_MODE:-manual}"
    case "${VALIDATION_RESULT_MODE}" in
        runner)
            if [ -z "${VALIDATION_RUN_ID:-}" ] || [ -z "${VALIDATION_RUN_ISSUED_AT:-}" ]; then
                printf 'runner mode requires externally assigned VALIDATION_RUN_ID and VALIDATION_RUN_ISSUED_AT\n' >&2
                return 2
            fi
            VALIDATION_CI_AUTHORITATIVE=true
            ;;
        manual)
            # A generated identity is what keeps manual evidence non-authoritative
            # and, incidentally, keeps repeated local runs from colliding with the
            # duplicate-run guard below.
            manual_identity="$(python3 - <<'PY'
from datetime import datetime, timezone
from uuid import uuid4
print(f"manual-{uuid4()} {datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}")
PY
)"
            VALIDATION_RUN_ID="${manual_identity%% *}"
            VALIDATION_RUN_ISSUED_AT="${manual_identity#* }"
            VALIDATION_CI_AUTHORITATIVE=false
            ;;
        *)
            printf 'invalid VALIDATION_RESULT_MODE: %s\n' "${VALIDATION_RESULT_MODE}" >&2
            return 2
            ;;
    esac
    case "${VALIDATION_RUN_ID}" in
        [A-Za-z0-9][A-Za-z0-9._-][A-Za-z0-9._-]*) ;;
        *) printf 'invalid VALIDATION_RUN_ID: %s\n' "${VALIDATION_RUN_ID}" >&2; return 2 ;;
    esac

    # A run id that is stale, naive, or from the future is a broken runner
    # handshake, not a hardware condition, so it fails rather than skips.
    if ! python3 - "${VALIDATION_RUN_ISSUED_AT}" "${VALIDATION_MAX_RUN_AGE_SECONDS:-86400}" <<'PY'
from datetime import datetime, timezone
import sys
import time

issued = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
if issued.tzinfo is None:
    raise SystemExit("VALIDATION_RUN_ISSUED_AT must include a timezone")
age_limit = int(sys.argv[2])
age = time.time() - issued.timestamp()
if age > age_limit:
    raise SystemExit("VALIDATION_RUN_ID is stale")
if age < -300:
    raise SystemExit("VALIDATION_RUN_ISSUED_AT is too far in the future")
PY
    then
        return 2
    fi

    # Release identity: evidence must record which immutable release the suite
    # ran against. CHAPAR_RELEASE_DIR is the concrete release directory
    # validation/run resolved and exported; fixture and standalone runs have
    # none, and their manifests simply carry no release block. A release that
    # cannot be described is a broken handshake, not a hardware condition, so
    # it fails rather than skips.
    VALIDATION_RELEASE_JSON=""
    if [ -n "${CHAPAR_RELEASE_DIR:-}" ]; then
        if ! VALIDATION_RELEASE_JSON="$(python3 - "${CHAPAR_RELEASE_DIR}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

release = Path(sys.argv[1])
identity = json.loads((release / "metadata.json").read_text(encoding="utf-8"))["identity"]
# The lock digest is recomputed from the bytes on disk at run time: the
# manifest records what the suite actually saw, and `chapar validate plan`
# is what ties those bytes back to the metadata digest before submission.
print(json.dumps({
    "software_set": identity["software_set"],
    "target": identity["target"],
    "release_id": identity["release_id"],
    "run_id": identity["run_id"],
    "release_lock_sha256": hashlib.sha256((release / "spack.lock").read_bytes()).hexdigest(),
}))
PY
)"; then
            printf 'cannot record release identity from %s\n' "${CHAPAR_RELEASE_DIR}" >&2
            return 2
        fi
    fi

    VALIDATION_SUITE="${suite}"
    VALIDATION_RESULTS_ROOT="${results_root}"
    # RESULTS_ROOT is already namespaced by tuple, release, and validation-run
    # id (chapar validate plan derives it from CHAPAR_VALIDATION_ROOT), so the
    # manifest adds only <suite>/<VALIDATION_RUN_ID>/<node> beneath it.
    VALIDATION_RUN_DIR="${results_root}/${suite}/${VALIDATION_RUN_ID}"
    VALIDATION_NODE_DIR="${VALIDATION_RUN_DIR}/${node}"
    if [ -e "${VALIDATION_RUN_DIR}" ]; then
        printf 'duplicate VALIDATION_RUN_ID for suite %s: %s\n' "${suite}" "${VALIDATION_RUN_ID}" >&2
        return 2
    fi
    mkdir -p "${VALIDATION_NODE_DIR}"
    validation_result_install_trap
}

validation_result_install_trap() {
    trap 'validation_result_finalize "$?"' EXIT
}

validation_result_write_atomic_json() {
    local destination="$1"
    shift
    python3 - "${destination}" "$@" <<'PY'
import json
import os
import sys
import tempfile

destination, payload = sys.argv[1:]
directory = os.path.dirname(destination)
data = json.loads(payload)
fd, temporary = tempfile.mkstemp(prefix=".tmp-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

validation_result_write_atomic_text() {
    local destination="$1"
    local content="$2"
    # Subshelled so the restrictive umask applies to this write only. Setting it in
    # the caller's shell would silently make every later artifact owner-only,
    # including files a validator or collector still has to read.
    (
        umask 077
        printf '%b' "${content}" > "${destination}.tmp.$$"
        mv -f "${destination}.tmp.$$" "${destination}"
    )
}

validation_result_validate_manifest() {
    local manifest="$1"
    local library_dir schema
    # Split declaration from assignment: `local x="$(...)"` masks the command's
    # exit status, which shellcheck reports as SC2155 and the offline gate runs at
    # --severity=warning.
    library_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    schema="${library_dir}/result-manifest.schema.json"
    [ -f "${manifest}" ] || { printf 'missing suite manifest: %s\n' "${manifest}" >&2; return 2; }
    python3 - "${schema}" "${manifest}" <<'PY'
import json
import sys

import jsonschema

with open(sys.argv[1], encoding="utf-8") as stream:
    schema = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    manifest = json.load(stream)
jsonschema.Draft202012Validator(
    schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER
).validate(manifest)
PY
}

# Schema validity alone does not make evidence authoritative: a manual manifest is
# schema-valid by design. A CI consumer must use this instead.
validation_result_validate_runner_manifest() {
    local manifest="$1"
    validation_result_validate_manifest "${manifest}" || return
    python3 - "${manifest}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    provenance = json.load(stream)["provenance"]
if provenance != {"mode": "runner", "ci_authoritative": True}:
    raise SystemExit("manifest is not runner-authoritative")
PY
}

validation_result_verdict_code() {
    case "$1" in
        PASS) printf '0\n' ;;
        WARN) printf '1\n' ;;
        FAIL) printf '2\n' ;;
        SKIP) printf '3\n' ;;
        *) printf '2\n' ;;
    esac
}

validation_result_finalize() {
    local command_status="$1"
    local verdict="${VALIDATION_VERDICT:-PASS}"
    local reason="${VALIDATION_VERDICT_REASON:-}"
    local generated_at summary manifest prom verdict_code

    trap - EXIT
    # The command's exit status outranks an optimistic recorded verdict: a suite
    # that died before recording anything must not report PASS.
    if [ "${command_status}" -eq 77 ] && [ "${verdict}" = PASS ]; then
        verdict=SKIP
        reason="suite exited 77"
    elif [ "${command_status}" -ne 0 ] && [ "${verdict}" != FAIL ] && [ "${verdict}" != SKIP ]; then
        verdict=FAIL
        reason="suite command exited ${command_status}"
    fi
    generated_at="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
PY
)"
    summary="${VALIDATION_RUN_DIR}/summary.json"
    prom="${VALIDATION_RUN_DIR}/suite.prom"
    manifest="${VALIDATION_RUN_DIR}/suite-manifest.json"
    verdict_code="$(validation_result_verdict_code "${verdict}")"

    validation_result_write_atomic_json "${summary}" "$(python3 - "${VALIDATION_SUITE}" "${VALIDATION_RUN_ID}" "${VALIDATION_RESULT_MODE}" "${VALIDATION_CI_AUTHORITATIVE}" "${verdict}" "${reason}" "${VALIDATION_UNAVAILABLE_POLICY}" "${VALIDATION_THRESHOLD_POLICY}" "${command_status}" "${VALIDATION_RELEASE_JSON:-}" <<'PY'
import json
import sys
payload = {
    "suite": sys.argv[1], "run_id": sys.argv[2],
    "provenance": {"mode": sys.argv[3], "ci_authoritative": sys.argv[4] == "true"},
    "verdict": sys.argv[5], "reason": sys.argv[6],
    "policies": {"unavailable": sys.argv[7], "threshold": sys.argv[8]},
    "command_exit_code": int(sys.argv[9]),
}
if sys.argv[10]:
    payload["release"] = json.loads(sys.argv[10])
print(json.dumps(payload))
PY
)"
    validation_result_write_atomic_text "${prom}" "# HELP chapar_validation_suite_verdict Suite verdict (PASS=0 WARN=1 FAIL=2 SKIP=3)\n# TYPE chapar_validation_suite_verdict gauge\nchapar_validation_suite_verdict{suite=\"${VALIDATION_SUITE}\",run_id=\"${VALIDATION_RUN_ID}\",verdict=\"${verdict}\"} ${verdict_code}\n"
    validation_result_write_atomic_json "${manifest}" "$(python3 - "${VALIDATION_SUITE}" "${VALIDATION_RUN_ID}" "${VALIDATION_RUN_ISSUED_AT}" "${generated_at}" "${VALIDATION_RESULT_MODE}" "${VALIDATION_CI_AUTHORITATIVE}" "${verdict}" "${reason}" "${VALIDATION_UNAVAILABLE_POLICY}" "${VALIDATION_THRESHOLD_POLICY}" "${VALIDATION_RELEASE_JSON:-}" <<'PY'
import json
import sys
payload = {
    "schema_version": "1.0", "kind": "suite", "suite": sys.argv[1],
    "run_id": sys.argv[2], "run_issued_at": sys.argv[3], "generated_at": sys.argv[4],
    "provenance": {"mode": sys.argv[5], "ci_authoritative": sys.argv[6] == "true"},
    "verdict": sys.argv[7], "policies": {"unavailable": sys.argv[9], "threshold": sys.argv[10]},
    "artifacts": {"summary": "summary.json", "prometheus": "suite.prom"},
}
if sys.argv[8]:
    payload["reason"] = sys.argv[8]
if sys.argv[11]:
    payload["release"] = json.loads(sys.argv[11])
print(json.dumps(payload))
PY
)"
    validation_result_validate_manifest "${manifest}" || exit 2
    case "${verdict}" in
        PASS|WARN) exit 0 ;;
        SKIP) exit 77 ;;
        FAIL) exit 1 ;;
    esac
}
