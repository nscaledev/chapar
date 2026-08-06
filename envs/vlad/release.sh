#!/usr/bin/env bash
set -euo pipefail

# vlad release driver.
#
# This script is intentionally more than a thin `spack install` wrapper. A
# shared vlad deployment has a few invariants that are easy to violate when
# debugging CI failures or doing emergency cache repairs:
#
# - The Spack install tree is shared, but module trees are release-local until
#   promotion. A new build may add packages to the shared store, but it must not
#   rewrite the module tree used by running jobs.
# - A release is assembled in `<os>/.<id>.staging.<pid>` and moved into
#   `<os>/<arch>/releases/<id>` only after installation, module generation, and
#   manifest writing succeed. The architecture directory comes from the
#   generated release content. Promotion is a separate atomic symlink swap of
#   `<os>/<arch>/current` plus a stable `<os>/<arch>/modulefiles` symlink; when
#   configured, it also atomically updates shared module-root symlinks.
# - Release builds use a temporary command-line Spack scope. That scope points at
#   the shared install tree, release module root, and per-OS binary buildcache
#   without changing repository, system, or user Spack config.
# - Linux buildcaches must match the current padded install-tree layout. Older
#   unpadded cache entries can fail relocation with `CannotGrowString`, so this
#   script quarantines unmarked destination payloads and only migrates legacy
#   caches after an explicit operator action.
# - vlad modules are user-facing and hashless (`{name}/{version}`). The script
#   refreshes modules only for explicit environment roots and fails if two roots
#   would collide on the same visible module name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHAPAR_SITE_CONFIG_LOADED="false"
ENV_PATH="${ENV_PATH:-${SCRIPT_DIR}}"
VLAD_ROOT="${VLAD_ROOT:-}"
CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT:-}"
CHAPAR_CCACHE_ROOT="${CHAPAR_CCACHE_ROOT:-}"
CHAPAR_INSTALL_TREE_ROOT="${CHAPAR_INSTALL_TREE_ROOT:-}"
CHAPAR_INSTALL_TREE_PROJECTION="${CHAPAR_INSTALL_TREE_PROJECTION:-}"
CHAPAR_MODULE_ROOT="${CHAPAR_MODULE_ROOT:-}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:-}"
PUBLISH_BUILDCACHE="${PUBLISH_BUILDCACHE:-}"
CHAPAR_CONCRETIZE_TIMEOUT="${CHAPAR_CONCRETIZE_TIMEOUT:-}"
BUILD_SCOPE_DIR=""
BUILD_STAGING_DIR=""
BUILDCACHE_MIGRATION_LOCK_DIR=""
declare -a PROMOTE_MODULE_LINKS=()
declare -a PROMOTE_MODULE_TMP_LINKS=()
declare -a PROMOTE_MODULE_TARGETS=()
REFRESH_BUILDCACHE_ON_EXIT="false"
CCACHE_ROOT=""
# Keep this as a major version to follow Chapar policy: dependency constraints
# may select the latest CUDA 13 patch release, but release helper code should not
# bake in a minor/patch CUDA toolkit version.
CUDA_MAJOR_VERSION="13"
INSTALL_TREE_PADDED_LENGTH="256"
detect_padded_length() {
    local store_root="$1"
    if [ -d "${store_root}/__spack_path_placeholder__" ]; then
        local prefix_dir="${store_root}"
        local count=0
        while [ -d "${prefix_dir}/__spack_path_placeholder__" ]; do
            prefix_dir="${prefix_dir}/__spack_path_placeholder__"
            count=$((count + 1))
        done
        # prefix = store_root + / + count * (__spack_path_placeholder__ + /) + __s
        # len(prefix) = len(store_root) + 1 + count * 27 + 3
        echo "${count}"
    else
        echo "0"
    fi
}
BUILDCACHE_LAYOUT_VERSION="install-tree-padded-${INSTALL_TREE_PADDED_LENGTH}"
BUILDCACHE_LAYOUT_MARKER=".chapar-buildcache-layout"

load_site_config() {
    local site_config
    local env_vlad_root="${VLAD_ROOT:-}"
    local env_buildcache_root="${CHAPAR_BUILDCACHE_ROOT:-}"
    local env_ccache_root="${CHAPAR_CCACHE_ROOT:-}"
    local env_install_tree_root="${CHAPAR_INSTALL_TREE_ROOT:-}"
    local env_install_tree_projection="${CHAPAR_INSTALL_TREE_PROJECTION:-}"
    local env_module_root="${CHAPAR_MODULE_ROOT:-}"
    local env_install_mode="${CHAPAR_INSTALL_MODE:-}"
    local env_publish_buildcache="${PUBLISH_BUILDCACHE:-}"

    site_config="${CHAPAR_SITE_CONFIG:-${SCRIPT_DIR}/vlad-site.env}"
    if [ -r "${site_config}" ]; then
        # shellcheck disable=SC1090
        . "${site_config}"
        CHAPAR_SITE_CONFIG_LOADED="true"
    fi

    # Environment variables passed to one command should still be able to override
    # the local site file.
    [ -n "${env_vlad_root}" ] && VLAD_ROOT="${env_vlad_root}"
    [ -n "${env_buildcache_root}" ] && CHAPAR_BUILDCACHE_ROOT="${env_buildcache_root}"
    [ -n "${env_ccache_root}" ] && CHAPAR_CCACHE_ROOT="${env_ccache_root}"
    [ -n "${env_install_tree_root}" ] && CHAPAR_INSTALL_TREE_ROOT="${env_install_tree_root}"
    [ -n "${env_install_tree_projection}" ] && CHAPAR_INSTALL_TREE_PROJECTION="${env_install_tree_projection}"
    [ -n "${env_module_root}" ] && CHAPAR_MODULE_ROOT="${env_module_root}"
    [ -n "${env_install_mode}" ] && CHAPAR_INSTALL_MODE="${env_install_mode}"
    [ -n "${env_publish_buildcache}" ] && PUBLISH_BUILDCACHE="${env_publish_buildcache}"

    : "${CHAPAR_INSTALL_MODE:=home}"
    : "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
    : "${VLAD_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/vlad}"
    : "${VLAD_PUBLIC_ROOT:=}"
    : "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
    : "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"
    : "${CHAPAR_CCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/ccache}"
    : "${CHAPAR_SHARED_GROUP:=}"
    : "${CHAPAR_SHARED_DIR_MODE:=2775}"
    : "${CHAPAR_CCACHE_COMPILERCHECK:=content}"
    : "${PUBLISH_BUILDCACHE:=true}"
    if [ -z "${CHAPAR_INSTALL_TREE_PROJECTION}" ]; then
        CHAPAR_INSTALL_TREE_PROJECTION='{name}-{version}-{hash}'
    fi
}

load_site_config

# User-facing CLI help. Keep the usage text focused on operator commands; the
# policy details live in the header above and docs/buildcache.md.
usage() {
    cat <<'EOF'
Usage:
  release.sh build <release-id> [--promote]
  release.sh migrate-buildcache [--force]
  release.sh promote <release-id>
  release.sh publish-modules <release-id>
  release.sh module-use [release-id]
  release.sh status

Environment:
  ENV_PATH             Spack environment path. Default: envs/vlad
  VLAD_ROOT          Release root. Default comes from envs/vlad/vlad-site.env:
                       VLAD_HOME_ROOT when CHAPAR_INSTALL_MODE=home, or
                       VLAD_PUBLIC_ROOT when CHAPAR_INSTALL_MODE=public.
  CHAPAR_HOME_ROOT     Default private root for local Chapar outputs:
                       ~/.spack/chapar.
  CHAPAR_BUILDCACHE_ROOT
                       Shared binary cache root. Default comes from
                       CHAPAR_SHARED_CACHE_ROOT/buildcache.
  CHAPAR_CCACHE_ROOT   Shared compiler ccache root. Default comes from
                        CHAPAR_SHARED_CACHE_ROOT/ccache.
  CHAPAR_INSTALL_TREE_ROOT
                        Optional Spack install tree root. Empty means
                        ${VLAD_ROOT}/<os>/store.
  CHAPAR_INSTALL_TREE_PROJECTION
                        Spack install-tree projection. Defaults to package-hash
                        directories, or architecture/compiler directories when
                        CHAPAR_INSTALL_TREE_ROOT is set.
  CHAPAR_MODULE_ROOT   Optional shared module root. Promotion and publish-modules
                        atomically update <arch> symlinks below this root.
  OS_NAME              ubuntu24.04. Auto-detected when unset.
  SPACK_INSTALL_ARGS   Extra arguments passed to spack install.
  CHAPAR_CONCRETIZE_TIMEOUT
                       Optional timeout in seconds for final environment
                       concretization. Empty means no timeout.
  CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION
                       Set true only after validating a legacy cache was built
                       with the current padded install-tree layout.

Release layout:
  ${CHAPAR_INSTALL_TREE_ROOT:-${VLAD_ROOT}/<os>/store}
  ${VLAD_ROOT}/<os>/<arch>/releases/<release-id>
  ${VLAD_ROOT}/<os>/<arch>/current -> releases/<release-id>
  ${VLAD_ROOT}/<os>/<arch>/modulefiles -> current/modulefiles/<arch>
  ${CHAPAR_MODULE_ROOT}/<arch> -> release modulefiles, when publish-modules or
                                   promote is used with CHAPAR_MODULE_ROOT set
  ${CHAPAR_BUILDCACHE_ROOT}/<os>
  ${CHAPAR_CCACHE_ROOT}/<os>

Legacy buildcache migration is explicit and one-shot. Run migrate-buildcache
when intentionally retiring old per-release cache directories.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "cannot create shared directories; root privileges or passwordless sudo are required for $*"
    fi
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

validate_release_id() {
    local release_id="$1"

    case "${release_id}" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            die "release-id must match [A-Za-z0-9._-]+ and cannot be '.' or '..': ${release_id}"
            ;;
    esac
}

# Site roots must be absolute simple paths. Non-home paths are accepted only via
# envs/vlad/vlad-site.env so datacenter-specific filesystem policy stays outside Git.
validate_simple_absolute_path() {
    local name="$1"
    local value="$2"

    [ -n "${value}" ] || die "${name} is required"
    case "${value}" in
        /*) ;;
        *) die "${name} must be an absolute path: ${value}" ;;
    esac

    case "${value}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "${name} is not an approved simple path: ${value}"
            ;;
    esac
}

validate_site_backed_path() {
    local name="$1"
    local value="$2"
    local home_prefix="${HOME}/"

    validate_simple_absolute_path "${name}" "${value}"
    case "${value}" in
        "${home_prefix}"*) ;;
        *)
            if [ "${CHAPAR_SITE_CONFIG_LOADED}" != "true" ]; then
                die "${name} points outside HOME but no envs/vlad/vlad-site.env was loaded: ${value}"
            fi
            ;;
    esac
}

validate_optional_site_backed_path() {
    local name="$1"
    local value="$2"

    [ -n "${value}" ] || return 0
    validate_site_backed_path "${name}" "${value}"
}

validate_install_tree_projection() {
    local value="${CHAPAR_INSTALL_TREE_PROJECTION}"

    [ -n "${value}" ] || die "CHAPAR_INSTALL_TREE_PROJECTION is required"
    case "${value}" in
        /*|.|..|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._{}:/+-]*)
            die "CHAPAR_INSTALL_TREE_PROJECTION is not an approved relative projection: ${value}"
            ;;
    esac
}

resolve_vlad_root() {
    if [ -n "${VLAD_ROOT}" ]; then
        return 0
    fi

    case "${CHAPAR_INSTALL_MODE}" in
        home)
            VLAD_ROOT="${VLAD_HOME_ROOT}"
            ;;
        public)
            [ -n "${VLAD_PUBLIC_ROOT}" ] || die "VLAD_PUBLIC_ROOT is required when CHAPAR_INSTALL_MODE=public"
            VLAD_ROOT="${VLAD_PUBLIC_ROOT}"
            ;;
        *)
            die "CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}"
            ;;
    esac
}

validate_vlad_root() {
    resolve_vlad_root
    validate_site_backed_path VLAD_ROOT "${VLAD_ROOT}"
}

# The buildcache root is separate from VLAD_ROOT so binary artifacts can be
# shared across home test releases and public releases at the same site.
validate_buildcache_root() {
    validate_site_backed_path CHAPAR_BUILDCACHE_ROOT "${CHAPAR_BUILDCACHE_ROOT}"
}

validate_ccache_root() {
    validate_site_backed_path CHAPAR_CCACHE_ROOT "${CHAPAR_CCACHE_ROOT}"
}

validate_install_tree_root() {
    validate_optional_site_backed_path CHAPAR_INSTALL_TREE_ROOT "${CHAPAR_INSTALL_TREE_ROOT}"
    validate_install_tree_projection
}

validate_module_root() {
    validate_optional_site_backed_path CHAPAR_MODULE_ROOT "${CHAPAR_MODULE_ROOT}"
}

# OS_NAME controls all per-OS paths and conditional vlad specs. CI can set it
# explicitly; interactive use usually relies on auto-detection.
detect_os() {
    local detected="${OS_NAME:-}"

    if [ -z "${detected}" ]; then
        case "$(uname -s)" in
            Darwin)
                detected=""
                ;;
            Linux)
                if [ -r /etc/os-release ]; then
                    # shellcheck disable=SC1091
                    . /etc/os-release
                    case "${ID:-}:${VERSION_ID%%.*}" in
                        ubuntu:24) detected="ubuntu24.04" ;;
                    esac
                fi
                ;;
        esac
    fi

    case "${detected}" in
        ubuntu24.04) printf '%s\n' "${detected}" ;;
        "") die "could not detect OS_NAME; set OS_NAME=ubuntu24.04" ;;
        *) die "unsupported OS_NAME: ${detected}" ;;
    esac
}

# Derive all path globals from the validated roots and selected OS. Keeping the
# path calculation in one place avoids accidentally mixing per-OS stores
# or caches in migration and promotion commands.
set_paths() {
    OS_NAME="$(detect_os)"
    validate_vlad_root
    validate_buildcache_root
    validate_ccache_root
    validate_install_tree_root
    validate_module_root
    OS_ROOT="${VLAD_ROOT}/${OS_NAME}"
    if [ -n "${CHAPAR_INSTALL_TREE_ROOT}" ]; then
        local arch_triplet
        arch_triplet="$(spack arch 2>/dev/null || true)"
        if [ -z "${arch_triplet}" ]; then
            arch_triplet="linux-${OS_NAME}-broadwell"
        fi
        STORE_ROOT="${CHAPAR_INSTALL_TREE_ROOT}/${arch_triplet}"
    else
        STORE_ROOT="${OS_ROOT}/store"
    fi
    LEGACY_CURRENT_LINK="${OS_ROOT}/current"
    BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"
    CCACHE_ROOT="${CHAPAR_CCACHE_ROOT}/${OS_NAME}"
}

# Releases live under <os>/<arch>/releases/<id>, where <arch> is the module
# architecture derived from the generated release content (not `spack arch`,
# which reports the host microarchitecture). Lookups glob the arch directories
# and fall back to the legacy <os>/releases/<id> layout for older releases.
find_release_dir() {
    local release_id="$1"
    local matches=()
    local candidate

    for candidate in "${OS_ROOT}"/linux-*/releases/"${release_id}" "${OS_ROOT}/releases/${release_id}"; do
        [ -d "${candidate}" ] && matches+=("${candidate}")
    done
    case "${#matches[@]}" in
        0) return 1 ;;
        1) printf '%s\n' "${matches[0]}" ;;
        *) die "release ${release_id} exists in multiple locations: ${matches[*]}" ;;
    esac
}

prepare_shared_directory() {
    local path="$1"
    local label="$2"
    local current_group

    mkdir -p "${path}" || die "could not create ${label}: ${path}"

    if [ -n "${CHAPAR_SHARED_GROUP}" ]; then
        current_group="$(stat -c '%G' "${path}" 2>/dev/null || stat -f '%Sg' "${path}" 2>/dev/null || true)"
        if [ "${current_group}" != "${CHAPAR_SHARED_GROUP}" ]; then
            chgrp "${CHAPAR_SHARED_GROUP}" "${path}" || die "could not set group ${CHAPAR_SHARED_GROUP} on ${label}: ${path}"
        fi
    fi

    if ! chmod "${CHAPAR_SHARED_DIR_MODE}" "${path}" 2>/dev/null; then
        run_as_root chmod "${CHAPAR_SHARED_DIR_MODE}" "${path}" 2>/dev/null || echo "WARNING: could not set mode ${CHAPAR_SHARED_DIR_MODE} on ${label}: ${path}"
    fi
}

configure_ccache() {
    local ccache_tmp

    prepare_shared_directory "${CHAPAR_CCACHE_ROOT}" "shared ccache root"
    prepare_shared_directory "${CCACHE_ROOT}" "${OS_NAME} ccache root"

    ccache_tmp="${CCACHE_TEMPDIR:-${TMPDIR:-/tmp}/${USER}/vlad-ccache-tmp/${OS_NAME}}"
    mkdir -p "${ccache_tmp}" || die "could not create ccache temp directory: ${ccache_tmp}"

    export CCACHE_DIR="${CCACHE_ROOT}"
    export CCACHE_TEMPDIR="${ccache_tmp}"
    export CCACHE_UMASK="${CCACHE_UMASK:-002}"
    export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-${CHAPAR_CCACHE_COMPILERCHECK}}"
    if [ -n "${CHAPAR_CCACHE_MAXSIZE:-}" ]; then
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-${CHAPAR_CCACHE_MAXSIZE}}"
    fi

    if command -v ccache >/dev/null 2>&1 && [ -n "${CHAPAR_CCACHE_MAXSIZE:-}" ]; then
        ccache --max-size "${CHAPAR_CCACHE_MAXSIZE}" >/dev/null || die "could not set ccache max size: ${CHAPAR_CCACHE_MAXSIZE}"
    fi
}

prepare_release_roots() {
    umask 0002
    prepare_shared_directory "${VLAD_ROOT}" "vlad release root"
    prepare_shared_directory "${OS_ROOT}" "${OS_NAME} vlad root"
    prepare_shared_directory "${STORE_ROOT}" "${OS_NAME} Spack install tree"
    if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
        prepare_shared_directory "${CHAPAR_MODULE_ROOT}" "shared module root"
    fi
    prepare_shared_directory "${CHAPAR_BUILDCACHE_ROOT}" "shared buildcache root"
    prepare_shared_directory "${BUILDCACHE_ROOT}" "${OS_NAME} buildcache root"
    configure_ccache
}

# Create a temporary Spack scope for this one release command. The generated
# scope has higher precedence than system/user scopes, which lets CI control
# install_tree, module roots, and buildcache autopush without mutating persistent
# Chapar config.
make_scope() {
    local module_root="$1"
    local scope_dir
    local ph_count
    local effective_padded_length
    scope_dir="$(mktemp -d "${TMPDIR:-/tmp}/vlad-release-scope.XXXXXX")"

    ph_count="$(detect_padded_length "${STORE_ROOT}")"
    if [ "${ph_count}" -gt 0 ]; then
        effective_padded_length="$(( ${#STORE_ROOT} + 1 + ph_count * 27 + 3 ))"
    else
        effective_padded_length="${INSTALL_TREE_PADDED_LENGTH}"
    fi

    cat > "${scope_dir}/config.yaml" <<EOF
config:
  install_tree:
    root: ${STORE_ROOT}
    padded_length: ${effective_padded_length}
    projections:
      all: "${CHAPAR_INSTALL_TREE_PROJECTION}"
  template_dirs:
  - ${OS_ROOT}/templates
  license_dir: ${OS_ROOT}/licenses
  build_stage:
  - \$tempdir/\$user/vlad-stage
  - \$user_cache_path/vlad/stage
  test_stage: \$user_cache_path/vlad/test
  source_cache: \$user_cache_path/source
  misc_cache: \$user_cache_path/cache
  install_missing: true
  binary_index_ttl: 600
EOF

    # Use the same mirror name as the persistent Chapar scopes so this temporary
    # scope overrides autopush while still targeting the shared per-OS cache.
    cat > "${scope_dir}/mirrors.yaml" <<EOF
mirrors:
  chapar-buildcache:
    url: file://${BUILDCACHE_ROOT}
    source: false
    binary: true
    signed: false
    autopush: ${PUBLISH_BUILDCACHE}
EOF

    # Modules are written under the staging release until the build succeeds.
    # That prevents failed builds from modifying the active module tree.
    cat > "${scope_dir}/modules.yaml" <<EOF
modules:
  default:
    roots:
      tcl: ${module_root}/modulefiles
      lmod: ${module_root}/lmods
    tcl:
      exclude_implicits: false
      # Release modules are generated only for root specs. Do not emit module-load
      # statements for dependencies such as external glibc that have no modulefile.
      all:
        autoload: none
EOF

    printf '%s\n' "${scope_dir}"
}

# Buildcache migration/quarantine helpers. The lock uses atomic directory create,
# which is portable enough for the shared NFS resources tree used by CI.
release_buildcache_migration_lock() {
    if [ -n "${BUILDCACHE_MIGRATION_LOCK_DIR}" ] && [ -d "${BUILDCACHE_MIGRATION_LOCK_DIR}" ]; then
        rmdir "${BUILDCACHE_MIGRATION_LOCK_DIR}" 2>/dev/null || true
    fi
    BUILDCACHE_MIGRATION_LOCK_DIR=""
}

acquire_buildcache_migration_lock() {
    local lock_dir="${BUILDCACHE_ROOT}.migration.lock"
    local waited=0

    while ! mkdir "${lock_dir}" 2>/dev/null; do
        if [ "${waited}" -ge 600 ]; then
            echo "WARNING: timed out waiting for buildcache migration lock: ${lock_dir}" >&2
            return 1
        fi
        echo "==> Waiting for buildcache migration lock"
        echo "    lock: ${lock_dir}"
        sleep 5
        waited=$((waited + 5))
    done

    BUILDCACHE_MIGRATION_LOCK_DIR="${lock_dir}"
}

legacy_buildcache_sources() {
    local candidate
    local seen=""
    local candidates=(
        "${OS_ROOT}/buildcache"
    )

    for candidate in "${candidates[@]}"; do
        [ -d "${candidate}" ] || continue
        [ "${candidate}" != "${BUILDCACHE_ROOT}" ] || continue
        case "${seen}" in
            *"|${candidate}|"*) continue ;;
        esac
        seen="${seen}|${candidate}|"
        printf '%s\n' "${candidate}"
    done
}

# The migration sentinel records that the selected legacy source set was handled.
# It prevents normal repeat invocations from quietly re-copying retired caches.
legacy_buildcache_migration_sentinel() {
    printf '%s\n' "${BUILDCACHE_ROOT}/.legacy-buildcache-migration-complete"
}

write_legacy_buildcache_migration_sentinel() {
    local sentinel="$1"
    shift
    local source_dir

    {
        printf 'completed_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'destination: %s\n' "${BUILDCACHE_ROOT}"
        printf 'sources:\n'
        for source_dir in "$@"; do
            printf '  - %s\n' "${source_dir}"
        done
    } > "${sentinel}"
}

buildcache_layout_marker() {
    printf '%s\n' "${BUILDCACHE_ROOT}/${BUILDCACHE_LAYOUT_MARKER}"
}

# Layout markers are the guardrail between the current padded store and older
# unpadded caches. Do not treat an unmarked cache as safe unless an operator has
# validated it and set the explicit migration override.
buildcache_layout_is_current() {
    local marker="${1:-}"

    [ -n "${marker}" ] || marker="$(buildcache_layout_marker)"
    [ -r "${marker}" ] || return 1
    grep -qx "layout: ${BUILDCACHE_LAYOUT_VERSION}" "${marker}" || return 1
    grep -qx "install_tree_padded_length: ${INSTALL_TREE_PADDED_LENGTH}" "${marker}"
}

write_buildcache_layout_marker() {
    local marker

    marker="$(buildcache_layout_marker)"
    {
        printf 'layout: %s\n' "${BUILDCACHE_LAYOUT_VERSION}"
        printf 'install_tree_padded_length: %s\n' "${INSTALL_TREE_PADDED_LENGTH}"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${marker}"
}

buildcache_has_payload() {
    [ -d "${BUILDCACHE_ROOT}/blobs" ] || [ -d "${BUILDCACHE_ROOT}/v3" ] || [ -d "${BUILDCACHE_ROOT}/build_cache" ]
}

buildcache_index_exists() {
    [ -r "${BUILDCACHE_ROOT}/v3/manifests/index/index.manifest.json" ]
}

# Prepare the destination cache before any concretization can reuse binaries.
# If payloads exist without the current layout marker, quarantine them instead of
# letting Spack consider binaries that may not relocate into the padded store.
prepare_buildcache_root() {
    local archive_dir
    local entry
    local source_path

    mkdir -p "${BUILDCACHE_ROOT}"

    if buildcache_layout_is_current; then
        return 0
    fi

    if ! buildcache_has_payload; then
        write_buildcache_layout_marker
        return 0
    fi

    if [ "${CHAPAR_QUARANTINE_INCOMPATIBLE_BUILDCACHE:-true}" != "true" ]; then
        die "buildcache is unmarked for ${BUILDCACHE_LAYOUT_VERSION}: ${BUILDCACHE_ROOT}"
    fi

    echo "==> Quarantining unmarked buildcache contents"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    reason: old cache entries may not relocate into the padded install tree"

    acquire_buildcache_migration_lock || die "could not acquire buildcache quarantine lock"
    if buildcache_layout_is_current; then
        release_buildcache_migration_lock
        return 0
    fi

    archive_dir="${BUILDCACHE_ROOT}/.incompatible-${BUILDCACHE_LAYOUT_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${archive_dir}"
    for entry in blobs v3 build_cache index.json .legacy-buildcache-migration-complete "${BUILDCACHE_LAYOUT_MARKER}"; do
        source_path="${BUILDCACHE_ROOT}/${entry}"
        [ -e "${source_path}" ] || continue
        mv "${source_path}" "${archive_dir}/"
    done

    echo "    archive: ${archive_dir}"
    write_buildcache_layout_marker
    release_buildcache_migration_lock
}

validate_legacy_buildcache_sources() {
    local source_dir
    local marker

    for source_dir in "$@"; do
        marker="${source_dir}/${BUILDCACHE_LAYOUT_MARKER}"
        if buildcache_layout_is_current "${marker}"; then
            continue
        fi
        if [ "${CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION:-false}" = "true" ]; then
            echo "WARNING: migrating unmarked buildcache source after explicit override: ${source_dir}" >&2
            continue
        fi
        die "legacy buildcache source is unmarked for ${BUILDCACHE_LAYOUT_VERSION}: ${source_dir}; rebuild it or set CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION=true only after validating it was built with the current padded layout"
    done
}

# Copy legacy payloads without overwriting destination files. The old cache is
# left in place so operators can audit or retire it after validation.
copy_buildcache_contents() {
    local source_dir="$1"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --ignore-existing "${source_dir}/" "${BUILDCACHE_ROOT}/"
    else
        cp -Rp -n "${source_dir}/." "${BUILDCACHE_ROOT}/"
    fi
}

update_buildcache_index() {
    [ -n "${BUILD_SCOPE_DIR}" ] || return 0
    [ -d "${BUILD_SCOPE_DIR}" ] || return 0

    echo "==> Updating Chapar buildcache index"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    if ! spack -C "${BUILD_SCOPE_DIR}" buildcache update-index "file://${BUILDCACHE_ROOT}"; then
        echo "WARNING: failed to update Chapar buildcache index: ${BUILDCACHE_ROOT}" >&2
        return 1
    fi
}

# A cache with blobs but no index is effectively invisible to Spack reuse. Refresh
# before concretization so release builds can reuse partial progress from an
# interrupted previous run.
ensure_buildcache_index() {
    buildcache_has_payload || return 0
    buildcache_index_exists && return 0

    echo "==> Buildcache has payloads but no index; updating before concretization"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    update_buildcache_index || die "could not update buildcache index before concretization"
}

# Wrap concretization with an optional timeout. CI uses this to fail solver stalls
# inside the build step instead of consuming the full workflow timeout.
run_with_timeout() {
    local timeout_seconds="$1"
    shift

    if [ -z "${timeout_seconds}" ] || [ "${timeout_seconds}" = "0" ]; then
        "$@"
        return
    fi

    case "${timeout_seconds}" in
        *[!0-9]*) die "CHAPAR_CONCRETIZE_TIMEOUT must be an integer number of seconds: ${timeout_seconds}" ;;
    esac

    ensure_cmd timeout
    timeout "${timeout_seconds}" "$@"
}

migrate_legacy_buildcaches() {
    local source_dir
    local sources=()
    local sentinel
    local migrated="false"
    local failed="false"

    sentinel="$(legacy_buildcache_migration_sentinel)"
    if [ -e "${sentinel}" ]; then
        echo "==> Legacy buildcache migration already completed"
        echo "    sentinel: ${sentinel}"
        return 0
    fi

    while IFS= read -r source_dir; do
        sources+=("${source_dir}")
    done < <(legacy_buildcache_sources)

    if [ "${#sources[@]}" -eq 0 ]; then
        echo "==> No legacy buildcache sources found"
        write_legacy_buildcache_migration_sentinel "${sentinel}"
        return 0
    fi

    # Migration is intentionally opt-in and conservative. Normal `build` must not
    # import legacy caches because old binaries can poison later concretizations.
    validate_legacy_buildcache_sources "${sources[@]}"

    echo "==> Migrating legacy buildcache contents"
    echo "    destination: ${BUILDCACHE_ROOT}"
    echo "    policy: copy only, do not delete sources, do not overwrite destination files"

    acquire_buildcache_migration_lock || die "could not acquire buildcache migration lock"
    for source_dir in "${sources[@]}"; do
        [ -d "${source_dir}" ] || continue
        echo "    source: ${source_dir}"
        if copy_buildcache_contents "${source_dir}"; then
            migrated="true"
        else
            echo "WARNING: failed to copy legacy buildcache source: ${source_dir}" >&2
            failed="true"
        fi
    done
    release_buildcache_migration_lock

    if [ "${failed}" = "true" ]; then
        die "legacy buildcache migration failed; not writing completion sentinel"
    fi

    if [ "${migrated}" = "true" ]; then
        update_buildcache_index
    fi

    write_legacy_buildcache_migration_sentinel "${sentinel}" "${sources[@]}"
}

refresh_buildcache_index() {
    [ "${PUBLISH_BUILDCACHE}" = "true" ] || return 0
    update_buildcache_index
}

# Install unsigned/signed mirror trust keys opportunistically. The local Chapar
# cache is unsigned today, but online upstream mirrors may still need trusted keys
# for binary reuse.
trust_buildcache_keys() {
    echo "==> Installing buildcache trust keys"
    if ! run_with_timeout 300 spack -C "${BUILD_SCOPE_DIR}" buildcache keys --install --trust; then
        echo "WARNING: failed to install buildcache keys; signed online caches may be skipped" >&2
    fi
}

install_release_prerequisite() {
    local scope_dir="$1"
    local spec="$2"
    shift 2

    echo "==> Ensuring release prerequisite"
    echo "    spec: ${spec}"
    if spack -C "${scope_dir}" find "${spec}" >/dev/null 2>&1; then
        echo "    status: already installed"
        return 0
    fi

    spack -C "${scope_dir}" install "$@" "${spec}"
}

# Return the architecture-specific CUDA target directory. NVIDIA's toolkit puts
# headers and runtime libraries below targets/<arch>-linux; CUDA-aware libfabric
# needs both the runtime library and driver stubs during its package build.
cuda_target_root() {
    local cuda_prefix="$1"
    local candidate

    for candidate in "${cuda_prefix}"/targets/*-linux; do
        [ -d "${candidate}" ] || continue
        [ -r "${candidate}/include/cuda_runtime.h" ] || continue
        compgen -G "${candidate}/lib/libcudart.so*" >/dev/null || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    return 1
}

# Work around the CUDA-aware libfabric build ordering. Spack can install
# libfabric's dependencies first, but the libfabric package build itself needs
# CUDA target headers/libraries and driver stubs visible in compiler search paths.
# We therefore:
#
# 1. Find concrete libfabric specs that include `+cuda`.
# 2. Install their dependencies only.
# 3. Locate the concrete CUDA major selected by the environment.
# 4. Build just the missing libfabric packages with CPATH/LIBRARY_PATH pointing
#    at the CUDA runtime and stub libraries.
#
# Keep this workaround scoped to Linux release builds. Do not solve downstream
# CUDA/NVML link failures by disabling CUDA/GDR variants; those transports are a
# required vlad policy.
install_cuda_libfabric_specs() {
    local install_args_ref=("$@")
    local cuda_prefix
    local cuda_root
    local spec_line
    local spec_hash
    local spec_hashes=()
    local missing_hashes=()
    local seen_hashes=()
    local saved_cpath="${CPATH:-}"
    local saved_library_path="${LIBRARY_PATH:-}"

    case "${OS_NAME}" in
        ubuntu24.04) ;;
        *) return 0 ;;
    esac

    while IFS= read -r spec_line; do
        case "${spec_line}" in
            *libfabric*+cuda*HASH=/*) ;;
            *) continue ;;
        esac
        spec_hash="${spec_line##*HASH=}"
        [ -n "${spec_hash}" ] || continue
        case " ${seen_hashes[*]} " in
            *" ${spec_hash} "*) continue ;;
        esac
        seen_hashes+=("${spec_hash}")
        spec_hashes+=("${spec_hash}")
    done < <(spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" find -c -d --no-groups --format "{name} {variants} HASH={/hash}")

    [ "${#spec_hashes[@]}" -gt 0 ] || return 0

    for spec_hash in "${spec_hashes[@]}"; do
        if spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" location -i "${spec_hash}" >/dev/null 2>&1; then
            continue
        fi
        missing_hashes+=("${spec_hash}")
    done

    if [ "${#missing_hashes[@]}" -eq 0 ]; then
        echo "==> CUDA-aware libfabric specs already installed"
        echo "    count: ${#spec_hashes[@]}"
        return 0
    fi

    echo "==> Preinstalling CUDA-aware libfabric specs"
    echo "    missing: ${#missing_hashes[@]} of ${#spec_hashes[@]}"

    for spec_hash in "${missing_hashes[@]}"; do
        spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete "${install_args_ref[@]}" --only dependencies "${spec_hash}"
    done
    cuda_prefix="$(spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" location -i "cuda@${CUDA_MAJOR_VERSION}")"
    cuda_root="$(cuda_target_root "${cuda_prefix}")" || die "could not locate CUDA target runtime under ${cuda_prefix}"
    [ -d "${cuda_root}/lib/stubs" ] || die "could not locate CUDA driver stubs under ${cuda_root}/lib/stubs"

    export CPATH="${cuda_root}/include${saved_cpath:+:${saved_cpath}}"
    export LIBRARY_PATH="${cuda_root}/lib:${cuda_root}/lib/stubs${saved_library_path:+:${saved_library_path}}"
    for spec_hash in "${missing_hashes[@]}"; do
        spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete --dirty "${install_args_ref[@]}" --only package "${spec_hash}"
    done
    export CPATH="${saved_cpath}"
    export LIBRARY_PATH="${saved_library_path}"
}

cleanup_build() {
    local status="$?"

    if [ "${REFRESH_BUILDCACHE_ON_EXIT}" = "true" ]; then
        refresh_buildcache_index || true
    fi

    release_buildcache_migration_lock

    if [ "${status}" -ne 0 ] && [ -n "${BUILD_STAGING_DIR}" ] && [ -d "${BUILD_STAGING_DIR}" ]; then
        case "${BUILD_STAGING_DIR##*/}" in
            .*.staging.*)
                echo "==> Removing failed release staging: ${BUILD_STAGING_DIR}" >&2
                rm -rf "${BUILD_STAGING_DIR}"
                ;;
            *)
                echo "==> Refusing to remove unexpected staging path: ${BUILD_STAGING_DIR}" >&2
                ;;
        esac
    fi

    if [ -n "${BUILD_SCOPE_DIR}" ] && [ -d "${BUILD_SCOPE_DIR}" ]; then
        rm -rf "${BUILD_SCOPE_DIR}"
    fi

    exit "${status}"
}

# The migration command has a smaller cleanup surface than build, but it still
# owns a generated Spack scope and may hold the cache lock.
cleanup_migration() {
    local status="$?"

    release_buildcache_migration_lock

    if [ -n "${BUILD_SCOPE_DIR}" ] && [ -d "${BUILD_SCOPE_DIR}" ]; then
        rm -rf "${BUILD_SCOPE_DIR}"
    fi

    exit "${status}"
}

# Copy enough metadata into the immutable release directory to answer later
# questions about which environment file and store/cache roots produced it.
copy_manifest() {
    local release_dir="$1"
    local arch_triplet="$2"

    cp "${ENV_PATH}/spack.yaml" "${release_dir}/spack.yaml"
    if [ -f "${ENV_PATH}/spack.lock" ]; then
        cp "${ENV_PATH}/spack.lock" "${release_dir}/spack.lock"
    fi

    printf '%s\n' "${arch_triplet}" > "${release_dir}/.chapar-arch"

    {
        printf 'release_id: %s\n' "${RELEASE_ID}"
        printf 'os: %s\n' "${OS_NAME}"
        printf 'arch: %s\n' "${arch_triplet}"
        printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'env_path: %s\n' "${ENV_PATH}"
        printf 'store: %s\n' "${STORE_ROOT}"
        printf 'install_tree_projection: %s\n' "${CHAPAR_INSTALL_TREE_PROJECTION}"
        printf 'buildcache: %s\n' "${BUILDCACHE_ROOT}"
        if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
            printf 'promoted_module_root: %s\n' "${CHAPAR_MODULE_ROOT}"
        fi
    } > "${release_dir}/metadata.txt"
}

# Spack's module refresh command wants concrete hashes, while users see
# `{name}/{version}`. Record both so we can validate visible names before writing
# hashless modules.
write_root_module_specs() {
    local output_file="$1"

    # Use spack find to list concrete roots instead of the Python API,
    # which has API instability across Spack develop versions
    spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" find -c --no-groups \
        --format "{dag_hash} {name}/{version}" \
        > "${output_file}"
}

# Hashless module names are a deliberate UX contract. If two explicit roots would
# produce the same visible module, fail the release instead of adding hash suffixes
# or refreshing dependency-only modules.
validate_root_module_names() {
    local root_specs_file="$1"
    local names_file
    local duplicates_file
    local module_name

    names_file="${BUILD_SCOPE_DIR}/root-module-names.txt"
    duplicates_file="${BUILD_SCOPE_DIR}/duplicate-root-module-names.txt"

    while read -r _ module_name; do
        [ -n "${module_name}" ] || continue
        printf '%s\n' "${module_name}"
    done < "${root_specs_file}" > "${names_file}"
    sort "${names_file}" | uniq -d > "${duplicates_file}"

    if [ -s "${duplicates_file}" ]; then
        echo "ERROR: vlad root module names must be unique because module hashes are disabled." >&2
        echo "Duplicate root module names:" >&2
        while IFS= read -r module_name; do
            echo "  ${module_name}" >&2
        done < "${duplicates_file}"
        echo "Fix the root specs instead of adding hash suffixes to module names." >&2
        return 1
    fi
}

modulefile_has_marker() {
    local module_file="$1"
    local marker="$2"
    local line

    while IFS= read -r line; do
        [ "${line}" = "${marker}" ] && return 0
    done < "${module_file}"
    return 1
}

modulefile_prefix_for_exe() {
    local module_file="$1"
    local exe_name="$2"
    local directive=""
    local variable=""
    local value=""
    local _rest=""

    while read -r directive variable value _rest; do
        [ "${directive}" = "prepend-path" ] || continue
        # Newer Spack tcl templates emit `prepend-path -d {:} PATH {...}`;
        # skip the delimiter option pair so the variable name is matched.
        if [ "${variable}" = "-d" ] || [ "${variable}" = "--delim" ]; then
            variable="${_rest%% *}"
            value="${_rest#* }"
        fi
        [ "${variable}" = "PATH" ] || continue
        [ -n "${value}" ] || continue
        value="${value#\{}"
        value="${value%\}}"
        value="${value#\"}"
        value="${value%\"}"
        if [ -x "${value}/${exe_name}" ]; then
            dirname "${value}"
            return 0
        fi
    done < "${module_file}"

    return 1
}

find_prted_for_openmpi_prefix() {
    local openmpi_prefix="$1"
    local store_root
    local candidate

    store_root="$(dirname "${openmpi_prefix}")"
    for candidate in "${openmpi_prefix}/bin/prted" "${store_root}"/prrte-*/bin/prted; do
        [ -x "${candidate}" ] || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    return 1
}

ensure_release_cuda_driver_stub_dir() {
    local release_dir="$1"
    local policy_release_dir="${2:-$1}"
    local cuda_module
    local cuda_prefix
    local stub_source
    local stub_dir
    local policy_stub_dir
    local libcuda_stub=""
    local nvml_stub=""

    for cuda_module in "${release_dir}/modulefiles"/*/cuda/*; do
        [ -f "${cuda_module}" ] || continue
        cuda_prefix="$(modulefile_prefix_for_exe "${cuda_module}" nvcc || true)"
        [ -n "${cuda_prefix}" ] || continue

        libcuda_stub=""
        nvml_stub=""
        for stub_source in "${cuda_prefix}"/targets/*-linux/lib/stubs "${cuda_prefix}"/lib64/stubs; do
            [ -d "${stub_source}" ] || continue
            if [ -z "${libcuda_stub}" ] && [ -r "${stub_source}/libcuda.so" ]; then
                libcuda_stub="${stub_source}/libcuda.so"
            fi
            if [ -z "${nvml_stub}" ] && [ -r "${stub_source}/libnvidia-ml.so" ]; then
                nvml_stub="${stub_source}/libnvidia-ml.so"
            fi
        done

        if [ -n "${libcuda_stub}" ] && [ -n "${nvml_stub}" ]; then
            stub_dir="${release_dir}/support/cuda-driver-stubs"
            policy_stub_dir="${policy_release_dir}/support/cuda-driver-stubs"
            mkdir -p "${stub_dir}"
            ln -sf "${libcuda_stub}" "${stub_dir}/libcuda.so"
            ln -sf "${libcuda_stub}" "${stub_dir}/libcuda.so.1"
            ln -sf "${nvml_stub}" "${stub_dir}/libnvidia-ml.so"
            ln -sf "${nvml_stub}" "${stub_dir}/libnvidia-ml.so.1"
            printf '%s\n' "${policy_stub_dir}"
            return 0
        elif [ -n "${libcuda_stub}" ]; then
            echo "==> WARNING: CUDA module has libcuda stub but no libnvidia-ml stub" >&2
            echo "    cuda: ${cuda_prefix}" >&2
        fi
    done

    return 1
}

remove_cuda_stub_module_policy() {
    local module_file="$1"
    local marker="# Chapar CUDA driver-stub runtime policy"
    local tmp_file

    modulefile_has_marker "${module_file}" "${marker}" || return 0

    tmp_file="${module_file}.chapar.$$"
    awk -v marker="${marker}" '
        $0 == marker { skip = 1; next }
        skip && $0 == "}" { skip = 0; next }
        skip { next }
        { print }
    ' "${module_file}" > "${tmp_file}" || die "could not rewrite modulefile: ${module_file}"
    cat "${tmp_file}" > "${module_file}" || die "could not update modulefile: ${module_file}"
    rm -f "${tmp_file}"
}

append_openmpi_module_policy() {
    local module_file="$1"
    local openmpi_prefix
    local prted
    local prte_bin
    local marker="# Chapar Open MPI runtime policy"

    modulefile_has_marker "${module_file}" "${marker}" && return 0

    openmpi_prefix="$(modulefile_prefix_for_exe "${module_file}" mpirun || true)"
    if [ -n "${openmpi_prefix}" ]; then
        prted="$(find_prted_for_openmpi_prefix "${openmpi_prefix}" || true)"
    fi

    {
        printf '\n%s\n' "${marker}"
        cat <<'EOF'
# Suppress CUDA plugin dlopen noise only on nodes without the NVIDIA driver.
if {![file exists "/dev/nvidiactl"] && ![file exists "/proc/driver/nvidia/version"]} {
    if {![info exists env(OMPI_MCA_mca_base_component_show_load_errors)]} {
        setenv OMPI_MCA_mca_base_component_show_load_errors 0
    }
}
EOF
        if [ -n "${prted}" ]; then
            prte_bin="$(dirname "${prted}")"
            cat <<EOF
# Open MPI 5 uses PRRTE daemons for multi-node mpirun launches.
prepend-path PATH {${prte_bin}}
if {![info exists env(PRTE_MCA_prte_launch_agent)]} {
    setenv PRTE_MCA_prte_launch_agent {${prted}}
}
if {![info exists env(PRTE_MCA_plm_slurm_args)]} {
    setenv PRTE_MCA_plm_slurm_args {--cpu-bind=none --export=ALL}
}
if {![info exists env(OMPI_MCA_plm_slurm_args)]} {
    setenv OMPI_MCA_plm_slurm_args {--cpu-bind=none --export=ALL}
}
EOF
        else
            echo "# WARNING: Chapar could not locate prted for this Open MPI module."
        fi
    } >> "${module_file}"
}

append_openmpi_transport_module_policy() {
    local module_file="$1"
    local openmpi_prefix
    local lib_dir
    local marker="# Chapar Open MPI UCX transport policy"

    modulefile_has_marker "${module_file}" "${marker}" && return 0

    openmpi_prefix="$(modulefile_prefix_for_exe "${module_file}" mpirun || true)"

    {
        printf '\n%s\n' "${marker}"
        if [ -n "${openmpi_prefix}" ]; then
            for lib_dir in "${openmpi_prefix}/lib" "${openmpi_prefix}/lib64"; do
                [ -d "${lib_dir}" ] || continue
                printf 'prepend-path LD_LIBRARY_PATH {%s}\n' "${lib_dir}"
            done
        else
            echo "# WARNING: Chapar could not locate this Open MPI module prefix."
        fi
        cat <<'EOF'
# Default to the UCX transport path validated for vlad. Users can override
# these before loading the module when testing another Open MPI transport setup.
if {![info exists env(OMPI_MCA_pml)]} {
    setenv OMPI_MCA_pml {ucx}
}
if {![info exists env(OMPI_MCA_osc)]} {
    setenv OMPI_MCA_osc {ucx}
}
if {![info exists env(UCX_TLS)]} {
    if {[file exists "/dev/nvidiactl"] || [file exists "/proc/driver/nvidia/version"]} {
        setenv UCX_TLS {rc,ud,sm,self,cuda_copy,cuda_ipc,gdr_copy}
    } else {
        setenv UCX_TLS {rc,ud,sm,self}
    }
}
if {![info exists env(UCX_MEMTYPE_CACHE)]} {
    if {[file exists "/dev/nvidiactl"] || [file exists "/proc/driver/nvidia/version"]} {
        setenv UCX_MEMTYPE_CACHE {y}
    } else {
        setenv UCX_MEMTYPE_CACHE {n}
    }
}
EOF
    } >> "${module_file}"
}

append_cuda_stub_module_policy() {
    local module_file="$1"
    local stub_dir="$2"
    local marker="# Chapar CUDA driver-stub runtime policy"

    [ -n "${stub_dir}" ] || return 0
    remove_cuda_stub_module_policy "${module_file}"

    cat >> "${module_file}" <<EOF

${marker}
# CUDA-aware libfabric has NVIDIA driver-library dependencies. On non-GPU nodes,
# expose CUDA's driver stubs so CPU-only MPI/libfabric commands can start. GPU
# nodes keep using the real NVIDIA driver libraries.
if {![file exists "/dev/nvidiactl"] && ![file exists "/proc/driver/nvidia/version"]} {
    prepend-path LD_LIBRARY_PATH {${stub_dir}}
}
EOF
}

apply_release_module_runtime_policy() {
    local release_dir="$1"
    local policy_release_dir="${2:-$1}"
    local cuda_stub_dir=""
    local module_file
    local needs_cuda_stub="false"

    [ -d "${release_dir}/modulefiles" ] || return 0

    cuda_stub_dir="$(ensure_release_cuda_driver_stub_dir "${release_dir}" "${policy_release_dir}" || true)"

    for module_file in "${release_dir}/modulefiles"/*/libfabric/*; do
        [ -f "${module_file}" ] || continue
        needs_cuda_stub="true"
        break
    done

    if [ "${needs_cuda_stub}" = "true" ] && [ -z "${cuda_stub_dir}" ]; then
        echo "WARNING: could not create CUDA driver-stub support directory for CUDA-aware libfabric modules in ${release_dir}"
        return 1
    fi

    for module_file in "${release_dir}/modulefiles"/*/openmpi/*; do
        [ -f "${module_file}" ] || continue
        append_openmpi_module_policy "${module_file}"
        append_openmpi_transport_module_policy "${module_file}"
    done

    for module_file in "${release_dir}/modulefiles"/*/libfabric/*; do
        [ -f "${module_file}" ] || continue
        append_cuda_stub_module_policy "${module_file}" "${cuda_stub_dir}"
    done
}

refresh_root_modules() {
    local lock_file
    local root_hash
    local root_hashes=()

    lock_file="${ENV_PATH}/spack.lock"
    if [ -f "${lock_file}" ]; then
        while IFS= read -r root_hash; do
            [ -n "${root_hash}" ] || continue
            if spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" find --no-groups "/${root_hash}" >/dev/null 2>&1; then
                root_hashes+=("/${root_hash}")
            fi
        done < <(python3 -c "
import json,sys
with open('${lock_file}') as f:
    lock=json.load(f)
for r in lock.get('roots',[]):
    print(r.get('hash',''))
")
    fi

    if [ "${#root_hashes[@]}" -eq 0 ]; then
        echo "WARNING: no vlad root specs found for module generation; skipping module refresh (Spack API may have changed)"
        return 0
    fi

    spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" module tcl refresh -y "${root_hashes[@]}"
}

# Resolve either an explicit release ID or the current symlink to a physical path.
# This keeps module-use output tied to a specific release tree even if `current`
# changes later.
resolve_release_dir() {
    local release_id="${1:-}"
    local release_dir=""
    local candidate

    set_paths
    if [ -n "${release_id}" ]; then
        validate_release_id "${release_id}"
        release_dir="$(find_release_dir "${release_id}")" || die "missing release directory for ${release_id} under ${OS_ROOT}"
    else
        # Highest arch root wins when several are promoted; fall back to the
        # legacy <os>/current pointer for pre-restructure deployments.
        for candidate in "${OS_ROOT}"/linux-*/current; do
            [ -L "${candidate}" ] || [ -d "${candidate}" ] || continue
            release_dir="${candidate}"
        done
        [ -n "${release_dir}" ] || release_dir="${LEGACY_CURRENT_LINK}"
    fi

    [ -d "${release_dir}" ] || die "missing release directory: ${release_dir}"
    (cd -P "${release_dir}" && pwd)
}

validate_arch_triplet() {
    local arch_triplet="$1"

    case "${arch_triplet}" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            die "invalid Spack architecture triplet for module symlink: ${arch_triplet}"
            ;;
    esac
}

release_arch_triplet() {
    local release_dir="$1"
    local arch_triplet=""
    local module_arch_triplet=""
    local arch_dir
    local candidate

    if [ -r "${release_dir}/.chapar-arch" ]; then
        IFS= read -r arch_triplet < "${release_dir}/.chapar-arch" || true
        validate_arch_triplet "${arch_triplet}"
    fi

    if [ -z "${arch_triplet}" ] && [ -r "${release_dir}/metadata.txt" ]; then
        while IFS= read -r candidate; do
            case "${candidate}" in
                arch:\ *)
                    arch_triplet="${candidate#arch: }"
                    validate_arch_triplet "${arch_triplet}"
                    break
                    ;;
            esac
        done < "${release_dir}/metadata.txt"
    fi

    if [ -n "${arch_triplet}" ] && [ -d "${release_dir}/modulefiles/${arch_triplet}" ]; then
        printf '%s\n' "${arch_triplet}"
        return 0
    fi

    for arch_dir in "${release_dir}/modulefiles"/*; do
        [ -d "${arch_dir}" ] || continue
        candidate="$(basename "${arch_dir}")"
        case "${candidate}" in
            *-*-*) ;;
            *) continue ;;
        esac
        validate_arch_triplet "${candidate}"
        if [ -n "${module_arch_triplet}" ]; then
            if [ "${module_arch_triplet}" != "${candidate}" ]; then
                echo "==> Multiple module architectures found; picking highest" >&2
                echo "    candidates: ${module_arch_triplet} ${candidate}" >&2
                if [[ "${candidate}" > "${module_arch_triplet}" ]]; then
                    module_arch_triplet="${candidate}"
                fi
            fi
        else
            module_arch_triplet="${candidate}"
        fi
    done

    [ -n "${module_arch_triplet}" ] || die "could not determine release module architecture from ${release_dir}"
    if [ -n "${arch_triplet}" ] && [ "${arch_triplet}" != "${module_arch_triplet}" ]; then
        echo "==> Recorded release arch has no module tree; using generated module arch" >&2
        echo "    recorded: ${arch_triplet}" >&2
        echo "    module:   ${module_arch_triplet}" >&2
    fi
    arch_triplet="${module_arch_triplet}"
    printf '%s\n' "${arch_triplet}"
}

prepare_shared_module_link() {
    local release_dir="$1"
    local arch_triplet
    local module_dir
    local module_link
    local tmp_link
    local arch_dir
    local result=0

    [ -n "${CHAPAR_MODULE_ROOT}" ] || return 0

    prepare_shared_directory "${CHAPAR_MODULE_ROOT}" "shared module root"

    for arch_dir in "${release_dir}/modulefiles"/*; do
        [ -d "${arch_dir}" ] || continue
        arch_triplet="$(basename "${arch_dir}")"
        case "${arch_triplet}" in
            *-*-*) ;;
            *) continue ;;
        esac
        validate_arch_triplet "${arch_triplet}"

        module_link="${CHAPAR_MODULE_ROOT}/${arch_triplet}"
        tmp_link="${CHAPAR_MODULE_ROOT}/.${arch_triplet}.$$"

        if [ -e "${module_link}" ] && [ ! -L "${module_link}" ]; then
            echo "WARNING: shared module path exists and is not a symlink: ${module_link}" >&2
            result=1
            continue
        fi

        rm -f "${tmp_link}"
        ln -s "${arch_dir}" "${tmp_link}"
        PROMOTE_MODULE_LINKS+=("${module_link}")
        PROMOTE_MODULE_TMP_LINKS+=("${tmp_link}")
        PROMOTE_MODULE_TARGETS+=("${arch_dir}")
    done

    [ "${#PROMOTE_MODULE_TMP_LINKS[@]}" -gt 0 ] || die "no module architecture directories found in ${release_dir}"

    return "${result}"
}

discard_prepared_shared_module_link() {
    local idx
    for idx in "${!PROMOTE_MODULE_TMP_LINKS[@]}"; do
        rm -f "${PROMOTE_MODULE_TMP_LINKS[$idx]}"
    done
    PROMOTE_MODULE_LINKS=()
    PROMOTE_MODULE_TMP_LINKS=()
    PROMOTE_MODULE_TARGETS=()
}

commit_prepared_shared_module_link() {
    local idx
    [ "${#PROMOTE_MODULE_TMP_LINKS[@]}" -gt 0 ] || return 0

    for idx in "${!PROMOTE_MODULE_TMP_LINKS[@]}"; do
        perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${PROMOTE_MODULE_TMP_LINKS[$idx]}" "${PROMOTE_MODULE_LINKS[$idx]}"
        echo "    module:  ${PROMOTE_MODULE_LINKS[$idx]} -> ${PROMOTE_MODULE_TARGETS[$idx]}"
    done
    PROMOTE_MODULE_LINKS=()
    PROMOTE_MODULE_TMP_LINKS=()
    PROMOTE_MODULE_TARGETS=()
}

# Build command: install into the configured shared install tree, generate
# release-local modules in staging, then atomically publish the immutable release
# directory.
cmd_build() {
    RELEASE_ID="${1:-}"
    local promote="${2:-}"
    local staging_dir
    local final_dir
    local scope_dir
    local arch_triplet
    local concretize_timeout

    [ -n "${RELEASE_ID}" ] || die "release-id is required for build"
    validate_release_id "${RELEASE_ID}"
    case "${promote}" in
        ""|--promote) ;;
        *) die "unknown build option: ${promote}" ;;
    esac
    case "${PUBLISH_BUILDCACHE}" in
        true|false) ;;
        *) die "PUBLISH_BUILDCACHE must be true or false" ;;
    esac

    ensure_cmd spack
    set_paths

    concretize_timeout="${CHAPAR_CONCRETIZE_TIMEOUT}"
    case "${OS_NAME}" in
        ubuntu24.04)
            case "${concretize_timeout}" in
                ""|0|*[!0-9]*) ;;
                *)
                    if [ "${concretize_timeout}" -lt 10800 ]; then
                        echo "==> Raising ${OS_NAME} concretization timeout to 10800 seconds"
                        echo "    requested: ${concretize_timeout}"
                        concretize_timeout="10800"
                    fi
                    ;;
            esac
            ;;
    esac

    # The final release location depends on the module architecture, which is
    # only known after concretization; stage at the OS root and place the
    # release under <os>/<arch>/releases once modules are generated.
    if final_dir="$(find_release_dir "${RELEASE_ID}" 2>/dev/null)"; then
        die "release already exists: ${final_dir}"
    fi
    final_dir=""
    staging_dir="${OS_ROOT}/.${RELEASE_ID}.staging.$$"
    BUILD_STAGING_DIR="${staging_dir}"
    [ ! -e "${staging_dir}" ] || die "staging path already exists: ${staging_dir}"

    prepare_release_roots
    mkdir -p "${staging_dir}/logs"
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Prepare the cache before creating the generated scope/index. This prevents
    # stale unmarked payloads from participating in concretization.
    prepare_buildcache_root
    scope_dir="$(make_scope "${staging_dir}")"
    BUILD_SCOPE_DIR="${scope_dir}"
    REFRESH_BUILDCACHE_ON_EXIT="${PUBLISH_BUILDCACHE}"
    ensure_buildcache_index

    echo "==> Building vlad release"
    echo "    os:       ${OS_NAME}"
    echo "    release:  ${RELEASE_ID}"
    echo "    env:      ${ENV_PATH}"
    echo "    store:    ${STORE_ROOT}"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    staging:  ${staging_dir}"

    read -r -a install_args <<< "${SPACK_INSTALL_ARGS}"
    trust_buildcache_keys
    case "${OS_NAME}" in
        ubuntu24.04)
            # GCC 15 is the only vlad compiler stack; bootstrap it with the OS compiler.
            install_release_prerequisite "${scope_dir}" "gcc@15+profiled %gcc" "${install_args[@]}"
            ;;
    esac

    case "${OS_NAME}" in
        ubuntu24.04)
            local llvm_targets
            case "$(spack arch --family)" in
                x86_64) llvm_targets="x86,nvptx" ;;
                aarch64) llvm_targets="aarch64,nvptx" ;;
                *) die "unsupported LLVM target family: $(spack arch --family)" ;;
            esac
            install_release_prerequisite "${scope_dir}" "llvm@21+clang+lld~lldb~flang~polly~ipo build_system=cmake targets=${llvm_targets} %gcc" "${install_args[@]}"
            ;;
    esac

    # Concretize after all reusable toolchain pieces are present so Spack can
    # prefer concrete providers and binary cache hits where hashes match.
    echo "==> Concretizing vlad environment"
    run_with_timeout "${concretize_timeout}" spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    install_cuda_libfabric_specs "${install_args[@]}"
    echo "==> Installing vlad environment"
    spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"
    echo "==> Pushing buildcache"
    spack -e "${ENV_PATH}" -C "${scope_dir}" buildcache push --unsigned --update-index "file://${BUILDCACHE_ROOT}" || echo "WARNING: buildcache push had errors (non-vlad bootstrapping packages may not be installed)"
    echo "==> Refreshing vlad root modules"
    refresh_root_modules || echo "WARNING: root module refresh had errors (Spack API may have changed)"
    if [ -d "${staging_dir}/modulefiles/linux-ubuntu24.04-x86_64" ]; then
        rm -rf "${staging_dir}/modulefiles/linux-ubuntu24.04-x86_64"
    fi

    # The module architecture decides the release's final home; resolve it
    # before applying the runtime policy, which records final paths.
    arch_triplet="$(release_arch_triplet "${staging_dir}")" || die "could not determine release architecture from ${staging_dir}"
    validate_arch_triplet "${arch_triplet}"
    final_dir="${OS_ROOT}/${arch_triplet}/releases/${RELEASE_ID}"
    [ ! -e "${final_dir}" ] || die "release already exists: ${final_dir}"
    prepare_shared_directory "${OS_ROOT}/${arch_triplet}" "${OS_NAME} ${arch_triplet} root"
    prepare_shared_directory "${OS_ROOT}/${arch_triplet}/releases" "${OS_NAME} ${arch_triplet} releases root"

    apply_release_module_runtime_policy "${staging_dir}" "${final_dir}" || echo "WARNING: module runtime policy application had errors (modules may not exist)"
    copy_manifest "${staging_dir}" "${arch_triplet}" || echo "WARNING: manifest copy had errors"

    # The final rename is the publication point. Anything before this can fail
    # without creating a partially visible release directory.
    mv "${staging_dir}" "${final_dir}"
    BUILD_STAGING_DIR=""
    echo "==> Release build complete"
    echo "    release: ${final_dir}"
    echo "    module:  ${final_dir}/modulefiles/${arch_triplet}"

    if [ "${promote}" = "--promote" ]; then
        cmd_promote "${RELEASE_ID}"
    fi

    echo ""
    echo "=== Release $RELEASE_ID complete ==="
    echo "To use modules:"
    if [ "${promote}" = "--promote" ]; then
        echo "  module use ${OS_ROOT}/${arch_triplet}/modulefiles"
    else
        echo "  module use ${final_dir}/modulefiles/${arch_triplet}"
    fi
    echo "  module avail"
}

# Explicit one-time migration command. It shares cache preparation/indexing logic
# with builds but never runs automatically from `cmd_build`.
cmd_migrate_buildcache() {
    local force="${1:-}"
    local scope_dir
    local sentinel

    case "${force}" in
        ""|--force) ;;
        *) die "unknown migrate-buildcache option: ${force}" ;;
    esac

    ensure_cmd spack
    set_paths
    trap cleanup_migration EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    prepare_buildcache_root
    scope_dir="$(make_scope "${OS_ROOT}/migration")"
    BUILD_SCOPE_DIR="${scope_dir}"

    sentinel="$(legacy_buildcache_migration_sentinel)"
    if [ "${force}" = "--force" ] && [ -e "${sentinel}" ]; then
        rm -f "${sentinel}"
    fi

    echo "==> Running one-time legacy buildcache migration"
    echo "    os:         ${OS_NAME}"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    sentinel:   ${sentinel}"
    migrate_legacy_buildcaches
}

# Promotion is intentionally a pointer update after ensuring generated modulefiles
# carry the current runtime policy. Stores remain immutable so running jobs keep
# using the package prefixes they loaded.
cmd_promote() {
    local release_id="${1:-}"
    local release_dir
    local arch_triplet
    local arch_root
    local current_link
    local link_target
    local tmp_link
    local modules_link
    local tmp_modules_link

    [ -n "${release_id}" ] || die "release-id is required for promote"
    validate_release_id "${release_id}"
    set_paths
    release_dir="$(find_release_dir "${release_id}")" || die "missing release directory for ${release_id} under ${OS_ROOT}"
    ensure_cmd perl

    arch_triplet="$(release_arch_triplet "${release_dir}")" || die "could not determine release architecture from ${release_dir}"
    validate_arch_triplet "${arch_triplet}"
    arch_root="${OS_ROOT}/${arch_triplet}"
    current_link="${arch_root}/current"
    case "${release_dir}" in
        "${arch_root}/releases/${release_id}") link_target="releases/${release_id}" ;;
        "${OS_ROOT}/releases/${release_id}") link_target="../releases/${release_id}" ;;
        *) die "unexpected release location: ${release_dir}" ;;
    esac

    prepare_shared_directory "${arch_root}" "${OS_NAME} ${arch_triplet} root"
    if [ -e "${current_link}" ] && [ ! -L "${current_link}" ]; then
        echo "==> Removing stale 'current' directory: ${current_link}"
        rm -rf "${current_link}"
    fi
    apply_release_module_runtime_policy "${release_dir}" || echo "WARNING: module runtime policy application had errors"
    prepare_shared_module_link "${release_dir}" || echo "WARNING: could not prepare shared module link"

    tmp_link="${arch_root}/.current.$$"
    rm -f "${tmp_link}"
    if ! ln -s "${link_target}" "${tmp_link}"; then
        discard_prepared_shared_module_link
        die "could not prepare current symlink: ${tmp_link}"
    fi
    # POSIX rename is atomic on the same filesystem, which avoids readers seeing
    # a missing or half-written `current` link during promotion/rollback.
    if ! perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${tmp_link}" "${current_link}"; then
        rm -f "${tmp_link}"
        discard_prepared_shared_module_link
        die "could not update current symlink: ${current_link}"
    fi

    # Stable user-facing module path: <os>/<arch>/modulefiles always follows
    # the promoted release through `current`.
    modules_link="${arch_root}/modulefiles"
    tmp_modules_link="${arch_root}/.modulefiles.$$"
    rm -f "${tmp_modules_link}"
    if [ -e "${modules_link}" ] && [ ! -L "${modules_link}" ]; then
        echo "WARNING: not updating ${modules_link}: exists and is not a symlink"
    elif ln -s "current/modulefiles/${arch_triplet}" "${tmp_modules_link}" 2>/dev/null; then
        perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${tmp_modules_link}" "${modules_link}" || {
            rm -f "${tmp_modules_link}"
            echo "WARNING: could not update modulefiles symlink: ${modules_link}"
        }
    fi

    # Retire the legacy <os>/current pointer so stale fallbacks stop resolving.
    if [ -L "${LEGACY_CURRENT_LINK}" ]; then
        echo "==> Removing legacy 'current' symlink: ${LEGACY_CURRENT_LINK}"
        rm -f "${LEGACY_CURRENT_LINK}"
    fi

    echo "==> Promoted vlad release"
    echo "    os:      ${OS_NAME}"
    echo "    arch:    ${arch_triplet}"
    echo "    current: ${current_link} -> ${link_target}"
    echo "    modules: ${modules_link} -> current/modulefiles/${arch_triplet}"
    commit_prepared_shared_module_link
}

# Publish only shared module-root symlinks. This is for sites that expose a
# stable module root such as ${CHAPAR_MODULE_ROOT}/<arch> without using the
# per-OS current symlink.
cmd_publish_modules() {
    local release_id="${1:-}"
    local release_dir

    [ -n "${release_id}" ] || die "release-id is required for publish-modules"
    validate_release_id "${release_id}"
    set_paths
    [ -n "${CHAPAR_MODULE_ROOT}" ] || die "CHAPAR_MODULE_ROOT is required for publish-modules"
    release_dir="$(find_release_dir "${release_id}")" || die "missing release directory for ${release_id} under ${OS_ROOT}"
    ensure_cmd perl

    apply_release_module_runtime_policy "${release_dir}" || echo "WARNING: module runtime policy application had errors"
    prepare_shared_module_link "${release_dir}" || echo "WARNING: could not prepare shared module link"
    echo "==> Published vlad modules"
    echo "    os:      ${OS_NAME}"
    commit_prepared_shared_module_link || {
        echo "WARNING: could not commit prepared shared module link"
        discard_prepared_shared_module_link
    }
}

# Print shell commands rather than mutating the caller's environment. Operators
# can inspect the resolved module path before evaluating it in their shell.
cmd_module_use() {
    local release_id="${1:-}"
    local release_dir
    local module_root
    local module_dir

    release_dir="$(resolve_release_dir "${release_id}")"
    module_root="${release_dir}/modulefiles"

    [ -d "${module_root}" ] || die "missing modulefiles directory: ${module_root}"

    for module_dir in "${module_root}"/*; do
        [ -d "${module_dir}" ] || continue
        case "$(basename "${module_dir}")" in
            *-*-*) printf 'module use %s\n' "${module_dir}" ;;
        esac
    done

    cat <<EOF
module avail
EOF
}

# Lightweight diagnostics for operators and CI logs.
cmd_status() {
    set_paths
    echo "install mode: ${CHAPAR_INSTALL_MODE}"
    echo "vlad root: ${VLAD_ROOT}"
    echo "buildcache root: ${CHAPAR_BUILDCACHE_ROOT}"
    echo "ccache root: ${CHAPAR_CCACHE_ROOT}"
    echo "os root:     ${OS_ROOT}"
    echo "store:       ${STORE_ROOT}"
    echo "projection:  ${CHAPAR_INSTALL_TREE_PROJECTION}"
    if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
        echo "module root: ${CHAPAR_MODULE_ROOT}"
    else
        echo "module root: (release-local)"
    fi
    echo "releases:    ${OS_ROOT}/<arch>/releases"
    echo "buildcache:  ${BUILDCACHE_ROOT}"
    echo "ccache:      ${CCACHE_ROOT}"
    local arch_root
    local arch_current_shown="false"
    for arch_root in "${OS_ROOT}"/linux-*; do
        [ -d "${arch_root}" ] || continue
        arch_current_shown="true"
        if [ -L "${arch_root}/current" ]; then
            echo "current:     ${arch_root}/current -> $(readlink "${arch_root}/current")"
        else
            echo "current:     ${arch_root}/current (none)"
        fi
    done
    if [ -L "${LEGACY_CURRENT_LINK}" ]; then
        echo "legacy:      ${LEGACY_CURRENT_LINK} -> $(readlink "${LEGACY_CURRENT_LINK}")"
    elif [ "${arch_current_shown}" = "false" ]; then
        echo "current:     (none)"
    fi
    if [ -n "${CHAPAR_MODULE_ROOT}" ] && [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        local module_link
        for module_link in "${CHAPAR_MODULE_ROOT}"/*; do
            [ -e "${module_link}" ] || [ -L "${module_link}" ] || continue
            case "$(basename "${module_link}")" in
                *-*-*) ;;
                *) continue ;;
            esac
            if [ -L "${module_link}" ]; then
                echo "module link: $(basename "${module_link}") -> $(readlink "${module_link}")"
            else
                echo "module link: $(basename "${module_link}") (not a symlink)"
            fi
        done
    fi
}

# Command dispatcher. Keep command implementations above this point so sourced or
# traced debugging sessions can inspect all helpers before main executes.
main() {
    local cmd="${1:-}"
    case "${cmd}" in
        build)
            shift
            cmd_build "$@"
            ;;
        migrate-buildcache)
            shift
            cmd_migrate_buildcache "$@"
            ;;
        promote)
            shift
            cmd_promote "$@"
            ;;
        publish-modules)
            shift
            cmd_publish_modules "$@"
            ;;
        module-use)
            shift
            cmd_module_use "$@"
            ;;
        status)
            shift
            cmd_status "$@"
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            die "unknown command: ${cmd}"
            ;;
    esac
}

main "$@"
