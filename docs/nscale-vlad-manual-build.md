# Manual nscale Vlad source and image build

This is a future live procedure. Repository QA validates its structure offline and
does not execute any command in this document. The production source lock remains blocked and is not modified by this runbook. Do not begin a live build until an
independent approver supplies an immutable source-approval receipt and the tracked
lock is separately completed with authoritative provenance.

The four receipt contracts reject unknown and recursive duplicate keys. Their exact
schema identities and sorted key sets are:

- `chapar-vlad-source-approval/v1`: `approved_at,approved_by,change_ticket,chapar_commit,chapar_remote,schema,source_lock_path,source_lock_sha256`
- `chapar-vlad-release-binding/v1`: `chapar_commit,metadata_path,metadata_sha256,release_dir,release_id,schema,source_lock_sha256,spack_lock_path,spack_lock_sha256,status,target`
- `chapar-vlad-builder-handoff/v1`: `build_root,chapar_commit,image_id,image_path,image_sha256,image_size,release_binding,release_binding_sha256,schema,source_lock_sha256,target,validation_root`
- `chapar-vlad-runtime-receipt/v1`: `builder_handoff_sha256,image_path,image_sha256,release_binding_sha256,runtime_preflight_sha256,runtime_receipt_path,schema,smoke_output_sha256,status,target,validator_image_root,validator_root`

Before any role starts, an administrator provisions validator and publisher code
roots at the exact approved commit. Every executed checkout file and every ancestor
from `/` is UID 0-owned, has no group/other write bit, is effectively nonwritable
including ACL effects, and byte-matches its Git blob. Builder access to protected
roots is denied. After each authenticated handoff the administrator provisions the
validator-image, validator-receipt, or publisher-evidence leaf as an empty role-owned
0755 directory beneath a UID 0-owned 0555 nonwritable chain. Immutable path and
digest values cross roles only through authenticated operator handoff.

## Builder operator gates

**OPERATOR GATE - NOT EXECUTED BY REPOSITORY QA**

Prerequisites: approved source receipt path/digest, approver and ticket identities,
target-native builder, pre-provisioned protected roots, site-contract digest, and
explicit release/image/partition identifiers.

Evidence: source approval, lock digest, generated lock digest, integrity-passed
release binding, sealed candidate, and builder handoff path/digest.

Stop conditions: any nonzero command, mismatch, collision, writable protected root,
missing/ambiguous release, failed integrity, or blocked/incomplete source lock.

```bash
set -euo pipefail
: "${CHAPAR_COMMIT:?}" "${SOURCE_APPROVAL_RECEIPT:?}" "${SOURCE_APPROVAL_SHA256:?}" "${EXPECTED_APPROVED_BY:?}" "${EXPECTED_CHANGE_TICKET:?}" "${TARGET:?}" "${RELEASE_ID:?}" "${IMAGE_ID:?}" "${PARTITION:?}" "${SITE_CONTRACT_SHA256:?}"
[[ "$CHAPAR_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$SOURCE_APPROVAL_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$SITE_CONTRACT_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$RELEASE_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "$IMAGE_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "$PARTITION" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
[[ "$TARGET" == linux-x86_64-v4 || "$TARGET" == linux-aarch64-gb300 ]]
SOURCE_CLONE_ROOT=/home/hpcadmin/chapar-sources/$CHAPAR_COMMIT-$TARGET; BUILD_ROOT=/vast/chapar/worktrees/$CHAPAR_COMMIT-$TARGET; SPACK_ROOT=/vast/chapar/spack; VLAD_ROOT=/vast/chapar/vlad
INSTALL_ROOT=/vast/chapar/install; BUILDCACHE_ROOT=/vast/chapar/buildcache; CCACHE_ROOT=/vast/chapar/ccache
CANDIDATE_ROOT=/vast/enroot-cache/$(uname -m)/chapar-vlad; FINAL_ROOT=/home/hpcadmin/shared/enroot-cache
IMAGE_ROOT="$FINAL_ROOT/chapar-vlad"; SITE_CONTRACT=/etc/chapar/vlad-image/site-contract.json
VALIDATOR_ROOT=/vast/chapar-validator-receipts; PUBLISHER_EVIDENCE_ROOT=/home/hpcadmin/shared/enroot-cache/chapar-vlad-evidence
VALIDATOR_CODE_ROOT=/vast/chapar-validator-code/$CHAPAR_COMMIT; VALIDATOR_IMAGE_ROOT=/vast/chapar-validator-images; PUBLISHER_CODE_ROOT=/vast/chapar-publisher-code/$CHAPAR_COMMIT
VALIDATION_ROOT=/vast/chapar/validation/$TARGET/$RELEASE_ID
BUILD_PREFLIGHT_IMAGE_ROOT=/vast/enroot-cache/$(uname -m)/chapar-vlad-preflight-images
CHAPAR_REMOTE=https://github.com/nscaledev/chapar.git
test "$(findmnt -n -o TARGET -T /vast)" = /vast; [[ "$(findmnt -n -o FSTYPE -T /vast)" =~ ^nfs4?$ ]]
test "$(findmnt -n -o TARGET -T "$FINAL_ROOT")" = /home; [[ "$(findmnt -n -o FSTYPE -T "$FINAL_ROOT")" =~ ^nfs4?$ ]]
df -hT /home/hpcadmin /vast; for protected in "$FINAL_ROOT" "$VALIDATOR_ROOT" "$VALIDATOR_CODE_ROOT" "$VALIDATOR_IMAGE_ROOT" "$PUBLISHER_CODE_ROOT" "$PUBLISHER_EVIDENCE_ROOT"; do test -d "$protected"; test ! -w "$protected"; done
command -v git bash python3 enroot skopeo srun sha256sum
install -d -m 0755 /home/hpcadmin/chapar-sources
test ! -e "$SOURCE_CLONE_ROOT"
git clone --filter=blob:none --no-checkout "$CHAPAR_REMOTE" "$SOURCE_CLONE_ROOT"
git -C "$SOURCE_CLONE_ROOT" fetch --depth=1 origin "$CHAPAR_COMMIT"
git -C "$SOURCE_CLONE_ROOT" checkout --detach "$CHAPAR_COMMIT"
test "$(git -C "$SOURCE_CLONE_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"
test "$(git -C "$SOURCE_CLONE_ROOT" cat-file -t "$CHAPAR_COMMIT")" = commit
test -z "$(git -C "$SOURCE_CLONE_ROOT" status --porcelain)"
APPROVAL_JSON="$(python3 "$SOURCE_CLONE_ROOT/ci/verify-vlad-source-approval.py" --receipt "$SOURCE_APPROVAL_RECEIPT" --expected-sha256 "$SOURCE_APPROVAL_SHA256" --expected-approved-by "$EXPECTED_APPROVED_BY" --expected-change-ticket "$EXPECTED_CHANGE_TICKET" --chapar-root "$SOURCE_CLONE_ROOT")"
APPROVED_SOURCE_LOCK="$SOURCE_CLONE_ROOT/containers/images/sources-lock.json"
APPROVED_LOCK_SHA256="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["source_lock_sha256"])' <<<"$APPROVAL_JSON")"
test ! -e "$BUILD_ROOT"; mkdir -p "$(dirname "$BUILD_ROOT")"; git -C "$SOURCE_CLONE_ROOT" worktree add --detach "$BUILD_ROOT" "$CHAPAR_COMMIT"
cd "$BUILD_ROOT"; SOURCE_LOCK="$BUILD_ROOT/containers/images/sources-lock.json"
verify_lock(){ local source_hash build_hash build_status; source_hash="$(sha256sum "$APPROVED_SOURCE_LOCK" | awk '{print $1}')"; build_hash="$(sha256sum "$SOURCE_LOCK" | awk '{print $1}')"; test "$source_hash" = "$APPROVED_LOCK_SHA256"; test "$build_hash" = "$APPROVED_LOCK_SHA256"; test "$(git -C "$SOURCE_CLONE_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"; test "$(git -C "$BUILD_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"; test "$(git -C "$SOURCE_CLONE_ROOT" remote get-url origin)" = "$CHAPAR_REMOTE"; test "$(git -C "$BUILD_ROOT" remote get-url origin)" = "$CHAPAR_REMOTE"; test -z "$(git -C "$SOURCE_CLONE_ROOT" status --porcelain --untracked-files=all)"; build_status="$(git -C "$BUILD_ROOT" status --porcelain --untracked-files=all)"; test -z "$build_status" || test "$build_status" = "?? envs/vlad/spack.lock"; if test -n "${GENERATED_LOCK_SHA256:-}"; then test "$(sha256sum "$BUILD_ROOT/envs/vlad/spack.lock" | awk '{print $1}')" = "$GENERATED_LOCK_SHA256"; fi; bash containers/images/tests/validate-locks.sh --require-complete; }
verify_lock
read -r SPACK_CORE_COMMIT SPACK_PACKAGES_COMMIT < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); r={x["id"]:x["commit"] for x in d["verified"]["spack_repositories"]}; print(r["spack-core"], r["spack-packages"])' "$SOURCE_LOCK")
[[ "$SPACK_CORE_COMMIT" =~ ^[0-9a-f]{40}$ && "$SPACK_PACKAGES_COMMIT" =~ ^[0-9a-f]{40}$ ]]
CHAPAR_SPACK_ROOT="$SPACK_ROOT" SPACK_REF="$SPACK_CORE_COMMIT" bash etc/install-spack.sh
test "$(git -C "$SPACK_ROOT" rev-parse HEAD)" = "$SPACK_CORE_COMMIT"
export CHAPAR_SPACK_ROOT="$SPACK_ROOT" CHAPAR_SITE_CONFIG=/dev/null
source "$SPACK_ROOT/share/spack/setup-env.sh"; source "$BUILD_ROOT/etc/init.sh"
test "$CHAPAR_ROOT" = "$BUILD_ROOT"; test "$SPACK_ROOT" = "$CHAPAR_SPACK_ROOT"; test "$CHAPAR_SITE_CONFIG" = /dev/null
test "$(git -C "$SOURCE_CLONE_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"; test "$(git -C "$SOURCE_CLONE_ROOT" remote get-url origin)" = "$CHAPAR_REMOTE"
test "$(git -C "$SPACK_ROOT" rev-parse HEAD)" = "$SPACK_CORE_COMMIT"
spack repo update
BUILTIN_REPO_PATH="$(spack python -c 'import spack.repo; print(spack.repo.PATH.get_repo("builtin").root)')"
test "$(git -C "$BUILTIN_REPO_PATH" rev-parse HEAD)" = "$SPACK_PACKAGES_COMMIT"; spack repo list
verify_lock
case "$TARGET" in linux-x86_64-v4) EXPECTED_NATIVE_ARCH=x86_64; EXPECTED_SPACK_FAMILY=x86_64; EXPECTED_CONCRETE_TARGET=x86_64_v4 ;; linux-aarch64-gb300) EXPECTED_NATIVE_ARCH=aarch64; EXPECTED_SPACK_FAMILY=aarch64; EXPECTED_CONCRETE_TARGET=aarch64 ;; *) exit 2 ;; esac
test "$(uname -m)" = "$EXPECTED_NATIVE_ARCH"; test "$(spack arch --family)" = "$EXPECTED_SPACK_FAMILY"
mkdir -p "$VALIDATION_ROOT"
spack -e envs/vlad spec --fresh --yaml zlib target="$(spack arch --family)" > "$VALIDATION_ROOT/native-spec.yaml"
python3 envs/vlad/tests/target-policy-test.py --assert-concrete-yaml "$VALIDATION_ROOT/native-spec.yaml" --expected-target "$EXPECTED_CONCRETE_TARGET"
spack -e envs/vlad concretize -f
test -f envs/vlad/spack.lock
GENERATED_LOCK_SHA256="$(sha256sum envs/vlad/spack.lock | awk '{print $1}')"
```

The same builder shell immediately continues with the next fence.

```bash
verify_lock
export VLAD_ROOT CHAPAR_INSTALL_TREE_ROOT="$INSTALL_ROOT" CHAPAR_BUILDCACHE_ROOT="$BUILDCACHE_ROOT" CCACHE_DIR="$CCACHE_ROOT" PUBLISH_BUILDCACHE=true
test -z "$(find "$VLAD_ROOT" -type d -path "*/releases/$RELEASE_ID" -print -quit 2>/dev/null)"
bash envs/vlad/release.sh build "$RELEASE_ID"
test "$(sha256sum envs/vlad/spack.lock | awk '{print $1}')" = "$GENERATED_LOCK_SHA256"
mapfile -d '' RELEASE_METADATA < <(find "$VLAD_ROOT" -type f -path "*/releases/$RELEASE_ID/metadata.txt" -print0)
test "${#RELEASE_METADATA[@]}" -eq 1
RELEASE_DIR="$(dirname "${RELEASE_METADATA[0]}")"
test -d "$RELEASE_DIR"
grep -Fx "release_id: $RELEASE_ID" "$RELEASE_DIR/metadata.txt"
MODULE_PATH="$RELEASE_DIR/modulefiles" ENV_NAME=vlad ./validation/run integrity-test
python3 ci/verify-vlad-source-approval.py --write-release-binding "$VALIDATION_ROOT/release-binding.json" --release-dir "$RELEASE_DIR" --metadata "$RELEASE_DIR/metadata.txt" --spack-lock "$BUILD_ROOT/envs/vlad/spack.lock" --chapar-commit "$CHAPAR_COMMIT" --source-lock-sha256 "$APPROVED_LOCK_SHA256" --target "$TARGET" --release-id "$RELEASE_ID" --status integrity-passed
python3 ci/verify-vlad-source-approval.py --verify-release-binding "$VALIDATION_ROOT/release-binding.json" --release-dir "$RELEASE_DIR" --metadata "$RELEASE_DIR/metadata.txt" --spack-lock "$BUILD_ROOT/envs/vlad/spack.lock" --chapar-commit "$CHAPAR_COMMIT" --source-lock-sha256 "$APPROVED_LOCK_SHA256" --target "$TARGET" --release-id "$RELEASE_ID" --status integrity-passed
bash envs/vlad/release.sh promote "$RELEASE_ID"
verify_lock
QUALIFIED_CANDIDATE="$CANDIDATE_ROOT/$TARGET/$IMAGE_ID"
install -d -m 0755 "$CANDIDATE_ROOT/$TARGET"
test ! -L "$CANDIDATE_ROOT/$TARGET"
test ! -e "$QUALIFIED_CANDIDATE"
mkdir "$QUALIFIED_CANDIDATE"
chmod 0755 "$QUALIFIED_CANDIDATE"
install -d -m 0755 "$BUILD_PREFLIGHT_IMAGE_ROOT" "$BUILD_PREFLIGHT_IMAGE_ROOT/$TARGET"
chmod 0555 "$BUILD_PREFLIGHT_IMAGE_ROOT" "$BUILD_PREFLIGHT_IMAGE_ROOT/$TARGET"
test ! -L "$CANDIDATE_ROOT/$TARGET/$IMAGE_ID"
test ! -L "$BUILD_PREFLIGHT_IMAGE_ROOT/$TARGET"
findmnt -T "$CANDIDATE_ROOT/$TARGET/$IMAGE_ID"
test -w "$CANDIDATE_ROOT/$TARGET/$IMAGE_ID"
test ! -w "$BUILD_PREFLIGHT_IMAGE_ROOT"
test ! -w "$BUILD_PREFLIGHT_IMAGE_ROOT/$TARGET"
python3 ci/verify-vlad-source-approval.py --verify-release-binding "$VALIDATION_ROOT/release-binding.json" --release-dir "$RELEASE_DIR" --metadata "$RELEASE_DIR/metadata.txt" --spack-lock "$BUILD_ROOT/envs/vlad/spack.lock" --chapar-commit "$CHAPAR_COMMIT" --source-lock-sha256 "$APPROVED_LOCK_SHA256" --target "$TARGET" --release-id "$RELEASE_ID" --status integrity-passed
bash containers/images/preflight.sh --mode build --base nvidia-vlad --target "$TARGET" --image-id "$IMAGE_ID" --candidate-root "$CANDIDATE_ROOT" --validation-root "$VALIDATION_ROOT" --image-root "$BUILD_PREFLIGHT_IMAGE_ROOT" --site-contract "$SITE_CONTRACT" --site-contract-sha256 "$SITE_CONTRACT_SHA256"
bash containers/images/build-image.sh --base nvidia-vlad --target "$TARGET" --release-dir "$RELEASE_DIR" --image-id "$IMAGE_ID" --candidate-root "$CANDIDATE_ROOT" --enroot-build-root "/vast/enroot-cache/$(uname -m)"
CANDIDATE_PATH="$CANDIDATE_ROOT/$TARGET/$IMAGE_ID/nvidia-vlad+26.02-$TARGET.sqsh"
test -f "$CANDIDATE_PATH"
(cd "$(dirname "$CANDIDATE_PATH")" && sha256sum -c "$(basename "$CANDIDATE_PATH").sha256")
CANDIDATE_SHA256="$(sha256sum "$CANDIDATE_PATH" | awk '{print $1}')"
CANDIDATE_SIZE="$(stat -c %s "$CANDIDATE_PATH")"
test -n "$CANDIDATE_SHA256"
test "$CANDIDATE_SIZE" -gt 0
verify_lock
SEALED_DIR="$CANDIDATE_ROOT/$TARGET/$IMAGE_ID/$CANDIDATE_SHA256"
test ! -e "$SEALED_DIR"
mkdir "$SEALED_DIR"
SEALED_PATH="$SEALED_DIR/$(basename "$CANDIDATE_PATH")"
ln "$CANDIDATE_PATH" "$SEALED_PATH"
chmod 0444 "$SEALED_PATH"; chmod 0555 "$SEALED_DIR"
BUILDER_HANDOFF="$VALIDATION_ROOT/builder-handoff-$TARGET-$IMAGE_ID.json"
python3 ci/verify-vlad-source-approval.py --write-builder-handoff "$BUILDER_HANDOFF" --build-root "$BUILD_ROOT" --chapar-commit "$CHAPAR_COMMIT" --source-lock-sha256 "$APPROVED_LOCK_SHA256" --release-binding "$VALIDATION_ROOT/release-binding.json" --target "$TARGET" --image-id "$IMAGE_ID" --image "$SEALED_PATH" --image-sha256 "$CANDIDATE_SHA256" --image-size "$CANDIDATE_SIZE"
BUILDER_HANDOFF_SHA256="$(sha256sum "$BUILDER_HANDOFF" | awk '{print $1}')"
printf 'BUILDER_HANDOFF=%s\nBUILDER_HANDOFF_SHA256=%s\n' "$BUILDER_HANDOFF" "$BUILDER_HANDOFF_SHA256"
```

## Validator operator gate

**OPERATOR GATE - NOT EXECUTED BY REPOSITORY QA**

Prerequisites: fresh validator-authorized allocation, authenticated builder handoff,
administrator-provisioned protected checkout and empty validator leaves, and explicit
Pyxis-job approval.

Evidence: validator-custody image, runtime preflight, Pyxis smoke output, sealed runtime
receipt, and receipt path/digest.

Stop conditions: any nonzero command, checkout/blob drift, unsafe Git configuration,
handoff drift, evidence identity/permission drift, runtime failure, or seal failure.

```bash
set -euo pipefail
verify_protected_checkout() {
  python3 - "$@" <<'PY'
import ctypes, errno, os, stat, subprocess, sys
root, commit, *relative_paths = sys.argv[1:]
def require(ok, message):
  if not ok: raise SystemExit(f"protected checkout failed: {message}")
require(root.startswith("/") and os.path.normpath(root) == root, "noncanonical root")
require(len(commit) == 40 and all(c in "0123456789abcdef" for c in commit), "commit")
require(relative_paths, "executed paths")
libc = ctypes.CDLL(None, use_errno=True)
def require_nonwritable_fd(fd, label):
  ctypes.set_errno(0)
  result = libc.syscall(439, fd, ctypes.c_char_p(b""), os.W_OK, 0x1000 | 0x200)
  error = ctypes.get_errno()
  require(result == -1 and error in (errno.EACCES, errno.EROFS), f"effective writable or faccessat2 unavailable: {label}:{result}:{error}")
def checked_read(absolute_path):
  parts = absolute_path.split("/")[1:]
  require(parts and all(p not in ("", ".", "..") for p in parts), "path components")
  fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
  try:
      root_stat = os.fstat(fd)
      require(root_stat.st_uid == 0 and not (root_stat.st_mode & 0o022), "root protection")
      require_nonwritable_fd(fd, "/")
      for index, part in enumerate(parts):
          flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
          if index < len(parts) - 1: flags |= os.O_DIRECTORY
          next_fd = os.open(part, flags, dir_fd=fd)
          os.close(fd); fd = next_fd
          info = os.fstat(fd)
          expected_type = stat.S_ISDIR(info.st_mode) if index < len(parts) - 1 else stat.S_ISREG(info.st_mode)
          require(expected_type and info.st_uid == 0 and not (info.st_mode & 0o022), f"owner/mode/type: {part}")
          require_nonwritable_fd(fd, part)
      before = os.fstat(fd); chunks = []
      while True:
          chunk = os.read(fd, 1024 * 1024)
          if not chunk: break
          chunks.append(chunk)
      after = os.fstat(fd)
      require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), "file changed")
      return b"".join(chunks)
  finally:
      os.close(fd)
for relative_path in relative_paths:
  require(not relative_path.startswith("/") and os.path.normpath(relative_path) == relative_path and ".." not in relative_path.split("/"), "relative path")
  actual = checked_read(root + "/" + relative_path)
  git_env = {"PATH":"/usr/bin:/bin", "HOME":"/nonexistent", "LANG":"C", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_OPTIONAL_LOCKS":"0"}
  expected = subprocess.run(["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", root, "-c", f"safe.directory={root}", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "cat-file", "blob", f"{commit}:{relative_path}"], check=True, stdout=subprocess.PIPE, env=git_env).stdout
  require(actual == expected, f"blob mismatch: {relative_path}")
PY
}
trusted_git() { local root="$1"; shift; env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 /usr/bin/git --no-pager --no-replace-objects -C "$root" -c "safe.directory=$root" -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.untrackedCache=false "$@"; }
: "${VALIDATOR_CODE_ROOT:?}" "${CHAPAR_COMMIT:?}" "${BUILDER_HANDOFF:?}" "${BUILDER_HANDOFF_SHA256:?}" "${PYXIS_JOB_APPROVED:?}" "${PARTITION:?}" "${SITE_CONTRACT_SHA256:?}"
test "$PYXIS_JOB_APPROVED" = yes
SITE_CONTRACT=/etc/chapar/vlad-image/site-contract.json
test "$VALIDATOR_CODE_ROOT" = "/vast/chapar-validator-code/$CHAPAR_COMMIT"
verify_protected_checkout "$VALIDATOR_CODE_ROOT" "$CHAPAR_COMMIT" ci/verify-vlad-source-approval.py ci/install-validated-sqsh.py containers/images/preflight.sh
test "$(trusted_git "$VALIDATOR_CODE_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"; test -z "$(trusted_git "$VALIDATOR_CODE_ROOT" status --porcelain --untracked-files=all)"
HELPER="$VALIDATOR_CODE_ROOT/ci/verify-vlad-source-approval.py"
HANDOFF_JSON="$(python3 "$HELPER" --verify-builder-handoff "$BUILDER_HANDOFF" --expected-sha256 "$BUILDER_HANDOFF_SHA256" --expected-chapar-commit "$CHAPAR_COMMIT")"
mapfile -t HANDOFF_VALUES < <(python3 -c 'import json,sys; d=json.load(sys.stdin); keys=("build_root","target","image_id","image_path","image_sha256","image_size","validation_root","release_binding"); print("\n".join(str(d[k]) for k in keys))' <<<"$HANDOFF_JSON")
test "${#HANDOFF_VALUES[@]}" -eq 8
BUILD_ROOT=${HANDOFF_VALUES[0]}; TARGET=${HANDOFF_VALUES[1]}; IMAGE_ID=${HANDOFF_VALUES[2]}; IMAGE_PATH=${HANDOFF_VALUES[3]}; IMAGE_SHA256=${HANDOFF_VALUES[4]}; IMAGE_SIZE=${HANDOFF_VALUES[5]}; VALIDATION_ROOT=${HANDOFF_VALUES[6]}; RELEASE_BINDING=${HANDOFF_VALUES[7]}
SOURCE_IMAGE_PATH="$IMAGE_PATH"
VALIDATOR_IMAGE_ROOT=/vast/chapar-validator-images
VALIDATOR_IMAGE_DIR="$VALIDATOR_IMAGE_ROOT/$TARGET/$IMAGE_ID/$IMAGE_SHA256"
VALIDATOR_IMAGE_DIR_JSON="$(python3 "$HELPER" --verify-empty-evidence-directory "$VALIDATOR_IMAGE_DIR" --owner-role validator)"
VALIDATOR_IMAGE_DIR_IDENTITY="$(python3 "$HELPER" --extract-canonical-field --schema directory-identity --field directory_identity <<<"$VALIDATOR_IMAGE_DIR_JSON")"
IMAGE_PATH="$VALIDATOR_IMAGE_DIR/$(basename "$SOURCE_IMAGE_PATH")"
python3 "$VALIDATOR_CODE_ROOT/ci/install-validated-sqsh.py" --source "$SOURCE_IMAGE_PATH" --destination-directory "$VALIDATOR_IMAGE_DIR" --destination-name "$(basename "$SOURCE_IMAGE_PATH")" --expected-sha256 "$IMAGE_SHA256" --expected-size "$IMAGE_SIZE"
python3 "$HELPER" --seal-evidence-directory "$VALIDATOR_IMAGE_DIR" --expected-directory-identity "$VALIDATOR_IMAGE_DIR_IDENTITY" --file-mode 0444 --directory-mode 0555
python3 "$HELPER" --verify-sealed-evidence-directory "$VALIDATOR_IMAGE_DIR" --expected-directory-identity "$VALIDATOR_IMAGE_DIR_IDENTITY" --expected-file "$(basename "$IMAGE_PATH")" --expected-sha256 "$IMAGE_SHA256" --owner-role validator
VALIDATOR_ROOT=/vast/chapar-validator-receipts
RECEIPT_ROOT="$VALIDATOR_ROOT/$TARGET/$IMAGE_ID/$IMAGE_SHA256"
RECEIPT_ROOT_JSON="$(python3 "$HELPER" --verify-empty-evidence-directory "$RECEIPT_ROOT" --owner-role validator)"
RECEIPT_ROOT_IDENTITY="$(python3 "$HELPER" --extract-canonical-field --schema directory-identity --field directory_identity <<<"$RECEIPT_ROOT_JSON")"
CANDIDATE_ROOT="$VALIDATOR_IMAGE_ROOT"
python3 "$HELPER" --run-and-capture --output "$RECEIPT_ROOT/runtime-preflight.json" -- bash "$VALIDATOR_CODE_ROOT/containers/images/preflight.sh" --mode runtime --base nvidia-vlad --target "$TARGET" --image-id "$IMAGE_ID" --sha256 "$IMAGE_SHA256" --candidate-root "$CANDIDATE_ROOT" --validation-root "$VALIDATOR_ROOT" --image-root /home/hpcadmin/shared/enroot-cache/chapar-vlad --site-contract "$SITE_CONTRACT" --site-contract-sha256 "$SITE_CONTRACT_SHA256"
python3 "$HELPER" --run-and-capture --output "$RECEIPT_ROOT/pyxis-smoke.txt" --capture-stderr -- srun --partition="$PARTITION" --nodes=1 --ntasks=1 --time=00:05:00 --container-image="$IMAGE_PATH" /bin/true
RUNTIME_RECEIPT="$RECEIPT_ROOT/receipt.json"
python3 "$HELPER" --write-runtime-receipt "$RUNTIME_RECEIPT" --builder-handoff "$BUILDER_HANDOFF" --builder-handoff-sha256 "$BUILDER_HANDOFF_SHA256" --validator-root "$VALIDATOR_ROOT" --validator-image-root "$VALIDATOR_IMAGE_ROOT" --preflight "$RECEIPT_ROOT/runtime-preflight.json" --smoke-output "$RECEIPT_ROOT/pyxis-smoke.txt" --image "$IMAGE_PATH" --sha256 "$IMAGE_SHA256" --target "$TARGET" --release-binding "$RELEASE_BINDING"
RUNTIME_RECEIPT_SHA256="$(sha256sum "$RUNTIME_RECEIPT" | awk '{print $1}')"
python3 "$HELPER" --seal-evidence-directory "$RECEIPT_ROOT" --expected-directory-identity "$RECEIPT_ROOT_IDENTITY" --file-mode 0444 --directory-mode 0555
RECEIPT_VERIFY_JSON="$(python3 "$HELPER" --verify-sealed-evidence-directory "$RECEIPT_ROOT" --expected-directory-identity "$RECEIPT_ROOT_IDENTITY" --expected-file receipt.json --expected-sha256 "$RUNTIME_RECEIPT_SHA256" --owner-role validator)"
test "$(python3 "$HELPER" --extract-canonical-field --schema sealed-evidence --field file_sha256 <<<"$RECEIPT_VERIFY_JSON")" = "$RUNTIME_RECEIPT_SHA256"
printf 'RUNTIME_RECEIPT=%s\nRUNTIME_RECEIPT_SHA256=%s\n' "$RUNTIME_RECEIPT" "$RUNTIME_RECEIPT_SHA256"
```

## Publisher operator gate

**OPERATOR GATE - NOT EXECUTED BY REPOSITORY QA**

Prerequisites: separate publisher-authorized session, independently authenticated
builder and runtime receipt digests, administrator-provisioned protected checkout and
empty publisher evidence leaf, and an existing target release directory.

Evidence: verified builder/runtime receipts, sealed publisher preflight, and the
no-clobber final image with matching size and digest.

Stop conditions: any nonzero command, receipt/custody drift, publisher denial,
preflight failure, evidence drift, existing final path, or durability uncertainty.

```bash
set -euo pipefail
verify_protected_checkout() {
  python3 - "$@" <<'PY'
import ctypes, errno, os, stat, subprocess, sys
root, commit, *relative_paths = sys.argv[1:]
def require(ok, message):
  if not ok: raise SystemExit(f"protected checkout failed: {message}")
require(root.startswith("/") and os.path.normpath(root) == root, "noncanonical root")
require(len(commit) == 40 and all(c in "0123456789abcdef" for c in commit), "commit")
require(relative_paths, "executed paths")
libc = ctypes.CDLL(None, use_errno=True)
def require_nonwritable_fd(fd, label):
  ctypes.set_errno(0)
  result = libc.syscall(439, fd, ctypes.c_char_p(b""), os.W_OK, 0x1000 | 0x200)
  error = ctypes.get_errno()
  require(result == -1 and error in (errno.EACCES, errno.EROFS), f"effective writable or faccessat2 unavailable: {label}:{result}:{error}")
def checked_read(absolute_path):
  parts = absolute_path.split("/")[1:]
  require(parts and all(p not in ("", ".", "..") for p in parts), "path components")
  fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
  try:
      root_stat = os.fstat(fd)
      require(root_stat.st_uid == 0 and not (root_stat.st_mode & 0o022), "root protection")
      require_nonwritable_fd(fd, "/")
      for index, part in enumerate(parts):
          flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
          if index < len(parts) - 1: flags |= os.O_DIRECTORY
          next_fd = os.open(part, flags, dir_fd=fd)
          os.close(fd); fd = next_fd
          info = os.fstat(fd)
          expected_type = stat.S_ISDIR(info.st_mode) if index < len(parts) - 1 else stat.S_ISREG(info.st_mode)
          require(expected_type and info.st_uid == 0 and not (info.st_mode & 0o022), f"owner/mode/type: {part}")
          require_nonwritable_fd(fd, part)
      before = os.fstat(fd); chunks = []
      while True:
          chunk = os.read(fd, 1024 * 1024)
          if not chunk: break
          chunks.append(chunk)
      after = os.fstat(fd)
      require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), "file changed")
      return b"".join(chunks)
  finally:
      os.close(fd)
for relative_path in relative_paths:
  require(not relative_path.startswith("/") and os.path.normpath(relative_path) == relative_path and ".." not in relative_path.split("/"), "relative path")
  actual = checked_read(root + "/" + relative_path)
  git_env = {"PATH":"/usr/bin:/bin", "HOME":"/nonexistent", "LANG":"C", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_OPTIONAL_LOCKS":"0"}
  expected = subprocess.run(["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", root, "-c", f"safe.directory={root}", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "cat-file", "blob", f"{commit}:{relative_path}"], check=True, stdout=subprocess.PIPE, env=git_env).stdout
  require(actual == expected, f"blob mismatch: {relative_path}")
PY
}
trusted_git() { local root="$1"; shift; env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 /usr/bin/git --no-pager --no-replace-objects -C "$root" -c "safe.directory=$root" -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.untrackedCache=false "$@"; }
: "${PUBLISHER_CODE_ROOT:?}" "${CHAPAR_COMMIT:?}" "${BUILDER_HANDOFF:?}" "${BUILDER_HANDOFF_SHA256:?}" "${RUNTIME_RECEIPT:?}" "${RUNTIME_RECEIPT_SHA256:?}" "${SITE_CONTRACT_SHA256:?}"
SITE_CONTRACT=/etc/chapar/vlad-image/site-contract.json
test "$PUBLISHER_CODE_ROOT" = "/vast/chapar-publisher-code/$CHAPAR_COMMIT"
verify_protected_checkout "$PUBLISHER_CODE_ROOT" "$CHAPAR_COMMIT" ci/verify-vlad-source-approval.py ci/install-validated-sqsh.py containers/images/preflight.sh
test "$(trusted_git "$PUBLISHER_CODE_ROOT" rev-parse HEAD)" = "$CHAPAR_COMMIT"; test -z "$(trusted_git "$PUBLISHER_CODE_ROOT" status --porcelain --untracked-files=all)"
HELPER="$PUBLISHER_CODE_ROOT/ci/verify-vlad-source-approval.py"
HANDOFF_JSON="$(python3 "$HELPER" --verify-builder-handoff "$BUILDER_HANDOFF" --expected-sha256 "$BUILDER_HANDOFF_SHA256" --expected-chapar-commit "$CHAPAR_COMMIT")"
mapfile -t HANDOFF_VALUES < <(python3 -c 'import json,sys; d=json.load(sys.stdin); keys=("build_root","target","image_id","image_path","image_sha256","image_size","validation_root","release_binding"); print("\n".join(str(d[k]) for k in keys))' <<<"$HANDOFF_JSON")
test "${#HANDOFF_VALUES[@]}" -eq 8
BUILD_ROOT=${HANDOFF_VALUES[0]}; TARGET=${HANDOFF_VALUES[1]}; IMAGE_ID=${HANDOFF_VALUES[2]}; IMAGE_PATH=${HANDOFF_VALUES[3]}; IMAGE_SHA256=${HANDOFF_VALUES[4]}; IMAGE_SIZE=${HANDOFF_VALUES[5]}; VALIDATION_ROOT=${HANDOFF_VALUES[6]}; RELEASE_BINDING=${HANDOFF_VALUES[7]}
RUNTIME_JSON="$(python3 "$HELPER" --verify-runtime-receipt "$RUNTIME_RECEIPT" --expected-sha256 "$RUNTIME_RECEIPT_SHA256" --builder-handoff "$BUILDER_HANDOFF" --builder-handoff-sha256 "$BUILDER_HANDOFF_SHA256" --target "$TARGET" --release-binding "$RELEASE_BINDING")"
mapfile -t RUNTIME_VALUES < <(python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(str(d[k]) for k in ("image_path","image_sha256","validator_root","validator_image_root")))' <<<"$RUNTIME_JSON")
test "${#RUNTIME_VALUES[@]}" -eq 4
IMAGE_PATH=${RUNTIME_VALUES[0]}; IMAGE_SHA256=${RUNTIME_VALUES[1]}; VALIDATOR_ROOT=${RUNTIME_VALUES[2]}; CANDIDATE_ROOT=${RUNTIME_VALUES[3]}
IMAGE_ROOT=/home/hpcadmin/shared/enroot-cache/chapar-vlad
FINAL_RELEASES_ROOT="$IMAGE_ROOT/$TARGET/releases"
test -d "$IMAGE_ROOT"; test -d "$IMAGE_ROOT/$TARGET"; test -d "$FINAL_RELEASES_ROOT"
PUBLISHER_EVIDENCE_ROOT=/home/hpcadmin/shared/enroot-cache/chapar-vlad-evidence
PUBLISHER_RUN_ROOT="$PUBLISHER_EVIDENCE_ROOT/$TARGET/$IMAGE_ID/$IMAGE_SHA256"
PUBLISHER_RUN_JSON="$(python3 "$HELPER" --verify-empty-evidence-directory "$PUBLISHER_RUN_ROOT" --owner-role publisher)"
PUBLISHER_RUN_IDENTITY="$(python3 "$HELPER" --extract-canonical-field --schema directory-identity --field directory_identity <<<"$PUBLISHER_RUN_JSON")"
python3 "$HELPER" --run-and-capture --output "$PUBLISHER_RUN_ROOT/publisher-preflight.json" -- bash "$PUBLISHER_CODE_ROOT/containers/images/preflight.sh" --mode publisher --base nvidia-vlad --target "$TARGET" --image-id "$IMAGE_ID" --sha256 "$IMAGE_SHA256" --candidate-root "$CANDIDATE_ROOT" --validation-root "$VALIDATOR_ROOT" --image-root "$IMAGE_ROOT" --site-contract "$SITE_CONTRACT" --site-contract-sha256 "$SITE_CONTRACT_SHA256"
PUBLISHER_PREFLIGHT_SHA256="$(sha256sum "$PUBLISHER_RUN_ROOT/publisher-preflight.json" | awk '{print $1}')"
python3 "$HELPER" --seal-evidence-directory "$PUBLISHER_RUN_ROOT" --expected-directory-identity "$PUBLISHER_RUN_IDENTITY" --file-mode 0444 --directory-mode 0555
FINAL_PATH="$FINAL_RELEASES_ROOT/$(basename "$IMAGE_PATH")"
test ! -e "$FINAL_PATH"
PUBLISHER_VERIFY_JSON="$(python3 "$HELPER" --verify-sealed-evidence-directory "$PUBLISHER_RUN_ROOT" --expected-directory-identity "$PUBLISHER_RUN_IDENTITY" --expected-file publisher-preflight.json --expected-sha256 "$PUBLISHER_PREFLIGHT_SHA256" --owner-role publisher)"
test "$(python3 "$HELPER" --extract-canonical-field --schema sealed-evidence --field file_sha256 <<<"$PUBLISHER_VERIFY_JSON")" = "$PUBLISHER_PREFLIGHT_SHA256"
python3 "$PUBLISHER_CODE_ROOT/ci/install-validated-sqsh.py" --source "$IMAGE_PATH" --destination-directory "$FINAL_RELEASES_ROOT" --destination-name "$(basename "$IMAGE_PATH")" --expected-sha256 "$IMAGE_SHA256" --expected-size "$IMAGE_SIZE"
test "$(sha256sum "$FINAL_PATH" | awk '{print $1}')" = "$IMAGE_SHA256"
test "$(stat -c %s "$FINAL_PATH")" = "$IMAGE_SIZE"
```

No Fleet Manager repository, Helm value, image source, shared production path, or
deployment is changed by repository QA. Fleet Manager adoption remains a separate
future operator gate after both native images have independent validation evidence.
