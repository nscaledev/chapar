#!/usr/bin/env bash

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "ERROR: source this file, do not execute it: source /path/to/chapar/etc/init.sh" >&2
    exit 1
fi

_chapar_etc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Site settings: sources etc/chapar-site.env (or CHAPAR_SITE_CONFIG), defaults
# and validates every CHAPAR_* variable, and exports them for the etc/user
# scope interpolations.
# shellcheck source=chapar-defaults.sh
. "${_chapar_etc_dir}/chapar-defaults.sh" || return 1

_chapar_spack_root="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
_chapar_spack_setup="${_chapar_spack_root}/share/spack/setup-env.sh"
if [ ! -r "${_chapar_spack_setup}" ]; then
    echo "ERROR: could not find Spack at ${_chapar_spack_root}" >&2
    echo "Install it with: bash ${CHAPAR_ROOT}/etc/install-spack.sh" >&2
    return 1
fi

export SPACK_ROOT="${_chapar_spack_root}"
. "${_chapar_spack_setup}"
export SPACK_USER_CONFIG_PATH="${CHAPAR_ROOT}/etc/user"
export SPACK_SYSTEM_CONFIG_PATH="${CHAPAR_ROOT}/etc/system"
: "${SPACK_USER_CACHE_PATH:=${TMPDIR:-/tmp}/${USER}/spack-cache}"
export SPACK_USER_CACHE_PATH
export PIP_CONFIG_FILE=/dev/null

# ccache is namespaced per target so x86_64 and aarch64 builders sharing a
# cache root never mix object caches. With no target selected yet, leave
# CCACHE_DIR alone.
if [ -n "${CHAPAR_TARGET}" ]; then
    export CCACHE_DIR="${CHAPAR_CCACHE_ROOT}/${CHAPAR_TARGET}"
fi
: "${CCACHE_TEMPDIR:=${TMPDIR:-/tmp}/${USER}/chapar-ccache-tmp/${CHAPAR_TARGET:-none}}"
: "${CCACHE_UMASK:=002}"
: "${CCACHE_COMPILERCHECK:=${CHAPAR_CCACHE_COMPILERCHECK}}"
export CCACHE_TEMPDIR CCACHE_UMASK CCACHE_COMPILERCHECK

# `module use` must run in the caller's shell -- a helper subshell would verify
# and then discard the MODULEPATH change. The promoted pointer only exists once
# a release was published for this <set>/<target>, so stay quiet otherwise.
_chapar_module_path="$(chapar_module_path)"
if type module >/dev/null 2>&1 && [ -n "${_chapar_module_path}" ]; then
    if [ -d "${_chapar_module_path}" ]; then
        module use "${_chapar_module_path}"
    else
        echo "WARNING: no promoted modules for ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}: ${_chapar_module_path}" >&2
    fi
fi

unset _chapar_etc_dir _chapar_spack_root _chapar_spack_setup _chapar_module_path
