#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BUILD_IMAGE="${ROOT_DIR}/containers/images/build-image.sh"
PYTHON_BIN="$(command -v python3)"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/chapar-image-plan.XXXXXX")"
TMP_BASE="$(cd "${TMP_BASE}" && pwd -P)"
trap 'chmod -R u+rwX "${TMP_BASE}" 2>/dev/null || true; rm -rf "${TMP_BASE}"' EXIT HUP INT TERM

REPOSITORY_ROOT="${TMP_BASE}/repository"
PIPELINE_ROOT="${REPOSITORY_ROOT}/containers/images"
PLAN_SCRIPT="${PIPELINE_ROOT}/build-image.sh"
RELEASE_DIR="${TMP_BASE}/release"
STORE_ROOT="${TMP_BASE}/store"
CANDIDATE_ROOT="${TMP_BASE}/candidates"
FINAL_ROOT="${TMP_BASE}/final"
TOOLS_ROOT="${TMP_BASE}/tools"
TOOL_CALL_LOG="${TMP_BASE}/tool-calls.log"
HOME_ROOT="${TMP_BASE}/home"
OUTPUT_ROOT="${TMP_BASE}/outputs"
PYTHON_GUARD_ROOT="${TMP_BASE}/python-guard"
IMAGE_ID="fixture-image"
ROOT_HASH="aaaabbbb"
RUNTIME_HASH="ccccdddd"
BUILD_HASH="eeeeffff"

mkdir -p "${PIPELINE_ROOT}/tests" "${REPOSITORY_ROOT}/etc/system/base" \
  "${CANDIDATE_ROOT}" "${FINAL_ROOT}" \
  "${TOOLS_ROOT}" "${HOME_ROOT}" "${OUTPUT_ROOT}" "${PYTHON_GUARD_ROOT}"
cp "${BUILD_IMAGE}" "${PLAN_SCRIPT}"
cp "${ROOT_DIR}/containers/images/tests/validate-locks.sh" "${PIPELINE_ROOT}/tests/validate-locks.real.sh"
cat >"${PIPELINE_ROOT}/tests/validate-locks.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"${SCRIPT_DIR}/validate-locks.real.sh" "$@"
if [[ -n "${VALIDATOR_SWAP_FROM:-}" && -n "${VALIDATOR_SWAP_TO:-}" ]]; then
  mv "${VALIDATOR_SWAP_FROM}" "${VALIDATOR_SWAP_TO}"
fi
SH
cp "${ROOT_DIR}/containers/images/targets.json" "${PIPELINE_ROOT}/targets.json"
cp "${ROOT_DIR}/containers/images/sources-lock.json" "${PIPELINE_ROOT}/sources-template.json"
cp "${ROOT_DIR}/etc/system/base/repos.yaml" "${REPOSITORY_ROOT}/etc/system/base/repos.yaml"
chmod 0755 "${PLAN_SCRIPT}" "${PIPELINE_ROOT}/tests/validate-locks.sh"
printf 'candidate sentinel\n' >"${CANDIDATE_ROOT}/sentinel.txt"
printf 'final sentinel\n' >"${FINAL_ROOT}/sentinel.txt"
: >"${TOOL_CALL_LOG}"
cat >"${PYTHON_GUARD_ROOT}/sitecustomize.py" <<'PY'
import socket

def denied(*args, **kwargs):
    raise RuntimeError("socket access denied by plan fixture")

socket.socket = denied
socket.create_connection = denied
PY

for tool in enroot skopeo spack docker srun ssh mount umount curl wget git; do
  cat >"${TOOLS_ROOT}/${tool}" <<'TOOL'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(basename "$0")" "$*" >>"${TOOL_CALL_LOG:?}"
exit 97
TOOL
  chmod 0755 "${TOOLS_ROOT}/${tool}"
done

write_fixture() {
  local target="$1"
  local arch="$2"
  rm -rf "${RELEASE_DIR}" "${STORE_ROOT}"
  mkdir -p "${RELEASE_DIR}" \
    "${STORE_ROOT}/root-1.0-${ROOT_HASH}" \
    "${STORE_ROOT}/runtime-1.0-${RUNTIME_HASH}" \
    "${STORE_ROOT}/build-only-1.0-${BUILD_HASH}"
  "${PYTHON_BIN}" - "${PIPELINE_ROOT}/sources-template.json" "${PIPELINE_ROOT}/sources-lock.json" <<'PY'
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

def digest(number):
    return f"sha256:{number:064x}"

snapshot = "https://snapshot.ubuntu.com/ubuntu/20260805T000000Z"
source["status"] = "complete"
source["resolved_on"] = "2026-08-05"
source["unresolved"] = []
verified = source["verified"]
verified["nvidia_hpc_benchmarks_oci"] = {
    "image": "nvcr.io/nvidia/hpc-benchmarks",
    "tag": "26.02",
    "index_digest": digest(1),
    "platforms": {
        "linux-x86_64-v4": {
            "oci_platform": "linux/amd64",
            "descriptor_digest": digest(2),
            "config_digest": digest(3),
        },
        "linux-aarch64-gb300": {
            "oci_platform": "linux/arm64",
            "descriptor_digest": digest(4),
            "config_digest": digest(5),
        },
    },
    "resolved_on": "2026-08-05",
}
verified["ubuntu_snapshot"] = {
    "release": "24.04",
    "snapshot_url": snapshot,
    "pockets": [{
        "id": "noble",
        "inrelease_url": f"{snapshot}/dists/noble/InRelease",
        "inrelease_sha256": f"{10:064x}",
        "package_indexes": [
            {
                "architecture": architecture,
                "url": f"{snapshot}/dists/noble/main/binary-{architecture}/Packages.xz",
                "sha256": f"{number:064x}",
            }
            for architecture, number in (("amd64", 11), ("arm64", 12))
        ],
    }],
    "archive_key_fingerprint": "A" * 40,
    "resolved_on": "2026-08-05",
}
verified["ubuntu_archive_key"] = {
    "fingerprint": "A" * 40,
    "source_url": "https://keyserver.ubuntu.com/pks/lookup?op=get&search=synthetic",
    "key_sha256": f"{13:064x}",
    "resolved_on": "2026-08-05",
}

def packages(name, first_hash):
    return [
        {
            "name": name,
            "version": "1.0",
            "architecture": architecture,
            "url": f"{snapshot}/pool/main/{name[0]}/{name}/{name}_1.0_{architecture}.deb",
            "sha256": f"{first_hash + offset:064x}",
        }
        for offset, architecture in enumerate(("amd64", "arm64"))
    ]

verified["ubuntu_builder_packages"] = packages("builder", 20)
verified["ubuntu_final_packages"] = packages("runtime", 30)
tool_projects = {
    "docker-buildx": ("https://github.com/docker/buildx", ("docker", "docker-buildx")),
    "buildkit": ("https://github.com/moby/buildkit", ("buildctl",)),
    "enroot": ("https://github.com/NVIDIA/enroot", ("enroot",)),
    "squashfs-tools": (snapshot, ("mksquashfs", "unsquashfs")),
    "zstd": (snapshot, ("zstd",)),
    "syft": ("https://github.com/anchore/syft", ("syft",)),
    "jq": ("https://github.com/jqlang/jq", ("jq",)),
    "skopeo": ("https://github.com/containers/skopeo", ("skopeo",)),
}
verified["builder_tools"] = []
for tool_offset, (identity, (prefix, binaries)) in enumerate(tool_projects.items(), start=40):
    base_url = f"{prefix}/releases/download/v1.0/{identity}-1.0"
    assets = {}
    for arch_offset, architecture in enumerate(("x86_64", "aarch64")):
        assets[architecture] = {
            "url": f"{base_url}-{architecture}.tar.gz",
            "sha256": f"{tool_offset + arch_offset:064x}",
            "binaries": [
                {
                    "name": binary,
                    "sha256": f"{tool_offset + arch_offset + binary_offset + 100:064x}",
                }
                for binary_offset, binary in enumerate(binaries)
            ],
        }
    verified["builder_tools"].append({
        "id": identity,
        "version": "1.0",
        "source_url": f"{base_url}-source.tar.gz",
        "release_sha256": f"{tool_offset + 200:064x}",
        "assets": assets,
    })
verified["actions_runner_archives"] = [
    {
        "id": identity,
        "architecture": architecture,
        "version": "1.0",
        "url": f"https://github.com/actions/runner/releases/download/v1.0/actions-runner-{identity}-1.0.tar.gz",
        "sha256": f"{300 + offset:064x}",
    }
    for offset, (identity, architecture) in enumerate((
        ("linux-x64", "x64"),
        ("linux-arm64", "arm64"),
    ))
]
Path(sys.argv[2]).write_text(json.dumps(source), encoding="utf-8")
PY
  "${PYTHON_BIN}" - "${PIPELINE_ROOT}/targets.json" "${PIPELINE_ROOT}/sources-lock.json" \
    "${RELEASE_DIR}" "${STORE_ROOT}" "${target}" "${arch}" \
    "${ROOT_HASH}" "${RUNTIME_HASH}" "${BUILD_HASH}" <<'PY'
import json
import sys
from pathlib import Path

targets_path, sources_path, release_raw, store_raw, target, arch, root_hash, runtime_hash, build_hash = sys.argv[1:]
json.loads(Path(targets_path).read_text(encoding="utf-8"))
json.loads(Path(sources_path).read_text(encoding="utf-8"))
release = Path(release_raw)
release.joinpath("metadata.txt").write_text(
    "release_id: plan-fixture\n"
    "os: ubuntu24.04\n"
    f"arch: {arch}\n"
    f"store: {store_raw}\n"
    "env_path: envs/vlad\n",
    encoding="utf-8",
)
lock = {
    "roots": [{"hash": root_hash}],
    "concrete_specs": {
        root_hash: {
            "dependencies": [
                {"hash": runtime_hash, "type": ["link", "run"]},
                {"hash": build_hash, "type": ["build"]},
            ]
        },
        runtime_hash: {"dependencies": []},
        build_hash: {"dependencies": []},
    },
}
release.joinpath("spack.lock").write_text(json.dumps(lock, sort_keys=True), encoding="utf-8")
PY
}

snapshot_tree() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
entries = []
for path in [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]:
    info = path.lstat()
    relative = "." if path == root else path.relative_to(root).as_posix()
    record = [relative, stat.S_IMODE(info.st_mode)]
    if path.is_symlink():
        record.extend(["symlink", os.readlink(path)])
    elif path.is_file():
        record.extend(["file", hashlib.sha256(path.read_bytes()).hexdigest()])
    elif path.is_dir():
        record.append("directory")
    else:
        record.append("other")
    entries.append(record)
payload = json.dumps(entries, separators=(",", ":"), ensure_ascii=True).encode()
print(hashlib.sha256(payload).hexdigest())
PY
}

invoke_plan() {
  local target="$1"
  local base="${2:-nvidia-vlad}"
  env -i \
    HOME="${HOME_ROOT}" \
    LC_ALL=C \
    PATH="${TOOLS_ROOT}:/usr/bin:/bin" \
      PYTHONPATH="${PYTHON_GUARD_ROOT}" \
      TMPDIR="${TMP_BASE}" \
      TOOL_CALL_LOG="${TOOL_CALL_LOG}" \
      VALIDATOR_SWAP_FROM="${VALIDATOR_SWAP_FROM:-}" \
      VALIDATOR_SWAP_TO="${VALIDATOR_SWAP_TO:-}" \
    "${PLAN_SCRIPT}" \
      --base "${base}" \
      --target "${target}" \
      --release-dir "${RELEASE_DIR}" \
      --image-id "${IMAGE_ID}" \
      --candidate-root "${CANDIDATE_ROOT}" \
      --plan-only
}

assert_roots_unchanged() {
  local name="$1"
  local candidate_before="$2"
  local final_before="$3"
  local candidate_after final_after
  candidate_after="$(snapshot_tree "${CANDIDATE_ROOT}")"
  final_after="$(snapshot_tree "${FINAL_ROOT}")"
  if [[ "${candidate_before}" != "${candidate_after}" || "${final_before}" != "${final_after}" ]]; then
    printf 'FAIL: %s changed candidate or final roots\n' "${name}" >&2
    exit 1
  fi
}

assert_plan_tools_unused() {
  local name="$1"
  if [[ -s "${TOOL_CALL_LOG}" ]]; then
    printf 'FAIL: %s invoked a denied tool:\n' "${name}" >&2
    cat "${TOOL_CALL_LOG}" >&2
    exit 1
  fi
}

expect_success() {
  local name="$1"
  shift
  local candidate_before final_before
  candidate_before="$(snapshot_tree "${CANDIDATE_ROOT}")"
  final_before="$(snapshot_tree "${FINAL_ROOT}")"
  : >"${TOOL_CALL_LOG}"
  if ! "$@" >"${OUTPUT_ROOT}/${name}.out" 2>"${OUTPUT_ROOT}/${name}.err"; then
    printf 'FAIL: %s unexpectedly failed\n' "${name}" >&2
    cat "${OUTPUT_ROOT}/${name}.err" >&2
    exit 1
  fi
  assert_roots_unchanged "${name}" "${candidate_before}" "${final_before}"
  assert_plan_tools_unused "${name}"
  printf 'PASS: %s planned without tools or artifact writes\n' "${name}"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local candidate_before final_before status
  candidate_before="$(snapshot_tree "${CANDIDATE_ROOT}")"
  final_before="$(snapshot_tree "${FINAL_ROOT}")"
  : >"${TOOL_CALL_LOG}"
  set +e
  "$@" >"${OUTPUT_ROOT}/${name}.out" 2>"${OUTPUT_ROOT}/${name}.err"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'FAIL: %s accepted an invalid fixture\n' "${name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" "${OUTPUT_ROOT}/${name}.out" "${OUTPUT_ROOT}/${name}.err"; then
    printf 'FAIL: %s did not report expected failure: %s\n' "${name}" "${expected}" >&2
    cat "${OUTPUT_ROOT}/${name}.err" >&2
    exit 1
  fi
  assert_roots_unchanged "${name}" "${candidate_before}" "${final_before}"
  assert_plan_tools_unused "${name}"
  printf 'PASS: %s failed closed before tools or artifact writes\n' "${name}"
}

expect_success publication-pair "${PLAN_SCRIPT}" --self-test-publication
grep -Fqx 'PASS: candidate artifact/checksum pair publication is no-clobber and crash-safe' "${OUTPUT_ROOT}/publication-pair.out"

set +e
SOURCES_PATH_OVERRIDE="${PIPELINE_ROOT}/sources-template.json" \
  "${PIPELINE_ROOT}/tests/validate-locks.real.sh" --emit-synthetic-complete \
  >"${OUTPUT_ROOT}/removed-synthetic-mode.out" 2>"${OUTPUT_ROOT}/removed-synthetic-mode.err"
removed_mode_status=$?
set -e
if [[ "${removed_mode_status}" -eq 0 ]] || grep -Fq '"status":"complete"' "${OUTPUT_ROOT}/removed-synthetic-mode.out"; then
  printf 'FAIL: source-lock validator still exports a synthetic complete production lock\n' >&2
  exit 1
fi
printf 'PASS: source-lock validator exposes no synthetic complete-lock export mode\n'

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_success x86-plan invoke_plan linux-x86_64-v4
grep -Fqx 'artifact:      nvidia-vlad+26.02-linux-x86_64-v4.sqsh' "${OUTPUT_ROOT}/x86-plan.out"

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
cp "${PIPELINE_ROOT}/sources-lock.json" "${PIPELINE_ROOT}/replacement-lock.json"
"${PYTHON_BIN}" - "${PIPELINE_ROOT}/replacement-lock.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["status"] = "blocked"
value["unresolved"] = [{"category": "nvidia_hpc_benchmarks_oci"}]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
VALIDATOR_SWAP_FROM="${PIPELINE_ROOT}/replacement-lock.json"
VALIDATOR_SWAP_TO="${PIPELINE_ROOT}/sources-lock.json"
export VALIDATOR_SWAP_FROM VALIDATOR_SWAP_TO
expect_failure descriptor-bound-lock 'source lock changed while it was being validated' invoke_plan linux-x86_64-v4
unset VALIDATOR_SWAP_FROM VALIDATOR_SWAP_TO
"${PYTHON_BIN}" - "${PIPELINE_ROOT}/sources-lock.json" <<'PY'
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1], encoding="utf-8"))["status"] == "blocked" else 1)
PY
printf 'PASS: plan rejected a source-lock pathname replacement after validation\n'

write_fixture linux-aarch64-gb300 linux-ubuntu24.04-aarch64
expect_success arm-plan invoke_plan linux-aarch64-gb300
grep -Fqx 'artifact:      nvidia-vlad+26.02-linux-aarch64-gb300.sqsh' "${OUTPUT_ROOT}/arm-plan.out"

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
"${PYTHON_BIN}" - "${PIPELINE_ROOT}/sources-lock.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["status"] = "blocked"
value["unresolved"] = [{"category": "nvidia_hpc_benchmarks_oci"}]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
expect_failure blocked-lock 'source lock failed complete structural validation' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
"${PYTHON_BIN}" - "${PIPELINE_ROOT}/sources-lock.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
del value["verified"]["builder_tools"]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
expect_failure incomplete-complete-lock 'source lock failed complete structural validation' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_failure unknown-base 'invalid choice' invoke_plan linux-x86_64-v4 unknown-base

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_failure unsupported-target 'does not support target' invoke_plan linux-x86_64-generic

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
"${PYTHON_BIN}" - "${RELEASE_DIR}/metadata.txt" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace("env_path: envs/vlad", "env_path: envs/hpcsim"), encoding="utf-8")
PY
expect_failure wrong-env-path 'but base' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-aarch64
expect_failure target-arch-mismatch 'release architecture mismatch' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
rm -rf "${STORE_ROOT}/runtime-1.0-${RUNTIME_HASH}"
expect_failure missing-prefix 'runtime closure are not installed' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
mkdir "${STORE_ROOT}/runtime-copy-${RUNTIME_HASH}"
expect_failure duplicate-hash-match 'multiple prefixes for hash' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
"${PYTHON_BIN}" - "${RELEASE_DIR}/spack.lock" "${ROOT_HASH}" <<'PY'
import json, sys
path, root_hash = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
value["concrete_specs"][root_hash]["dependencies"][0].pop("type")
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
expect_failure malformed-dependency-edge 'dependency edge has no deptype' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
"${PYTHON_BIN}" - "${RELEASE_DIR}/spack.lock" "${ROOT_HASH}" <<'PY'
import json, sys
path, root_hash = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
value["concrete_specs"][root_hash]["dependencies"][0].pop("hash")
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
expect_failure missing-runtime-child 'runtime dependency edge has no valid child' invoke_plan linux-x86_64-v4

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
mkdir -p "${CANDIDATE_ROOT}/linux-x86_64-v4/${IMAGE_ID}"
NONPLAN_BUILD_ROOT="${TMP_BASE}/nonplan-build"
candidate_before="$(snapshot_tree "${CANDIDATE_ROOT}")"
final_before="$(snapshot_tree "${FINAL_ROOT}")"
: >"${TOOL_CALL_LOG}"
artifact_path="${CANDIDATE_ROOT}/linux-x86_64-v4/${IMAGE_ID}/nvidia-vlad+26.02-linux-x86_64-v4.sqsh"
checksum_path="${artifact_path}.sha256"
printf 'retained artifact\n' >"${artifact_path}"
printf 'retained checksum\n' >"${checksum_path}"
set +e
env -i \
  HOME="${HOME_ROOT}" \
  LC_ALL=C \
  PATH="${TOOLS_ROOT}:/usr/bin:/bin" \
  PYTHONPATH="${PYTHON_GUARD_ROOT}" \
  TMPDIR="${TMP_BASE}" \
  TOOL_CALL_LOG="${TOOL_CALL_LOG}" \
  "${PLAN_SCRIPT}" \
    --base nvidia-vlad \
    --target linux-x86_64-v4 \
    --release-dir "${RELEASE_DIR}" \
    --image-id "${IMAGE_ID}" \
    --candidate-root "${CANDIDATE_ROOT}" \
    --enroot-build-root "${NONPLAN_BUILD_ROOT}" \
    >"${OUTPUT_ROOT}/existing-output.out" 2>"${OUTPUT_ROOT}/existing-output.err"
existing_status=$?
set -e
if [[ "${existing_status}" -eq 0 ]] || \
   ! grep -Fq 'candidate output already exists' "${OUTPUT_ROOT}/existing-output.err" || \
   [[ -s "${TOOL_CALL_LOG}" ]] || \
   [[ "$(cat "${artifact_path}")" != 'retained artifact' ]] || \
   [[ "$(cat "${checksum_path}")" != 'retained checksum' ]]; then
  printf 'FAIL: existing candidate artifact/checksum were not preserved before tool execution\n' >&2
  cat "${OUTPUT_ROOT}/existing-output.err" >&2
  exit 1
fi
rm "${artifact_path}" "${checksum_path}"
printf 'PASS: existing candidate artifact and checksum failed closed without clobbering\n'

: >"${TOOL_CALL_LOG}"
mkdir -p "${NONPLAN_BUILD_ROOT}/cache"
untrusted_cache="${NONPLAN_BUILD_ROOT}/cache/hpc-benchmarks+26.02-linux-x86_64-v4-sha256-$(printf '1%.0s' {1..64}).sqsh"
printf 'attacker-controlled-sqsh\n' >"${untrusted_cache}"
chmod 0444 "${untrusted_cache}"
set +e
env -i \
  HOME="${HOME_ROOT}" \
  LC_ALL=C \
  PATH="${TOOLS_ROOT}:/usr/bin:/bin" \
  PYTHONPATH="${PYTHON_GUARD_ROOT}" \
  TMPDIR="${TMP_BASE}" \
  TOOL_CALL_LOG="${TOOL_CALL_LOG}" \
  "${PLAN_SCRIPT}" \
    --base nvidia-vlad \
    --target linux-x86_64-v4 \
    --release-dir "${RELEASE_DIR}" \
    --image-id "${IMAGE_ID}" \
    --candidate-root "${CANDIDATE_ROOT}" \
    --enroot-build-root "${NONPLAN_BUILD_ROOT}" \
    >"${OUTPUT_ROOT}/untrusted-base-cache.out" 2>"${OUTPUT_ROOT}/untrusted-base-cache.err"
cache_status=$?
set -e
if [[ "${cache_status}" -eq 0 ]] || \
   ! grep -Fq 'skopeo copy failed' "${OUTPUT_ROOT}/untrusted-base-cache.err" || \
   ! grep -q '^skopeo' "${TOOL_CALL_LOG}" || \
   grep -q $'^enroot\tcreate' "${TOOL_CALL_LOG}"; then
  printf 'FAIL: untrusted base cache bytes were reused instead of refreshing the locked descriptor\n' >&2
  cat "${OUTPUT_ROOT}/untrusted-base-cache.err" >&2
  exit 1
fi
chmod 0600 "${untrusted_cache}"
rm "${untrusted_cache}"
printf 'PASS: preseeded regular cache bytes were ignored and the locked descriptor was refreshed\n'

: >"${TOOL_CALL_LOG}"
set +e
env -i \
  HOME="${HOME_ROOT}" \
  LC_ALL=C \
  PATH="${TOOLS_ROOT}:/usr/bin:/bin" \
  PYTHONPATH="${PYTHON_GUARD_ROOT}" \
  TMPDIR="${TMP_BASE}" \
  TOOL_CALL_LOG="${TOOL_CALL_LOG}" \
  "${PLAN_SCRIPT}" \
    --base nvidia-vlad \
    --target linux-x86_64-v4 \
    --release-dir "${RELEASE_DIR}" \
    --image-id "${IMAGE_ID}" \
    --candidate-root "${CANDIDATE_ROOT}" \
    --enroot-build-root "${NONPLAN_BUILD_ROOT}" \
    >"${OUTPUT_ROOT}/nonplan.out" 2>"${OUTPUT_ROOT}/nonplan.err"
nonplan_status=$?
set -e
if [[ "${nonplan_status}" -eq 0 ]] || ! grep -q '^skopeo' "${TOOL_CALL_LOG}"; then
  printf 'FAIL: deliberate non-plan child did not stop at the fake-tool boundary\n' >&2
  exit 1
fi
assert_roots_unchanged nonplan-fake-tool "${candidate_before}" "${final_before}"
if "${PYTHON_BIN}" - "${CANDIDATE_ROOT}" "${FINAL_ROOT}" <<'PY'
import sys
from pathlib import Path
raise SystemExit(0 if any(any(Path(root).rglob("*.sqsh")) for root in sys.argv[1:]) else 1)
PY
then
  printf 'FAIL: deliberate non-plan child wrote an image artifact\n' >&2
  exit 1
fi
printf 'PASS: deliberate non-plan child stopped at fake skopeo before artifact writes\n'

printf 'PASS: plan fixture suite used only disposable local files, sanitized environment variables, and denied tool stubs; no NFS, Spack, credentials, sockets, or network were required\n'
