"""Additive-injection proofs over a container rootfs. Stdlib only.

The base image exists to provide its own payload, so injection's effect on it
is proven, not assumed: the rootfs is inventoried before and after, and any
removal, modification, or undeclared addition is fatal.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path, PurePosixPath
from typing import Final, NamedTuple

from chapar.common.jsonio import fail

# Environment variables an injected modulefile must never set. Spack's Linux
# prefix_inspections are LD_LIBRARY_PATH-free by design precisely because
# packages embed RPATHs; a module that sets one of these reaches every process in
# the container, including the base image's own binaries.
FORBIDDEN_MODULE_VARIABLES: Final = ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME")


class Entry(NamedTuple):
    kind: str
    mode: int
    size: int
    mtime_ns: int
    link: str


def rootfs_path(data_path: Path, container: str, absolute_target: Path) -> Path:
    return data_path / container / str(absolute_target).lstrip("/")


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
        fail(f"injection removed {len(removed)} path(s) from the base image (first: {removed[0]})")
    changed = [
        name for name, entry in after.items() if name in before and before[name].kind != "dir" and before[name] != entry
    ]
    if changed:
        fail(f"injection modified {len(changed)} existing base-image path(s) (first: {changed[0]})")
    remoded = [
        name
        for name, entry in after.items()
        if name in before and before[name].kind == "dir" and before[name].mode != entry.mode
    ]
    if remoded:
        fail(f"injection changed the mode of {len(remoded)} existing base-image director(ies) (first: {remoded[0]})")
    undeclared = sorted(name for name in set(after) - set(before) if not declared(name))
    if undeclared:
        fail(f"injection added {len(undeclared)} path(s) outside its declared destinations (first: {undeclared[0]})")
    return {"added": len(set(after) - set(before)), "inspected": len(after)}
