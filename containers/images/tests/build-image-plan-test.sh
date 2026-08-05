#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BUILD_IMAGE="${ROOT_DIR}/containers/images/build-image.sh"
PYTHON_BIN="$(command -v python3)"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/chapar-image-plan.XXXXXX")"
TMP_BASE="$(cd "${TMP_BASE}" && pwd -P)"
trap 'chmod -R u+rwX "${TMP_BASE}" 2>/dev/null || true; rm -rf "${TMP_BASE}"' EXIT HUP INT TERM

PIPELINE_ROOT="${TMP_BASE}/pipeline"
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

mkdir -p "${PIPELINE_ROOT}/tests" "${CANDIDATE_ROOT}" "${FINAL_ROOT}" \
  "${TOOLS_ROOT}" "${HOME_ROOT}" "${OUTPUT_ROOT}" "${PYTHON_GUARD_ROOT}"
cp "${BUILD_IMAGE}" "${PLAN_SCRIPT}"
chmod 0755 "${PLAN_SCRIPT}"
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
  "${PYTHON_BIN}" - "${PIPELINE_ROOT}/targets.json" "${PIPELINE_ROOT}/sources-lock.json" \
    "${RELEASE_DIR}" "${STORE_ROOT}" "${target}" "${arch}" \
    "${ROOT_HASH}" "${RUNTIME_HASH}" "${BUILD_HASH}" <<'PY'
import json
import sys
from pathlib import Path

targets_path, sources_path, release_raw, store_raw, target, arch, root_hash, runtime_hash, build_hash = sys.argv[1:]
targets = {
    "linux-x86_64-generic": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64",
    },
    "linux-x86_64-v4": {
        "oci_platform": "linux/amd64",
        "native_arch": "x86_64",
        "spack_target": "x86_64_v4",
    },
    "linux-aarch64-gb300": {
        "oci_platform": "linux/arm64",
        "native_arch": "aarch64",
        "spack_target": "aarch64",
    },
}
Path(targets_path).write_text(json.dumps({"targets": targets}, sort_keys=True), encoding="utf-8")
sources = {
    "status": "complete",
    "unresolved": [],
    "verified": {
        "nvidia_hpc_benchmarks_oci": {
            "image": "nvcr.io/nvidia/hpc-benchmarks",
            "tag": "26.02",
            "platforms": {
                "linux-x86_64-v4": {"descriptor_digest": "sha256:" + "1" * 64},
                "linux-aarch64-gb300": {"descriptor_digest": "sha256:" + "2" * 64},
            },
        }
    },
}
Path(sources_path).write_text(json.dumps(sources, sort_keys=True), encoding="utf-8")
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
    "${PLAN_SCRIPT}" \
      --base "${base}" \
      --target "${target}" \
      --release-dir "${RELEASE_DIR}" \
      --image-id "${IMAGE_ID}" \
      --candidate-root "${CANDIDATE_ROOT}" \
      --plan-only
}

invoke_plan_with_arch_contract() {
  local target="$1"
  local output
  output="$(invoke_plan "${target}")" || return
  printf '%s\n' "${output}"
  local release_line="$(printf '%s\n' "${output}" | grep '^release:')"
  local arch="${release_line##*arch=}"
  case "${target}" in
    linux-x86_64-v4) [[ "${arch}" == *x86_64_v4 ]] ;;
    linux-aarch64-gb300) [[ "${arch}" == *aarch64 ]] ;;
    *) return 0 ;;
  esac || {
    printf 'plan contract rejected target/arch mismatch: target=%s arch=%s\n' "${target}" "${arch}" >&2
    return 65
  }
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

write_fixture linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_success x86-plan invoke_plan_with_arch_contract linux-x86_64-v4
grep -Fqx 'artifact:      nvidia-vlad+26.02-linux-x86_64-v4.sqsh' "${OUTPUT_ROOT}/x86-plan.out"

write_fixture linux-aarch64-gb300 linux-ubuntu24.04-aarch64
expect_success arm-plan invoke_plan_with_arch_contract linux-aarch64-gb300
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
expect_failure blocked-lock 'source lock is not usable' invoke_plan linux-x86_64-v4

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
expect_failure target-arch-mismatch 'plan contract rejected target/arch mismatch' invoke_plan_with_arch_contract linux-x86_64-v4

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
mkdir -p "${CANDIDATE_ROOT}/linux-x86_64-v4/${IMAGE_ID}"
NONPLAN_BUILD_ROOT="${TMP_BASE}/nonplan-build"
candidate_before="$(snapshot_tree "${CANDIDATE_ROOT}")"
final_before="$(snapshot_tree "${FINAL_ROOT}")"
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
