#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: containers/images/build-image.sh \
  --base nvidia-vlad --target linux-x86_64-v4 \
  --release-dir /resources/chapar/<env>/<os>/<arch>/releases/<release-id> \
  --image-id <image-id> \
  --datacenter-contract /etc/chapar/datacenter.json \
  --target-contract /etc/chapar/target-contract.json \
  [--enroot-build-root DIR] [--keep-container] [--plan-only]

Layer a promoted Chapar environment release into a digest-locked base image and
export an Enroot squashfs (.sqsh) that Pyxis consumes via
`srun --container-image=<path>`. Each selected container pairs one base image
with one Chapar environment and its own target list:

  --base nvidia-vlad   NVIDIA HPC-benchmarks 26.02 + the selected vlad set.
                        Targets: linux-x86_64-generic, linux-x86_64-v4,
                        linux-aarch64-generic, linux-aarch64-gb300.
  --base ubuntu-hpcsim Plain Ubuntu 24.04 + the hpcsim env. hpcsim policy
                        builds its own CUDA/GDR stack via Spack rather than
                        relying on an NVIDIA-branded OS image, so the base
                        stays vendor-neutral. Targets: linux-x86_64-generic.

The immutable release metadata, selection, effective manifest, target policy,
and release-local lock must match the selected contract and global registries.

What is injected: the environment's explicit root specs plus their transitive
link/run dependency closure, each copied to the SAME absolute prefix it was
built at. Spack embeds absolute RPATHs, so a prefix moved to a different path
would not resolve at run time. Build-only dependencies are excluded.

Module precedence: injected modules are reachable only via an explicit
`module load` after `module use`; nothing already present in the base image's
PATH or LD_LIBRARY_PATH is disturbed.

The base image is resolved by digest from sources-lock.json, never by tag: the
lock's floating_input_rule forbids tags as locked values. This script therefore
refuses to run until that lock reaches status "complete", which requires
resolving every locked category's index and per-platform descriptors on a
builder with skopeo (and registry credentials/reachability where the base
requires them).

--plan-only prints the resolved base digest, injection prefix list, and output
path, then exits without importing, mutating, or writing anything. It is the
only mode that is useful on a workstation.
USAGE
}

case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="${SCRIPT_DIR}" exec python3 - "${SCRIPT_DIR}" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Final, NamedTuple

SCRIPT_DIR = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]
from registry import Container, Sources
from release_contract import ContractError, ReleaseRequest, verify_release

TARGETS_PATH = SCRIPT_DIR / "targets.json"
CONTAINERS_PATH = SCRIPT_DIR / "containers.json"
SOURCES_PATH = SCRIPT_DIR / "sources-lock.json"
CATALOG_PATH = SCRIPT_DIR.parents[1] / "envs" / "software" / "spack.yaml"
LOCK_VALIDATOR = SCRIPT_DIR / "tests" / "validate-locks.sh"
PROFILE_SCRIPT: Final = "/etc/profile.d/zz-chapar-image.sh"
DIGEST_RE: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
RUNTIME_DEPTYPES: Final = frozenset({"link", "run"})


class BuildError(Exception):
    pass


def fail(message: str) -> None:
    raise BuildError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    except (OSError, ValueError) as error:
        fail(f"{label} is unreadable or malformed: {error}")
    raise AssertionError("unreachable")


def absolute(raw: str, label: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        fail(f"{label} must be an absolute path: {raw}")
    return Path(os.path.normpath(str(path)))


def run(command: list[str], label: str) -> str:
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError:
        fail(f"{label} requires a tool that is not on PATH: {command[0]}")
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip().splitlines()
        tail = detail[-1] if detail else f"exit {error.returncode}"
        fail(f"{label} failed: {tail}")
    return completed.stdout


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        fail(f"required tool is missing from PATH: {name}")
    return path


# ---------------------------------------------------------------- base image --

def resolve_base_descriptor(base: Container, target: str, lock: Sources) -> tuple[str, str]:
    """Return the immutable per-platform descriptor digest for `target`.

    Fails closed unless the lock is complete. Copying fleet-manager's
    `docker://nvcr.io#<image>:<tag>` tag import would violate the lock's
    floating_input_rule, so the digest must come from the lock.
    """
    if lock.status != "complete":
        fail(
            "source lock is not usable for an image build: status="
            f"{lock.status!r}. "
            f"Resolve the {base.base_image} OCI index and per-platform "
            "descriptors on a builder with skopeo and nvcr.io access, then "
            f"re-run {LOCK_VALIDATOR} --require-complete."
        )
    try:
        oci = lock.verified[base.source_lock_category]
        platform = oci["platforms"][target]
        descriptor = platform["descriptor_digest"]
    except (KeyError, TypeError):
        fail(
            f"source lock has no verified platform descriptor for base "
            f"{base.base_image} (category {base.source_lock_category}) "
            f"and target {target}"
        )
    tag = oci.get("tag")
    if oci.get("image") != base.base_image or not isinstance(tag, str) or not tag:
        fail(f"source lock {base.source_lock_category} identity differs from the container registry")
    if not isinstance(descriptor, str) or DIGEST_RE.fullmatch(descriptor) is None:
        fail(f"platform descriptor for {target} is not an immutable sha256 digest")
    return descriptor, tag


def import_base(base: Container, tag: str, descriptor: str, cache_dir: Path, target: str) -> Path:
    """Import the digest-pinned base into a local .sqsh, atomically.

    skopeo copies by digest into an OCI archive first, then enroot imports that
    archive. Going through skopeo keeps the digest exact and avoids depending on
    enroot's registry URI supporting `@sha256:` forms.
    """
    slug = base.base_image.rsplit("/", 1)[-1]
    out = cache_dir / f"{slug}+{tag}-{target}.sqsh"
    if out.exists():
        print(f"==> base already imported: {out.name}")
        return out
    skopeo = require_tool("skopeo")
    enroot = require_tool("enroot")
    cache_dir.mkdir(parents=True, exist_ok=True)
    partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
    archive = cache_dir / f".oci-archive.{os.getpid()}.tar"
    for stale in (partial, archive):
        stale.unlink(missing_ok=True)
    print(f"==> copying {base.base_image}@{descriptor}")
    run([skopeo, "copy", f"docker://{base.base_image}@{descriptor}", f"oci-archive:{archive}"], "skopeo copy")
    print("==> importing base into enroot")
    run([enroot, "import", "-o", str(partial), f"oci-archive://{archive}"], "enroot import")
    archive.unlink(missing_ok=True)
    # mv within one filesystem is atomic, so a reader never sees a partial base.
    partial.replace(out)
    return out


# ------------------------------------------------------------ release closure --

def runtime_closure(release_dir: Path) -> list[str]:
    """Return the dag hashes of the explicit roots plus their link/run closure.

    Read from the release's own spack.lock rather than by shelling out to spack:
    the image builder is not necessarily the host that built the release, and the
    lock is the immutable record of what was actually installed.
    """
    lock = load_json(release_dir / "spack.lock", "release spack.lock")
    concrete = lock.get("concrete_specs")
    if not isinstance(concrete, dict) or not concrete:
        fail("release spack.lock has no concrete_specs")
    roots = lock.get("roots")
    if not isinstance(roots, list) or not roots:
        fail("release spack.lock has no roots")

    root_hashes = []
    for root in roots:
        digest = root.get("hash") if isinstance(root, dict) else None
        if not isinstance(digest, str) or digest not in concrete:
            fail("release spack.lock root does not name a concrete spec")
        root_hashes.append(digest)

    selected: list[str] = []
    seen: set[str] = set()
    queue = list(root_hashes)
    while queue:
        digest = queue.pop()
        if digest in seen:
            continue
        seen.add(digest)
        selected.append(digest)
        node = concrete.get(digest)
        if not isinstance(node, dict):
            fail(f"release spack.lock references an unknown spec hash: {digest}")
        for edge in node.get("dependencies") or []:
            if not isinstance(edge, dict):
                continue
            # Spack has spelled this key both "type" and "deptypes"/"parameters"
            # across versions; accept whichever the lock carries.
            raw = edge.get("type") or edge.get("deptypes") or (edge.get("parameters") or {}).get("deptypes") or []
            deptypes = {raw} if isinstance(raw, str) else set(raw)
            if not deptypes:
                fail(f"release spack.lock dependency edge has no deptype: {digest}")
            if deptypes & RUNTIME_DEPTYPES:
                child = edge.get("hash") or edge.get("id")
                if isinstance(child, str):
                    queue.append(child)
    return selected


# The install-tree projection is owned by etc/user/base/config.yaml and rendered
# identically by release.sh make_scope and etc/chapar-selection.sh render_scopes.
# It is currently upstream Spack's default,
# `{architecture.platform}-{architecture.target}/{name}-{version}-{hash}`, so a
# prefix sits one directory below the (placeholder-padded) store root rather than
# directly in it. Search a bounded depth instead of hard-coding that number, so a
# later projection change cannot silently resolve zero prefixes -- which would
# surface as "the release is incomplete for imaging" rather than as a
# configuration mismatch.
PROJECTION_MAX_DEPTH = 4


def resolve_prefixes(store: Path, hashes: list[str]) -> list[Path]:
    """Map dag hashes to installed prefixes by hash suffix.

    Matching on the hash suffix keeps this projection-agnostic and needs no spack
    invocation. A hash that matches nothing, or more than one prefix, is fatal
    rather than skipped.
    """
    if not store.is_dir():
        fail(f"release store root is not a directory: {store}")
    if store.resolve() != store:
        fail(f"release store root contains a symlink component: {store}")
    # Padded install trees (release.sh detect_padded_length) nest the real
    # prefixes under a chain of __spack_path_placeholder__ directories; the
    # metadata's store field records the unpadded root. Descend to the deepest
    # placeholder before searching, mirroring release.sh.
    while (store / "__spack_path_placeholder__").is_dir():
        store = store / "__spack_path_placeholder__"
    wanted = set(hashes)
    index: dict[str, list[Path]] = {}
    queue: list[tuple[Path, int]] = [(store, 0)]
    while queue:
        parent, depth = queue.pop()
        for entry in sorted(parent.iterdir()):
            if entry.is_symlink():
                fail(f"release store contains a symlinked prefix: {entry}")
            if not entry.is_dir():
                continue
            suffix = entry.name.rsplit("-", 1)[-1]
            if suffix in wanted:
                # A matched prefix is a package installation, never a projection
                # directory: index it and do not walk into it.
                index.setdefault(suffix, []).append(entry)
                continue
            if depth + 1 < PROJECTION_MAX_DEPTH:
                queue.append((entry, depth + 1))
    prefixes: list[Path] = []
    missing: list[str] = []
    for digest in hashes:
        matches = index.get(digest, [])
        if len(matches) > 1:
            fail(f"store has multiple prefixes for hash {digest}")
        if not matches:
            missing.append(digest)
            continue
        prefixes.append(matches[0])
    if missing:
        fail(
            f"{len(missing)} spec(s) in the runtime closure are not installed in "
            f"{store} (first: {missing[0]}). The release is incomplete for imaging."
        )
    return sorted(prefixes)


# ------------------------------------------------------------------- ELF audit --
#
# Parsed here rather than shelled out to readelf/objdump on purpose: preflight.sh
# BUILD_TOOLS is a pinned, verified toolchain list, and binutils is not in it.
# 64-bit little-endian only, which is every registered target (x86_64, aarch64);
# anything else is skipped rather than guessed at.

ELF_MAGIC: Final = b"\x7fELF"
DT_NULL: Final = 0
DT_NEEDED: Final = 1
DT_RPATH: Final = 15
DT_RUNPATH: Final = 29
SHT_DYNAMIC: Final = 6
GLIBC_VERSION_RE: Final = re.compile(r"^GLIBC_2\.(\d+)$")
# Libraries that MUST come from outside the release at run time, so a DT_NEEDED
# naming one is correct rather than a broken closure.
#
# - The CUDA driver stack and NVML are injected into the container by
#   nvidia-container-cli from enroot's 98-nvidia.sh hook. There is no Spack
#   package for the driver: `+cuda` builds link the toolkit's libcuda *stub*, and
#   the stub directory must never survive into a runtime search path, which is
#   what the `stubs` check below enforces.
# - libc/libm/libdl/libpthread/librt/libresolv/libutil come from the base image:
#   etc/system/<os>/packages.yaml declares glibc `buildable: false`, so glibc is
#   an external and is never installed into the store or injected.
#
# rdma-core deliberately is NOT on this list. enroot's 99-mellanox.sh mounts only
# devices and sysfs, never MOFED userspace, and the uverbs uABI is version
# negotiated, so libibverbs/librdmacm/libmlx5 are Spack-built and must resolve
# inside the closure.
HOST_PROVIDED_SONAMES: Final = frozenset({
    "libcuda.so.1",
    "libnvidia-ml.so.1",
    "libnvidia-ptxjitcompiler.so.1",
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1",
})
HOST_PROVIDED_PREFIXES: Final = ("libnvidia-",)
# Environment variables an injected modulefile must never set. Spack's Linux
# prefix_inspections are LD_LIBRARY_PATH-free by design precisely because
# packages embed RPATHs; a module that sets one of these reaches every process in
# the container, including the base image's own binaries.
FORBIDDEN_MODULE_VARIABLES: Final = ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME")


class DynamicInfo(NamedTuple):
    needed: tuple[str, ...]
    rpath: tuple[str, ...]
    runpath: tuple[str, ...]
    glibc_max: int


def read_dynamic(path: Path) -> DynamicInfo | None:
    """Return the ELF dynamic-section facts for path, or None if not applicable."""
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 64 or data[:4] != ELF_MAGIC or data[4] != 2 or data[5] != 1:
        return None
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    if not e_shoff or not e_shnum:
        return None
    dynamic: tuple[int, int, int] | None = None
    sections: list[tuple[int, int, int, int]] = []
    for index in range(e_shnum):
        base = e_shoff + index * e_shentsize
        if base + 64 > len(data):
            return None
        sh_type, = struct.unpack_from("<I", data, base + 0x04)
        sh_offset, sh_size = struct.unpack_from("<QQ", data, base + 0x18)
        sh_link, = struct.unpack_from("<I", data, base + 0x28)
        sections.append((sh_type, sh_offset, sh_size, sh_link))
        if sh_type == SHT_DYNAMIC:
            dynamic = (sh_offset, sh_size, sh_link)
    if dynamic is None:
        return None
    dyn_offset, dyn_size, dyn_link = dynamic
    if dyn_link >= len(sections):
        return None
    _, str_offset, str_size, _ = sections[dyn_link]
    strings = data[str_offset:str_offset + str_size]

    def string_at(position: int) -> str:
        end = strings.find(b"\x00", position)
        if position < 0 or position >= len(strings) or end < 0:
            return ""
        return strings[position:end].decode("utf-8", "replace")

    needed: list[str] = []
    rpath: list[str] = []
    runpath: list[str] = []
    for entry in range(dyn_size // 16):
        tag, value = struct.unpack_from("<qQ", data, dyn_offset + entry * 16)
        if tag == DT_NULL:
            break
        if tag == DT_NEEDED:
            needed.append(string_at(value))
        elif tag == DT_RPATH:
            rpath.extend(part for part in string_at(value).split(":") if part)
        elif tag == DT_RUNPATH:
            runpath.extend(part for part in string_at(value).split(":") if part)
    # Every GLIBC_2.N token in the dynamic string table of a non-libc object is a
    # symbol-version requirement, so the maximum is the oldest glibc that can run
    # this binary.
    glibc_max = 0
    for token in strings.split(b"\x00"):
        match = GLIBC_VERSION_RE.match(token.decode("utf-8", "replace"))
        if match is not None:
            glibc_max = max(glibc_max, int(match.group(1)))
    return DynamicInfo(tuple(needed), tuple(rpath), tuple(runpath), glibc_max)


def audit_closure(prefixes: list[Path]) -> tuple[int, int]:
    """Prove the injected closure is self-contained and rpath-linked.

    Returns (objects audited, highest required GLIBC_2.N minor).
    """
    provided: set[str] = set()
    objects: list[tuple[Path, DynamicInfo]] = []
    for prefix in prefixes:
        for path in prefix.rglob("*"):
            if path.is_dir() or path.is_symlink():
                if path.is_symlink():
                    provided.add(path.name)
                continue
            provided.add(path.name)
            info = read_dynamic(path)
            if info is not None:
                objects.append((path, info))

    stub_paths: list[str] = []
    runpath_objects: list[str] = []
    unresolved: list[str] = []
    glibc_max = 0
    for path, info in objects:
        glibc_max = max(glibc_max, info.glibc_max)
        for entry in (*info.rpath, *info.runpath):
            if "stubs" in entry:
                stub_paths.append(f"{path}: {entry}")
        if info.runpath and not info.rpath:
            runpath_objects.append(str(path))
        for soname in info.needed:
            if soname in provided or soname in HOST_PROVIDED_SONAMES:
                continue
            if soname.startswith(HOST_PROVIDED_PREFIXES):
                continue
            unresolved.append(f"{path}: {soname}")

    if stub_paths:
        fail(
            "injected objects keep a CUDA stub directory on their runtime search "
            "path, which would shadow the driver libcuda the container hook "
            f"provides ({len(stub_paths)} entries, first: {stub_paths[0]})"
        )
    if runpath_objects:
        fail(
            "injected objects use DT_RUNPATH instead of DT_RPATH, so the base "
            "image's LD_LIBRARY_PATH would outrank the release's own closure. "
            "Rebuild with config:shared_linking:type: rpath "
            f"({len(runpath_objects)} objects, first: {runpath_objects[0]})"
        )
    if unresolved:
        fail(
            "injected objects need libraries that are neither in the closure nor "
            "host-provided, so they would not load inside the image "
            f"({len(unresolved)} entries, first: {unresolved[0]})"
        )
    if prefixes and not any(prefix.name.startswith("gcc-runtime-") for prefix in prefixes):
        fail(
            "the injected closure has no gcc-runtime prefix, so libstdc++, "
            "libgomp and libgfortran would resolve against whatever the base "
            "image ships rather than against the release's own compiler runtime"
        )
    return len(objects), glibc_max


def base_glibc_minor(rootfs: Path) -> int | None:
    """Highest GLIBC_2.N the base image's own libc provides, or None if absent."""
    for pattern in ("usr/lib/*/libc.so.6", "lib/*/libc.so.6", "usr/lib64/libc.so.6", "lib64/libc.so.6"):
        for candidate in sorted(rootfs.glob(pattern)):
            info = read_dynamic(candidate)
            if info is not None and info.glibc_max:
                return info.glibc_max
    return None


# ------------------------------------------------------------------ injection --

def rootfs_path(data_path: Path, container: str, absolute_target: Path) -> Path:
    return data_path / container / str(absolute_target).lstrip("/")


class Entry(NamedTuple):
    kind: str
    mode: int
    size: int
    mtime_ns: int
    link: str


def snapshot_rootfs(root: Path) -> dict[str, Entry]:
    """Inventory a rootfs so injection's effect on it can be proven, not assumed."""
    inventory: dict[str, Entry] = {}
    for path in root.rglob("*"):
        try:
            status = path.lstat()
        except OSError:
            continue
        if stat.S_ISLNK(status.st_mode):
            try:
                link = os.readlink(path)
            except OSError:
                link = ""
            kind = "link"
        elif stat.S_ISDIR(status.st_mode):
            kind, link = "dir", ""
        else:
            kind, link = "file", ""
        inventory[str(path.relative_to(root))] = Entry(
            kind, stat.S_IMODE(status.st_mode), status.st_size, status.st_mtime_ns, link
        )
    return inventory


def assert_modules_are_opt_in(modules: Path) -> int:
    """Fail if an injected modulefile would leak into unrelated container processes.

    Counting modulefiles proves only that generation ran. What matters for a base
    image is that loading a Chapar module changes the caller's environment and
    nothing else, so the delivered content -- not the config that was supposed to
    produce it -- is what gets checked.
    """
    offenders: list[str] = []
    count = 0
    for path in sorted(modules.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        count += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            statement = line.strip()
            if statement.startswith(("#", "--")):
                continue
            for variable in FORBIDDEN_MODULE_VARIABLES:
                if variable in statement:
                    offenders.append(f"{path.name}: {statement}")
                    break
    if not count:
        fail(f"release generated no modulefiles under {modules}")
    if offenders:
        fail(
            f"{len(offenders)} injected modulefile statement(s) set a variable that "
            "applies process-wide inside the container rather than to the caller "
            f"alone (first: {offenders[0]})"
        )
    return count


def assert_base_undisturbed(
    before: dict[str, Entry], after: dict[str, Entry], allowed: list[Path], root: Path
) -> dict[str, int]:
    """Fail unless injection only added paths under the destinations it declared.

    The base image exists to provide its own payload, so the contract is stronger
    than "the parts we happen to check still work": nothing may be removed, no
    file or symlink may change, and every addition must belong to a declared
    injection destination or be a parent directory created to reach one.
    """
    permitted = {str(path.relative_to(root)) for path in allowed}
    ancestors: set[str] = set()
    for target in permitted:
        parts = PurePosixPath(target).parts
        for depth in range(1, len(parts)):
            ancestors.add(str(PurePosixPath(*parts[:depth])))

    def declared(name: str) -> bool:
        if name in permitted or name in ancestors:
            return True
        return any(name.startswith(f"{target}/") for target in permitted)

    removed = sorted(set(before) - set(after))
    if removed:
        fail(
            f"injection removed {len(removed)} path(s) from the base image "
            f"(first: {removed[0]})"
        )
    changed = [
        name
        for name, entry in after.items()
        if name in before
        and before[name].kind != "dir"
        and before[name] != entry
    ]
    if changed:
        fail(
            f"injection modified {len(changed)} existing base-image path(s) "
            f"(first: {changed[0]})"
        )
    remoded = [
        name
        for name, entry in after.items()
        if name in before and before[name].kind == "dir" and before[name].mode != entry.mode
    ]
    if remoded:
        fail(
            f"injection changed the mode of {len(remoded)} existing base-image "
            f"director(ies) (first: {remoded[0]})"
        )
    undeclared = sorted(name for name in set(after) - set(before) if not declared(name))
    if undeclared:
        fail(
            f"injection added {len(undeclared)} path(s) outside its declared "
            f"destinations (first: {undeclared[0]})"
        )
    return {"added": len(set(after) - set(before)), "inspected": len(after)}


def inject(data_path: Path, container: str, prefixes: list[Path], modules_root: Path, arch: str, module_root: str, software_set: str) -> list[Path]:
    """Copy the closure in at its build-time paths; return every destination written."""
    print(f"==> injecting {len(prefixes)} prefixes at their build-time paths")
    destinations = [rootfs_path(data_path, container, prefix) for prefix in prefixes]
    modules_source = modules_root / arch
    if not modules_source.is_dir():
        fail(f"release has no modulefiles for arch {arch}: {modules_source}")
    modules_destination = rootfs_path(data_path, container, Path(module_root)) / arch
    profile = rootfs_path(data_path, container, Path(PROFILE_SCRIPT))

    # A destination that already exists is fatal, not skippable. Skipping it left
    # the base image's content in place while the release's modulefiles went on
    # pointing at that prefix, so the image silently served foreign software under
    # a Chapar module name. There is deliberately no override: the reserved
    # /opt/chapar store namespace means a collision is a contract violation
    # somewhere upstream, not a situation to wave through.
    collisions = [
        str(destination)
        for destination in (*destinations, modules_destination, profile)
        if destination.exists() or destination.is_symlink()
    ]
    if collisions:
        fail(
            f"{len(collisions)} injection destination(s) already exist in the base "
            f"image (first: {collisions[0]}). The base image would be serving "
            "foreign content under a Chapar path."
        )

    for prefix, destination in zip(prefixes, destinations):
        destination.parent.mkdir(parents=True, exist_ok=True)
        # -a preserves mode, symlinks, and times. Modes matter: a plain copy
        # under a restrictive umask breaks non-owner execution under Pyxis.
        run(["cp", "-a", str(prefix), str(destination)], f"injecting {prefix.name}")

    modules_destination.parent.mkdir(parents=True, exist_ok=True)
    run(["cp", "-a", str(modules_source), str(modules_destination)], "injecting modulefiles")

    # Opt-in by design: `module use` only, never a PATH/LD_LIBRARY_PATH prepend.
    # Anything already on PATH/LD_LIBRARY_PATH in the base image (e.g. the
    # NVIDIA base's own MPI/HPL/NCCL under /workspace) keeps resolving to what
    # it was linked against.
    profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text(
        f"# Chapar {software_set} release, layered into this image.\n"
        "# Deliberately does not alter PATH or LD_LIBRARY_PATH. Run\n"
        f"# `module avail` then `module load <name>` to use the {software_set} stack.\n"
        f'if command -v module >/dev/null 2>&1 && [ -d "{module_root}/{arch}" ]; then\n'
        f'    module use "{module_root}/{arch}"\n'
        "fi\n",
        encoding="utf-8",
    )
    profile.chmod(0o644)


def verify(enroot: str, container: str, arch: str, spack_target: str, base_id: str, module_root: str, store: Path) -> None:
    print("==> verifying injected tree inside the rootfs")
    if not arch.endswith(spack_target):
        fail(
            f"release arch {arch!r} does not end with the target's spack_target "
            f"{spack_target!r}: this release was not built for the requested "
            "microarchitecture"
        )
    # Base-specific evidence that injection did not disturb the payload the
    # base image exists to provide.
    if base_id == "nvidia-vlad":
        # The NVIDIA HPC-benchmarks base's own HPL entrypoint must survive
        # injection -- confirms we layered vlad on top rather than clobbering it.
        base_check = (
            'case "$(uname -m)" in\n'
            '  x86_64) test -f /workspace/hpl-linux-x86_64/hpl.sh ;;\n'
            '  aarch64) test -f /workspace/hpl-linux-aarch64-gpu/hpl.sh ;;\n'
            'esac\n'
        )
    elif base_id == "ubuntu-hpcsim":
        # Confirms the base is still a genuine, uncorrupted Ubuntu 24.04
        # rootfs after injection -- apt/dpkg intact, correct OS release.
        base_check = (
            'grep -q \'VERSION_ID="24.04"\' /etc/os-release\n'
            'command -v dpkg >/dev/null 2>&1\n'
        )
    else:
        fail(f"no in-image verification defined for base {base_id!r}")
    # NVIDIA_VISIBLE_DEVICES=void keeps enroot's GPU hook from running
    # nvidia-container-cli; verification never needs a GPU. PS1="" keeps the
    # base image's /etc/bash.bashrc from tripping over an unset prompt.
    # The other half of "did not disturb the base image": before any `module
    # load`, the base image's own interpreters and tools must still resolve to
    # base-image paths. A release that shadowed them on the default PATH would
    # pass every positive check above while breaking the image's own software.
    shadow_check = (
        f'for tool in python3 python mpirun mpiexec nvcc cmake; do\n'
        f'    resolved=$(command -v "$tool" 2>/dev/null || true)\n'
        f'    case "$resolved" in\n'
        f'      "") ;;\n'
        f'      {store}/*|{module_root}/*)\n'
        f'        echo "shadowed: $tool resolves to $resolved before any module load" >&2\n'
        f'        exit 1 ;;\n'
        f'    esac\n'
        f'done\n'
    )
    script = (
        f'set -eu\n'
        f'test -d "{module_root}/{arch}"\n'
        f'test -r "{PROFILE_SCRIPT}"\n'
        f'{base_check}'
        f'{shadow_check}'
        f'count=$(find "{module_root}/{arch}" -type f | wc -l)\n'
        f'[ "$count" -gt 0 ]\n'
        f'echo "verified: $count modulefiles, base payload intact, base tools unshadowed"\n'
    )
    output = run(
        [enroot, "start", "--root", "--rw", "--env", "PS1=", "--env", "NVIDIA_VISIBLE_DEVICES=void",
         container, "bash", "-c", script],
        "in-image verification",
    )
    print("    " + output.strip().splitlines()[-1])


# ----------------------------------------------------------------------- main --

def main() -> int:
    parser = argparse.ArgumentParser(description="Layer a Chapar environment release into a digest-locked base image")
    parser.add_argument("--target", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--datacenter-contract", required=True)
    parser.add_argument("--target-contract", required=True)
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--enroot-build-root")
    parser.add_argument("--keep-container", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()

    if ID_RE.fullmatch(args.image_id) is None:
        fail("image id must be a short lowercase identifier")
    release_dir = absolute(args.release_dir, "release dir")
    if not release_dir.is_dir():
        fail(f"release dir is not a directory: {release_dir}")
    datacenter_contract = absolute(args.datacenter_contract, "datacenter contract")
    target_contract = absolute(args.target_contract, "target contract")
    try:
        plan = verify_release(
            ReleaseRequest(
                release_dir,
                args.base,
                args.target,
                CATALOG_PATH,
                TARGETS_PATH,
                CONTAINERS_PATH,
                SOURCES_PATH,
                datacenter_contract,
                target_contract,
            )
        )
    except ContractError as error:
        fail(str(error))
    base = plan.container
    target_spec = plan.target
    store = absolute(plan.roots["install_tree"], "release install tree")
    # Read the release-local module tree, not metadata.roots["modulefiles"].
    # That root is the durable *published* path, which release.sh only ever
    # materialises as a symlink to this directory's single architecture child --
    # so resolving it here would either be absent (before publish-modules) or a
    # symlink (after). The release-local tree is immutable and always present.
    module_tree = release_dir / "modulefiles"
    if module_tree.is_symlink():
        fail("release module destination cannot be a symlink")
    module_arches = sorted(path.name for path in module_tree.iterdir() if path.is_dir()) if module_tree.is_dir() else []
    if len(module_arches) != 1:
        fail("release must contain exactly one module destination")
    arch = module_arches[0]
    if not arch.endswith(plan.target.spack_target):
        fail("release module architecture does not match selected target")

    # publication.publish_containers was already parsed, planned, printed and
    # exported by ci/sbatch-env-build.sh, and then consumed by nothing. An image
    # is a publishable artifact, so the contract's own switch has to gate it.
    try:
        publication = json.loads(target_contract.read_bytes())["publication"]
        publish_containers = publication["publish_containers"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        fail(f"target contract publication policy is unreadable: {error}")
    if type(publish_containers) is not bool:
        fail("target contract publish_containers must be a boolean")

    descriptor, tag = resolve_base_descriptor(base, args.target, plan.sources)
    closure = runtime_closure(release_dir)
    prefixes = resolve_prefixes(store, closure)
    # Pure reads, so this runs in plan mode too: an operator finds out that the
    # closure is not self-contained before requesting a builder, not after.
    audited, glibc_required = audit_closure(prefixes)
    # Checked on the release-local source, not the injected copy, so a modulefile
    # that would leak into unrelated container processes is caught before any
    # builder is asked for a container.
    modulefiles = assert_modules_are_opt_in(module_tree / arch)

    artifact_name = f"{args.base}+{tag}-{args.target}.sqsh"
    if args.plan_only:
        print(f"target:        {args.target} ({target_spec.oci_platform}, spack_target={target_spec.spack_target})")
        print(f"base id:       {args.base} (software_set={plan.identity['software_set']})")
        print(f"release:       {plan.identity['release_id']} run={plan.identity['run_id']} arch={arch}")
        print(f"selection:     {plan.selection_sha256}")
        print(f"release lock:  {plan.lock_sha256}")
        print(f"base:          {base.base_image}@{descriptor}")
        print(f"store:         {store}")
        print(f"closure:       {len(prefixes)} runtime prefixes of {len(closure)} closure specs")
        print(f"elf audit:     {audited} dynamic objects, rpath-linked, no stub search paths")
        print(f"requires:      GLIBC_2.{glibc_required} or newer in the base image")
        print(f"modules:       {base.module_destination}/{arch} ({modulefiles} files, opt-in via module load)")
        print(f"publish:       publish_containers={str(publish_containers).lower()}")
        print(f"artifact:      {artifact_name}")
        for prefix in prefixes[:10]:
            print(f"    inject {prefix}")
        if len(prefixes) > 10:
            print(f"    ... and {len(prefixes) - 10} more")
        return 0

    if not publish_containers:
        fail(
            "the verified target contract sets publication.publish_containers "
            "false, so this tuple may not produce a container artifact"
        )

    candidate_root = absolute(plan.paths["image_staging"], "selected image staging root")
    work = candidate_root / args.image_id
    if not work.is_dir():
        fail(f"target/image-qualified candidate work root must exist and be writable: {work}")

    enroot = require_tool("enroot")
    build_root = absolute(args.enroot_build_root, "enroot build root") if args.enroot_build_root else work / ".enroot-build"
    for name in ("data", "cache", "temp", "runtime"):
        (build_root / name).mkdir(parents=True, exist_ok=True)
    os.environ["ENROOT_DATA_PATH"] = str(build_root / "data")
    os.environ["ENROOT_CACHE_PATH"] = str(build_root / "cache")
    os.environ["ENROOT_TEMP_PATH"] = str(build_root / "temp")
    os.environ["ENROOT_RUNTIME_PATH"] = str(build_root / "runtime")

    base_sqsh = import_base(base, tag, descriptor, build_root / "cache", args.target)
    container = f"chaparbuild-{args.base}-{args.target}-{os.getpid()}"
    subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False)
    run([enroot, "create", "--name", container, str(base_sqsh)], "enroot create")
    try:
        rootfs = build_root / "data" / container
        # An externally built stack links the *base image's* glibc: glibc is an
        # external in etc/system/<os>/packages.yaml, so it is never in the store
        # and never injected. The rule is one-directional -- a binary records the
        # symbol versions it needs, and an older libc cannot satisfy them.
        glibc_provided = base_glibc_minor(rootfs)
        if glibc_provided is None:
            fail("cannot determine the base image's glibc version from its rootfs")
        if glibc_required > glibc_provided:
            fail(
                f"the release requires GLIBC_2.{glibc_required} but the base image "
                f"provides GLIBC_2.{glibc_provided}: build against a glibc no newer "
                "than every base image this release is injected into"
            )
        print(f"==> glibc: release needs 2.{glibc_required}, base provides 2.{glibc_provided}")

        before = snapshot_rootfs(rootfs)
        written = inject(build_root / "data", container, prefixes, module_tree, arch, base.module_destination, plan.identity["software_set"])
        # Taken before verification so the diff attributes changes to injection
        # alone; `enroot start --root --rw` below writes to the rootfs itself.
        counts = assert_base_undisturbed(before, snapshot_rootfs(rootfs), written, rootfs)
        print(
            f"==> base image undisturbed: {counts['added']} paths added, "
            f"0 removed, 0 modified, {counts['inspected']} inspected"
        )
        verify(enroot, container, arch, target_spec.spack_target, args.base, base.module_destination, store)
        out = work / artifact_name
        partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
        partial.unlink(missing_ok=True)
        print(f"==> exporting {out}")
        run([enroot, "export", "-o", str(partial), container], "enroot export")
        partial.replace(out)
    finally:
        if not args.keep_container:
            subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False)

    digest = run(["sha256sum", str(out)], "hashing artifact").split()[0]
    (work / f"{artifact_name}.sha256").write_text(f"{digest}  {artifact_name}\n", encoding="utf-8")
    # ci/install-validated-sqsh.py performs the publisher seal and requires
    # --expected-size alongside the digest. Only the digest was ever emitted, so
    # the sealing step the closing message asks for could not actually be run.
    size = out.stat().st_size
    (work / f"{artifact_name}.size").write_text(f"{size}\n", encoding="utf-8")
    print(f"==> {artifact_name}")
    print(f"    sha256 {digest}")
    print(f"    size   {size}")
    print("    seal with the publisher role via ci/install-validated-sqsh.py")
    print(f"      --source {out} --expected-sha256 {digest} --expected-size {size}")
    print("    then consume via srun --container-image=<sealed path>")
    return 0


try:
    sys.exit(main())
except BuildError as error:
    print(f"chapar image build failed: {error}", file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
