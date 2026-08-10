"""Subprocess helpers shared by the image pipeline. Stdlib only."""

from __future__ import annotations

import shutil
import subprocess
from collections.abc import Sequence

from chapar.common.jsonio import fail


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        fail(f"required tool is not on PATH: {name}")
    return path


def run(command: Sequence[str], *, capture: bool = False, cwd: str | None = None) -> str:
    """Run a command, failing loudly with the command line on error."""
    try:
        completed = subprocess.run(
            list(command),
            check=True,
            cwd=cwd,
            text=True,
            capture_output=capture,
        )
    except FileNotFoundError as error:
        fail(f"required tool is not on PATH: {command[0]}: {error}")
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip() if capture else ""
        suffix = f": {detail}" if detail else ""
        fail(f"command failed with exit {error.returncode}: {' '.join(command)}{suffix}")
    return completed.stdout if capture else ""
