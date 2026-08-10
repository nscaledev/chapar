#!/usr/bin/env bash
# Chapar site-bound module path.
#
# This runs for every login shell on the host, so it must never abort or spam
# the caller: with no site settings and no promoted release there is simply
# nothing to activate. Site settings resolve through etc/chapar-defaults.sh —
# the same file interactive shells and builds use — and `module use` runs here,
# in the caller's shell, because a helper subshell would discard the MODULEPATH
# change.

if [ -z "${CHAPAR_PROFILE_DISABLE:-}" ]; then
    _chapar_profile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _chapar_defaults="${_chapar_profile_dir}/../chapar-defaults.sh"
    if [ -r "${_chapar_defaults}" ]; then
        # shellcheck disable=SC1090
        if . "${_chapar_defaults}" 2>/dev/null; then
            _chapar_module_path="$(chapar_module_path)"
            if [ -n "${_chapar_module_path}" ] && [ -d "${_chapar_module_path}" ] \
                && command -v module >/dev/null 2>&1; then
                module use "${_chapar_module_path}"
            fi
        else
            echo "WARNING: Chapar site settings did not validate; modules were not added" >&2
        fi
    fi
    unset _chapar_profile_dir _chapar_defaults _chapar_module_path
fi
