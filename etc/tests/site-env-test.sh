#!/usr/bin/env bash
# Offline checks for etc/chapar-defaults.sh: defaulting, site-file layering,
# per-target policy, and the path guards. Runs everything in subshells against
# a disposable HOME so no real site file or environment leaks in.
set -euo pipefail

ETC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS="${ETC_DIR}/chapar-defaults.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chapar-site-env-test.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT

failures=0

# Sources chapar-defaults.sh in a clean bash with only the given VAR=VALUE
# pairs, then runs the given snippet. A leading '!' expects failure.
run_defaults() {
    local expect_failure=0
    if [ "$1" = "!" ]; then expect_failure=1; shift; fi
    local snippet="$1"; shift
    local status=0 output
    output="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" "$@" \
        bash -c ". '${DEFAULTS}' && ${snippet}" 2>&1)" || status=$?
    if [ "${expect_failure}" -eq 1 ]; then
        [ "${status}" -ne 0 ] && return 0
        echo "FAIL: expected failure, got: ${output}" >&2
        return 1
    fi
    [ "${status}" -eq 0 ] || { echo "FAIL: ${output}" >&2; return 1; }
    printf '%s\n' "${output}"
}

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        echo "ok: ${label}"
    else
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
        failures=$((failures + 1))
    fi
}

check_fails() {
    local label="$1"; shift
    if run_defaults "!" true "$@" >/dev/null; then
        echo "ok: ${label}"
    else
        failures=$((failures + 1))
    fi
}

mkdir -p "${WORK}/home"

# --- bare defaults: private per-user layout, module-only delivery -----------
check "default env root" "${WORK}/home/.spack/chapar" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_ENV_ROOT}"')"
check "default install tree" "${WORK}/home/.spack/chapar/store" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_INSTALL_TREE_ROOT}"')"
check "default software set" "all" "$(run_defaults 'printf "%s\n" "${CHAPAR_SOFTWARE_SET}"')"
check "default delivery" "modules" "$(run_defaults 'printf "%s\n" "${CHAPAR_DELIVER}"')"
check "default module systems" "tcl" "$(run_defaults 'printf "%s\n" "${CHAPAR_MODULE_SYSTEMS}"')"
check "no target, no module path" "" "$(run_defaults 'chapar_module_path')"

# --- site file layering ------------------------------------------------------
cat > "${WORK}/site.env" <<'EOF'
: "${CHAPAR_INSTALL_MODE:=public}"
: "${CHAPAR_PUBLIC_ROOT:=/shared/chapar}"
: "${CHAPAR_SOFTWARE_SET:=vlad}"
: "${CHAPAR_TARGET:=linux-x86_64-v4}"

chapar_site_target_policy() {
    case "${CHAPAR_SOFTWARE_SET}:${CHAPAR_TARGET}" in
        vlad:linux-x86_64-v4)
            CHAPAR_DELIVER="modules container"
            CHAPAR_CONTAINER_BASE=nvidia-vlad
            CHAPAR_SLURM_PARTITION=gpu
            ;;
        *)
            CHAPAR_DELIVER="modules"
            ;;
    esac
}
EOF

check "site file public env root" "/shared/chapar" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_ENV_ROOT}"' CHAPAR_SITE_CONFIG="${WORK}/site.env")"
check "site file identity" "vlad" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_SOFTWARE_SET}"' CHAPAR_SITE_CONFIG="${WORK}/site.env")"
check "per-target delivery" "modules container" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_DELIVER}"' CHAPAR_SITE_CONFIG="${WORK}/site.env")"
check "per-target container base" "nvidia-vlad" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_CONTAINER_BASE}"' CHAPAR_SITE_CONFIG="${WORK}/site.env")"
check "per-target slurm partition" "gpu" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_SLURM_PARTITION}"' CHAPAR_SITE_CONFIG="${WORK}/site.env")"
check "module path from identity" "/shared/chapar/modulefiles/vlad/linux-x86_64-v4/current" \
    "$(run_defaults 'chapar_module_path' CHAPAR_SITE_CONFIG="${WORK}/site.env")"

# Exported environment beats the site file, and policy follows the final tuple.
check "env identity beats site file" "hpcsim" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_SOFTWARE_SET}"' \
        CHAPAR_SITE_CONFIG="${WORK}/site.env" CHAPAR_SOFTWARE_SET=hpcsim)"
check "policy follows final identity" "modules" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_DELIVER}"' \
        CHAPAR_SITE_CONFIG="${WORK}/site.env" CHAPAR_SOFTWARE_SET=hpcsim)"
check "env root override" "/nfs/override" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_MODULE_ROOT}"' \
        CHAPAR_SITE_CONFIG="${WORK}/site.env" CHAPAR_MODULE_ROOT=/nfs/override)"

# --- refusals ----------------------------------------------------------------
check_fails "unknown software set" CHAPAR_SOFTWARE_SET=weird
check_fails "unknown install mode" CHAPAR_INSTALL_MODE=cluster
check_fails "public mode without public root" CHAPAR_INSTALL_MODE=public
check_fails "relative path" CHAPAR_MODULE_ROOT=relative/path
check_fails "path traversal" CHAPAR_MODULE_ROOT=/nfs/../etc
check_fails "legacy root overlap" CHAPAR_INSTALL_TREE_ROOT=/resources/chapar/vlad/store
check_fails "legacy root ancestor" CHAPAR_INSTALL_TREE_ROOT=/resources
check_fails "seed mirror in legacy roots" CHAPAR_SEED_MIRRORS=/resources/chapar/vlad/buildcache
check_fails "unknown module system" CHAPAR_MODULE_SYSTEMS="tcl modules4"
check_fails "lmod without tcl" CHAPAR_MODULE_SYSTEMS=lmod
check_fails "unknown delivery word" CHAPAR_DELIVER=images
check_fails "unreadable explicit site config" CHAPAR_SITE_CONFIG="${WORK}/missing.env"

# Container delivery demands a container base.
cat > "${WORK}/container-no-base.env" <<'EOF'
CHAPAR_DELIVER="modules container"
EOF
check_fails "container delivery without base" \
    CHAPAR_SITE_CONFIG="${WORK}/container-no-base.env"

# --- sourcing must return, never exit the caller's shell ---------------------
after="$(env -i HOME="${WORK}/home" USER=tester PATH="${PATH}" \
    CHAPAR_SOFTWARE_SET=weird \
    bash -c ". '${DEFAULTS}' ; status=\$? ; echo after:\${status}" 2>/dev/null)"
check "failure returns without killing the shell" "after:1" "${after}"

# Canonicalization result is exported, not just validated.
check "path canonicalized" "/nfs/x" \
    "$(run_defaults 'printf "%s\n" "${CHAPAR_MODULE_ROOT}"' CHAPAR_MODULE_ROOT=//nfs//x/)"

if [ "${failures}" -ne 0 ]; then
    echo "site-env-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "site-env-test: all checks passed"
