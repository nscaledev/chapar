"""Shared fixture builders for the image-pipeline tests."""

from __future__ import annotations

import hashlib
import json
import shutil
import struct
from pathlib import Path

from tests.conftest import REPO_ROOT, make_release_dir

REGISTRY_DIR = REPO_ROOT / "containers/images"

#: (oci_platform, descriptor, config) per target. Targets map many-to-one onto
#: the base's OCI platforms, so targets sharing a platform share one chain.
_PLATFORMS = {
    "linux-x86_64-generic": ("linux/amd64", "sha256:" + "1" * 64, "sha256:" + "3" * 64),
    "linux-x86_64-v4": ("linux/amd64", "sha256:" + "1" * 64, "sha256:" + "3" * 64),
    "linux-aarch64-generic": ("linux/arm64", "sha256:" + "2" * 64, "sha256:" + "4" * 64),
    "linux-aarch64-gb300": ("linux/arm64", "sha256:" + "2" * 64, "sha256:" + "4" * 64),
}


def _platform_entry(target: str) -> dict[str, str]:
    oci_platform, descriptor, config = _PLATFORMS[target]
    return {"oci_platform": oci_platform, "descriptor_digest": descriptor, "config_digest": config}


def make_registry_dir(parent: Path, *, lock_status: str = "complete") -> Path:
    """A registry directory with the committed registries and a usable source lock.

    The committed sources-lock.json is honestly blocked, so plan/build tests get
    a synthetic lock whose OCI categories are resolved for every registered
    target.
    """
    registry = parent / "registry"
    registry.mkdir(parents=True, exist_ok=True)
    shutil.copy(REGISTRY_DIR / "targets.json", registry / "targets.json")
    shutil.copy(REGISTRY_DIR / "containers.json", registry / "containers.json")
    lock = {
        "status": lock_status,
        "unresolved": [],
        "verified": {
            "nvidia_hpc_benchmarks_oci": {
                "image": "nvcr.io/nvidia/hpc-benchmarks",
                "tag": "26.02",
                "platforms": {target: _platform_entry(target) for target in _PLATFORMS},
            },
            "ubuntu_base_oci": {
                "image": "ubuntu",
                "tag": "24.04",
                "platforms": {"linux-x86_64-generic": _platform_entry("linux-x86_64-generic")},
            },
        },
    }
    (registry / "sources-lock.json").write_text(json.dumps(lock, indent=2, sort_keys=True))
    return registry


def make_elf(destination: Path, mode: str = "plain") -> None:
    """Synthesize a genuine, minimal ELF64 dynamic object.

    The injection audit's own parser is exercised rather than trusted: it reads
    DT_NEEDED, DT_RPATH, DT_RUNPATH and GLIBC_2.N tokens straight out of the
    file, so a store fixture holding no ELF at all proves nothing.
    """
    needed = ["libc.so.6"]
    rpath = ["/opt/chapar/store/lib"]
    runpath: list[str] = []
    extra = ["GLIBC_2.38"]
    if mode == "stubs":
        rpath = ["/opt/chapar/store/cuda-13/targets/x86_64-linux/lib/stubs"]
    elif mode == "runpath":
        rpath, runpath = [], ["/opt/chapar/store/lib"]
    elif mode == "unresolved":
        needed = ["libc.so.6", "libmystery.so.7"]
    elif mode == "closure":
        needed = ["libc.so.6", "libbar.so.1"]
    elif mode == "driver":
        needed = ["libc.so.6", "libcuda.so.1", "libnvidia-ml.so.1"]
    elif mode == "newglibc":
        extra = ["GLIBC_2.41"]

    strings = b"\x00"
    offsets: dict[str, int] = {}
    for text in [*needed, *rpath, *runpath, *extra]:
        offsets[text] = len(strings)
        strings += text.encode() + b"\x00"

    entries = [(1, offsets[name]) for name in needed]
    entries += [(15, offsets[item]) for item in rpath]
    entries += [(29, offsets[item]) for item in runpath]
    entries.append((0, 0))
    dynamic = b"".join(struct.pack("<qQ", tag, value) for tag, value in entries)

    str_off = 64
    dyn_off = str_off + len(strings)
    sh_off = dyn_off + len(dynamic)
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # ELFDATA2LSB
    struct.pack_into("<Q", header, 0x28, sh_off)
    struct.pack_into("<HH", header, 0x3A, 64, 2)

    def section(sh_type: int, offset: int, size: int, link: int) -> bytes:
        raw = bytearray(64)
        struct.pack_into("<I", raw, 0x04, sh_type)
        struct.pack_into("<QQ", raw, 0x18, offset, size)
        struct.pack_into("<I", raw, 0x28, link)
        return bytes(raw)

    blob = bytes(header) + strings + dynamic
    blob += section(3, str_off, len(strings), 0)  # SHT_STRTAB at index 0
    blob += section(6, dyn_off, len(dynamic), 0)  # SHT_DYNAMIC, sh_link -> index 0
    destination.write_bytes(blob)


def _rewrite_lock(release_dir: Path) -> None:
    """Add the canonical dependency shape to the fixture lock and re-seal it.

    gcc-runtime is a real link dependency of every Spack-built root, and the
    injection audit requires it; a build-only dependency must be excluded from
    the closure.
    """
    lock_path = release_dir / "spack.lock"
    lock = json.loads(lock_path.read_text())
    lock["concrete_specs"]["aaaabbbb"]["dependencies"] = [
        {"hash": "ccccdddd", "type": ["link", "run"]},
        {"hash": "11112222", "type": ["link"]},
        {"hash": "eeeeffff", "type": ["build"]},
    ]
    lock["concrete_specs"]["ccccdddd"] = {"name": "runtime", "version": "1.0", "dependencies": []}
    lock["concrete_specs"]["11112222"] = {"name": "gcc-runtime", "version": "15.1.0", "dependencies": []}
    lock["concrete_specs"]["eeeeffff"] = {"name": "build", "version": "1.0", "dependencies": []}
    lock_bytes = json.dumps(lock, indent=2).encode()
    lock_path.write_bytes(lock_bytes)
    metadata_path = release_dir / "metadata.json"
    metadata = json.loads(metadata_path.read_text())
    metadata["digests"]["release_local_lock_sha256"] = hashlib.sha256(lock_bytes).hexdigest()
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


class ImageFixture:
    """A digest-consistent release with a populated store and module tree."""

    def __init__(self, env_root: Path, release_dir: Path, arch: str) -> None:
        self.env_root = env_root
        self.release_dir = release_dir
        self.arch = arch
        self.store_prefix_dir = env_root / "store" / "__spack_path_placeholder__" / f"linux-{arch.rsplit('-', 1)[-1]}"

    def prefix(self, name: str) -> Path:
        return self.store_prefix_dir / name

    def module_file(self) -> Path:
        return self.release_dir / "modulefiles" / self.arch / "root.lua"

    def add_elf(self, mode: str) -> None:
        library = self.prefix("root-1.0-aaaabbbb") / "lib"
        library.mkdir(parents=True, exist_ok=True)
        make_elf(library / "libroot.so", mode)


def make_image_release(
    parent: Path,
    *,
    software_set: str = "vlad",
    target: str = "linux-x86_64-v4",
    arch: str = "linux-ubuntu24.04-x86_64_v4",
    deliver: list[str] | None = None,
) -> ImageFixture:
    env_root = parent / "env"
    release_dir = make_release_dir(
        env_root,
        software_set=software_set,
        target=target,
        roots=[("root", "1.0", "aaaabbbb")],
        deliver=deliver if deliver is not None else ["modules", "container"],
    )
    _rewrite_lock(release_dir)
    # The conftest module tree has a fixed arch child and no files; replace it
    # with the requested architecture and one real modulefile.
    shutil.rmtree(release_dir / "modulefiles")
    module_dir = release_dir / "modulefiles" / arch
    module_dir.mkdir(parents=True)
    (module_dir / "root.lua").write_text("module fixture\n")
    fixture = ImageFixture(env_root, release_dir, arch)
    # Prefixes never sit directly in the store root in a real release: a padded
    # install tree nests them under a __spack_path_placeholder__ chain, and the
    # projection adds a {platform}-{target} directory below that, so
    # resolve_prefixes' descent and bounded search are exercised, not assumed.
    for name in ("root-1.0-aaaabbbb", "runtime-1.0-ccccdddd", "gcc-runtime-15.1.0-11112222", "build-1.0-eeeeffff"):
        fixture.prefix(name).mkdir(parents=True)
    return fixture
