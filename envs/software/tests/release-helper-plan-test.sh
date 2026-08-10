#!/usr/bin/env bash
# Offline checks for the site-settings-bound release helper: plan derivation
# for every tuple, delivery/publication gating, and argument refusals.
# Nothing here builds, submits, or mutates state outside a temp HOME.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${REPO_ROOT}/envs/software/release.sh"
SUBMIT="${REPO_ROOT}/ci/submit-env-build.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chapar-release-plan-test.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
mkdir -p "${WORK}/home"

failures=0

ok() { echo "ok: $*"; }
flunk() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# run_helper <expected-exit> <output-var> [ENV=VALUE...] -- args...
run_helper() {
    local expected="$1" __outvar="$2"; shift 2
    local env_pairs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        env_pairs+=("$1"); shift
    done
    shift
    local output status=0
    output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
        CHAPAR_RUN_ID=testrun.1 "${env_pairs[@]}" bash "${HELPER}" "$@" 2>&1)" || status=$?
    printf -v "${__outvar}" '%s' "${output}"
    if [ "${status}" -ne "${expected}" ]; then
        flunk "expected exit ${expected}, got ${status}: ${output}"
        return 1
    fi
    return 0
}

expect_line() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s\n' "${haystack}" | grep -qF -- "${needle}"; then
        ok "${label}"
    else
        flunk "${label}"
        printf '%s\n' "  wanted: ${needle}" "  in output:" >&2
        printf '%s\n' "${haystack}" | sed 's/^/    /' >&2
    fi
}

# expect_refusal <label> <expected-message> [ENV=VALUE...] -- args...
expect_refusal() {
    local label="$1" message="$2"; shift 2
    local env_pairs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        env_pairs+=("$1"); shift
    done
    shift
    local output status=0
    output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
        CHAPAR_RUN_ID=testrun.1 "${env_pairs[@]}" bash "${HELPER}" "$@" 2>&1)" || status=$?
    if [ "${status}" -eq 0 ]; then
        flunk "${label}: unexpectedly succeeded"
        return
    fi
    expect_line "${label}" "${output}" "${message}"
}

# --- plan derivation for every set x target -----------------------------------
for set_name in vlad hpcsim all; do
    for target in linux-x86_64-generic linux-x86_64-v4 linux-aarch64-generic linux-aarch64-gb300; do
        if run_helper 0 plan_output \
            CHAPAR_SOFTWARE_SET="${set_name}" CHAPAR_TARGET="${target}" \
            -- plan rel-1; then
            expect_line "plan ${set_name}/${target} identity" "${plan_output}" \
                "identity: ${set_name}/${target}/rel-1/testrun.1"
            expect_line "plan ${set_name}/${target} release final" "${plan_output}" \
                "release_final: ${WORK}/home/.spack/chapar/releases/${set_name}/${target}/rel-1"
            expect_line "plan ${set_name}/${target} buildcache namespaced by target" "${plan_output}" \
                "writable_buildcache: ${WORK}/home/.spack/chapar/cache/buildcache/${target}"
        fi
    done
done

# The default run ID (no CHAPAR_RUN_ID) must satisfy the identifier rule.
default_run_output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 \
    bash "${HELPER}" plan rel-default 2>&1)" || {
    flunk "plan with default run ID failed: ${default_run_output}"
}
expect_line "default run ID is a valid identifier" "${default_run_output}" "identity: vlad/linux-x86_64-v4/rel-default/"

# Module-only delivery is the default for every tuple: no container required.
if run_helper 0 plan_output CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 -- plan rel-1; then
    expect_line "module-only vlad is representable" "${plan_output}" "deliver: modules"
fi

# Per-target site policy flows into the plan.
cat > "${WORK}/site.env" <<'EOF'
chapar_site_target_policy() {
    case "${CHAPAR_SOFTWARE_SET}:${CHAPAR_TARGET}" in
        vlad:linux-aarch64-gb300)
            CHAPAR_DELIVER="modules container"
            CHAPAR_CONTAINER_BASE=nvidia-vlad
            ;;
    esac
}
EOF
if run_helper 0 plan_output CHAPAR_SITE_CONFIG="${WORK}/site.env" \
    -- plan rel-1 --set vlad --target linux-aarch64-gb300; then
    expect_line "site policy selects dual delivery" "${plan_output}" "deliver: modules container"
fi
if run_helper 0 plan_output CHAPAR_SITE_CONFIG="${WORK}/site.env" \
    -- plan rel-1 --set hpcsim --target linux-aarch64-gb300; then
    expect_line "other tuples stay module-only" "${plan_output}" "deliver: modules"
fi

# --- refusals ------------------------------------------------------------------
expect_refusal "missing target refused" "CHAPAR_TARGET is required" \
    -- plan rel-1
expect_refusal "unregistered target refused" "unknown target" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-riscv64 -- plan rel-1
expect_refusal "retired selection flag refused" "selections were retired" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 -- plan rel-1 --selection /tmp/selection.json
expect_refusal "invalid release id refused" "invalid release ID" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 -- plan 'Rel 1!'
expect_refusal "promotion gated on PUBLISH_CURRENT" "site settings forbid promotion" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 -- promote rel-1
expect_refusal "publish-modules gated on delivery policy" "does not include modules" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 \
    CHAPAR_DELIVER=container CHAPAR_CONTAINER_BASE=nvidia-vlad -- publish-modules rel-1
# promote with PUBLISH_CURRENT=true still demands an existing release.
expect_refusal "promotion requires an existing release" "release does not exist" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 PUBLISH_CURRENT=true -- promote rel-1
# build refuses a duplicate release ID before touching anything.
mkdir -p "${WORK}/home/.spack/chapar/releases/vlad/linux-x86_64-v4/rel-dup"
expect_refusal "duplicate release id refused" "duplicate release ID" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 -- build rel-dup
# Site settings that fail validation abort before any derivation.
expect_refusal "invalid software set refused" "CHAPAR_SOFTWARE_SET must be" \
    CHAPAR_SOFTWARE_SET=weird CHAPAR_TARGET=linux-x86_64-v4 -- plan rel-1
expect_refusal "legacy root overlap refused" "immutable legacy roots" \
    CHAPAR_SOFTWARE_SET=vlad CHAPAR_TARGET=linux-x86_64-v4 \
    CHAPAR_INSTALL_TREE_ROOT=/resources/chapar/vlad/store -- plan rel-1

# --- submit dry run ------------------------------------------------------------
cat > "${WORK}/submit-site.env" <<'EOF'
chapar_site_target_policy() {
    CHAPAR_SLURM_PARTITION=cpu
    CHAPAR_SLURM_ACCOUNT=hpc
}
EOF
submit_output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
    CHAPAR_RUN_ID=testrun.1 CHAPAR_SITE_CONFIG="${WORK}/submit-site.env" \
    bash "${SUBMIT}" --set hpcsim --target linux-x86_64-generic --release-id rel-2 --dry-run 2>&1)" || {
    flunk "submit dry-run failed: ${submit_output}"
}
expect_line "submit dry-run prints tuple" "${submit_output}" "tuple: hpcsim/linux-x86_64-generic"
expect_line "submit dry-run prints partition" "${submit_output}" "partition: cpu"
expect_line "submit dry-run stops before sbatch" "${submit_output}" "dry-run: verified plan only"

# Submit without a partition must refuse before sbatch.
submit_status=0
submit_output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
    bash "${SUBMIT}" --set hpcsim --target linux-x86_64-generic --release-id rel-3 --dry-run 2>&1)" || submit_status=$?
if [ "${submit_status}" -ne 0 ]; then
    expect_line "submit refuses without slurm placement" "${submit_output}" "no Slurm partition"
else
    flunk "submit accepted a tuple with no Slurm placement"
fi

if [ "${failures}" -ne 0 ]; then
    echo "release-helper-plan-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "release-helper-plan-test: all checks passed"
