"""Enroot mechanics: base import, injection, in-image verification, export.

The base image is resolved by digest from sources-lock.json, never by tag: the
lock's floating_input_rule forbids tags as locked values, so nothing here runs
until that lock reaches status "complete". Stdlib only.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Final

from chapar.common.jsonio import fail
from chapar.common.proc import require_tool, run
from chapar.image.registry import OCI_DIGEST, Container, Sources
from chapar.image.rootfs import rootfs_path

PROFILE_SCRIPT: Final = "/etc/profile.d/zz-chapar-image.sh"


def resolve_base_descriptor(base: Container, target: str, lock: Sources) -> tuple[str, str]:
    """Return the immutable per-platform descriptor digest and tag for `target`.

    Fails closed unless the lock is complete. Copying fleet-manager's
    `docker://nvcr.io#<image>:<tag>` tag import would violate the lock's
    floating_input_rule, so the digest must come from the lock.
    """
    if lock.status != "complete":
        fail(
            "source lock is not usable for an image build: status="
            f"{lock.status!r}. "
            f"Resolve the {base.base_image} OCI index and per-platform "
            "descriptors on a builder with skopeo and registry access, then "
            "re-record containers/images/sources-lock.json as complete."
        )
    oci = lock.verified.get(base.source_lock_category)
    platforms = oci.get("platforms") if isinstance(oci, dict) else None
    platform = platforms.get(target) if isinstance(platforms, dict) else None
    descriptor = platform.get("descriptor_digest") if isinstance(platform, dict) else None
    if not isinstance(oci, dict) or descriptor is None:
        fail(
            f"source lock has no verified platform descriptor for base "
            f"{base.base_image} (category {base.source_lock_category}) "
            f"and target {target}"
        )
    tag = oci.get("tag")
    if oci.get("image") != base.base_image or not isinstance(tag, str) or not tag:
        fail(f"source lock {base.source_lock_category} identity differs from the container registry")
    if not isinstance(descriptor, str) or OCI_DIGEST.fullmatch(descriptor) is None:
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
    run([skopeo, "copy", f"docker://{base.base_image}@{descriptor}", f"oci-archive:{archive}"], capture=True)
    print("==> importing base into enroot")
    run([enroot, "import", "-o", str(partial), f"oci-archive://{archive}"], capture=True)
    archive.unlink(missing_ok=True)
    # mv within one filesystem is atomic, so a reader never sees a partial base.
    partial.replace(out)
    return out


def inject(
    data_path: Path,
    container: str,
    prefixes: list[Path],
    modules_root: Path,
    arch: str,
    module_root: str,
    software_set: str,
) -> list[Path]:
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
        run(["cp", "-a", str(prefix), str(destination)], capture=True)

    modules_destination.parent.mkdir(parents=True, exist_ok=True)
    run(["cp", "-a", str(modules_source), str(modules_destination)], capture=True)

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
    return [*destinations, modules_destination, profile]


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
            "  x86_64) test -f /workspace/hpl-linux-x86_64/hpl.sh ;;\n"
            "  aarch64) test -f /workspace/hpl-linux-aarch64-gpu/hpl.sh ;;\n"
            "esac\n"
        )
    elif base_id == "ubuntu-hpcsim":
        # Confirms the base is still a genuine, uncorrupted Ubuntu 24.04
        # rootfs after injection -- apt/dpkg intact, correct OS release.
        base_check = "grep -q 'VERSION_ID=\"24.04\"' /etc/os-release\ncommand -v dpkg >/dev/null 2>&1\n"
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
        "for tool in python3 python mpirun mpiexec nvcc cmake; do\n"
        '    resolved=$(command -v "$tool" 2>/dev/null || true)\n'
        '    case "$resolved" in\n'
        '      "") ;;\n'
        f"      {store}/*|{module_root}/*)\n"
        '        echo "shadowed: $tool resolves to $resolved before any module load" >&2\n'
        "        exit 1 ;;\n"
        "    esac\n"
        "done\n"
    )
    script = (
        "set -eu\n"
        f'test -d "{module_root}/{arch}"\n'
        f'test -r "{PROFILE_SCRIPT}"\n'
        f"{base_check}"
        f"{shadow_check}"
        f'count=$(find "{module_root}/{arch}" -type f | wc -l)\n'
        '[ "$count" -gt 0 ]\n'
        'echo "verified: $count modulefiles, base payload intact, base tools unshadowed"\n'
    )
    output = run(
        [
            enroot,
            "start",
            "--root",
            "--rw",
            "--env",
            "PS1=",
            "--env",
            "NVIDIA_VISIBLE_DEVICES=void",
            container,
            "bash",
            "-c",
            script,
        ],
        capture=True,
    )
    print("    " + output.strip().splitlines()[-1])


def export(enroot: str, container: str, work: Path, artifact_name: str) -> Path:
    """Export the container to work/<artifact_name>.sqsh with digest/size sidecars."""
    out = work / artifact_name
    partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
    partial.unlink(missing_ok=True)
    print(f"==> exporting {out}")
    run([enroot, "export", "-o", str(partial), container], capture=True)
    partial.replace(out)
    digest = run(["sha256sum", str(out)], capture=True).split()[0]
    (work / f"{artifact_name}.sha256").write_text(f"{digest}  {artifact_name}\n", encoding="utf-8")
    # `chapar image publish` performs the publisher seal and requires
    # --expected-size alongside the digest, so both sidecars are emitted.
    size = out.stat().st_size
    (work / f"{artifact_name}.size").write_text(f"{size}\n", encoding="utf-8")
    print(f"==> {artifact_name}")
    print(f"    sha256 {digest}")
    print(f"    size   {size}")
    print("    seal with the publisher role via `chapar image publish`")
    print(f"      --source {out} --expected-sha256 {digest} --expected-size {size}")
    print("    then consume via srun --container-image=<sealed path>")
    return out


def remove_container(enroot: str, container: str) -> None:
    """Best-effort cleanup of a working container; failure is not fatal."""
    subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False)
