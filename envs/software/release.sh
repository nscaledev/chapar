#!/usr/bin/env bash
set -euo pipefail

# Tuple-bound Chapar release driver. Identity (CHAPAR_SOFTWARE_SET,
# CHAPAR_TARGET) and every path root come from the site settings via
# etc/chapar-defaults.sh; target facts come from the committed registry.
# Builds are staged, then atomically renamed into an immutable release.

BUILD_STAGING_DIR=""
BUILD_SCOPE_DIR=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../../etc/chapar-install-tree.sh
. "${REPO_ROOT}/etc/chapar-install-tree.sh"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  release.sh plan            <release-id> [--set SET] [--target TARGET]
  release.sh build           <release-id> [--set SET] [--target TARGET] [--promote]
  release.sh promote         <release-id> [--set SET] [--target TARGET]
  release.sh publish-modules <release-id> [--set SET] [--target TARGET]
  release.sh module-use      <release-id> [--set SET] [--target TARGET]
  release.sh status          <release-id> [--set SET] [--target TARGET]
  release.sh migrate-buildcache <release-id> --legacy-source <path> [--set SET] [--target TARGET]

Identity and paths come from the site settings (etc/chapar-site.env via
etc/chapar-defaults.sh); --set/--target override CHAPAR_SOFTWARE_SET and
CHAPAR_TARGET for this invocation. CHAPAR_TARGET must be a key of
containers/images/targets.json. Delivery policy:
  publish-modules requires "modules" in CHAPAR_DELIVER
  promote requires PUBLISH_CURRENT=true
  buildcache publication requires PUBLISH_BUILDCACHE=true

Layout under the site roots:
  ${CHAPAR_RELEASE_ROOT}/<set>/<target>/<release-id>   immutable release
  ${CHAPAR_RELEASE_ROOT}/<set>/<target>/current        promotion pointer
  ${CHAPAR_MODULE_ROOT}/<set>/<target>/<release-id> and current published modules
  ${CHAPAR_INSTALL_TREE_ROOT}                                   shared padded store
  ${CHAPAR_BUILDCACHE_ROOT}/<target>, ${CHAPAR_CCACHE_ROOT}/<target>
EOF
}

validate_identifier() {
    case "$1" in
        ""|*[!a-z0-9._-]*) return 1 ;;
    esac
    case "$1" in
        [a-z0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup_build() {
    local status=$?
    trap - EXIT INT TERM
    if [ "${status}" -ne 0 ] && [ -n "${BUILD_STAGING_DIR}" ]; then
        rm -rf -- "${BUILD_STAGING_DIR}"
    fi
    if [ -n "${BUILD_SCOPE_DIR}" ]; then
        rm -rf -- "${BUILD_SCOPE_DIR}"
    fi
    exit "${status}"
}

# The chapar package is used stdlib-only from the checkout: builders need
# python3 but neither uv nor an installed wheel.
chapar_cli() {
    PYTHONPATH="${REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}" python3 -m chapar "$@"
}

# Derive every path for the current tuple. Requires chapar_apply_defaults to
# have run (identity exported and validated) and CHAPAR_TARGET registered.
derive_paths() {
    [ -n "${CHAPAR_TARGET}" ] || die "CHAPAR_TARGET is required: set it in the site settings or pass --target"
    chapar_cli target scope --target "${CHAPAR_TARGET}" >/dev/null || exit $?
    TUPLE="${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}"
    RELEASE_ROOT="${CHAPAR_RELEASE_ROOT}/${TUPLE}"
    RELEASE_FINAL="${RELEASE_ROOT}/${RELEASE_ID}"
    RELEASE_STAGING="${RELEASE_ROOT}/.staging/${RELEASE_ID}.${RUN_ID}"
    MODULEFILES="${CHAPAR_MODULE_ROOT}/${TUPLE}/${RELEASE_ID}"
    INSTALL_TREE="${CHAPAR_INSTALL_TREE_ROOT}"
    WRITABLE_BUILDCACHE="${CHAPAR_BUILDCACHE_ROOT}/${CHAPAR_TARGET}"
    CCACHE="${CHAPAR_CCACHE_ROOT}/${CHAPAR_TARGET}"
    SPACK_BUILD_STAGE="${CHAPAR_BUILD_STAGE_ROOT}/${TUPLE}/${RELEASE_ID}.${RUN_ID}"
}

deliver_enabled() {
    case " ${CHAPAR_DELIVER} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

print_plan() {
    cat <<EOF
operation: ${OPERATION}
identity: ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}/${RELEASE_ID}/${RUN_ID}
site_config: ${CHAPAR_SITE_CONFIG:-${CHAPAR_ROOT}/etc/chapar-site.env}
release_root: ${RELEASE_ROOT}
release_staging: ${RELEASE_STAGING}
release_final: ${RELEASE_FINAL}
modulefiles: ${MODULEFILES}
install_tree: ${INSTALL_TREE}
writable_buildcache: ${WRITABLE_BUILDCACHE}
ccache: ${CCACHE}
spack_build_stage: ${SPACK_BUILD_STAGE}
spack_environment: ${RELEASE_STAGING}
catalog: ${REPO_ROOT}/envs/software/spack.yaml
target_registry: ${REPO_ROOT}/containers/images/targets.json
target_scope: rendered per target by 'chapar target scope --target ${CHAPAR_TARGET}'
bootstrap_specs: ccache
bootstrap_compiler: os external gcc, resolved from the system scope at build time
staged_roots: ${STAGED_ROOTS[*]}
ccache_dir: ${CCACHE}
staged_manifest: ${RELEASE_STAGING}/spack.yaml
release_local_lock: ${RELEASE_FINAL}/spack.lock
metadata: ${RELEASE_FINAL}/metadata.json
module_systems: ${CHAPAR_MODULE_SYSTEMS}
deliver: ${CHAPAR_DELIVER}
seed_mirrors: ${CHAPAR_SEED_MIRRORS:-none}
publish_buildcache: ${PUBLISH_BUILDCACHE}
publish_current: ${PUBLISH_CURRENT}
buildcache_signed: false
buildcache_autopush: ${PUBLISH_BUILDCACHE}
EOF
}

# make_scope <module root> <ccache enabled>
#
# ccache must be false for the bootstrap pass. Spack resolves the binary with
# which_string("ccache", required=True), which searches PATH only and raises
# when it is missing -- so enabling ccache before ccache itself is installed
# would abort the build that installs it.
make_scope() {
    local module_root="$1"
    local ccache_enabled="$2"
    local effective_padded_length seed index=0
    BUILD_SCOPE_DIR="${SPACK_BUILD_STAGE}/command-line-scope"
    mkdir -p "${BUILD_SCOPE_DIR}"
    effective_padded_length="$(install_tree_padded_length "${INSTALL_TREE}")"
    cat >"${BUILD_SCOPE_DIR}/config.yaml" <<EOF
config:
  install_tree:
    root: ${INSTALL_TREE}
    padded_length: ${effective_padded_length}
    projections:
      all: "{architecture.platform}-{architecture.target}/{name}-{version}-{hash}"
  build_stage:
  - ${SPACK_BUILD_STAGE}/stage
  ccache: ${ccache_enabled}
EOF
    printf 'mirrors:\n' >"${BUILD_SCOPE_DIR}/mirrors.yaml"
    for seed in ${CHAPAR_SEED_MIRRORS}; do
        index=$((index + 1))
        cat >>"${BUILD_SCOPE_DIR}/mirrors.yaml" <<EOF
  chapar-seed-$(printf '%03d' "${index}"):
    url: file://${seed}
    source: false
    binary: true
    signed: false
    autopush: false
EOF
    done
    cat >>"${BUILD_SCOPE_DIR}/mirrors.yaml" <<EOF
  chapar-buildcache:
    url: file://${WRITABLE_BUILDCACHE}
    source: false
    binary: true
    signed: false
    autopush: ${PUBLISH_BUILDCACHE}
EOF
    {
        printf 'modules:\n  default:\n    roots:\n'
        printf '      tcl: %s/modulefiles\n' "${module_root}"
        printf '      lmod: %s/lmod\n' "${module_root}"
        printf '    enable: [%s]\n' "$(printf '%s' "${CHAPAR_MODULE_SYSTEMS}" | tr ' ' ',')"
        printf '    tcl:\n      exclude_implicits: true\n      hash_length: 0\n      all:\n        autoload: none\n'
        if deliver_module_system lmod; then
            printf '    lmod:\n      exclude_implicits: true\n      hash_length: 0\n      all:\n        autoload: none\n'
        fi
    } >"${BUILD_SCOPE_DIR}/modules.yaml"
    # Target facts as package requirements: binds transitive instances (gdrcopy
    # under ucx) that root-spec decoration cannot reach.
    chapar_cli target scope --target "${CHAPAR_TARGET}" --output "${BUILD_SCOPE_DIR}"
}

deliver_module_system() {
    case " ${CHAPAR_MODULE_SYSTEMS} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# The bootstrap compiler is whatever the OS scope declares as its external gcc.
# Reading it from config keeps this OS-independent. Run through `spack python`
# rather than the system interpreter: it resolves scope precedence with Spack's
# own config API and needs no PyYAML on the builder.
bootstrap_compiler() {
    spack -C "${BUILD_SCOPE_DIR}" python -c '
import spack.config
externals = spack.config.get("packages:gcc:externals", [])
if not externals:
    raise SystemExit("ERROR: no external gcc declared for this OS; cannot bootstrap")
# "gcc@13 languages:=c,c++,fortran" -> "gcc@13"
specification = str(externals[0].get("spec", "")).split()[0]
if "@" not in specification:
    raise SystemExit("ERROR: external gcc spec has no version: " + specification)
print(specification)
'
}

# Install one spec outside the environment, idempotently. Bootstrap specs cannot
# be environment roots: the catalog requires c/cxx/fortran -> gcc@15, so an
# in-environment ccache would need gcc@15 built first, which is the build ccache
# exists to accelerate.
bootstrap_install() {
    if ! spack -C "${BUILD_SCOPE_DIR}" find "$@" >/dev/null 2>&1; then
        echo "==> Bootstrapping $*"
        spack -C "${BUILD_SCOPE_DIR}" install "$@"
    fi
    spack -C "${BUILD_SCOPE_DIR}" location -i "$@"
}

# Build ccache with the OS compiler and put it on PATH before anything else, so
# the compiler build itself goes through it. The version-pinned compiler is what
# disambiguates: once the environment's own gcc@15-built ccache root exists, a
# bare `ccache` query would match two installs.
bootstrap_ccache() {
    local compiler prefix
    compiler="$(bootstrap_compiler)" || exit $?
    prefix="$(bootstrap_install ccache "%${compiler}")" || exit $?
    [ -x "${prefix}/bin/ccache" ] || die "bootstrapped ccache has no binary: ${prefix}/bin/ccache"
    export PATH="${prefix}/bin:${PATH}"
    echo "==> ccache: ${prefix}/bin/ccache (built with ${compiler})"
}

# Roots to install before the rest of the environment, in order. Names only: the
# specs come from the concretized lock, so gcc@15's +profiled variant and any
# other catalog policy applies without being restated here.
STAGED_ROOTS=(gcc)

staged_root_hash() {
    python3 - "${RELEASE_STAGING}/spack.lock" "$1" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_bytes())
concrete = document.get("concrete_specs", {})
for root in document.get("roots", []):
    digest = root.get("hash")
    node = concrete.get(digest) or {}
    if digest and node.get("name") == sys.argv[2]:
        print(digest)
        break
PY
}

install_staged_roots() {
    local name hash
    for name in "${STAGED_ROOTS[@]}"; do
        hash="$(staged_root_hash "${name}")"
        [ -n "${hash}" ] || continue
        echo "==> Installing staged root: ${name}"
        spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" install --only-concrete "/${hash}"
    done
}

root_hashes() {
    python3 - "${RELEASE_STAGING}/spack.lock" <<'PY'
import json
import sys
from pathlib import Path
for root in json.loads(Path(sys.argv[1]).read_bytes()).get("roots", []):
    value = root.get("hash")
    if value:
        print(f"/{value}")
PY
}

refresh_root_modules() {
    local hashes_file names_file duplicate_file root_hash module_name system
    hashes_file="${BUILD_SCOPE_DIR}/root-hashes.txt"
    names_file="${BUILD_SCOPE_DIR}/root-module-names.txt"
    duplicate_file="${BUILD_SCOPE_DIR}/duplicate-root-module-names.txt"
    root_hashes >"${hashes_file}"
    [ -s "${hashes_file}" ] || die "release-local lock has no concrete roots"
    : >"${names_file}"
    while IFS= read -r root_hash; do
        module_name="$(spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" find --no-groups --format '{name}/{version}' "${root_hash}")"
        printf '%s\n' "${module_name}" >>"${names_file}"
    done <"${hashes_file}"
    # Hashless names must be unique; the check is module-system independent.
    sort "${names_file}" | uniq -d >"${duplicate_file}"
    [ ! -s "${duplicate_file}" ] || die "duplicate hashless root module name"
    for system in ${CHAPAR_MODULE_SYSTEMS}; do
        # shellcheck disable=SC2046
        spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" module "${system}" refresh -y $(cat "${hashes_file}")
    done
}

# Release metadata v2: identity, verbatim target facts, release-local digests,
# and delivery policy. This file plus spack.lock is the release's complete
# self-description; containers, validation, and CVE consumers read it instead
# of re-deriving anything from ambient state.
write_metadata() {
    python3 - "${RELEASE_STAGING}" "${REPO_ROOT}/containers/images/targets.json" \
        "${CHAPAR_SOFTWARE_SET}" "${CHAPAR_TARGET}" "${RELEASE_ID}" "${RUN_ID}" \
        "${RELEASE_ROOT}" "${RELEASE_FINAL}" "${RELEASE_STAGING}" "${MODULEFILES}" \
        "${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}" \
        "${PUBLISH_BUILDCACHE}" "${CHAPAR_DELIVER}" "${CHAPAR_MODULE_SYSTEMS}" \
        "${BUILD_SCOPE_DIR}/packages.yaml" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

staging = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
software_set, target, release_id, run_id = sys.argv[3:7]

registry_bytes = registry_path.read_bytes()
targets = json.loads(registry_bytes).get("targets", {})
facts = targets.get(target)
if facts is None:
    raise SystemExit(f"ERROR: target vanished from the registry: {target}")

document = {
    "schema": "https://nscaledev.github.io/chapar/schemas/release-metadata/v2",
    "schema_version": 2,
    "identity": {
        "software_set": software_set,
        "target": target,
        "release_id": release_id,
        "run_id": run_id,
    },
    "target_facts": facts,
    "roots": dict(
        zip(
            (
                "release_root", "release_final", "release_staging", "modulefiles",
                "install_tree", "writable_buildcache", "ccache", "spack_build_stage",
            ),
            sys.argv[7:15],
        )
    ),
    "digests": {
        "software_catalog_sha256": hashlib.sha256((staging / "spack.yaml").read_bytes()).hexdigest(),
        "target_registry_sha256": hashlib.sha256(registry_bytes).hexdigest(),
        "target_scope_sha256": hashlib.sha256((staging / "target-scope.yaml").read_bytes()).hexdigest(),
        "release_local_lock_sha256": hashlib.sha256((staging / "spack.lock").read_bytes()).hexdigest(),
    },
    "policy": {
        "publish_buildcache": sys.argv[15] == "true",
        "buildcache_signed": False,
        "buildcache_autopush": sys.argv[15] == "true",
        "deliver": sys.argv[16].split(),
        "module_systems": sys.argv[17].split(),
    },
}
(staging / "metadata.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
}

# A release build pins its own Spack scopes so nothing leaks in from ~/.spack
# or /etc/spack. etc/system carries the OS externals (bootstrap compiler,
# libc); etc/user carries the $CHAPAR_* interpolations the site settings
# export, so the same user scope serves interactive shells and builds.
pin_spack_scopes() {
    [ -d "${REPO_ROOT}/etc/system" ] || die "checkout has no etc/system scope: ${REPO_ROOT}"
    export SPACK_SYSTEM_CONFIG_PATH="${REPO_ROOT}/etc/system"
    export SPACK_USER_CONFIG_PATH="${REPO_ROOT}/etc/user"
    export SPACK_USER_CACHE_PATH="${SPACK_BUILD_STAGE}/spack-user-cache"
    mkdir -p "${SPACK_USER_CACHE_PATH}"
}

# The site ccache class is only real if the compiler wrapper writes there;
# `config:ccache: true` alone would silently use the ambient cache. The umask
# and compilercheck settings matter because the cache is shared across users
# and across rebuilds of an identical compiler, where mtime checks would miss.
configure_ccache() {
    export CCACHE_DIR="${CCACHE}"
    export CCACHE_TEMPDIR="${SPACK_BUILD_STAGE}/ccache-tmp"
    export CCACHE_BASEDIR="${SPACK_BUILD_STAGE}"
    export CCACHE_UMASK="${CCACHE_UMASK:-002}"
    export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-${CHAPAR_CCACHE_COMPILERCHECK}}"
    if [ -n "${CHAPAR_CCACHE_MAXSIZE}" ]; then
        export CCACHE_MAXSIZE="${CHAPAR_CCACHE_MAXSIZE}"
    fi
    mkdir -p "${CCACHE_DIR}" "${CCACHE_TEMPDIR}"
}

cmd_build() {
    if [ -e "${RELEASE_FINAL}" ] || [ -L "${RELEASE_FINAL}" ]; then
        die "duplicate release ID: immutable release already exists: ${RELEASE_FINAL}"
    fi
    if [ -e "${RELEASE_STAGING}" ] || [ -L "${RELEASE_STAGING}" ]; then
        die "stale release staging already exists: ${RELEASE_STAGING}"
    fi
    command -v spack >/dev/null 2>&1 || die "required command 'spack' not found"
    mkdir -p "$(dirname "${RELEASE_STAGING}")" "$(dirname "${RELEASE_FINAL}")" \
        "${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}"
    mkdir "${RELEASE_STAGING}"
    BUILD_STAGING_DIR="${RELEASE_STAGING}"
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Copy the catalog first: the staged manifest is what this release builds,
    # even if the checkout changes mid-build.
    cp "${REPO_ROOT}/envs/software/spack.yaml" "${RELEASE_STAGING}/spack.yaml"
    pin_spack_scopes
    configure_ccache
    # Pass 1: ccache disabled, because ccache is not on PATH yet.
    make_scope "${RELEASE_STAGING}" false
    bootstrap_ccache
    # Pass 2: same scope, ccache now resolvable, for every remaining install.
    make_scope "${RELEASE_STAGING}" true
    cp "${BUILD_SCOPE_DIR}/packages.yaml" "${RELEASE_STAGING}/target-scope.yaml"
    spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" concretize -f
    install_staged_roots
    spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" install --only-concrete
    refresh_root_modules
    if [ "${PUBLISH_BUILDCACHE}" = true ]; then
        spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" buildcache push --unsigned --update-index --allow-missing "file://${WRITABLE_BUILDCACHE}"
    fi
    [ -f "${RELEASE_STAGING}/spack.lock" ] || die "Spack did not create the staged release-local lock"
    write_metadata
    publish_release "${RELEASE_STAGING}" "${RELEASE_FINAL}"
    BUILD_STAGING_DIR=""
    rm -rf -- "${BUILD_SCOPE_DIR}"
    BUILD_SCOPE_DIR=""
    trap - EXIT INT TERM
    printf 'release: %s\n' "${RELEASE_FINAL}"
}

# Rename the staged tree onto its immutable destination. `mv` would move the
# staging directory *inside* an existing release rather than failing, so a
# concurrent run reusing the release ID could corrupt an already-published
# release. rename(2) replaces only an empty destination and reports ENOTEMPTY
# otherwise, which is the fail-closed behaviour this step needs.
publish_release() {
    python3 - "$1" "$2" <<'PY'
import os
import sys

try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as error:
    raise SystemExit(f"ERROR: cannot publish immutable release: {error}")
PY
}

atomic_link() {
    local target="$1" link="$2" temporary
    if [ -e "${link}" ] && [ ! -L "${link}" ]; then
        # Documented auto-repair, but only for the promotion pointer: any other
        # occupied destination is real content and must not be removed here.
        [ "$(basename "${link}")" = current ] || die "link destination is not a symlink: ${link}"
        echo "==> Removing stale 'current' directory: ${link}"
        rm -rf -- "${link}"
    fi
    temporary="${link}.tmp.${RUN_ID}"
    rm -f -- "${temporary}"
    ln -s "${target}" "${temporary}"
    mv -f -- "${temporary}" "${link}"
}

# Spack writes modules to <tcl root>/<platform-os-target>/<name>/<version>, so
# every `module use` target is the architecture directory, not its parent.
release_module_arch() {
    local modules="${RELEASE_FINAL}/modulefiles" arch_dir count
    [ -d "${modules}" ] || die "release has no generated modulefiles: ${modules}"
    count="$(find "${modules}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    [ "${count}" -eq 1 ] || die "release must contain exactly one module architecture, found ${count}"
    arch_dir="$(find "${modules}" -mindepth 1 -maxdepth 1 -type d)"
    printf '%s\n' "${arch_dir}"
}

require_release() {
    [ -d "${RELEASE_FINAL}" ] || die "release does not exist: ${RELEASE_FINAL}"
    [ -f "${RELEASE_FINAL}/spack.lock" ] || die "release has no release-local spack.lock"
    [ -f "${RELEASE_FINAL}/metadata.json" ] || die "release has no metadata.json"
}

cmd_promote() {
    local module_parent
    require_release
    atomic_link "${RELEASE_ID}" "${RELEASE_ROOT}/current"
    printf 'current: %s/current -> %s\n' "${RELEASE_ROOT}" "${RELEASE_ID}"
    # The modulefiles pointer resolves through <ns>/<release_id>, which only
    # publish-modules creates. Linking it unconditionally would leave a dangling
    # `current` where module delivery is not enabled.
    if [ -e "${MODULEFILES}" ] || [ -L "${MODULEFILES}" ]; then
        module_parent="$(dirname "${MODULEFILES}")"
        atomic_link "${RELEASE_ID}" "${module_parent}/current"
        printf 'modulefiles current: %s/current -> %s\n' "${module_parent}" "${RELEASE_ID}"
    else
        printf 'modulefiles current: skipped, no published modulefiles\n'
    fi
}

cmd_publish_modules() {
    local module_parent arch_dir
    require_release
    module_parent="$(dirname "${MODULEFILES}")"
    arch_dir="$(release_module_arch)"
    mkdir -p "${module_parent}"
    atomic_link "${arch_dir}" "${MODULEFILES}"
    printf 'modulefiles: %s -> %s\n' "${MODULEFILES}" "${arch_dir}"
}

parse_common() {
    OPERATION="$1"
    shift
    RELEASE_ID=""
    PROMOTE_AFTER_BUILD=false
    LEGACY_SOURCE=""
    local set_override="" target_override=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --set) [ "$#" -ge 2 ] || die "--set requires a value"; set_override="$2"; shift 2 ;;
            --target) [ "$#" -ge 2 ] || die "--target requires a value"; target_override="$2"; shift 2 ;;
            --release-id) [ "$#" -ge 2 ] || die "--release-id requires a value"; RELEASE_ID="$2"; shift 2 ;;
            --promote) PROMOTE_AFTER_BUILD=true; shift ;;
            --legacy-source) [ "$#" -ge 2 ] || die "--legacy-source requires a value"; LEGACY_SOURCE="$2"; shift 2 ;;
            --selection|--selection-digest|--expected-selection-sha256)
                die "selections were retired: identity comes from the site settings (see etc/chapar-site.env.example)" ;;
            -*) die "unknown argument: $1" ;;
            *)
                [ -z "${RELEASE_ID}" ] || die "unexpected argument: $1"
                RELEASE_ID="$1"; shift ;;
        esac
    done
    [ -n "${RELEASE_ID}" ] || die "release ID is required"
    validate_identifier "${RELEASE_ID}" || die "invalid release ID: ${RELEASE_ID}"
    # Export identity overrides before the defaults run so the site policy
    # function sees the final tuple.
    [ -z "${set_override}" ] || export CHAPAR_SOFTWARE_SET="${set_override}"
    [ -z "${target_override}" ] || export CHAPAR_TARGET="${target_override}"
    # shellcheck source=../../etc/chapar-defaults.sh
    . "${REPO_ROOT}/etc/chapar-defaults.sh" || exit 1
    RUN_ID="${CHAPAR_RUN_ID:-$(date +%Y%m%d-%H%M%S).$$}"
    validate_identifier "${RUN_ID}" || die "invalid run ID: ${RUN_ID}"
    derive_paths
}

main() {
    local command="${1:-}" module_arch
    case "${command}" in
        -h|--help|help|"") usage; return 0 ;;
    esac
    shift
    case "${command}" in
        plan|status)
            OPERATION="${command}"
            parse_common build "$@"
            OPERATION="${command}"
            print_plan
            return 0
            ;;
        build|promote|publish-modules|module-use|migrate-buildcache) parse_common "${command}" "$@" ;;
        *) die "unknown command: ${command}" ;;
    esac
    case "${command}" in
        build)
            cmd_build
            if [ "${PROMOTE_AFTER_BUILD}" = true ]; then
                [ "${PUBLISH_CURRENT}" = true ] || die "site settings forbid promotion: PUBLISH_CURRENT is not true"
                # Promotion repoints <ns>/current at the release ID under the
                # modulefiles root; without publication that name does not exist.
                if deliver_enabled modules; then
                    cmd_publish_modules
                fi
                cmd_promote
            fi
            ;;
        promote)
            [ "${PUBLISH_CURRENT}" = true ] || die "site settings forbid promotion: PUBLISH_CURRENT is not true"
            cmd_promote
            ;;
        publish-modules)
            deliver_enabled modules || die "delivery policy for ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET} does not include modules (CHAPAR_DELIVER=${CHAPAR_DELIVER})"
            cmd_publish_modules
            ;;
        # Assign first: a failing command substitution inside printf's argument
        # list would print an empty path and still exit 0.
        module-use) module_arch="$(release_module_arch)"; printf 'module use %s\n' "${module_arch}" ;;
        migrate-buildcache)
            [ -n "${LEGACY_SOURCE}" ] || die "explicit --legacy-source is required"
            [ -d "${LEGACY_SOURCE}" ] || die "legacy source is not a directory"
            # Resolve first: a literal prefix test lets a symlinked source reach
            # the protected legacy roots the guard exists to keep out.
            LEGACY_SOURCE="$(realpath -e -- "${LEGACY_SOURCE}")" || die "legacy source cannot be resolved"
            case "${LEGACY_SOURCE}" in /resources/chapar|/resources/chapar/*) die "legacy source overlaps protected path" ;; esac
            mkdir -p "${WRITABLE_BUILDCACHE}"
            cp -nR "${LEGACY_SOURCE}/." "${WRITABLE_BUILDCACHE}/"
            ;;
    esac
}

main "$@"
