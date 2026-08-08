#!/usr/bin/env bash

# Shared policy helpers for validation suites.  A suite records its outcome here;
# result-manifest.sh is responsible for persisting it at process exit.
#
# The vocabulary is fixed at PASS | WARN | FAIL | SKIP, which validation/
# ARCHITECTURE.md and .agents/skills/chapar-validation/SKILL.md both require, and
# escalation is monotone: a suite can only ever make its verdict worse, so no
# later check can quietly clear an earlier failure.

VALIDATION_VERDICT=""
VALIDATION_VERDICT_REASON=""
VALIDATION_UNAVAILABLE_POLICY="${VALIDATION_UNAVAILABLE_POLICY:-skip}"
VALIDATION_THRESHOLD_POLICY="${VALIDATION_THRESHOLD_POLICY:-fail}"

validation_verdict_init() {
    case "${VALIDATION_UNAVAILABLE_POLICY}" in
        fail|skip) ;;
        *) printf 'invalid VALIDATION_UNAVAILABLE_POLICY: %s\n' "${VALIDATION_UNAVAILABLE_POLICY}" >&2; return 2 ;;
    esac
    case "${VALIDATION_THRESHOLD_POLICY}" in
        fail|warn) ;;
        *) printf 'invalid VALIDATION_THRESHOLD_POLICY: %s\n' "${VALIDATION_THRESHOLD_POLICY}" >&2; return 2 ;;
    esac
    VALIDATION_VERDICT="PASS"
    VALIDATION_VERDICT_REASON=""
}

validation_set_verdict() {
    local verdict="$1"
    local reason="${2:-}"
    local current_rank next_rank
    case "${verdict}" in
        PASS) next_rank=0 ;;
        SKIP) next_rank=1 ;;
        WARN) next_rank=2 ;;
        FAIL) next_rank=3 ;;
        *) printf 'invalid validation verdict: %s\n' "${verdict}" >&2; return 2 ;;
    esac
    # The default arm matters: without it an unexpected VALIDATION_VERDICT leaves
    # current_rank unset and the comparison below is a syntax error rather than a
    # verdict, which would lose the outcome it was called to record.
    case "${VALIDATION_VERDICT:-PASS}" in
        PASS) current_rank=0 ;;
        SKIP) current_rank=1 ;;
        WARN) current_rank=2 ;;
        FAIL) current_rank=3 ;;
        *) current_rank=0 ;;
    esac
    if (( next_rank >= current_rank )); then
        VALIDATION_VERDICT="${verdict}"
        VALIDATION_VERDICT_REASON="${reason}"
    fi
}

validation_threshold_violation() {
    local reason="$1"
    if [ "${VALIDATION_THRESHOLD_POLICY}" = "warn" ]; then
        validation_set_verdict WARN "${reason}"
    else
        validation_set_verdict FAIL "${reason}"
    fi
}

# Returns the exit code the caller should die with, so a suite reads:
#   command -v ibstat >/dev/null || validation_resource_unavailable 'ibstat' mandatory
# and `set -e` turns 1 into FAIL and 77 into the SKIP that validation/run reports
# without failing the whole run.
validation_resource_unavailable() {
    local reason="$1"
    local requirement="$2"
    case "${requirement}" in
        mandatory)
            validation_set_verdict FAIL "required resource unavailable: ${reason}"
            return 1
            ;;
        optional)
            if [ "${VALIDATION_UNAVAILABLE_POLICY}" = "skip" ]; then
                validation_set_verdict SKIP "optional resource unavailable: ${reason}"
                return 77
            fi
            validation_set_verdict FAIL "optional resource unavailable under fail policy: ${reason}"
            return 1
            ;;
        *)
            printf 'invalid resource requirement: %s\n' "${requirement}" >&2
            return 2
            ;;
    esac
}
