#!/usr/bin/env bash
# Python quality is exactly what `make lint` enforces (ruff + basedpyright).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export PATH="${HOME}/.local/bin:${PATH}"

make -C "${ROOT}" lint
