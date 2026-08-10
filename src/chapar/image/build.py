"""`chapar image build`: layer a Chapar release into a digest-locked base image.

Layer a promoted release into the digest-pinned base and export an Enroot
squashfs (.sqsh) that Pyxis consumes via `srun --container-image=<path>`. Each
container in containers.json pairs one base image with one software set and its
own target list.

What is injected: the release's explicit root specs plus their transitive
link/run dependency closure, each copied to the SAME absolute prefix it was
built at. Spack embeds absolute RPATHs, so a prefix moved to a different path
would not resolve at run time. Build-only dependencies are excluded.

Module precedence: injected modules are reachable only via an explicit
`module load` after `module use`; nothing already present in the base image's
PATH or LD_LIBRARY_PATH is disturbed.

--plan-only prints the resolved base digest, injection prefix list, and output
path, then exits without importing, mutating, or writing anything. It is the
only mode that is useful on a workstation. Stdlib only.
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from typing import Final

from chapar.common.jsonio import fail
from chapar.common.proc import require_tool, run
from chapar.common.release import Release, verify_release
from chapar.image import enroot as enroot_ops
from chapar.image.closure import resolve_prefixes, runtime_closure
from chapar.image.elf import audit_closure, base_glibc_minor
from chapar.image.registry import (
    Container,
    Sources,
    Target,
    default_registry_dir,
    parse_containers,
    parse_sources,
    parse_targets,
)
from chapar.image.rootfs import assert_base_undisturbed, assert_modules_are_opt_in, snapshot_rootfs

ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


def absolute(raw: str, label: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        fail(f"{label} must be an absolute path: {raw}")
    return Path(os.path.normpath(str(path)))


def release_module_arch(release_dir: Path, spack_target: str) -> tuple[Path, str]:
    """The release-local module tree and its single architecture directory.

    Read the release-local module tree, not metadata.roots["modulefiles"].
    That root is the durable *published* path, which release.sh only ever
    materialises as a symlink to this directory's single architecture child --
    so resolving it here would either be absent (before publish-modules) or a
    symlink (after). The release-local tree is immutable and always present.
    """
    module_tree = release_dir / "modulefiles"
    if module_tree.is_symlink():
        fail("release module destination cannot be a symlink")
    module_arches = (
        sorted(path.name for path in module_tree.iterdir() if path.is_dir()) if module_tree.is_dir() else []
    )
    if len(module_arches) != 1:
        fail("release must contain exactly one module destination")
    arch = module_arches[0]
    if not arch.endswith(spack_target):
        fail("release module architecture does not match selected target")
    return module_tree, arch


def admit_release(release: Release, base: Container, target_id: str) -> None:
    """Check the container accepts this release's identity and the request's target."""
    if release.target != target_id:
        fail(f"release target does not match image request: {release.target} != {target_id}")
    if release.software_set not in base.accepted_software_sets:
        fail(f"release software set is not accepted by selected container: {release.software_set}")
    if target_id not in base.allowed_targets:
        fail(f"selected container does not allow release target: {target_id}")


def load_registries(registry_dir: Path) -> tuple[dict[str, Target], dict[str, Container], Sources]:
    targets = parse_targets(registry_dir / "targets.json")
    sources = parse_sources(registry_dir / "sources-lock.json")
    containers = parse_containers(registry_dir / "containers.json", targets, sources)
    return targets, containers, sources


def run_build(arguments: argparse.Namespace) -> int:
    if ID_RE.fullmatch(arguments.image_id) is None:
        fail("image id must be a short lowercase identifier")
    release_dir = absolute(arguments.release_dir, "release dir")
    if not release_dir.is_dir():
        fail(f"release dir is not a directory: {release_dir}")
    registry_dir = absolute(str(arguments.registry_dir), "registry dir") if arguments.registry_dir else default_registry_dir()
    targets, containers, sources = load_registries(registry_dir)
    base = containers.get(arguments.base)
    if base is None:
        fail(f"unknown container: {arguments.base} (registry has: {', '.join(sorted(containers))})")
    target_facts = targets.get(arguments.target)
    if target_facts is None:
        fail(f"unknown target: {arguments.target} (registry has: {', '.join(sorted(targets))})")

    # The release directory is self-describing: verify_release checks its bytes
    # against the digests the build recorded and its recorded target facts
    # against the committed registry. Nothing else vouches for it.
    release = verify_release(release_dir, targets_registry=registry_dir / "targets.json")
    admit_release(release, base, arguments.target)
    store = absolute(release.roots["install_tree"], "release install tree")
    module_tree, arch = release_module_arch(release_dir, target_facts.spack_target)

    descriptor, tag = enroot_ops.resolve_base_descriptor(base, arguments.target, sources)
    closure = runtime_closure(release_dir)
    prefixes = resolve_prefixes(store, closure)
    # Pure reads, so this runs in plan mode too: an operator finds out that the
    # closure is not self-contained before requesting a builder, not after.
    audited, glibc_required = audit_closure(prefixes)
    # Checked on the release-local source, not the injected copy, so a modulefile
    # that would leak into unrelated container processes is caught before any
    # builder is asked for a container.
    modulefiles = assert_modules_are_opt_in(module_tree / arch)

    artifact_name = f"{arguments.base}+{tag}-{arguments.target}.sqsh"
    deliver = " ".join(release.deliver)
    if arguments.plan_only:
        print(f"target:        {arguments.target} ({target_facts.oci_platform}, spack_target={target_facts.spack_target})")
        print(f"base id:       {arguments.base} (software_set={release.software_set})")
        print(f"release:       {release.release_id} run={release.run_id} arch={arch}")
        print(f"release lock:  {release.lock_sha256}")
        print(f"base:          {base.base_image}@{descriptor}")
        print(f"store:         {store}")
        print(f"closure:       {len(prefixes)} runtime prefixes of {len(closure)} closure specs")
        print(f"elf audit:     {audited} dynamic objects, rpath-linked, no stub search paths")
        print(f"requires:      GLIBC_2.{glibc_required} or newer in the base image")
        print(f"modules:       {base.module_destination}/{arch} ({modulefiles} files, opt-in via module load)")
        print(f"deliver:       {deliver}")
        print(f"artifact:      {artifact_name}")
        for prefix in prefixes[:10]:
            print(f"    inject {prefix}")
        if len(prefixes) > 10:
            print(f"    ... and {len(prefixes) - 10} more")
        return 0

    # The release records its own delivery policy (site settings at build time).
    # An image is a publishable artifact, so that policy gates it; --force is
    # the explicit operator override for a one-off image from a modules-only
    # release.
    if "container" not in release.deliver and not arguments.force:
        fail(
            f"release delivery policy does not include container (deliver: {deliver}); "
            "set CHAPAR_DELIVER to include container and rebuild, or pass --force"
        )

    if arguments.output_dir:
        work = absolute(str(arguments.output_dir), "output dir")
    else:
        output_root = os.environ.get("CHAPAR_CONTAINER_OUTPUT_ROOT")
        if not output_root:
            fail("no --output-dir given and CHAPAR_CONTAINER_OUTPUT_ROOT is not set")
        work = (
            absolute(output_root, "CHAPAR_CONTAINER_OUTPUT_ROOT")
            / release.software_set
            / arguments.target
            / "staging"
            / arguments.image_id
        )
    work.mkdir(parents=True, exist_ok=True)

    enroot = require_tool("enroot")
    build_root = (
        absolute(str(arguments.enroot_build_root), "enroot build root")
        if arguments.enroot_build_root
        else work / ".enroot-build"
    )
    for name in ("data", "cache", "temp", "runtime"):
        (build_root / name).mkdir(parents=True, exist_ok=True)
    os.environ["ENROOT_DATA_PATH"] = str(build_root / "data")
    os.environ["ENROOT_CACHE_PATH"] = str(build_root / "cache")
    os.environ["ENROOT_TEMP_PATH"] = str(build_root / "temp")
    os.environ["ENROOT_RUNTIME_PATH"] = str(build_root / "runtime")

    base_sqsh = enroot_ops.import_base(base, tag, descriptor, build_root / "cache", arguments.target)
    container = f"chaparbuild-{arguments.base}-{arguments.target}-{os.getpid()}"
    enroot_ops.remove_container(enroot, container)
    run([enroot, "create", "--name", container, str(base_sqsh)], capture=True)
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
        written = enroot_ops.inject(
            build_root / "data", container, prefixes, module_tree, arch, base.module_destination, release.software_set
        )
        # Taken before verification so the diff attributes changes to injection
        # alone; `enroot start --root --rw` below writes to the rootfs itself.
        counts = assert_base_undisturbed(before, snapshot_rootfs(rootfs), written, rootfs)
        print(
            f"==> base image undisturbed: {counts['added']} paths added, "
            f"0 removed, 0 modified, {counts['inspected']} inspected"
        )
        enroot_ops.verify(enroot, container, arch, target_facts.spack_target, arguments.base, base.module_destination, store)
        enroot_ops.export(enroot, container, work, artifact_name)
    finally:
        if not arguments.keep_container:
            enroot_ops.remove_container(enroot, container)
    return 0
