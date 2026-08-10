"""The image pipeline and its common helpers must stay stdlib-only.

A bare builder runs `python3 -m chapar image ...` with the system interpreter
and no virtualenv, so nothing under chapar.image or chapar.common may import
PyYAML, pydantic, or any other third-party package -- even lazily.
"""

from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path

from tests.conftest import REPO_ROOT

PACKAGES = ("chapar/image", "chapar/common")
FORBIDDEN = {"yaml", "pydantic", "requests"}


def _imported_roots(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    roots: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            roots.add(node.module.split(".")[0])
    return roots


def test_no_third_party_imports_anywhere() -> None:
    """Static: no module in the stdlib-only packages names a third-party import,
    not even inside a function (the system python3 has no wheels at all)."""
    offenders: list[str] = []
    for package in PACKAGES:
        for module in sorted((REPO_ROOT / "src" / package).glob("*.py")):
            for name in _imported_roots(module):
                if name in FORBIDDEN or (name not in sys.stdlib_module_names and name != "chapar"):
                    offenders.append(f"{module.relative_to(REPO_ROOT)}: {name}")
    assert offenders == []


def test_importable_with_yaml_poisoned() -> None:
    """Dynamic: every chapar.image/chapar.common module imports and the image
    CLI registers with PyYAML made unimportable, proving no hidden dependency."""
    program = (
        "import sys\n"
        "sys.modules['yaml'] = None\n"
        "sys.modules['pydantic'] = None\n"
        "sys.path.insert(0, 'src')\n"
        "import importlib, pkgutil, argparse\n"
        "import chapar.image, chapar.common\n"
        "for package in (chapar.image, chapar.common):\n"
        "    for module in pkgutil.iter_modules(package.__path__):\n"
        "        importlib.import_module(f'{package.__name__}.{module.name}')\n"
        "from chapar.image.cli import register\n"
        "parser = argparse.ArgumentParser()\n"
        "register(parser.add_subparsers())\n"
        "print('stdlib-only ok')\n"
    )
    completed = subprocess.run(
        ["/usr/bin/python3", "-c", program],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
        cwd=REPO_ROOT,
        env={"PATH": "/usr/bin:/bin"},
    )
    assert completed.returncode == 0, completed.stderr
    assert "stdlib-only ok" in completed.stdout
