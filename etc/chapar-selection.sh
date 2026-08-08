#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# shellcheck source=chapar-install-tree.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chapar-install-tree.sh"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

path_relation() {
    [ "$1" = "$2" ] && return 0
    [ "$1" = / ] || [ "$2" = / ] && return 0
    case "$1" in "$2"/*) return 0 ;; esac
    case "$2" in "$1"/*) return 0 ;; esac
    return 1
}

canonical_path() {
    local input="$1" output="" part
    [[ "${input}" = /* ]] || fail "selected path must be absolute"
    IFS='/' read -r -a parts <<< "${input}"
    for part in "${parts[@]}"; do
        case "${part}" in
            ""|.) continue ;;
            ..) fail "selected path contains traversal" ;;
            *) output="${output}/${part}" ;;
        esac
    done
    [ -n "${output}" ] || output="/"
    printf '%s\n' "${output}"
}

reject_symlink_components() {
    local value="$1" current="/" part parts
    IFS='/' read -r -a parts <<< "${value#/}"
    for part in "${parts[@]}"; do
        [ -n "${part}" ] || continue
        current="${current%/}/${part}"
        [ ! -L "${current}" ] || fail "selected path has symlink ambiguity: ${current}"
    done
}

# The published modulefiles pointer is a symlink by design -- publish-modules
# creates it so consumers get a release-id-stable name for the architecture
# directory inside the immutable release. Only its ancestors must be literal.
reject_symlink_ancestors() {
    local value="$1"
    reject_symlink_components "$(dirname "${value}")"
}

verify_selection() {
    SELECTION_PATH="$1"
    EXPECTED_SELECTION_SHA256="$2"
    CONTRACT_PATH="$3"

    local sealed_dir
    sealed_dir="$(python3 - "${SELECTION_PATH}" "${EXPECTED_SELECTION_SHA256}" "${CONTRACT_PATH}" "${command}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result

def read_regular(path: Path, label: str) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be absolute without traversal")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            trusted = current in {Path("/tmp"), Path("/var")} and current.resolve() == Path("/private") / current.name
            if not trusted:
                fail(f"{label} has symlink ambiguity: {current}")
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
        with os.fdopen(descriptor, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                fail(f"{label} is not a regular file")
            return source.read()
    except OSError as error:
        fail(f"cannot open {label}: {error}")
    finally:
        os.close(directory)

selection_path, expected, supplied_contract, operation, repository = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5])
if len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected):
    fail("selection digest must be lowercase SHA-256")
selection = read_regular(selection_path, "selection")
if hashlib.sha256(selection).hexdigest() != expected:
    fail("selection digest mismatch")
try:
    selection_document = json.loads(selection, object_pairs_hook=unique)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"invalid selection JSON: {error}")
policy = selection_document.get("policy", {})
invocation = selection_document.get("invocation", {})
if not isinstance(policy, dict) or not isinstance(invocation, dict):
    fail("selection policy or invocation is missing")
datacenter, software_set, target = (policy.get(name) for name in ("datacenter", "software_set", "target"))
release_id, run_id = (invocation.get(name) for name in ("release_id", "run_id"))
identity = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
if any(not isinstance(value, str) or identity.fullmatch(value) is None for value in (datacenter, software_set, target, release_id, run_id)):
    fail("selection identity is invalid")
canonical_contract = repository / "datacenters" / datacenter / "targets" / target / "contract.json"
if supplied_contract != canonical_contract:
    fail("target contract is not the canonical datacenter authority")
contract = read_regular(canonical_contract, "contract")
datacenter_contract = read_regular(repository / "datacenters" / datacenter / "datacenter.json", "datacenter contract")
catalog = read_regular(repository / "envs/software/spack.yaml", "software catalog")
targets = read_regular(repository / "containers/images/targets.json", "target registry")
containers = read_regular(repository / "containers/images/containers.json", "container registry")
manifest = read_regular(selection_path.parent / "spack.yaml", "effective manifest")
target_policy = read_regular(selection_path.parent / "target-policy.yaml", "target policy")
authorities = selection_document.get("authorities")
expected_authorities = {
    "software_catalog": hashlib.sha256(catalog).hexdigest(),
    "target_registry": hashlib.sha256(targets).hexdigest(),
    "container_registry": hashlib.sha256(containers).hexdigest(),
    "datacenter_contract": hashlib.sha256(datacenter_contract).hexdigest(),
    "target_contract": hashlib.sha256(contract).hexdigest(),
}
if authorities != expected_authorities:
    fail("selection authority digests do not match canonical authorities")
artifacts = selection_document.get("artifacts")
if artifacts != {"effective_manifest_sha256": hashlib.sha256(manifest).hexdigest(), "target_policy_sha256": hashlib.sha256(target_policy).hexdigest()}:
    fail("selection-local artifact digests do not match exact bytes")
contract_document = json.loads(contract, object_pairs_hook=unique)
durable = contract_document.get("paths", {}).get("durable_writable", {})
temporary = contract_document.get("paths", {}).get("temporary", {})
sharing = contract_document.get("sharing", {})
namespace = (datacenter, software_set, target)
shared = [datacenter]
if sharing.get("share_across_software_sets") is not True:
    shared.append(software_set)
if sharing.get("share_across_targets") is not True:
    shared.append(target)
def child(root, *parts):
    if not isinstance(root, str) or not root.startswith("/"):
        fail("target contract path root is invalid")
    return str(Path(root).joinpath(*parts))
expected_paths = {
    "release_root": child(durable.get("releases"), *namespace),
    "release_final": child(durable.get("releases"), *namespace, release_id),
    "release_staging": child(temporary.get("release_staging"), *namespace, f"{release_id}.{run_id}"),
    "modulefiles": child(durable.get("modulefiles"), *namespace, release_id),
    "install_tree": child(durable.get("install_tree"), *shared),
    "writable_buildcache": child(durable.get("writable_buildcache"), *shared),
    "ccache": child(durable.get("ccache"), *shared),
    "container_outputs": child(durable.get("container_outputs"), *namespace, release_id),
    "receipts": child(durable.get("receipts"), *namespace, release_id),
    "evidence": child(durable.get("evidence"), *namespace, run_id),
    "spack_build_stage": child(temporary.get("spack_build_stage"), *namespace, run_id),
    "image_staging": child(temporary.get("image_staging"), *namespace, run_id),
    "validation_work": child(temporary.get("validation_work"), *namespace, run_id),
    "resolver_work": child(temporary.get("resolver_work"), *namespace, run_id),
}
if selection_document.get("paths") != expected_paths:
    fail("selection paths do not match canonical contract derivation")
sealed_files = [("selection.json", selection), ("contract.json", contract), ("spack.yaml", manifest), ("target-policy.yaml", target_policy)]
directory = Path(tempfile.mkdtemp(prefix="chapar-sealed-selection."))
for name, payload in sealed_files:
    destination = directory / name
    destination.write_bytes(payload)
    destination.chmod(0o400)
print(directory)
PY
)" || exit $?
    trap 'rm -rf -- "${SEALED_SELECTION_DIR:-}"' EXIT
    SEALED_SELECTION_DIR="${sealed_dir}"
    SELECTION_PATH="${sealed_dir}/selection.json"
    CONTRACT_PATH="${sealed_dir}/contract.json"

    jq -e '
      . as $selection |
      .schema == "https://nscaledev.github.io/chapar/schemas/software-selection/v1" and
      .schema_version == 1 and
      ([.policy.datacenter,.policy.software_set,.policy.target,.invocation.release_id,.invocation.run_id,
        .target_facts.native_arch,.target_facts.spack_target,.target_facts.oci_platform,
        .authorities.target_contract,.paths.install_tree,.paths.writable_buildcache,.paths.ccache,
        .paths.spack_build_stage,.paths.modulefiles] | all(type == "string" and length > 0)) and
      ((.policy.target | startswith("linux-x86_64-")) and .target_facts.native_arch == "x86_64" or
       (.policy.target | startswith("linux-aarch64-")) and .target_facts.native_arch == "aarch64") and
      ([.paths.install_tree,.paths.writable_buildcache,.paths.ccache,.paths.spack_build_stage,.paths.modulefiles] |
        all(startswith("/") and (contains("/../") | not) and (endswith("/..") | not))) and
      (.paths.modulefiles | contains("/" + $selection.policy.datacenter + "/" + $selection.policy.software_set + "/" + $selection.policy.target + "/")) and
      ([.paths[] | select(type == "string")] |
        if $selection.target_facts.native_arch == "x86_64" then all(contains("linux-aarch64-") | not)
        else all(contains("linux-x86_64-") | not) end) and
      ([.paths.install_tree,.paths.writable_buildcache,.paths.ccache,.paths.spack_build_stage,.paths.modulefiles] | unique | length == 5) and
      (.paths.modulefiles | split("/") | index("current") | not)
    ' "${SELECTION_PATH}" >/dev/null || fail "selection shape, tuple, architecture, or path validation failed"

    CONTRACT_SHA256="$(sha256_file "${CONTRACT_PATH}")"
    [ "$(jq -r '.authorities.target_contract' "${SELECTION_PATH}")" = "${CONTRACT_SHA256}" ] || fail "target contract digest mismatch"
    jq -e --slurpfile selection "${SELECTION_PATH}" '
      .datacenter_id == $selection[0].policy.datacenter and
      .target == $selection[0].policy.target and
      .sharing.seed_mirrors_read_only == true and
      ([.paths.read_only_inputs[] | select(.kind == "seed_mirror") | .path] | length > 0) and
      ([.paths.read_only_inputs[] | select(.kind == "seed_mirror") | .path] |
        all(type == "string" and startswith("/") and (contains("/../") | not) and (endswith("/..") | not)))
    ' "${CONTRACT_PATH}" >/dev/null || fail "contract tuple or read-only seed policy validation failed"

    DATACENTER="$(jq -r '.policy.datacenter' "${SELECTION_PATH}")"
    SOFTWARE_SET="$(jq -r '.policy.software_set' "${SELECTION_PATH}")"
    TARGET="$(jq -r '.policy.target' "${SELECTION_PATH}")"
    INSTALL_TREE="$(canonical_path "$(jq -r '.paths.install_tree' "${SELECTION_PATH}")")"
    WRITABLE_BUILDCACHE="$(canonical_path "$(jq -r '.paths.writable_buildcache' "${SELECTION_PATH}")")"
    CCACHE="$(canonical_path "$(jq -r '.paths.ccache' "${SELECTION_PATH}")")"
    SPACK_BUILD_STAGE="$(canonical_path "$(jq -r '.paths.spack_build_stage' "${SELECTION_PATH}")")"
    MODULEFILES="$(canonical_path "$(jq -r '.paths.modulefiles' "${SELECTION_PATH}")")"
    RELEASE_FINAL="$(canonical_path "$(jq -r '.paths.release_final' "${SELECTION_PATH}")")"
    mapfile -t RAW_SEED_MIRRORS < <(jq -r '.paths.read_only_inputs[] | select(.kind == "seed_mirror") | .path' "${CONTRACT_PATH}")
    PUBLISH_BUILDCACHE="$(jq -r '.publication.publish_buildcache' "${CONTRACT_PATH}")"
    [ "${PUBLISH_BUILDCACHE}" = true ] || [ "${PUBLISH_BUILDCACHE}" = false ] || fail "contract buildcache publication policy must be boolean"
    EFFECTIVE_MANIFEST="${sealed_dir}/spack.yaml"
    TARGET_POLICY="${sealed_dir}/target-policy.yaml"
    SEED_MIRRORS=()
    local raw_seed
    for raw_seed in "${RAW_SEED_MIRRORS[@]}"; do
        SEED_MIRRORS+=("$(canonical_path "${raw_seed}")")
    done

    local path seed left right left_index right_index
    for path in "${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}" "${MODULEFILES}" "${SEED_MIRRORS[@]}"; do
        path_relation "${path}" /resources/chapar && fail "selected path overlaps protected legacy root"
    done
    WRITABLE_PATHS=("${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}" "${MODULEFILES}")
    for ((left_index = 0; left_index < ${#WRITABLE_PATHS[@]}; left_index++)); do
        left="${WRITABLE_PATHS[${left_index}]}"
        for ((right_index = left_index + 1; right_index < ${#WRITABLE_PATHS[@]}; right_index++)); do
            right="${WRITABLE_PATHS[${right_index}]}"
            path_relation "${left}" "${right}" && fail "managed writable paths overlap"
        done
    done
    for seed in "${SEED_MIRRORS[@]}"; do
        for path in "${WRITABLE_PATHS[@]}"; do
            path_relation "${seed}" "${path}" && fail "read-only seed overlaps managed writable path"
        done
    done
    for path in "${INSTALL_TREE}" "${WRITABLE_BUILDCACHE}" "${CCACHE}" "${SPACK_BUILD_STAGE}"; do
        reject_symlink_components "${path}"
    done
    reject_symlink_ancestors "${MODULEFILES}"
}

render_scopes() {
    local output="$1" index=0 seed padded module_root
    [ ! -e "${output}" ] && [ ! -L "${output}" ] || fail "scope output already exists"
    mkdir -p "${output}"
    # padded_length must match release.sh, otherwise a scope rendered here
    # installs to unpadded prefixes inside the same padded store.
    padded="$(install_tree_padded_length "${INSTALL_TREE}")"
    printf 'config:\n  install_tree:\n    root: %s\n    padded_length: %s\n    projections:\n      all: "{architecture.platform}-{architecture.target}/{name}-{version}-{hash}"\n  build_stage:\n    - %s\n  ccache: true\n' \
        "$(jq -Rrn --arg value "${INSTALL_TREE}" '$value|@json')" \
        "${padded}" \
        "$(jq -Rrn --arg value "${SPACK_BUILD_STAGE}" '$value|@json')" > "${output}/config.yaml"
    # Spack appends <platform-os-target> under the module root, so the root is
    # the release-local modulefiles directory -- not the published pointer,
    # which already names one architecture directory inside it.
    module_root="${RELEASE_FINAL}/modulefiles"
    # Must stay byte-equivalent in policy to release.sh make_scope. These two
    # renderers had diverged -- this one set `enable: [tcl]` and no tcl options,
    # make_scope set the tcl options and no `enable:` -- so which tool rendered a
    # release's scope decided whether hash_length, exclude_implicits and
    # autoload actually applied to its modulefiles.
    printf 'modules:\n  default:\n    roots:\n      tcl: %s\n      lmod: %s\n    enable: [tcl]\n    tcl:\n      exclude_implicits: true\n      hash_length: 0\n      all:\n        autoload: none\n' \
        "$(jq -Rrn --arg value "${module_root}" '$value|@json')" \
        "$(jq -Rrn --arg value "${module_root}/lmod" '$value|@json')" > "${output}/modules.yaml"
    printf 'mirrors:\n' > "${output}/mirrors.yaml"
    for seed in "${SEED_MIRRORS[@]}"; do
        index=$((index + 1))
        printf '  chapar-seed-%03d:\n    url: %s\n    source: false\n    binary: true\n    signed: false\n    autopush: false\n' \
            "${index}" "$(jq -Rrn --arg value "file://${seed}" '$value|@json')" >> "${output}/mirrors.yaml"
    done
    printf '  chapar-buildcache:\n    url: %s\n    source: false\n    binary: true\n    signed: false\n    autopush: true\n' \
        "$(jq -Rrn --arg value "file://${WRITABLE_BUILDCACHE}" '$value|@json')" >> "${output}/mirrors.yaml"
}

usage() {
    echo "Usage: $0 verify|exports|module-use|buildcache-push SELECTION SHA256 CONTRACT" >&2
    echo "       $0 render-scopes SELECTION SHA256 CONTRACT OUTPUT" >&2
}

[ "$#" -ge 4 ] || { usage; exit 2; }
command="$1"
shift
verify_selection "$1" "$2" "$3"
shift 3

case "${command}" in
    verify) [ "$#" -eq 0 ] || fail "verify takes no output argument" ;;
    exports)
        [ "$#" -eq 0 ] || fail "exports takes no output argument"
        printf 'export CHAPAR_DATACENTER=%q\n' "${DATACENTER}"
        printf 'export CHAPAR_SOFTWARE_SET=%q\n' "${SOFTWARE_SET}"
        printf 'export CHAPAR_TARGET=%q\n' "${TARGET}"
        printf 'export CHAPAR_INSTALL_TREE_ROOT=%q\n' "${INSTALL_TREE}"
        printf 'export CHAPAR_BUILDCACHE_DIR=%q\n' "${WRITABLE_BUILDCACHE}"
        printf 'export CHAPAR_CCACHE_DIR=%q\n' "${CCACHE}"
        printf 'export CHAPAR_SPACK_BUILD_STAGE=%q\n' "${SPACK_BUILD_STAGE}"
        printf 'export CHAPAR_MODULE_ROOT=%q\n' "${MODULEFILES}"
        printf 'export CHAPAR_PUBLISH_BUILDCACHE=%q\n' "${PUBLISH_BUILDCACHE}"
        printf 'export CHAPAR_EFFECTIVE_MANIFEST=%q\n' "${EFFECTIVE_MANIFEST}"
        printf 'export CHAPAR_TARGET_POLICY=%q\n' "${TARGET_POLICY}"
        ;;
    module-use)
        [ "$#" -eq 0 ] || fail "module-use takes no output argument"
        # -d follows the published pointer; requiring a non-symlink here would
        # reject exactly the layout publish-modules creates.
        [ -d "${MODULEFILES}" ] || fail "selected module tree is not a directory"
        command -v module >/dev/null 2>&1 || fail "module command is unavailable"
        module use "${MODULEFILES}"
        ;;
    buildcache-push)
        [ "$#" -eq 0 ] || fail "buildcache-push takes no output argument"
        [ "${PUBLISH_BUILDCACHE}" = true ] || fail "target contract forbids buildcache publication"
        scope_dir="$(mktemp -d "${TMPDIR:-/tmp}/chapar-buildcache-scope.XXXXXX")"
        rmdir "${scope_dir}"
        render_scopes "${scope_dir}"
        mkdir -p "${WRITABLE_BUILDCACHE}"
        spack -e "${EFFECTIVE_MANIFEST}" -C "${scope_dir}" buildcache push \
            --unsigned --update-index "file://${WRITABLE_BUILDCACHE}"
        rm -rf -- "${scope_dir}"
        ;;
    render-scopes)
        [ "$#" -eq 1 ] || fail "render-scopes requires one output directory"
        render_scopes "$1"
        ;;
    *) usage; exit 2 ;;
esac
