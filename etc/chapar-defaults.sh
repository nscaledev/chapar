#!/usr/bin/env bash
# Chapar site-settings resolution. Source this file; do not execute it.
#
# Shared by etc/init.sh (interactive shells), etc/profile.d/zz-chapar.sh
# (login shells), and envs/software/release.sh (builds) so every consumer
# derives identical paths from the same site settings.
#
# Resolution order:
#   1. Variables already exported by the caller win — every default below and
#      in the site file uses `: "${VAR:=...}"`.
#   2. The per-machine site file, ${CHAPAR_SITE_CONFIG} or
#      ${CHAPAR_ROOT}/etc/chapar-site.env, supplies site values.
#   3. Built-in defaults produce a private per-user layout under
#      ${HOME}/.spack/chapar.
# After CHAPAR_SOFTWARE_SET and CHAPAR_TARGET are final, a site-declared
# chapar_site_target_policy() is invoked for per-tuple delivery and Slurm
# placement, then policy gaps are defaulted and everything is validated and
# exported. Spack leaves an undefined $VAR literal in scope YAML, so every
# variable etc/user interpolates must be exported here unconditionally.
#
# On failure the sourcing shell gets a non-zero return, never an exit: this
# file is sourced by interactive shells.

_chapar_defaults_fail() {
    echo "ERROR: chapar site settings: $*" >&2
    return 1
}

# True when the two canonical paths are equal or one contains the other.
chapar_path_relation() {
    [ "$1" = "$2" ] && return 0
    { [ "$1" = / ] || [ "$2" = / ]; } && return 0
    case "$1" in "$2"/*) return 0 ;; esac
    case "$2" in "$1"/*) return 0 ;; esac
    return 1
}

# Prints the canonical form of an absolute path; fails on relative paths and
# `..` traversal. Purely lexical: no filesystem access, no symlink resolution.
chapar_canonical_path() {
    local input="$1" output="" part parts
    case "${input}" in /*) ;; *) return 1 ;; esac
    IFS='/' read -r -a parts <<< "${input}"
    for part in "${parts[@]}"; do
        case "${part}" in
            ""|.) continue ;;
            ..) return 1 ;;
            *) output="${output}/${part}" ;;
        esac
    done
    [ -n "${output}" ] || output="/"
    printf '%s\n' "${output}"
}

# Canonicalizes ${!1} in place; rejects overlap with the immutable legacy
# roots under /resources/chapar, which no new state may touch or extend.
_chapar_defaults_check_path() {
    local name="$1" value canonical
    value="${!name}"
    canonical="$(chapar_canonical_path "${value}")" ||
        { _chapar_defaults_fail "${name} must be an absolute path without traversal: ${value}"; return 1; }
    if chapar_path_relation "${canonical}" /resources/chapar; then
        _chapar_defaults_fail "${name} overlaps the immutable legacy roots: ${canonical}"
        return 1
    fi
    printf -v "${name}" '%s' "${canonical}"
}

chapar_apply_defaults() {
    local _site_file _var _word

    if [ -z "${CHAPAR_ROOT:-}" ]; then
        CHAPAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi

    # --- site file ---------------------------------------------------------
    _site_file="${CHAPAR_SITE_CONFIG:-${CHAPAR_ROOT}/etc/chapar-site.env}"
    if [ -r "${_site_file}" ]; then
        # shellcheck disable=SC1090
        . "${_site_file}" || return 1
    elif [ -n "${CHAPAR_SITE_CONFIG:-}" ]; then
        _chapar_defaults_fail "CHAPAR_SITE_CONFIG is set but unreadable: ${CHAPAR_SITE_CONFIG}"
        return 1
    fi

    # --- identity ----------------------------------------------------------
    : "${CHAPAR_SOFTWARE_SET:=all}"
    : "${CHAPAR_TARGET:=}"
    case "${CHAPAR_SOFTWARE_SET}" in
        vlad|hpcsim|all) ;;
        *) _chapar_defaults_fail "CHAPAR_SOFTWARE_SET must be vlad, hpcsim, or all: ${CHAPAR_SOFTWARE_SET}"
           return 1 ;;
    esac

    # --- roots --------------------------------------------------------------
    : "${CHAPAR_INSTALL_MODE:=home}"
    : "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
    : "${CHAPAR_PUBLIC_ROOT:=}"
    case "${CHAPAR_INSTALL_MODE}" in
        home) CHAPAR_ENV_ROOT="${CHAPAR_HOME_ROOT}" ;;
        public)
            [ -n "${CHAPAR_PUBLIC_ROOT}" ] ||
                { _chapar_defaults_fail "CHAPAR_INSTALL_MODE=public requires CHAPAR_PUBLIC_ROOT"; return 1; }
            CHAPAR_ENV_ROOT="${CHAPAR_PUBLIC_ROOT}" ;;
        *) _chapar_defaults_fail "CHAPAR_INSTALL_MODE must be home or public: ${CHAPAR_INSTALL_MODE}"
           return 1 ;;
    esac

    : "${CHAPAR_INSTALL_TREE_ROOT:=${CHAPAR_ENV_ROOT}/store}"
    : "${CHAPAR_RELEASE_ROOT:=${CHAPAR_ENV_ROOT}/releases}"
    : "${CHAPAR_MODULE_ROOT:=${CHAPAR_ENV_ROOT}/modulefiles}"
    : "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_ENV_ROOT}/cache/buildcache}"
    : "${CHAPAR_CCACHE_ROOT:=${CHAPAR_ENV_ROOT}/cache/ccache}"
    : "${CHAPAR_BUILD_STAGE_ROOT:=${TMPDIR:-/tmp}/${USER}/chapar-stage}"
    : "${CHAPAR_CONTAINER_OUTPUT_ROOT:=${CHAPAR_ENV_ROOT}/images}"
    : "${CHAPAR_VALIDATION_ROOT:=${CHAPAR_ENV_ROOT}/validation}"
    : "${CHAPAR_SEED_MIRRORS:=}"
    : "${CHAPAR_SHARED_GROUP:=}"
    : "${CHAPAR_SHARED_DIR_MODE:=2775}"

    for _var in CHAPAR_ENV_ROOT CHAPAR_INSTALL_TREE_ROOT CHAPAR_RELEASE_ROOT \
        CHAPAR_MODULE_ROOT CHAPAR_BUILDCACHE_ROOT CHAPAR_CCACHE_ROOT \
        CHAPAR_BUILD_STAGE_ROOT CHAPAR_CONTAINER_OUTPUT_ROOT CHAPAR_VALIDATION_ROOT; do
        _chapar_defaults_check_path "${_var}" || return 1
    done
    for _word in ${CHAPAR_SEED_MIRRORS}; do
        chapar_canonical_path "${_word}" >/dev/null ||
            { _chapar_defaults_fail "CHAPAR_SEED_MIRRORS entries must be absolute paths: ${_word}"; return 1; }
        if chapar_path_relation "$(chapar_canonical_path "${_word}")" /resources/chapar; then
            _chapar_defaults_fail "seed mirror derives state from the legacy roots: ${_word}"
            return 1
        fi
    done

    # --- policy -------------------------------------------------------------
    : "${CHAPAR_MODULE_SYSTEMS:=tcl}"
    for _word in ${CHAPAR_MODULE_SYSTEMS}; do
        case "${_word}" in
            tcl|lmod) ;;
            *) _chapar_defaults_fail "CHAPAR_MODULE_SYSTEMS entries must be tcl or lmod: ${_word}"
               return 1 ;;
        esac
    done
    case " ${CHAPAR_MODULE_SYSTEMS} " in
        *" tcl "*) ;;
        *) _chapar_defaults_fail "CHAPAR_MODULE_SYSTEMS must include tcl"; return 1 ;;
    esac
    : "${CHAPAR_CCACHE_COMPILERCHECK:=content}"
    : "${CHAPAR_CCACHE_MAXSIZE:=}"
    : "${PUBLISH_BUILDCACHE:=false}"
    : "${PUBLISH_CURRENT:=false}"
    : "${PUBLISH_MODULES:=false}"

    # --- per-target policy ---------------------------------------------------
    if declare -F chapar_site_target_policy >/dev/null; then
        chapar_site_target_policy || return 1
    fi
    : "${CHAPAR_DELIVER:=modules}"
    : "${CHAPAR_CONTAINER_BASE:=}"
    : "${CHAPAR_SLURM_PARTITION:=}"
    : "${CHAPAR_SLURM_CONSTRAINT:=}"
    : "${CHAPAR_SLURM_ACCOUNT:=}"
    : "${CHAPAR_SLURM_QOS:=}"
    for _word in ${CHAPAR_DELIVER}; do
        case "${_word}" in
            modules|container) ;;
            *) _chapar_defaults_fail "CHAPAR_DELIVER entries must be modules or container: ${_word}"
               return 1 ;;
        esac
    done
    case " ${CHAPAR_DELIVER} " in
        *" container "*)
            [ -n "${CHAPAR_CONTAINER_BASE}" ] ||
                { _chapar_defaults_fail "CHAPAR_DELIVER contains container but CHAPAR_CONTAINER_BASE is empty"; return 1; }
            ;;
    esac

    export CHAPAR_ROOT CHAPAR_SOFTWARE_SET CHAPAR_TARGET \
        CHAPAR_INSTALL_MODE CHAPAR_HOME_ROOT CHAPAR_PUBLIC_ROOT CHAPAR_ENV_ROOT \
        CHAPAR_INSTALL_TREE_ROOT CHAPAR_RELEASE_ROOT CHAPAR_MODULE_ROOT \
        CHAPAR_BUILDCACHE_ROOT CHAPAR_CCACHE_ROOT CHAPAR_BUILD_STAGE_ROOT \
        CHAPAR_CONTAINER_OUTPUT_ROOT CHAPAR_VALIDATION_ROOT CHAPAR_SEED_MIRRORS \
        CHAPAR_SHARED_GROUP CHAPAR_SHARED_DIR_MODE \
        CHAPAR_MODULE_SYSTEMS CHAPAR_CCACHE_COMPILERCHECK CHAPAR_CCACHE_MAXSIZE \
        PUBLISH_BUILDCACHE PUBLISH_CURRENT PUBLISH_MODULES \
        CHAPAR_DELIVER CHAPAR_CONTAINER_BASE \
        CHAPAR_SLURM_PARTITION CHAPAR_SLURM_CONSTRAINT \
        CHAPAR_SLURM_ACCOUNT CHAPAR_SLURM_QOS
}

# Prints the module tree consumers should `module use` for the current
# identity: the promoted `current` pointer for <set>/<target>. Empty when
# CHAPAR_TARGET is unset.
chapar_module_path() {
    [ -n "${CHAPAR_TARGET}" ] || return 0
    printf '%s\n' "${CHAPAR_MODULE_ROOT}/${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}/current"
}

chapar_apply_defaults
