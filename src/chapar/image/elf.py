"""Raw-ELF audit of an injection closure.

Parsed here rather than shelled out to readelf/objdump on purpose: the image
preflight's BUILD_TOOLS is a pinned, verified toolchain list, and binutils is
not in it. 64-bit little-endian only, which is every registered target
(x86_64, aarch64); anything else is skipped rather than guessed at.
Stdlib only.
"""

from __future__ import annotations

import re
import struct
from pathlib import Path
from typing import Final, NamedTuple

from chapar.common.jsonio import fail

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
HOST_PROVIDED_SONAMES: Final = frozenset(
    {
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
    }
)
HOST_PROVIDED_PREFIXES: Final = ("libnvidia-",)


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
    (e_shoff,) = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    if not e_shoff or not e_shnum:
        return None
    dynamic: tuple[int, int, int] | None = None
    sections: list[tuple[int, int, int, int]] = []
    for index in range(e_shnum):
        base = e_shoff + index * e_shentsize
        if base + 64 > len(data):
            return None
        (sh_type,) = struct.unpack_from("<I", data, base + 0x04)
        sh_offset, sh_size = struct.unpack_from("<QQ", data, base + 0x18)
        (sh_link,) = struct.unpack_from("<I", data, base + 0x28)
        sections.append((sh_type, sh_offset, sh_size, sh_link))
        if sh_type == SHT_DYNAMIC:
            dynamic = (sh_offset, sh_size, sh_link)
    if dynamic is None:
        return None
    dyn_offset, dyn_size, dyn_link = dynamic
    if dyn_link >= len(sections):
        return None
    _, str_offset, str_size, _ = sections[dyn_link]
    strings = data[str_offset : str_offset + str_size]

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
