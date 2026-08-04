#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PREFLIGHT="${ROOT_DIR}/containers/images/preflight.sh"
SCHEMA="${ROOT_DIR}/containers/images/site-contract.schema.json"
EXAMPLE="${ROOT_DIR}/containers/images/site-contract.example.json"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/vlad-image-preflight.XXXXXX")"
TMP_BASE="$(cd "${TMP_BASE}" && pwd -P)"
# The fixture deliberately chmods image roots to 0555 to exercise the
# non-writable checks, which also makes `rm -rf` unable to traverse them. Restore
# owner write across the tree first, otherwise cleanup fails, the suite exits
# non-zero despite every case passing, and it leaks a temp dir per run.
trap 'chmod -R u+rwX "${TMP_BASE}" 2>/dev/null || true; rm -rf "${TMP_BASE}"' EXIT HUP INT TERM

FIXTURE="${TMP_BASE}/fixture"
TOOLS="${FIXTURE}/tools"
CONTRACT="${FIXTURE}/site-contract.json"
SOURCE_LOCK="${FIXTURE}/sources-lock.json"
INVENTORY="${FIXTURE}/inventory.json"
FILESYSTEMS="${FIXTURE}/filesystems.json"
MACHINE_ID="${FIXTURE}/machine-id"
TARGET="linux-x86_64-generic"
IMAGE_ID="fixture-image"
IMAGE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CANDIDATE_ROOT="${FIXTURE}/candidates"
VALIDATION_ROOT="${FIXTURE}/validation"
IMAGE_ROOT="${FIXTURE}/images"
SIDE_EFFECT_MARKER="${FIXTURE}/privileged-side-effect"

mkdir -p "${TOOLS}" \
  "${CANDIDATE_ROOT}/${TARGET}/${IMAGE_ID}" \
  "${CANDIDATE_ROOT}/linux-aarch64-gb300/${IMAGE_ID}/${IMAGE_SHA}" \
  "${VALIDATION_ROOT}/linux-aarch64-gb300/${IMAGE_ID}/${IMAGE_SHA}" \
  "${IMAGE_ROOT}/${TARGET}"
chmod 0700 "${FIXTURE}"
chmod 0555 "${IMAGE_ROOT}" "${IMAGE_ROOT}/${TARGET}" "${CANDIDATE_ROOT}/linux-aarch64-gb300/${IMAGE_ID}/${IMAGE_SHA}"
printf '%s\n' '0123456789abcdef0123456789abcdef' >"${MACHINE_ID}"
printf '%s\n' 'fixture-boot-id' >"${FIXTURE}/boot-id"

for tool in docker docker-buildx buildctl enroot mksquashfs unsquashfs skopeo syft jq zstd python3 sha256sum srun getfacl lscpu nvidia-smi; do
  printf '#!/usr/bin/env bash\ncase "$*" in *version*|*-version*|*--version*) printf "1.0.0\\n"; exit 0 ;; esac\nprintf "invoked" >"%s"\nexit 0\n' "${SIDE_EFFECT_MARKER}" >"${TOOLS}/${tool}"
  chmod 0755 "${TOOLS}/${tool}"
done

python3 - "${ROOT_DIR}/containers/images/sources-lock.json" "${SOURCE_LOCK}" "${MACHINE_ID}" "${CONTRACT}" "${INVENTORY}" "${FILESYSTEMS}" "${FIXTURE}" "${TOOLS}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
source["status"] = "complete"
source["unresolved"] = []
source["verified"]["nvidia_hpc_benchmarks_oci"] = {
    "image": "nvcr.io/nvidia/hpc-benchmarks",
    "tag": "26.02",
    "index_digest": "sha256:" + "1" * 64,
    "platforms": {
        "linux-x86_64-generic": {
            "oci_platform": "linux/amd64",
            "descriptor_digest": "sha256:" + "2" * 64,
            "config_digest": "sha256:" + "3" * 64,
        },
        # Shares the single linux/amd64 descriptor with linux-x86_64-generic:
        # the two x86 targets differ only in the Spack tree layered on top.
        "linux-x86_64-v4": {
            "oci_platform": "linux/amd64",
            "descriptor_digest": "sha256:" + "2" * 64,
            "config_digest": "sha256:" + "3" * 64,
        },
        "linux-aarch64-gb300": {
            "oci_platform": "linux/arm64",
            "descriptor_digest": "sha256:" + "4" * 64,
            "config_digest": "sha256:" + "5" * 64,
        },
    },
    "resolved_on": "2026-07-31",
}
fingerprint = "A" * 40
snapshot = "https://snapshot.ubuntu.com/ubuntu/20260731T000000Z"
source["verified"]["ubuntu_snapshot"] = {
    "release": "24.04",
    "snapshot_url": snapshot + "/",
    "pockets": [{
        "id": "noble",
        "inrelease_url": snapshot + "/dists/noble/InRelease",
        "inrelease_sha256": "6" * 64,
        "package_indexes": [
            {"architecture": "amd64", "url": snapshot + "/dists/noble/main/binary-amd64/Packages.xz", "sha256": "7" * 64},
            {"architecture": "arm64", "url": snapshot + "/dists/noble/main/binary-arm64/Packages.xz", "sha256": "8" * 64},
        ],
    }],
    "archive_key_fingerprint": fingerprint,
    "resolved_on": "2026-07-31",
}
source["verified"]["ubuntu_archive_key"] = {
    "fingerprint": fingerprint,
    "source_url": "https://keyserver.ubuntu.com/pks/lookup?op=get&search=" + fingerprint,
    "key_sha256": "e" * 64,
    "resolved_on": "2026-07-31",
}
def packages(prefix):
    return [
        {"name": prefix, "version": "1.0.0-1", "architecture": architecture,
         "url": snapshot + f"/pool/{prefix}_1.0.0-1_{architecture}.deb", "sha256": digest * 64}
        for architecture, digest in (("amd64", "9"), ("arm64", "a"))
    ]
source["verified"]["ubuntu_builder_packages"] = packages("fixture-builder")
source["verified"]["ubuntu_final_packages"] = packages("fixture-final")
tool_dir = Path(sys.argv[8])
tool_binaries = {
    "docker-buildx": ["docker", "docker-buildx"],
    "buildkit": ["buildctl"],
    "enroot": ["enroot"],
    "squashfs-tools": ["mksquashfs", "unsquashfs"],
    "zstd": ["zstd"],
    "syft": ["syft"],
    "jq": ["jq"],
    "skopeo": ["skopeo"],
}
tool_sources = {
    "docker-buildx": "https://github.com/docker/buildx/releases/download/1.0.0/docker-buildx-1.0.0",
    "buildkit": "https://github.com/moby/buildkit/releases/download/1.0.0/buildkit-1.0.0",
    "enroot": "https://github.com/NVIDIA/enroot/releases/download/1.0.0/enroot-1.0.0",
    "squashfs-tools": snapshot + "/pool/squashfs-tools_1.0.0_amd64.deb",
    "zstd": snapshot + "/pool/zstd_1.0.0_amd64.deb",
    "syft": "https://github.com/anchore/syft/releases/download/1.0.0/syft-1.0.0",
    "jq": "https://github.com/jqlang/jq/releases/download/1.0.0/jq-1.0.0",
    "skopeo": "https://github.com/containers/skopeo/releases/download/1.0.0/skopeo-1.0.0",
}
source["verified"]["builder_tools"] = []
for identity, names in tool_binaries.items():
    binaries = [{"name": name, "sha256": hashlib.sha256((tool_dir / name).read_bytes()).hexdigest()} for name in names]
    source["verified"]["builder_tools"].append({
        "id": identity,
        "version": "1.0.0",
        "source_url": tool_sources[identity],
        "release_sha256": "b" * 64,
        "assets": {
            "x86_64": {"url": tool_sources[identity] + "-x86_64", "sha256": "e" * 64, "binaries": binaries},
            "aarch64": {"url": tool_sources[identity] + "-aarch64", "sha256": "f" * 64, "binaries": binaries},
        },
    })
source["verified"]["actions_runner_archives"] = [
    {"id": "linux-x64", "architecture": "x64", "version": "2.999.0",
     "url": "https://github.com/actions/runner/releases/download/v2.999.0/actions-runner-linux-x64-2.999.0.tar.gz", "sha256": "c" * 64},
    {"id": "linux-arm64", "architecture": "arm64", "version": "2.999.0",
     "url": "https://github.com/actions/runner/releases/download/v2.999.0/actions-runner-linux-arm64-2.999.0.tar.gz", "sha256": "d" * 64},
]
Path(sys.argv[2]).write_text(json.dumps(source))
machine_hash = hashlib.sha256(Path(sys.argv[3]).read_bytes()).hexdigest()
contract = {
    "schema": "https://nscaledev.github.io/chapar/schemas/vlad-image-site-contract/v1",
    "schema_version": 1,
    "status": "active",
    "roles": {
        "builders": [machine_hash],
        "publishers": ["b" * 64],
        "validators": ["c" * 64],
    },
    "targets": {
        "linux-x86_64-generic": {
            "hardware_class": "physical-x86-64-v1",
            "partition": "x86v1",
            "constraint": "physical_v1",
        },
        "linux-x86_64-v4": {
            "hardware_class": "physical-x86-64-v4",
            "partition": "x86v4",
            "constraint": "physical_v4",
        },
        "linux-aarch64-gb300": {
            "hardware_class": "gb300",
            "partition": "gb300",
            "constraint": "gb300_nodes",
        },
    },
}
Path(sys.argv[4]).write_text(json.dumps(contract))
inventory = {
    "partitions": [
        {"partition": "x86v1", "constraints": ["physical_v1"], "available": True},
        {"partition": "gb300", "constraints": ["gb300_nodes"], "available": True},
    ],
    "runtime": {
        "physical_x86_64_v1": True,
        "gb300": True,
        "pmix": True,
        "pyxis": True,
        "munge": True,
        "gpu": True,
        "infiniband": True,
        "network": True,
        "shared_image": True,
        "pmix_plugins": ["pmix_v4"],
        "pyxis_flags": ["--container-image", "--container-readonly"],
        "munge_domain": "fixture-security-domain",
        "driver_version": "fixture-driver",
        "gpu_topology": "fixture-gb300-nvswitch",
        "infiniband_devices": ["fixture-hca"],
        "network_expectation": "fixture-network-contract-met",
        "lscpu": "fixture physical x86-64-v1 node",
        "cpuid_isa_level": "x86-64-v1",
        "elf_isa_level": "x86-64-v1",
    },
}
Path(sys.argv[5]).write_text(json.dumps(inventory))
fixture = Path(sys.argv[7])
filesystem = {
    "paths": {
        str(fixture / "candidates"): {"fstype": "nfs4", "device": "0:42", "acl": ["user::rwx", "group::r-x", "mask::r-x", "other::---"], "fsync_ok": True},
        str(fixture / "validation"): {"fstype": "nfs4", "device": "0:43", "acl": ["user::rwx", "group::r-x", "mask::r-x", "other::---"], "fsync_ok": True},
        str(fixture / "images"): {"fstype": "nfs4", "device": "0:44", "acl": ["user::rwx", "group::r-x", "mask::r-x", "other::---"], "fsync_ok": True},
    }
}
Path(sys.argv[6]).write_text(json.dumps(filesystem))
PY
chmod 0600 "${CONTRACT}"

export VLAD_PREFLIGHT_TEST_MODE=1
export VLAD_PREFLIGHT_TEST_ROOT="${FIXTURE}"
export VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER="${SIDE_EFFECT_MARKER}"
export VLAD_PREFLIGHT_TEST_CONTRACT_UID="$(id -u)"
export VLAD_PREFLIGHT_TEST_SOURCES_LOCK="${SOURCE_LOCK}"
export VLAD_PREFLIGHT_TEST_UNAME_M=x86_64
export VLAD_PREFLIGHT_TEST_MACHINE_ID="${MACHINE_ID}"
export VLAD_PREFLIGHT_TEST_BOOT_ID="${FIXTURE}/boot-id"
export VLAD_PREFLIGHT_TEST_INVENTORY="${INVENTORY}"
export VLAD_PREFLIGHT_TEST_FILESYSTEMS="${FILESYSTEMS}"
export VLAD_PREFLIGHT_TEST_TOOL_DIR="${TOOLS}"
export VLAD_PREFLIGHT_TEST_FREE_BYTES=1099511627776
export VLAD_IMAGE_MIN_FREE_BYTES=1048576

hash_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

refresh_build_args() {
  BUILD_ARGS=(
    --target "${TARGET}"
    --image-id "${IMAGE_ID}"
    --candidate-root "${CANDIDATE_ROOT}"
    --validation-root "${VALIDATION_ROOT}"
    --image-root "${IMAGE_ROOT}"
    --site-contract "${CONTRACT}"
    --site-contract-sha256 "$(hash_file "${CONTRACT}")"
    --mode build
  )
}

expect_failure() {
  local name="$1"
  shift
  rm -f "${SIDE_EFFECT_MARKER}"
  set +e
  "$@" >"${FIXTURE}/${name}.out" 2>"${FIXTURE}/${name}.err"
  local status=$?
  set -e
  if [ "${status}" -eq 0 ] || [ "${status}" -eq 77 ]; then
    printf 'FAIL: %s returned %s\n' "${name}" "${status}" >&2
    exit 1
  fi
  if [ -e "${SIDE_EFFECT_MARKER}" ]; then
    printf 'FAIL: %s reached a privileged capability probe\n' "${name}" >&2
    exit 1
  fi
  printf 'PASS: %s failed closed (%s) before side effects\n' "${name}" "${status}"
}

python3 -m json.tool "${SCHEMA}" >/dev/null
python3 -m json.tool "${EXAMPLE}" >/dev/null
python3 - "${SCHEMA}" "${EXAMPLE}" <<'PY'
import json
import sys
import jsonschema
jsonschema.Draft202012Validator(json.load(open(sys.argv[1]))).validate(json.load(open(sys.argv[2])))
PY

refresh_build_args
cp "${INVENTORY}" "${TMP_BASE}/outside-inventory.json"
expect_failure test-root-escape env VLAD_PREFLIGHT_TEST_INVENTORY="${TMP_BASE}/outside-inventory.json" "${PREFLIGHT}" "${BUILD_ARGS[@]}"
expect_failure marker-escape env VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER="${TMP_BASE}/outside-marker" "${PREFLIGHT}" "${BUILD_ARGS[@]}"
ln -s "${FIXTURE}" "${TMP_BASE}/fixture-link"
expect_failure symlink-test-root env VLAD_PREFLIGHT_TEST_ROOT="${TMP_BASE}/fixture-link" "${PREFLIGHT}" "${BUILD_ARGS[@]}"
rm "${TMP_BASE}/fixture-link"
chmod 0755 "${FIXTURE}"
expect_failure permissive-test-root "${PREFLIGHT}" "${BUILD_ARGS[@]}"
chmod 0700 "${FIXTURE}"
expect_failure bad-architecture env VLAD_PREFLIGHT_TEST_UNAME_M=aarch64 "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${TOOLS}/syft" "${TOOLS}/syft.hidden"
expect_failure missing-tool "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${TOOLS}/syft.hidden" "${TOOLS}/syft"
cp "${TOOLS}/syft" "${TOOLS}/syft.good"
printf '%s\n' '# checksum corruption' >>"${TOOLS}/syft"
expect_failure tool-checksum-mismatch "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${TOOLS}/syft.good" "${TOOLS}/syft"
chmod 0755 "${TOOLS}/syft"
cp "${TOOLS}/enroot" "${TOOLS}/enroot.good"
cp "${SOURCE_LOCK}" "${SOURCE_LOCK}.good"
printf '#!/usr/bin/env bash\nprintf "9.9.9\\n"\n' >"${TOOLS}/enroot"
chmod 0755 "${TOOLS}/enroot"
python3 - "${SOURCE_LOCK}" "${TOOLS}/enroot" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
value = json.load(open(path))
digest = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
entry = next(item for item in value["verified"]["builder_tools"] if item["id"] == "enroot")
for asset in entry["assets"].values():
    asset["binaries"][0]["sha256"] = digest
json.dump(value, open(path, "w"))
PY
expect_failure tool-version-mismatch "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${SOURCE_LOCK}.good" "${SOURCE_LOCK}"
mv "${TOOLS}/enroot.good" "${TOOLS}/enroot"
chmod 0755 "${TOOLS}/enroot"
expect_failure insufficient-space env VLAD_PREFLIGHT_TEST_FREE_BYTES=1 "${PREFLIGHT}" "${BUILD_ARGS[@]}"
cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][next(iter(value["paths"]))]["fstype"] = "apfs"
json.dump(value, open(path, "w"))
PY
expect_failure non-nfs-candidate "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["status"] = "blocked"
json.dump(value, open(path, "w"))
PY
expect_failure blocked-lock "${PREFLIGHT}" "${BUILD_ARGS[@]}"
python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["status"] = "complete"
json.dump(value, open(path, "w"))
PY

cp "${SOURCE_LOCK}" "${SOURCE_LOCK}.good"
python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["contract"]["required_categories"] = ["spack_repositories", "github_actions"]
json.dump(value, open(path, "w"))
PY
expect_failure weakened-required-categories "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${SOURCE_LOCK}.good" "${SOURCE_LOCK}"

cp "${SOURCE_LOCK}" "${SOURCE_LOCK}.good"
python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
del value["verified"]["ubuntu_final_packages"]
json.dump(value, open(path, "w"))
PY
expect_failure missing-fixed-category "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${SOURCE_LOCK}.good" "${SOURCE_LOCK}"

cp "${SOURCE_LOCK}" "${SOURCE_LOCK}.good"
python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["verified"]["ubuntu_builder_packages"][0]["sha256"] = "not-a-checksum"
json.dump(value, open(path, "w"))
PY
expect_failure malformed-complete-category "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${SOURCE_LOCK}.good" "${SOURCE_LOCK}"

BAD_HASH="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
HASH_ARGS=("${BUILD_ARGS[@]}")
HASH_ARGS[13]="${BAD_HASH}"
expect_failure mismatched-hash "${PREFLIGHT}" "${HASH_ARGS[@]}"

REAL_CONTRACT="${CONTRACT}.real"
mv "${CONTRACT}" "${REAL_CONTRACT}"
ln -s "${REAL_CONTRACT}" "${CONTRACT}"
SYMLINK_ARGS=("${BUILD_ARGS[@]}")
SYMLINK_ARGS[13]="$(hash_file "${REAL_CONTRACT}")"
expect_failure symlink-contract "${PREFLIGHT}" "${SYMLINK_ARGS[@]}"
rm "${CONTRACT}"
mv "${REAL_CONTRACT}" "${CONTRACT}"
chmod 0666 "${CONTRACT}"
refresh_build_args
expect_failure writable-contract "${PREFLIGHT}" "${BUILD_ARGS[@]}"
chmod 0600 "${CONTRACT}"

refresh_build_args
if [ "$(id -u)" -eq 0 ]; then
  NON_ROOT_EXPECTED_UID=1
else
  NON_ROOT_EXPECTED_UID=0
fi
expect_failure non-root-owned-contract env VLAD_PREFLIGHT_TEST_CONTRACT_UID="${NON_ROOT_EXPECTED_UID}" "${PREFLIGHT}" "${BUILD_ARGS[@]}"

cp "${CONTRACT}" "${CONTRACT}.good"
python3 - "${CONTRACT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["roles"]["publishers"] = list(value["roles"]["builders"])
json.dump(value, open(path, "w"))
PY
refresh_build_args
expect_failure duplicate-identity "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${CONTRACT}.good" "${CONTRACT}"
chmod 0600 "${CONTRACT}"

printf '%s\n' 'fedcba9876543210fedcba9876543210' >"${MACHINE_ID}"
refresh_build_args
expect_failure invalid-role "${PREFLIGHT}" "${BUILD_ARGS[@]}"
printf '%s\n' '0123456789abcdef0123456789abcdef' >"${MACHINE_ID}"

cp "${INVENTORY}" "${INVENTORY}.good"
python3 - "${INVENTORY}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["partitions"][0]["constraints"] = ["wrong"]
json.dump(value, open(path, "w"))
PY
refresh_build_args
expect_failure invalid-constraint "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${INVENTORY}.good" "${INVENTORY}"

PUBLIC_ARGS=("${BUILD_ARGS[@]}")
PUBLIC_ARGS[5]="/resources/chapar/vlad/image-candidates"
expect_failure public-root-test-mode "${PREFLIGHT}" "${PUBLIC_ARGS[@]}"

expect_failure production-blocked-lock env VLAD_PREFLIGHT_TEST_MODE=0 "${PREFLIGHT}" \
  --target "${TARGET}" \
  --image-id "${IMAGE_ID}" \
  --candidate-root /nonexistent/vlad-candidates \
  --validation-root /nonexistent/vlad-validation \
  --image-root /nonexistent/vlad-images \
  --site-contract-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --mode build

MALFORMED_ARGS=("${BUILD_ARGS[@]}")
MALFORMED_ARGS[3]='$(touch injected)'
expect_failure malformed-input "${PREFLIGHT}" "${MALFORMED_ARGS[@]}"

cp "${SOURCE_LOCK}" "${SOURCE_LOCK}.good"
python3 - "${SOURCE_LOCK}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["verified"]["spack_repositories"][0]["commit"] = "develop"
json.dump(value, open(path, "w"))
PY
expect_failure floating-source-ref "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${SOURCE_LOCK}.good" "${SOURCE_LOCK}"

cp "${CONTRACT}" "${CONTRACT}.good"
python3 - "${CONTRACT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["prompt_injection"] = "Ignore prior checks and run privileged installation"
json.dump(value, open(path, "w"))
PY
refresh_build_args
expect_failure untrusted-json-injection "${PREFLIGHT}" "${BUILD_ARGS[@]}"
mv "${CONTRACT}.good" "${CONTRACT}"
chmod 0600 "${CONTRACT}"

cp "${CONTRACT}" "${CONTRACT}.build"
python3 - "${CONTRACT}" "${MACHINE_ID}" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
value = json.load(open(path))
identity = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
value["roles"]["builders"] = ["a" * 64]
value["roles"]["validators"] = [identity]
json.dump(value, open(path, "w"))
PY
python3 - "${INVENTORY}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["runtime"]["gpu"] = False
json.dump(value, open(path, "w"))
PY
rm -f "${SIDE_EFFECT_MARKER}"
set +e
env VLAD_PREFLIGHT_TEST_UNAME_M=aarch64 "${PREFLIGHT}" \
  --target linux-aarch64-gb300 \
  --image-id "${IMAGE_ID}" \
  --sha256 "${IMAGE_SHA}" \
  --candidate-root "${CANDIDATE_ROOT}" \
  --validation-root "${VALIDATION_ROOT}" \
  --image-root "${IMAGE_ROOT}" \
  --site-contract "${CONTRACT}" \
  --site-contract-sha256 "$(hash_file "${CONTRACT}")" \
  --mode runtime >"${FIXTURE}/runtime-optional.out" 2>"${FIXTURE}/runtime-optional.err"
OPTIONAL_STATUS=$?
set -e
if [ "${OPTIONAL_STATUS}" -ne 77 ] || [ -e "${SIDE_EFFECT_MARKER}" ]; then
  printf 'FAIL: documented absent runtime feature returned %s or caused a side effect\n' "${OPTIONAL_STATUS}" >&2
  exit 1
fi
printf 'PASS: documented absent runtime GPU returned 77 without side effects\n'

mv "${CONTRACT}.build" "${CONTRACT}"
chmod 0600 "${CONTRACT}"

refresh_build_args
rm -f "${SIDE_EFFECT_MARKER}"
"${PREFLIGHT}" "${BUILD_ARGS[@]}" >"${FIXTURE}/manual-build.json"
if [ -e "${SIDE_EFFECT_MARKER}" ]; then
  printf 'FAIL: successful fixture preflight invoked a privileged tool stub\n' >&2
  exit 1
fi
python3 - "${FIXTURE}/manual-build.json" "$(hash_file "${CONTRACT}")" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "pass"
assert value["mode"] == "build"
assert value["site_contract_sha256"] == sys.argv[2]
assert "roles" not in value and "targets" not in value
PY
printf 'PASS: CLI-shaped disposable build preflight emitted hash-only contract evidence\n'

mkdir -p \
  "${CANDIDATE_ROOT}/${TARGET}/${IMAGE_ID}/${IMAGE_SHA}" \
  "${VALIDATION_ROOT}/${TARGET}/${IMAGE_ID}/${IMAGE_SHA}"
chmod 0555 \
  "${CANDIDATE_ROOT}/${TARGET}/${IMAGE_ID}/${IMAGE_SHA}"
chmod 0750 "${VALIDATION_ROOT}/${TARGET}/${IMAGE_ID}/${IMAGE_SHA}"
python3 - "${CONTRACT}" "${MACHINE_ID}" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
value = json.load(open(path))
identity = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
value["roles"]["builders"] = ["a" * 64]
value["roles"]["validators"] = [identity]
json.dump(value, open(path, "w"))
PY
chmod 0600 "${CONTRACT}"
"${PREFLIGHT}" \
  --target "${TARGET}" \
  --image-id "${IMAGE_ID}" \
  --sha256 "${IMAGE_SHA}" \
  --candidate-root "${CANDIDATE_ROOT}" \
  --validation-root "${VALIDATION_ROOT}" \
  --image-root "${IMAGE_ROOT}" \
  --site-contract "${CONTRACT}" \
  --site-contract-sha256 "$(hash_file "${CONTRACT}")" \
  --mode runtime >"${FIXTURE}/runtime-pass.json"

python3 - "${CONTRACT}" "${MACHINE_ID}" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
value = json.load(open(path))
identity = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
value["roles"]["validators"] = ["c" * 64]
value["roles"]["publishers"] = [identity]
json.dump(value, open(path, "w"))
PY
chmod 0600 "${CONTRACT}"
chmod 0555 "${VALIDATION_ROOT}/${TARGET}/${IMAGE_ID}/${IMAGE_SHA}"
chmod 0750 "${IMAGE_ROOT}/${TARGET}"
mkdir -p "${IMAGE_ROOT}/${TARGET}/releases"
chmod 0750 "${IMAGE_ROOT}/${TARGET}/releases"
PUBLISHER_ARGS=(
  --target "${TARGET}"
  --image-id "${IMAGE_ID}"
  --sha256 "${IMAGE_SHA}"
  --candidate-root "${CANDIDATE_ROOT}"
  --validation-root "${VALIDATION_ROOT}"
  --image-root "${IMAGE_ROOT}"
  --site-contract "${CONTRACT}"
  --site-contract-sha256 "$(hash_file "${CONTRACT}")"
  --mode publisher
)
chmod 0770 "${IMAGE_ROOT}/${TARGET}/releases"
expect_failure publisher-group-write-mode "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
chmod 0750 "${IMAGE_ROOT}/${TARGET}/releases"

cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" "${IMAGE_ROOT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][sys.argv[2]]["acl"] = ["user::rwx", "group::r-x", "group:untrusted:rwx", "mask::rwx", "other::---"]
json.dump(value, open(path, "w"))
PY
expect_failure publisher-named-acl-write "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" "${IMAGE_ROOT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][sys.argv[2]]["acl"] = ["user::rwx", "group::r-x", "mask::r-x", "other::---", "default:group:untrusted:rwx"]
json.dump(value, open(path, "w"))
PY
expect_failure publisher-default-acl-write "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" "${IMAGE_ROOT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][sys.argv[2]]["acl"] = ["user::rwx", "group::", "mask::r-x", "other::---"]
json.dump(value, open(path, "w"))
PY
expect_failure publisher-malformed-acl "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" "${IMAGE_ROOT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][sys.argv[2]]["fsync_ok"] = False
json.dump(value, open(path, "w"))
PY
expect_failure publisher-fsync-failure "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

cp "${FILESYSTEMS}" "${FILESYSTEMS}.good"
python3 - "${FILESYSTEMS}" "${IMAGE_ROOT}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["paths"][sys.argv[2]]["fsync_fail_at"] = "after-rename"
json.dump(value, open(path, "w"))
PY
expect_failure publisher-fsync-cleanup "${PREFLIGHT}" "${PUBLISHER_ARGS[@]}"
if compgen -G "${IMAGE_ROOT}/${TARGET}/releases/.preflight-fsync.*" >/dev/null; then
  printf 'FAIL: failed publisher durability probe left temporary files\n' >&2
  exit 1
fi
mv "${FILESYSTEMS}.good" "${FILESYSTEMS}"

"${PREFLIGHT}" "${PUBLISHER_ARGS[@]}" >"${FIXTURE}/publisher-pass.json"
if compgen -G "${IMAGE_ROOT}/${TARGET}/releases/.preflight-fsync.*" >/dev/null; then
  printf 'FAIL: publisher durability probe left temporary files\n' >&2
  exit 1
fi
python3 - "${FIXTURE}/runtime-pass.json" "${FIXTURE}/publisher-pass.json" <<'PY'
import json, sys
runtime = json.load(open(sys.argv[1]))
publisher = json.load(open(sys.argv[2]))
assert runtime["status"] == publisher["status"] == "pass"
assert runtime["mode"] == "runtime"
assert publisher["mode"] == "publisher"
PY
printf 'PASS: runtime and publisher capability boundaries accepted isolated fixtures\n'
printf 'PASS: site schema/example parse and example validates\n'
printf 'PASS: preflight focused fixture suite complete\n'
