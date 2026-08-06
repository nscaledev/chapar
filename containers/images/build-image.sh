#!/bin/bash
set -euo pipefail

unset BASH_ENV ENV LD_AUDIT LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PYTHONHOME PYTHONPATH
export PATH=/usr/bin:/bin

usage() {
    cat <<'USAGE'
Usage: containers/images/build-image.sh \
  --base nvidia-vlad --target linux-x86_64-v4 \
  --release-dir /resources/chapar/<env>/<os>/<arch>/releases/<release-id> \
  --image-id <image-id> \
  --candidate-root /resources/chapar/vlad-image/candidates \
  --tool-root /opt/chapar/vlad-image/tools/<native-arch> \
  --tool-evidence /resources/chapar/validation/builder-tools.json \
  [--enroot-build-root DIR] [--keep-container] [--plan-only]

Layer a promoted Chapar environment release into a digest-locked base image and
export an Enroot squashfs (.sqsh) that Pyxis consumes via
`srun --container-image=<path>`. Each selected container pairs one base image
with one Chapar environment and its own target list:

  --base nvidia-vlad   NVIDIA HPC-benchmarks 26.02 (default) + the vlad env.
                        Targets: linux-x86_64-v4, linux-aarch64-gb300.
  --base ubuntu-hpcsim Plain Ubuntu 24.04 + the hpcsim env. hpcsim policy
                        builds its own CUDA/GDR stack via Spack rather than
                        relying on an NVIDIA-branded OS image, so the base
                        stays vendor-neutral. Targets: linux-x86_64-generic.

The release directory's own metadata.txt must match the selected base's
environment (env_path) — pointing --base nvidia-vlad at an hpcsim release, or
vice versa, fails closed rather than producing a mismatched image.

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
requires them). Set REGISTRY_AUTH_FILE explicitly for authenticated registries;
the protected subprocess environment does not read credentials from caller HOME.

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
exec /usr/bin/python3 -I -E - "${SCRIPT_DIR}" "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Final

FORBIDDEN_STARTUP_ENV: Final = frozenset(
    {
        "BASH_ENV",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "ENV",
        "LD_AUDIT",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
        "PYTHONHOME",
        "PYTHONPATH",
    }
)
if FORBIDDEN_STARTUP_ENV & os.environ.keys():
    raise SystemExit("protected builder startup environment was not isolated")

SCRIPT_DIR = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]

TARGETS_PATH = SCRIPT_DIR / "targets.json"
SOURCES_PATH = SCRIPT_DIR / "sources-lock.json"
LOCK_VALIDATOR = SCRIPT_DIR / "tests" / "validate-locks.sh"

# Each selected container is one (base image, Chapar environment) pairing.
# `targets` is an allow-list checked against containers/images/targets.json --
# a base is not required to support every registered target (hpcsim has no
# aarch64 policy, so ubuntu-hpcsim only ever builds linux-x86_64-generic).
# Every base must be digest-locked in sources-lock.json under its own
# lock_category before a real (non --plan-only) build can run; never import a
# base by tag.
BASES: Final = {
    "nvidia-vlad": {
        "image": "nvcr.io/nvidia/hpc-benchmarks",
        "tag": "26.02",
        "lock_category": "nvidia_hpc_benchmarks_oci",
        "env": "vlad",
        "env_path": "envs/vlad",
        "targets": ("linux-x86_64-v4", "linux-aarch64-gb300"),
    },
    "ubuntu-hpcsim": {
        "image": "ubuntu",
        "tag": "24.04",
        "lock_category": "ubuntu_base_oci",
        "env": "hpcsim",
        "env_path": "envs/hpcsim",
        "targets": ("linux-x86_64-generic",),
    },
}
# Where the generated modulefiles land inside the image. Deliberately outside
# /resources so the module tree is image-owned while the store keeps its
# build-time absolute path.
IMAGE_MODULE_ROOT: Final = "/opt/chapar/modulefiles"
PROFILE_SCRIPT: Final = "/etc/profile.d/zz-chapar-image.sh"
DIGEST_RE: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
# Link/run edges carry the runtime closure. Build-only deps (cmake, ninja,
# autoconf, ...) are intentionally dropped -- they are not needed to execute the
# roots and they are a large fraction of the store.
RUNTIME_DEPTYPES: Final = frozenset({"link", "run"})
REQUIRED_BUILD_TOOLS: Final = ("enroot", "mksquashfs", "unsquashfs", "zstd", "syft", "jq", "skopeo")
TOOL_EVIDENCE_SCHEMA: Final = "chapar-vlad-builder-tools/v1"
SAFE_ENVIRONMENT_INPUTS: Final = (
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "REGISTRY_AUTH_FILE",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
)


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


def child_environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    environment = {
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TMPDIR": "/tmp",
    }
    for name in SAFE_ENVIRONMENT_INPUTS:
        value = os.environ.get(name)
        if value:
            environment[name] = value
    if extra:
        environment.update(extra)
    return environment


def load_validated_source_lock() -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(SOURCES_PATH, flags)
    except OSError as error:
        fail(f"source lock is missing or cannot be opened securely: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"source lock is not a regular file: {SOURCES_PATH}")
        validator_environment = child_environment(
            {"PATH": "/usr/bin:/bin", "SOURCES_PATH_OVERRIDE": f"/dev/fd/{descriptor}"}
        )
        try:
            subprocess.run(
                ["/bin/bash", str(LOCK_VALIDATOR), "--require-complete"],
                check=True,
                capture_output=True,
                text=True,
                env=validator_environment,
                pass_fds=(descriptor,),
            )
        except FileNotFoundError:
            fail(f"source-lock validator is missing: {LOCK_VALIDATOR}")
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or error.stdout or "").strip().splitlines()
            tail = detail[-1] if detail else f"exit {error.returncode}"
            fail(f"source lock failed complete structural validation: {tail}")
        os.lseek(descriptor, 0, os.SEEK_SET)
        payload = bytearray()
        while chunk := os.read(descriptor, 1024 * 1024):
            payload.extend(chunk)
        after = os.fstat(descriptor)
        def identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
            return (
                info.st_dev,
                info.st_ino,
                info.st_size,
                info.st_mtime_ns,
                info.st_ctime_ns,
            )
        if identity(before) != identity(after):
            fail("source lock changed while it was being validated")
        try:
            loaded = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_object)
        except (UnicodeError, ValueError) as error:
            fail(f"source lock is unreadable or malformed: {error}")
        if not isinstance(loaded, dict):
            fail("source lock must be a JSON object")
        return loaded
    except OSError as error:
        fail(f"source lock could not be read from its validated descriptor: {error}")
    finally:
        os.close(descriptor)
    raise AssertionError("unreachable")


def absolute(raw: str, label: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        fail(f"{label} must be an absolute path: {raw}")
    return Path(os.path.normpath(str(path)))


def run(command: list[str], label: str, pass_fds: tuple[int, ...] = (), environment: dict[str, str] | None = None) -> str:
    try:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            pass_fds=pass_fds,
            env=environment if environment is not None else child_environment(),
        )
    except FileNotFoundError:
        fail(f"{label} requires an unavailable tool: {command[0]}")
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip().splitlines()
        tail = detail[-1] if detail else f"exit {error.returncode}"
        fail(f"{label} failed: {tail}")
    return completed.stdout


def stable_sha256(path: Path, label: str, owner_uid: int | None = None) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"{label} cannot be opened securely: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"{label} is not a regular file: {path}")
        if owner_uid is not None and before.st_uid != owner_uid:
            fail(f"{label} is not owned by UID {owner_uid}: {path}")
        if stat.S_IMODE(before.st_mode) & 0o022:
            fail(f"{label} is group/other writable: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if identity(before) != identity(after):
            fail(f"{label} changed while open: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def protected_directory(path: Path, owner_uid: int = 0) -> None:
    if path != Path(os.path.realpath(path)):
        fail(f"tool root must be canonical and contain no symlink: {path}")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        root_info = os.fstat(descriptor)
        if root_info.st_uid != owner_uid or stat.S_IMODE(root_info.st_mode) & 0o022:
            fail(f"tool root is not protected by UID {owner_uid}: {path}")
        for part in path.parts[1:]:
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            info = os.fstat(descriptor)
            if info.st_uid != owner_uid or stat.S_IMODE(info.st_mode) & 0o022:
                fail(f"tool root is not protected by UID {owner_uid}: {path}")
    finally:
        os.close(descriptor)


def locked_binary_hashes(source_lock: dict[str, Any], native_arch: str) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for entry in source_lock["verified"]["builder_tools"]:
        for binary in entry["assets"][native_arch]["binaries"]:
            name = binary["name"]
            if name in REQUIRED_BUILD_TOOLS:
                if name in hashes:
                    fail(f"locked builder tool is duplicated: {name}")
                hashes[name] = binary["sha256"]
    if set(hashes) != set(REQUIRED_BUILD_TOOLS):
        fail("source lock does not contain the required image builder binaries")
    return hashes


def open_locked_tool(path: Path, name: str, expected_digest: str, owner_uid: int = 0) -> tuple[str, int]:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"locked builder tool cannot be inspected: {path}: {error}")
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid or stat.S_IMODE(info.st_mode) & 0o022 or stat.S_IMODE(info.st_mode) & 0o111 == 0:
        fail(f"locked builder tool has unsafe owner, mode, or type: {path}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != owner_uid or stat.S_IMODE(before.st_mode) & 0o022 or stat.S_IMODE(before.st_mode) & 0o111 == 0:
            fail(f"locked builder tool changed owner, mode, or type while opening: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after):
            fail(f"locked builder tool changed while open: {name}")
        if digest.hexdigest() != expected_digest:
            fail(f"locked builder tool digest mismatch: {name}")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return f"/dev/fd/{descriptor}", descriptor
    except Exception:
        os.close(descriptor)
        raise


def locked_tool_paths(source_lock: dict[str, Any], native_arch: str, tool_root: Path) -> tuple[dict[str, str], dict[str, str], tuple[int, ...]]:
    try:
        protected_directory(tool_root)
    except OSError as error:
        fail(f"tool root cannot be opened securely: {error}")
    expected = locked_binary_hashes(source_lock, native_arch)
    paths: dict[str, str] = {}
    descriptors: list[int] = []
    try:
        for name, digest in expected.items():
            path = tool_root / name
            command, descriptor = open_locked_tool(path, name, digest)
            paths[name] = command
            descriptors.append(descriptor)
    except Exception:
        for descriptor in descriptors:
            os.close(descriptor)
        raise
    return paths, expected, tuple(descriptors)


def descriptor_tool_environment(
    tools: dict[str, str], directory: Path, extra: dict[str, str] | None = None
) -> dict[str, str]:
    for name, command in tools.items():
        os.symlink(command, directory / name)
    environment = child_environment(extra)
    environment["PATH"] = f"{directory}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    return environment


def write_tool_evidence(path: Path, target: str, native_arch: str, hashes: dict[str, str]) -> None:
    parent = path.parent
    info = parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
        fail(f"tool evidence parent is not a trusted caller-owned directory: {parent}")
    payload = json.dumps(
        {"schema": TOOL_EVIDENCE_SCHEMA, "target": target, "native_arch": native_arch, "tools": hashes},
        sort_keys=True,
        separators=(",", ":"),
    ).encode() + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), 0o444)
    try:
        os.fchmod(descriptor, 0o444)
        view = memoryview(payload)
        while view:
            view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if stable_sha256(path, "tool evidence") != hashlib.sha256(payload).hexdigest():
        fail("tool evidence bytes drifted after publication")


def tool_supply_self_test() -> None:
    root = Path("/usr/bin")
    protected_directory(root)
    binary = root / "true"
    digest = stable_sha256(binary, "tool self-test binary", 0)
    command, descriptor = open_locked_tool(binary, "true", digest)
    try:
        with tempfile.TemporaryDirectory(prefix="chapar-tool-self-test.") as raw:
            poisoned = {
                "BASH_ENV": "/attacker/bash-env",
                "DYLD_INSERT_LIBRARIES": "/attacker/dyld-insert.dylib",
                "DYLD_LIBRARY_PATH": "/attacker/dyld-library",
                "ENROOT_CONFIG_PATH": "/attacker/enroot-config",
                "LD_AUDIT": "/attacker/audit.so",
                "LD_LIBRARY_PATH": "/attacker/library",
                "LD_PRELOAD": "/attacker/preload.so",
                "PYTHONHOME": "/attacker/python-home",
                "PYTHONPATH": "/attacker/python-path",
            }
            previous = {name: os.environ.get(name) for name in poisoned}
            os.environ.update(poisoned)
            try:
                environment = descriptor_tool_environment(
                    {"true": command}, Path(raw), {"ENROOT_DATA_PATH": "/trusted/enroot-data"}
                )
            finally:
                for name, value in previous.items():
                    if value is None:
                        os.environ.pop(name, None)
                    else:
                        os.environ[name] = value
            if Path(raw, "true").readlink() != Path(command) or environment["PATH"].split(":", 1)[0] != raw:
                fail("tool self-test did not bind the controlled PATH to the descriptor")
            if poisoned.keys() & environment.keys() or environment.get("ENROOT_DATA_PATH") != "/trusted/enroot-data":
                fail("tool self-test did not isolate the controlled subprocess environment")
            if sys.platform.startswith("linux"):
                subprocess.run(["true"], check=True, pass_fds=(descriptor,), env=environment)
            elif command != f"/dev/fd/{descriptor}" or not stat.S_ISREG(os.fstat(descriptor).st_mode):
                fail("tool self-test did not retain a descriptor-bound command")
    finally:
        os.close(descriptor)
    try:
        open_locked_tool(binary, "true", "0" * 64)
    except BuildError as error:
        if "digest mismatch" not in str(error):
            raise
    else:
        fail("tool self-test accepted a digest mismatch")
    print("PASS: locked builder tools execute from descriptor-bound bytes under a protected tool root")


def prepare_owned_directory(path: Path, label: str) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(f"{label} is not a trusted directory: {path}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
        fail(f"{label} is writable or owned by another identity: {path}")


# ---------------------------------------------------------------- base image --

def resolve_base_descriptor(base: dict[str, str], target: str, lock: dict[str, Any]) -> str:
    """Return the immutable per-platform descriptor digest for `target`.

    Fails closed unless the lock is complete. Copying fleet-manager's
    `docker://nvcr.io#<image>:<tag>` tag import would violate the lock's
    floating_input_rule, so the digest must come from the lock.
    """
    status = lock.get("status")
    unresolved = lock.get("unresolved") or []
    if status != "complete" or unresolved:
        categories = ", ".join(sorted({str(item.get("category")) for item in unresolved})) or "none listed"
        fail(
            "source lock is not usable for an image build: status="
            f"{status!r}, unresolved categories: {categories}. "
            f"Resolve the {base['image']}:{base['tag']} index and per-platform "
            "descriptors on a builder with skopeo and nvcr.io access, then "
            f"re-run {LOCK_VALIDATOR} --require-complete."
        )
    try:
        oci = lock["verified"][base["lock_category"]]
        platform = oci["platforms"][target]
        descriptor = platform["descriptor_digest"]
    except (KeyError, TypeError):
        fail(
            f"source lock has no verified platform descriptor for base "
            f"{base['image']}:{base['tag']} (category {base['lock_category']}) "
            f"and target {target}"
        )
    if oci.get("image") != base["image"] or oci.get("tag") != base["tag"]:
        fail(f"source lock {base['lock_category']} identity is not the approved {base['image']}:{base['tag']} source")
    if not isinstance(descriptor, str) or DIGEST_RE.fullmatch(descriptor) is None:
        fail(f"platform descriptor for {target} is not an immutable sha256 digest")
    return descriptor


def import_base(base: dict[str, str], descriptor: str, import_dir: Path, tools: dict[str, str], tool_descriptors: tuple[int, ...], tool_environment: dict[str, str]) -> Path:
    """Import the digest-pinned base into a one-use local SQSH.

    skopeo copies by digest into an OCI archive first, then enroot imports that
    archive. Going through skopeo keeps the digest exact and avoids depending on
    enroot's registry URI supporting `@sha256:` forms. The result is never
    reused: an OCI descriptor authenticates registry content, not arbitrary
    bytes stored under a descriptor-shaped local filename.
    """
    out = import_dir / "base.sqsh"
    skopeo = tools["skopeo"]
    enroot = tools["enroot"]
    archive = import_dir / "base-oci.tar"
    print(f"==> copying {base['image']}@{descriptor}")
    run([skopeo, "copy", f"docker://{base['image']}@{descriptor}", f"oci-archive:{archive}"], "skopeo copy", tool_descriptors, tool_environment)
    print("==> importing base into enroot")
    run([enroot, "import", "-o", str(out), f"oci-archive://{archive}"], "enroot import", tool_descriptors, tool_environment)
    archive.unlink(missing_ok=True)
    imported = out.lstat()
    if not stat.S_ISREG(imported.st_mode) or imported.st_uid != os.geteuid() or imported.st_nlink != 1:
        fail("enroot produced an untrusted base import")
    out.chmod(0o400)
    return out


def link_no_clobber(source: Path, destination: Path, label: str) -> os.stat_result:
    info = source.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        fail(f"{label} source is not a trusted regular file: {source}")
    try:
        os.link(source, destination, follow_symlinks=False)
    except FileExistsError:
        raise BuildError(f"{label} already exists: {destination}") from None
    published = destination.lstat()
    if (published.st_dev, published.st_ino) != (info.st_dev, info.st_ino):
        fail(f"{label} publication identity changed: {destination}")
    return info


def publish_pair_no_clobber(
    artifact_source: Path,
    artifact: Path,
    checksum_source: Path,
    checksum: Path,
    checksum_payload: str,
) -> None:
    """Publish without overwrites, unsafe rollback, or a valid checksum first."""
    checksum_descriptor = os.open(
        checksum_source,
        os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        checksum_info = os.fstat(checksum_descriptor)
        if not stat.S_ISREG(checksum_info.st_mode) or checksum_info.st_uid != os.geteuid() or checksum_info.st_nlink != 1:
            fail(f"candidate checksum source is not a trusted regular file: {checksum_source}")
        os.fchmod(checksum_descriptor, 0o444)
        link_no_clobber(checksum_source, checksum, "candidate checksum")
        link_no_clobber(artifact_source, artifact, "candidate artifact")
        payload = checksum_payload.encode("utf-8")
        os.lseek(checksum_descriptor, 0, os.SEEK_SET)
        os.ftruncate(checksum_descriptor, 0)
        offset = 0
        while offset < len(payload):
            offset += os.write(checksum_descriptor, payload[offset:])
        os.fsync(checksum_descriptor)
        published = checksum.lstat()
        current = os.fstat(checksum_descriptor)
        if (published.st_dev, published.st_ino) != (current.st_dev, current.st_ino):
            fail(f"candidate checksum publication identity changed: {checksum}")
    finally:
        os.close(checksum_descriptor)
    artifact_source.unlink()
    checksum_source.unlink()


def publication_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="chapar-image-publication.") as raw:
        root = Path(raw)

        def source(name: str, payload: str) -> Path:
            path = root / name
            path.write_text(payload, encoding="utf-8")
            path.chmod(0o444)
            return path

        artifact = root / "candidate.sqsh"
        checksum = root / "candidate.sqsh.sha256"
        artifact_source = source("artifact.partial", "artifact\n")
        checksum_source = source("checksum.partial", "PENDING\n")
        checksum_source.chmod(0o600)
        publish_pair_no_clobber(artifact_source, artifact, checksum_source, checksum, "digest  candidate.sqsh\n")
        if artifact.read_text(encoding="utf-8") != "artifact\n" or checksum.read_text(encoding="utf-8") != "digest  candidate.sqsh\n":
            fail("publication self-test changed successful pair bytes")

        artifact.unlink()
        checksum.unlink()
        artifact.write_text("retained artifact\n", encoding="utf-8")
        artifact.chmod(0o444)
        artifact_source = source("artifact-race.partial", "new artifact\n")
        checksum_source = source("checksum-race.partial", "PENDING\n")
        checksum_source.chmod(0o600)
        try:
            publish_pair_no_clobber(artifact_source, artifact, checksum_source, checksum, "new digest\n")
        except BuildError:
            pass
        else:
            fail("publication self-test overwrote an artifact collision")
        if artifact.read_text(encoding="utf-8") != "retained artifact\n" or checksum.read_text(encoding="utf-8") != "PENDING\n":
            fail("artifact collision changed the artifact or exposed a valid checksum")

        artifact.unlink()
        checksum.unlink()
        checksum.write_text("retained checksum\n", encoding="utf-8")
        checksum.chmod(0o444)
        artifact_source = source("artifact-checksum-race.partial", "new artifact\n")
        checksum_source = source("checksum-checksum-race.partial", "PENDING\n")
        checksum_source.chmod(0o600)
        try:
            publish_pair_no_clobber(artifact_source, artifact, checksum_source, checksum, "new digest\n")
        except BuildError:
            pass
        else:
            fail("publication self-test overwrote a checksum collision")
        if artifact.exists() or checksum.read_text(encoding="utf-8") != "retained checksum\n":
            fail("checksum collision published an artifact or changed checksum bytes")
    print("PASS: candidate artifact/checksum pair publication is no-clobber and crash-safe")


# ------------------------------------------------------------ release closure --

def read_metadata(release_dir: Path) -> dict[str, str]:
    path = release_dir / "metadata.txt"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"release metadata is unreadable: {error}")
    metadata: dict[str, str] = {}
    for line in lines:
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        metadata[key.strip()] = value.strip()
    for required in ("release_id", "os", "arch", "store", "env_path"):
        if not metadata.get(required):
            fail(f"release metadata is missing required field: {required}")
    return metadata


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
                fail(f"release spack.lock dependency edge is malformed: {digest}")
            # Spack has spelled this key both "type" and "deptypes"/"parameters"
            # across versions; accept whichever the lock carries.
            raw = edge.get("type") or edge.get("deptypes") or (edge.get("parameters") or {}).get("deptypes") or []
            if isinstance(raw, str):
                deptypes = {raw}
            elif isinstance(raw, list) and all(isinstance(item, str) for item in raw):
                deptypes = set(raw)
            else:
                fail(f"release spack.lock dependency edge has malformed deptypes: {digest}")
            if not deptypes:
                fail(f"release spack.lock dependency edge has no deptype: {digest}")
            if deptypes & RUNTIME_DEPTYPES:
                child = edge.get("hash") or edge.get("id")
                if not isinstance(child, str) or child not in concrete:
                    fail(f"release spack.lock runtime dependency edge has no valid child: {digest}")
                queue.append(child)
    return selected


def resolve_prefixes(store: Path, hashes: list[str]) -> list[Path]:
    """Map dag hashes to installed prefixes by hash suffix.

    Chapar's shared install tree uses a flat `{name}-{version}-{hash}`
    projection with padded paths, so globbing for the hash suffix is
    projection-agnostic and needs no spack invocation. A hash that matches
    nothing, or more than one prefix, is fatal rather than skipped.
    """
    if not store.is_dir():
        fail(f"release store root is not a directory: {store}")
    # Padded install trees (release.sh detect_padded_length) nest the real
    # prefixes under a chain of __spack_path_placeholder__ directories; the
    # metadata's store field records the unpadded root. Descend to the deepest
    # placeholder before globbing, mirroring release.sh.
    while (store / "__spack_path_placeholder__").is_dir():
        store = store / "__spack_path_placeholder__"
    index: dict[str, list[Path]] = {}
    for entry in store.iterdir():
        suffix = entry.name.rsplit("-", 1)[-1]
        if entry.is_dir():
            index.setdefault(suffix, []).append(entry)
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


# ------------------------------------------------------------------ injection --

def rootfs_path(data_path: Path, container: str, absolute_target: Path) -> Path:
    return data_path / container / str(absolute_target).lstrip("/")


def inject(data_path: Path, container: str, prefixes: list[Path], release_dir: Path, arch: str, base: dict[str, str]) -> None:
    print(f"==> injecting {len(prefixes)} prefixes at their build-time paths")
    for prefix in prefixes:
        destination = rootfs_path(data_path, container, prefix)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            continue
        # -a preserves mode, symlinks, and times. Modes matter: a plain copy
        # under a restrictive umask breaks non-owner execution under Pyxis.
        run(["/bin/cp", "-a", str(prefix), str(destination)], f"injecting {prefix.name}")

    modules_source = release_dir / "modulefiles" / arch
    if not modules_source.is_dir():
        fail(f"release has no modulefiles for arch {arch}: {modules_source}")
    modules_destination = rootfs_path(data_path, container, Path(IMAGE_MODULE_ROOT)) / arch
    modules_destination.parent.mkdir(parents=True, exist_ok=True)
    if not modules_destination.exists():
        run(["/bin/cp", "-a", str(modules_source), str(modules_destination)], "injecting modulefiles")

    # Opt-in by design: `module use` only, never a PATH/LD_LIBRARY_PATH prepend.
    # Anything already on PATH/LD_LIBRARY_PATH in the base image (e.g. the
    # NVIDIA base's own MPI/HPL/NCCL under /workspace) keeps resolving to what
    # it was linked against.
    profile = rootfs_path(data_path, container, Path(PROFILE_SCRIPT))
    profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text(
        f"# Chapar {base['env']} release, layered into this image.\n"
        "# Deliberately does not alter PATH or LD_LIBRARY_PATH. Run\n"
        f"# `module avail` then `module load <name>` to use the {base['env']} stack.\n"
        f'if command -v module >/dev/null 2>&1 && [ -d "{IMAGE_MODULE_ROOT}/{arch}" ]; then\n'
        f'    module use "{IMAGE_MODULE_ROOT}/{arch}"\n'
        "fi\n",
        encoding="utf-8",
    )
    profile.chmod(0o644)


def verify(enroot: str, container: str, arch: str, spack_target: str, base_id: str, tool_descriptors: tuple[int, ...], tool_environment: dict[str, str]) -> None:
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
    script = (
        f'set -eu\n'
        f'test -d "{IMAGE_MODULE_ROOT}/{arch}"\n'
        f'test -r "{PROFILE_SCRIPT}"\n'
        f'{base_check}'
        f'count=$(find "{IMAGE_MODULE_ROOT}/{arch}" -type f | wc -l)\n'
        f'[ "$count" -gt 0 ]\n'
        f'echo "verified: $count modulefiles, base payload intact"\n'
    )
    output = run(
        [enroot, "start", "--root", "--rw", "--env", "PS1=", "--env", "NVIDIA_VISIBLE_DEVICES=void",
         container, "bash", "-c", script],
        "in-image verification",
        tool_descriptors,
        tool_environment,
    )
    print("    " + output.strip().splitlines()[-1])


# ----------------------------------------------------------------------- main --

def main() -> int:
    if sys.argv[1:] == ["--self-test-publication"]:
        publication_self_test()
        return 0
    if sys.argv[1:] == ["--self-test-tools"]:
        tool_supply_self_test()
        return 0
    parser = argparse.ArgumentParser(description="Layer a Chapar environment release into a digest-locked base image")
    parser.add_argument("--target", required=True)
    parser.add_argument("--base", default="nvidia-vlad", choices=tuple(BASES))
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--candidate-root")
    parser.add_argument("--enroot-build-root")
    parser.add_argument("--tool-root")
    parser.add_argument("--tool-evidence")
    parser.add_argument("--keep-container", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()

    targets = load_json(TARGETS_PATH, "target registry")["targets"]
    if args.target not in targets:
        fail(f"unknown target {args.target!r}; known: {', '.join(sorted(targets))}")
    target_spec = targets[args.target]
    if ID_RE.fullmatch(args.image_id) is None:
        fail("image id must be a short lowercase identifier")
    if not args.plan_only and not args.candidate_root:
        fail("--candidate-root is required unless --plan-only is given")

    base = BASES[args.base]
    if args.target not in base["targets"]:
        fail(
            f"base {args.base!r} does not support target {args.target!r}; "
            f"it supports: {', '.join(base['targets'])}"
        )

    release_dir = absolute(args.release_dir, "release dir")
    if not release_dir.is_dir():
        fail(f"release dir is not a directory: {release_dir}")
    metadata = read_metadata(release_dir)
    arch = metadata["arch"]
    expected_arch = f"linux-{metadata['os']}-{target_spec['spack_target']}"
    if arch != expected_arch:
        fail(f"release architecture mismatch: target {args.target} requires {expected_arch}, release records {arch}")
    store = absolute(metadata["store"], "release store")
    if metadata["env_path"] != base["env_path"]:
        fail(
            f"release at {release_dir} was built from {metadata['env_path']!r}, "
            f"but base {args.base!r} is for {base['env_path']!r} ({base['env']}). "
            "Point --release-dir at a release of the matching environment."
        )

    source_lock = load_validated_source_lock()
    descriptor = resolve_base_descriptor(base, args.target, source_lock)
    closure = runtime_closure(release_dir)
    prefixes = resolve_prefixes(store, closure)

    artifact_name = f"{args.base}+{base['tag']}-{args.target}.sqsh"
    if args.plan_only:
        print(f"target:        {args.target} ({target_spec['oci_platform']}, spack_target={target_spec['spack_target']})")
        print(f"base id:       {args.base} (env={base['env']})")
        print(f"release:       {metadata['release_id']} arch={arch}")
        print(f"base:          {base['image']}@{descriptor}")
        print(f"store:         {store}")
        print(f"closure:       {len(prefixes)} runtime prefixes of {len(closure)} closure specs")
        print(f"modules:       {IMAGE_MODULE_ROOT}/{arch} (opt-in via module load)")
        print(f"artifact:      {artifact_name}")
        for prefix in prefixes[:10]:
            print(f"    inject {prefix}")
        if len(prefixes) > 10:
            print(f"    ... and {len(prefixes) - 10} more")
        return 0

    candidate_root = absolute(args.candidate_root, "candidate root")
    work = candidate_root / args.target / args.image_id
    if not work.is_dir():
        fail(f"target/image-qualified candidate work root must exist and be writable: {work}")
    out = work / artifact_name
    checksum = work / f"{artifact_name}.sha256"
    for candidate_output in (out, checksum):
        try:
            candidate_output.lstat()
        except FileNotFoundError:
            continue
        fail(f"candidate output already exists: {candidate_output}")

    if not args.tool_root or not args.tool_evidence:
        fail("--tool-root and --tool-evidence are required for a real image build")
    tool_root = absolute(args.tool_root, "tool root")
    tool_evidence = absolute(args.tool_evidence, "tool evidence")
    try:
        tool_evidence.lstat()
    except FileNotFoundError:
        pass
    else:
        fail(f"tool evidence already exists: {tool_evidence}")
    tools, tool_hashes, tool_descriptors = locked_tool_paths(source_lock, target_spec["native_arch"], tool_root)
    try:
        write_tool_evidence(tool_evidence, args.target, target_spec["native_arch"], tool_hashes)
        enroot = tools["enroot"]
        build_root = absolute(args.enroot_build_root, "enroot build root") if args.enroot_build_root else work / ".enroot-build"
        prepare_owned_directory(build_root, "enroot build root")
        for name in ("data", "cache", "temp", "runtime"):
            prepare_owned_directory(build_root / name, f"enroot {name} directory")
        enroot_environment = {
            "ENROOT_DATA_PATH": str(build_root / "data"),
            "ENROOT_CACHE_PATH": str(build_root / "cache"),
            "ENROOT_TEMP_PATH": str(build_root / "temp"),
            "ENROOT_RUNTIME_PATH": str(build_root / "runtime"),
        }

        container = f"chaparbuild-{args.base}-{args.target}-{os.getpid()}"
        with tempfile.TemporaryDirectory(prefix="verified-tools.", dir=build_root / "temp") as tool_raw:
            tool_environment = descriptor_tool_environment(tools, Path(tool_raw), enroot_environment)
            subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False, pass_fds=tool_descriptors, env=tool_environment)
            with tempfile.TemporaryDirectory(prefix="base-import.", dir=build_root / "temp") as import_raw:
                base_sqsh = import_base(base, descriptor, Path(import_raw), tools, tool_descriptors, tool_environment)
                run([enroot, "create", "--name", container, str(base_sqsh)], "enroot create", tool_descriptors, tool_environment)
            try:
                inject(build_root / "data", container, prefixes, release_dir, arch, base)
                verify(enroot, container, arch, target_spec["spack_target"], args.base, tool_descriptors, tool_environment)
                partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
                checksum_partial: Path | None = None
                partial.unlink(missing_ok=True)
                try:
                    print(f"==> exporting {out}")
                    run([enroot, "export", "-o", str(partial), container], "enroot export", tool_descriptors, tool_environment)
                    exported = partial.lstat()
                    if not stat.S_ISREG(exported.st_mode) or exported.st_uid != os.geteuid() or exported.st_nlink != 1:
                        fail("enroot produced an untrusted candidate artifact")
                    partial.chmod(0o444)
                    digest = stable_sha256(partial, "candidate artifact", os.geteuid())
                    checksum_fd, checksum_raw = tempfile.mkstemp(prefix=f".{artifact_name}.sha256.partial.", dir=work)
                    checksum_partial = Path(checksum_raw)
                    with os.fdopen(checksum_fd, "w", encoding="utf-8") as stream:
                        stream.write("PENDING\n")
                        stream.flush()
                        os.fsync(stream.fileno())
                    publish_pair_no_clobber(
                        partial,
                        out,
                        checksum_partial,
                        checksum,
                        f"{digest}  {artifact_name}\n",
                    )
                finally:
                    partial.unlink(missing_ok=True)
                    if checksum_partial is not None:
                        checksum_partial.unlink(missing_ok=True)
            finally:
                if not args.keep_container:
                    subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False, pass_fds=tool_descriptors, env=tool_environment)
    finally:
        for descriptor_fd in tool_descriptors:
            os.close(descriptor_fd)

    print(f"==> {artifact_name}")
    print(f"    sha256 {digest}")
    print(f"    seal with the publisher role, then consume via srun --container-image=<sealed path>")
    return 0


try:
    sys.exit(main())
except BuildError as error:
    print(f"chapar image build failed: {error}", file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
