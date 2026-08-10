#!/usr/bin/env bash
# Shared install-tree padding helpers.
#
# Sourced by envs/software/release.sh, the only scope renderer left. Any future
# renderer must reuse these helpers: when two renderers diverged historically, a
# scope rendered by one tool installed to unpadded prefixes inside a padded
# store built by the other, silently defeating buildcache reuse and prefix
# relocation.

# Fallback used only for a store that has no placeholder chain yet.
CHAPAR_INSTALL_TREE_PADDED_LENGTH=256

# Count the __spack_path_placeholder__ components already present in a store.
detect_padded_length() {
    local store_root="$1"
    local prefix_dir count
    prefix_dir="${store_root}"
    count=0
    while [ -d "${prefix_dir}/__spack_path_placeholder__" ]; do
        prefix_dir="${prefix_dir}/__spack_path_placeholder__"
        count=$((count + 1))
    done
    printf '%s\n' "${count}"
}

# Resolve the padded_length an existing store already commits to, so a later
# build reproduces the same prefix length instead of re-padding to a new one.
install_tree_padded_length() {
    local root="$1" count
    count="$(detect_padded_length "${root}")"
    if [ "${count}" -gt 0 ]; then
        printf '%s\n' "$(( ${#root} + 1 + count * 27 + 3 ))"
    else
        printf '%s\n' "${CHAPAR_INSTALL_TREE_PADDED_LENGTH}"
    fi
}
