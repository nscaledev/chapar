#!/usr/bin/env bash
set -euo pipefail

# Tuple-bound Chapar release driver. Resolver output is the only path and policy
# authority. Builds are staged, then atomically renamed into an immutable release.

BUILD_STAGING_DIR=""
BUILD_SCOPE_DIR=""

# shellcheck source=../../etc/chapar-install-tree.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/etc/chapar-install-tree.sh"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  release.sh plan --selection <selection.json> --expected-selection-sha256 <sha256> [--operation build|promote|publish-modules|status|migrate-buildcache]
  release.sh build --selection <selection.json> --selection-digest <sha256> [--promote]
  release.sh promote --selection <selection.json> --expected-selection-sha256 <sha256>
  release.sh publish-modules --selection <selection.json> --expected-selection-sha256 <sha256>
  release.sh module-use --selection <selection.json> --expected-selection-sha256 <sha256>
  release.sh status --selection <selection.json> --expected-selection-sha256 <sha256>
  release.sh migrate-buildcache --selection <selection.json> --expected-selection-sha256 <sha256> --legacy-source <path>

The selection must be a resolver-produced selection.json beside its exact
spack.yaml and target-policy.yaml. Ambient release/cache/module path overrides
are rejected. Checkout locks are never an input.
EOF
}

reject_ambient_authority() {
    local name
    for name in ENV_PATH HPCSIM_ROOT VLAD_ROOT CHAPAR_ENV_ROOT CHAPAR_INSTALL_TREE_ROOT \
        CHAPAR_BUILDCACHE_ROOT CHAPAR_CCACHE_ROOT CHAPAR_MODULE_ROOT \
        CHAPAR_TARGET_PROFILE PUBLISH_BUILDCACHE; do
        if [ -n "${!name+x}" ]; then
            printf 'ERROR: ambient authority is forbidden: %s\n' "${name}" >&2
            printf '       etc/init.sh exports these for interactive use and sets them from a\n' >&2
            printf '       selection. Run release.sh from a clean shell instead; it derives every\n' >&2
            printf '       path from --selection and pins its own Spack scopes.\n' >&2
            exit 1
        fi
    done
}

validate_sha256() {
    case "$1" in
        ""|*[!0-9a-f]* ) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
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

# Emits one unit-separator-delimited record after validating every byte and path.
# No directory is created and no subprocess other than this read-only validator
# is launched before it succeeds.
selection_record() {
    local selection="$1"
    local expected="$2"
    local operation="$3"
    python3 - "${selection}" "${expected}" "${operation}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath

selection_path = Path(sys.argv[1])
expected = sys.argv[2]
operation = sys.argv[3]
repository_root = Path(sys.argv[4])
identifier = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
digest_re = re.compile(r"^[0-9a-f]{64}$")

def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")

def reject_symlink(path: Path, label: str) -> None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        trusted_tmp_alias = current == Path("/tmp") and current.resolve() == Path("/private/tmp")
        if current.is_symlink() and not trusted_tmp_alias:
            fail(f"{label} has symlink ambiguity: {current}")

def read_regular(path: Path, label: str) -> bytes:
    reject_symlink(path, label)
    if len(path.parts) > 1 and path.parts[1] in {"tmp", "var"}:
        alias = Path(path.anchor) / path.parts[1]
        expected_alias = Path("/private") / path.parts[1]
        if alias.is_symlink() and alias.resolve() == expected_alias:
            path = expected_alias.joinpath(*path.parts[2:])
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_flags = file_flags | getattr(os, "O_DIRECTORY", 0)
    directory = os.open(path.anchor, directory_flags)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(path.name, file_flags, dir_fd=directory)
        with os.fdopen(descriptor, "rb") as authority:
            if not stat.S_ISREG(os.fstat(authority.fileno()).st_mode):
                fail(f"{label} is not a regular file")
            return authority.read()
    except OSError as error:
        fail(f"cannot open {label}: {error}")
    finally:
        os.close(directory)

if not digest_re.fullmatch(expected):
    fail("expected selection digest must be 64 lowercase hexadecimal characters")
if not selection_path.is_absolute():
    selection_path = Path.cwd() / selection_path
reject_symlink(selection_path, "selection")
if not selection_path.is_file():
    fail("selection is not a regular file")
raw = read_regular(selection_path, "selection")
actual = hashlib.sha256(raw).hexdigest()
if actual != expected:
    fail("selection digest mismatch")
try:
    document = json.loads(raw)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"invalid selection JSON: {error}")
if not isinstance(document, dict):
    fail("selection must be an object")
if document.get("schema") != "https://nscaledev.github.io/chapar/schemas/software-selection/v1" or document.get("schema_version") != 1:
    fail("unsupported selection schema")

policy = document.get("policy")
invocation = document.get("invocation")
paths = document.get("paths")
authorities = document.get("authorities")
artifacts = document.get("artifacts")
if not all(isinstance(item, dict) for item in (policy, invocation, paths, authorities, artifacts)):
    fail("selection is missing typed policy, invocation, paths, authorities, or artifacts")

dc = policy.get("datacenter")
software_set = policy.get("software_set")
target = policy.get("target")
release_id = invocation.get("release_id")
run_id = invocation.get("run_id")
for label, value in (("datacenter", dc), ("software set", software_set), ("target", target), ("release ID", release_id), ("run ID", run_id)):
    if not isinstance(value, str) or not identifier.fullmatch(value):
        fail(f"invalid {label}")
if software_set not in {"vlad", "hpcsim", "all"}:
    fail("unknown software set")

required_paths = {
    "release_root", "release_final", "release_staging", "modulefiles",
    "install_tree", "writable_buildcache", "ccache", "container_outputs",
    "receipts", "evidence", "spack_build_stage", "image_staging",
    "validation_work", "resolver_work",
}
if set(paths) != required_paths:
    extra = sorted(set(paths) - required_paths)
    if any("seed" in name for name in extra):
        fail("seed mirrors are read-only and cannot be an autopush destination")
    fail("selection path set is incomplete or contains unknown path authority")

protected = PurePosixPath("/resources/chapar")
def related(left: PurePosixPath, right: PurePosixPath) -> bool:
    return left == right or left in right.parents or right in left.parents

for name, value in paths.items():
    if not isinstance(value, str) or any(ord(char) < 32 for char in value):
        fail(f"invalid {name} path")
    path = PurePosixPath(value)
    if not path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        fail(f"ambiguous {name} path")
    if related(path, protected):
        fail(f"{name} overlaps protected legacy path")
    reject_symlink(Path(value), name)

namespace = PurePosixPath(dc, software_set, target)
contract_path = repository_root / "datacenters" / dc / "targets" / target / "contract.json"
contract_raw = read_regular(contract_path, "target contract")
try:
    contract = json.loads(contract_raw)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"invalid target contract JSON: {error}")
if not isinstance(contract, dict) or contract.get("datacenter_id") != dc or contract.get("target") != target:
    fail("target contract identity mismatch")
try:
    durable = contract["paths"]["durable_writable"]
    temporary = contract["paths"]["temporary"]
    sharing = contract["sharing"]
    publication = contract["publication"]
except (KeyError, TypeError):
    fail("target contract path or publication policy is incomplete")
shared = [dc]
if sharing.get("share_across_software_sets") is not True:
    shared.append(software_set)
if sharing.get("share_across_targets") is not True:
    shared.append(target)
shared_namespace = PurePosixPath(*shared)
expected_paths = {
    "release_root": str(PurePosixPath(durable["releases"]) / namespace),
    "release_final": str(PurePosixPath(durable["releases"]) / namespace / release_id),
    "release_staging": str(PurePosixPath(temporary["release_staging"]) / namespace / f"{release_id}.{run_id}"),
    "modulefiles": str(PurePosixPath(durable["modulefiles"]) / namespace / release_id),
    "install_tree": str(PurePosixPath(durable["install_tree"]) / shared_namespace),
    "writable_buildcache": str(PurePosixPath(durable["writable_buildcache"]) / shared_namespace),
    "ccache": str(PurePosixPath(durable["ccache"]) / shared_namespace),
    "container_outputs": str(PurePosixPath(durable["container_outputs"]) / namespace / release_id),
    "receipts": str(PurePosixPath(durable["receipts"]) / namespace / release_id),
    "evidence": str(PurePosixPath(durable["evidence"]) / namespace / run_id),
    "spack_build_stage": str(PurePosixPath(temporary["spack_build_stage"]) / namespace / run_id),
    "image_staging": str(PurePosixPath(temporary["image_staging"]) / namespace / run_id),
    "validation_work": str(PurePosixPath(temporary["validation_work"]) / namespace / run_id),
    "resolver_work": str(PurePosixPath(temporary["resolver_work"]) / namespace / run_id),
}
if paths != expected_paths:
    fail("selection paths do not match target contract derivation")
# Mirrors tools/chapar_config/paths.py CONTAINER_PREFIX. A store prefix built here
# is copied into a container image at its identical absolute path, so a contract
# that selects a container must build inside the reserved /opt/chapar namespace.
# Re-derived rather than trusted, because release.sh never treats the selection as
# authoritative over the on-disk contract.
container_prefix = PurePosixPath("/opt/chapar")
if contract.get("container_selections"):
    install_root = PurePosixPath(durable["install_tree"])
    if container_prefix != install_root and container_prefix not in install_root.parents:
        fail("a container-selecting contract must place install_tree under /opt/chapar")
authority_paths = {
    "software_catalog": repository_root / "envs/software/spack.yaml",
    "target_registry": repository_root / "containers/images/targets.json",
    "container_registry": repository_root / "containers/images/containers.json",
    "datacenter_contract": contract_path.parents[2] / "datacenter.json",
}
expected_authorities = {name: hashlib.sha256(read_regular(path, name)).hexdigest() for name, path in authority_paths.items()}
expected_authorities["target_contract"] = hashlib.sha256(contract_raw).hexdigest()
if authorities != expected_authorities:
    fail("selection authority digests do not match current authorities")
for key in ("publish_buildcache", "publish_modules", "publish_containers", "promote_current"):
    if type(publication.get(key)) is not bool:
        fail("target contract publication policy is invalid")

release_root = PurePosixPath(paths["release_root"])
release_final = PurePosixPath(paths["release_final"])
release_staging = PurePosixPath(paths["release_staging"])
if release_final != release_root / release_id:
    fail("release final does not match tuple and release identity")
if tuple(release_root.parts[-3:]) != namespace.parts:
    fail("release root does not match tuple identity")
try:
    marker = release_staging.parts.index(".staging")
except ValueError:
    fail("release staging is not under the declared adjacent .staging root")
if PurePosixPath(*release_staging.parts[:marker]) != PurePosixPath(*release_root.parts[:-3]):
    fail("release staging and final roots do not share the declared release filesystem")
if tuple(release_staging.parts[marker + 1:-1]) != namespace.parts or release_staging.name != f"{release_id}.{run_id}":
    fail("release staging does not match tuple, release, and run identity")

suffixes = {
    "modulefiles": (*namespace.parts, release_id),
    "install_tree": namespace.parts,
    "writable_buildcache": namespace.parts,
    "ccache": namespace.parts,
    "spack_build_stage": (*namespace.parts, run_id),
}
for name, suffix in suffixes.items():
    if tuple(PurePosixPath(paths[name]).parts[-len(suffix):]) != tuple(suffix):
        fail(f"{name} does not match tuple identity")

required_authorities = {"software_catalog", "target_registry", "container_registry", "datacenter_contract", "target_contract"}
if set(authorities) != required_authorities or any(not isinstance(value, str) or not digest_re.fullmatch(value) for value in authorities.values()):
    fail("authority digests are incomplete or invalid")
manifest_digest = artifacts.get("effective_manifest_sha256")
policy_digest = artifacts.get("target_policy_sha256")
if not isinstance(manifest_digest, str) or not digest_re.fullmatch(manifest_digest):
    fail("effective manifest digest is invalid")
if not isinstance(policy_digest, str) or not digest_re.fullmatch(policy_digest):
    fail("target policy digest is invalid")

artifact_dir = selection_path.parent
manifest = artifact_dir / "spack.yaml"
target_policy = artifact_dir / "target-policy.yaml"
for artifact, digest, label in ((manifest, manifest_digest, "effective manifest"), (target_policy, policy_digest, "target policy")):
    reject_symlink(artifact, label)
    if not artifact.is_file() or hashlib.sha256(artifact.read_bytes()).hexdigest() != digest:
        fail(f"{label} digest mismatch")

final = Path(paths["release_final"])
if operation == "build" and (final.exists() or final.is_symlink()):
    fail("duplicate release ID: immutable release already exists")
if operation == "build":
    for name in ("release_staging", "spack_build_stage"):
        candidate = Path(paths[name])
        if candidate.exists() or candidate.is_symlink():
            fail(f"stale {name} path already exists")
if operation in {"promote", "publish-modules", "module-use"}:
    lock = final / "spack.lock"
    metadata = final / "metadata.json"
    reject_symlink(final, "release")
    reject_symlink(lock, "release-local lock")
    if not final.is_dir() or not lock.is_file():
        fail("promotion requires an immutable release-local spack.lock")
    if not metadata.is_file():
        fail("release metadata is missing")
    try:
        saved = json.loads(metadata.read_bytes())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"release metadata is stale or partial: {error}")
    metadata_keys = {"schema", "schema_version", "identity", "roots", "digests", "policy"}
    identity_keys = {"datacenter", "software_set", "target", "release_id", "run_id"}
    root_keys = {"release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage"}
    digest_keys = {
        "selection_sha256", "effective_manifest_sha256", "target_policy_sha256",
        "software_catalog_sha256", "target_registry_sha256", "container_registry_sha256",
        "datacenter_contract_sha256", "target_contract_sha256", "release_local_lock_sha256",
    }
    policy_keys = {"publish_buildcache", "buildcache_signed", "buildcache_autopush"}
    if not isinstance(saved, dict) or set(saved) != metadata_keys:
        fail("release metadata has missing or unknown top-level fields")
    if saved.get("schema") != "https://nscaledev.github.io/chapar/schemas/release-metadata/v1" or type(saved.get("schema_version")) is not int or saved.get("schema_version") != 1:
        fail("unsupported release metadata schema or version")
    nested = (("identity", identity_keys, str), ("roots", root_keys, str), ("digests", digest_keys, str), ("policy", policy_keys, bool))
    for name, keys, value_type in nested:
        value = saved.get(name)
        if not isinstance(value, dict) or set(value) != keys:
            fail(f"release metadata {name} has missing or unknown fields")
        if any(type(item) is not value_type for item in value.values()):
            fail(f"release metadata {name} has invalid field types")
    if any(digest_re.fullmatch(value) is None for value in saved["digests"].values()):
        fail("release metadata contains an invalid digest")
    saved_identity = saved.get("identity", {})
    expected_identity = {"datacenter": dc, "software_set": software_set, "target": target, "release_id": release_id, "run_id": run_id}
    if saved_identity != expected_identity:
        fail("release metadata identity mismatch")
    expected_roots = {key: paths[key] for key in ("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage")}
    if saved.get("roots") != expected_roots:
        fail("release metadata roots mismatch")
    expected_policy = {"publish_buildcache": publication["publish_buildcache"], "buildcache_signed": False, "buildcache_autopush": publication["publish_buildcache"]}
    if saved.get("policy") != expected_policy:
        fail("release metadata publication policy mismatch")
    saved_digests = saved.get("digests", {})
    release_files = {
        "selection_sha256": final / "selection.json",
        "effective_manifest_sha256": final / "spack.yaml",
        "target_policy_sha256": final / "target-policy.yaml",
        "release_local_lock_sha256": lock,
    }
    if any(not path.is_file() or saved_digests.get(name) != hashlib.sha256(path.read_bytes()).hexdigest() for name, path in release_files.items()):
        fail("release metadata digest mismatch")
    expected_digests = {
        "selection_sha256": actual,
        "effective_manifest_sha256": manifest_digest,
        "target_policy_sha256": policy_digest,
        "software_catalog_sha256": authorities["software_catalog"],
        "target_registry_sha256": authorities["target_registry"],
        "container_registry_sha256": authorities["container_registry"],
        "datacenter_contract_sha256": authorities["datacenter_contract"],
        "target_contract_sha256": authorities["target_contract"],
        "release_local_lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
    }
    if saved_digests != expected_digests:
        fail("release metadata authority binding mismatch")

values = [
    dc, software_set, target, release_id, run_id, actual,
    paths["release_root"], paths["release_final"], paths["release_staging"],
    paths["modulefiles"], paths["install_tree"], paths["writable_buildcache"],
    paths["ccache"], paths["spack_build_stage"], str(selection_path),
    str(manifest), str(target_policy), manifest_digest, policy_digest,
    authorities["software_catalog"], authorities["target_registry"],
    authorities["container_registry"], authorities["datacenter_contract"],
    authorities["target_contract"],
    str(publication["publish_buildcache"]).lower(), str(publication["publish_modules"]).lower(),
    str(publication["publish_containers"]).lower(), str(publication["promote_current"]).lower(),
]
print("\x1f".join(values))
PY
}

load_selection() {
    local record
    record="$(selection_record "${SELECTION_FILE}" "${EXPECTED_SELECTION_SHA256}" "${OPERATION}")" || exit $?
    IFS=$'\037' read -r DATACENTER SOFTWARE_SET TARGET RELEASE_ID RUN_ID SELECTION_SHA256 \
        RELEASE_ROOT RELEASE_FINAL RELEASE_STAGING MODULEFILES INSTALL_TREE WRITABLE_BUILDCACHE \
        CCACHE SPACK_BUILD_STAGE SELECTION_FILE EFFECTIVE_MANIFEST TARGET_POLICY \
        EFFECTIVE_MANIFEST_SHA256 TARGET_POLICY_SHA256 SOFTWARE_CATALOG_SHA256 \
        TARGET_REGISTRY_SHA256 CONTAINER_REGISTRY_SHA256 DATACENTER_CONTRACT_SHA256 \
        TARGET_CONTRACT_SHA256 PUBLISH_BUILDCACHE PUBLISH_MODULES PUBLISH_CONTAINERS \
        PROMOTE_CURRENT <<<"${record}"
}

print_plan() {
    cat <<EOF
operation: ${OPERATION}
identity: ${DATACENTER}/${SOFTWARE_SET}/${TARGET}/${RELEASE_ID}/${RUN_ID}
selection_sha256: ${SELECTION_SHA256}
release_root: ${RELEASE_ROOT}
release_staging: ${RELEASE_STAGING}
release_final: ${RELEASE_FINAL}
modulefiles: ${MODULEFILES}
install_tree: ${INSTALL_TREE}
writable_buildcache: ${WRITABLE_BUILDCACHE}
ccache: ${CCACHE}
spack_build_stage: ${SPACK_BUILD_STAGE}
spack_environment: ${RELEASE_STAGING}
bootstrap_specs: ccache
bootstrap_compiler: os external gcc, resolved from the system scope at build time
staged_roots: ${STAGED_ROOTS[*]}
ccache_dir: ${CCACHE}
staged_manifest: ${RELEASE_STAGING}/spack.yaml
release_local_lock: ${RELEASE_FINAL}/spack.lock
metadata: ${RELEASE_FINAL}/metadata.json
effective_manifest_sha256: ${EFFECTIVE_MANIFEST_SHA256}
target_policy_sha256: ${TARGET_POLICY_SHA256}
software_catalog_sha256: ${SOFTWARE_CATALOG_SHA256}
target_registry_sha256: ${TARGET_REGISTRY_SHA256}
container_registry_sha256: ${CONTAINER_REGISTRY_SHA256}
datacenter_contract_sha256: ${DATACENTER_CONTRACT_SHA256}
target_contract_sha256: ${TARGET_CONTRACT_SHA256}
checkout_lock: forbidden
publish_buildcache: ${PUBLISH_BUILDCACHE}
publish_modules: ${PUBLISH_MODULES}
publish_containers: ${PUBLISH_CONTAINERS}
promote_current: ${PROMOTE_CURRENT}
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
    local effective_padded_length
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
    cat >"${BUILD_SCOPE_DIR}/mirrors.yaml" <<EOF
mirrors:
  chapar-buildcache:
    url: file://${WRITABLE_BUILDCACHE}
    source: false
    binary: true
    signed: false
    autopush: true
EOF
    cat >"${BUILD_SCOPE_DIR}/modules.yaml" <<EOF
modules:
  default:
    roots:
      tcl: ${module_root}/modulefiles
      lmod: ${module_root}/lmod
    enable: [tcl]
    tcl:
      exclude_implicits: true
      hash_length: 0
      all:
        autoload: none
EOF
}

# The bootstrap compiler is whatever the OS scope declares as its external gcc.
# Reading it from config keeps this OS-independent: the retired helper hardcoded
# `case "${OS_NAME}" in ubuntu24.04)` around its prerequisite installs.
# Run through `spack python` rather than the system interpreter: it resolves
# scope precedence with Spack's own config API and needs no PyYAML on the
# builder, which release.sh has otherwise never required.
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
# other catalog policy applies without being restated here. The retired helper
# also preinstalled llvm because it provided the C/CXX virtuals; the catalog now
# requires gcc@15 for those, and llvm is not a root, so it is not staged.
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
    local hashes_file names_file duplicate_file root_hash module_name
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
    sort "${names_file}" | uniq -d >"${duplicate_file}"
    [ ! -s "${duplicate_file}" ] || die "duplicate hashless root module name"
    # shellcheck disable=SC2046
    spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" module tcl refresh -y $(cat "${hashes_file}")
}

write_metadata() {
    python3 - "${RELEASE_STAGING}" "${DATACENTER}" "${SOFTWARE_SET}" "${TARGET}" \
        "${RELEASE_ID}" "${RUN_ID}" "${SELECTION_SHA256}" "${EFFECTIVE_MANIFEST_SHA256}" \
        "${SOFTWARE_CATALOG_SHA256}" "${TARGET_REGISTRY_SHA256}" "${CONTAINER_REGISTRY_SHA256}" \
        "${DATACENTER_CONTRACT_SHA256}" "${TARGET_CONTRACT_SHA256}" "${RELEASE_ROOT}" \
        "${RELEASE_FINAL}" "${RELEASE_STAGING}" "${MODULEFILES}" "${INSTALL_TREE}" \
        "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}" \
        "${PUBLISH_BUILDCACHE}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
s = Path(sys.argv[1])
lock_digest = hashlib.sha256((s / "spack.lock").read_bytes()).hexdigest()
doc = {
    "schema": "https://nscaledev.github.io/chapar/schemas/release-metadata/v1",
    "schema_version": 1,
    "identity": dict(zip(("datacenter", "software_set", "target", "release_id", "run_id"), sys.argv[2:7])),
    "roots": dict(zip(("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage"), sys.argv[14:22])),
    "digests": {
        "selection_sha256": sys.argv[7], "effective_manifest_sha256": sys.argv[8],
        "target_policy_sha256": hashlib.sha256((s / "target-policy.yaml").read_bytes()).hexdigest(),
        "software_catalog_sha256": sys.argv[9], "target_registry_sha256": sys.argv[10],
        "container_registry_sha256": sys.argv[11], "datacenter_contract_sha256": sys.argv[12],
        "target_contract_sha256": sys.argv[13], "release_local_lock_sha256": lock_digest,
    },
    "policy": {"publish_buildcache": sys.argv[22] == "true", "buildcache_signed": False, "buildcache_autopush": sys.argv[22] == "true"},
}
(s / "metadata.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
PY
}

# A release build supplies its own Spack scopes. etc/system carries the OS
# externals (bootstrap compiler, libc) that the build cannot proceed without,
# and etc/init.sh -- the only other thing that sets them -- exports
# CHAPAR_INSTALL_TREE_ROOT, which reject_ambient_authority refuses. Pinning them
# here also stops a build inheriting the operator's ~/.spack.
pin_spack_scopes() {
    local repository
    repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    [ -d "${repository}/etc/system" ] || die "checkout has no etc/system scope: ${repository}"
    export SPACK_SYSTEM_CONFIG_PATH="${repository}/etc/system"
    export SPACK_USER_CONFIG_PATH="${SPACK_BUILD_STAGE}/spack-user-config"
    export SPACK_USER_CACHE_PATH="${SPACK_BUILD_STAGE}/spack-user-cache"
    mkdir -p "${SPACK_USER_CONFIG_PATH}" "${SPACK_USER_CACHE_PATH}"
}

# The contract's ccache class is only real if the compiler wrapper writes there;
# `config:ccache: true` alone would silently use the ambient cache. The umask and
# compilercheck settings matter because the cache is shared across users and
# across rebuilds of an identical compiler, where mtime checks would all miss.
configure_ccache() {
    export CCACHE_DIR="${CCACHE}"
    export CCACHE_TEMPDIR="${SPACK_BUILD_STAGE}/ccache-tmp"
    export CCACHE_BASEDIR="${SPACK_BUILD_STAGE}"
    export CCACHE_UMASK="${CCACHE_UMASK:-002}"
    export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
    mkdir -p "${CCACHE_DIR}" "${CCACHE_TEMPDIR}"
}

cmd_build() {
    command -v spack >/dev/null 2>&1 || die "required command 'spack' not found"
    mkdir -p "$(dirname "${RELEASE_STAGING}")" "$(dirname "${RELEASE_FINAL}")" \
        "${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}"
    mkdir "${RELEASE_STAGING}"
    BUILD_STAGING_DIR="${RELEASE_STAGING}"
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp "${SELECTION_FILE}" "${RELEASE_STAGING}/selection.json"
    cp "${EFFECTIVE_MANIFEST}" "${RELEASE_STAGING}/spack.yaml"
    cp "${TARGET_POLICY}" "${RELEASE_STAGING}/target-policy.yaml"
    pin_spack_scopes
    configure_ccache
    # Pass 1: ccache disabled, because ccache is not on PATH yet.
    make_scope "${RELEASE_STAGING}" false
    bootstrap_ccache
    # Pass 2: same scope, ccache now resolvable, for every remaining install.
    make_scope "${RELEASE_STAGING}" true
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

cmd_promote() {
    local module_parent
    atomic_link "${RELEASE_ID}" "${RELEASE_ROOT}/current"
    printf 'current: %s/current -> %s\n' "${RELEASE_ROOT}" "${RELEASE_ID}"
    # The modulefiles pointer resolves through <ns>/<release_id>, which only
    # publish-modules creates. Linking it unconditionally would leave a dangling
    # `current` on a contract that forbids module publication.
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
    module_parent="$(dirname "${MODULEFILES}")"
    arch_dir="$(release_module_arch)"
    mkdir -p "${module_parent}"
    atomic_link "${arch_dir}" "${MODULEFILES}"
    printf 'modulefiles: %s -> %s\n' "${MODULEFILES}" "${arch_dir}"
}

parse_common() {
    SELECTION_FILE=""
    EXPECTED_SELECTION_SHA256=""
    OPERATION="${1}"
    shift
    PROMOTE_AFTER_BUILD=false
    LEGACY_SOURCE=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --selection) [ "$#" -ge 2 ] || die "--selection requires a value"; SELECTION_FILE="$2"; shift 2 ;;
            --selection-digest|--expected-selection-sha256) [ "$#" -ge 2 ] || die "$1 requires a value"; EXPECTED_SELECTION_SHA256="$2"; shift 2 ;;
            --operation) [ "$#" -ge 2 ] || die "--operation requires a value"; OPERATION="$2"; shift 2 ;;
            --promote) PROMOTE_AFTER_BUILD=true; shift ;;
            --legacy-source) [ "$#" -ge 2 ] || die "--legacy-source requires a value"; LEGACY_SOURCE="$2"; shift 2 ;;
            --lock) die "checkout lock inputs are forbidden" ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    [ -n "${SELECTION_FILE}" ] || die "--selection is required"
    [ -n "${EXPECTED_SELECTION_SHA256}" ] || die "--selection-digest is required"
    validate_sha256 "${EXPECTED_SELECTION_SHA256}" || die "invalid expected selection digest"
    case "${OPERATION}" in build|promote|publish-modules|module-use|status|migrate-buildcache) ;;
        *) die "unknown operation: ${OPERATION}" ;;
    esac
    reject_ambient_authority
    load_selection
}

main() {
    local command="${1:-}" module_arch
    case "${command}" in
        -h|--help|help|"") usage; return 0 ;;
    esac
    shift
    if [ "${command}" = plan ]; then
        parse_common build "$@"
        print_plan
        return 0
    fi
    parse_common "${command}" "$@"
    case "${command}" in
        build)
            cmd_build
            if [ "${PROMOTE_AFTER_BUILD}" = true ]; then
                [ "${PROMOTE_CURRENT}" = true ] || die "target contract forbids promotion"
                OPERATION=promote
                load_selection
                # Promotion repoints <ns>/current at the release ID under the
                # modulefiles root; without publication that name does not exist.
                [ "${PUBLISH_MODULES}" = false ] || cmd_publish_modules
                cmd_promote
            fi
            ;;
        promote) [ "${PROMOTE_CURRENT}" = true ] || die "target contract forbids promotion"; cmd_promote ;;
        publish-modules) [ "${PUBLISH_MODULES}" = true ] || die "target contract forbids module publication"; cmd_publish_modules ;;
        # Assign first: a failing command substitution inside printf's argument
        # list would print an empty path and still exit 0.
        module-use) module_arch="$(release_module_arch)"; printf 'module use %s\n' "${module_arch}" ;;
        status) print_plan ;;
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
