#!/usr/bin/env bash

# Offline hardware fixtures for validation suites.
#
# A hardware suite is useless in CI if it can only run on the hardware. Each suite
# therefore has exactly one branch: in fixture mode it loads observations from a
# JSON manifest instead of probing sysfs, nvidia-smi, ibv_devinfo or a mount, and
# the evaluator below that branch is identical either way. A fixture may also
# declare its own expected outcome under verdicts.<suite>, so a fixture asserts a
# result rather than merely exercising a path.
#
# The injection discipline is the one containers/images/preflight.sh already uses,
# not a second convention:
#
#   - fixtures apply only when VALIDATION_TEST_MODE=1;
#   - every override variable is named in an allowlist, and an unrecognised
#     VALIDATION_TEST_* name is fatal rather than ignored, so a typo cannot
#     silently leave a suite probing real hardware;
#   - a VALIDATION_TEST_* variable set outside test mode is also fatal, so fixture
#     plumbing can never reach a production run;
#   - the fixture root must be a real, owner-only, symlink-free directory owned by
#     the caller, and every fixture path must resolve inside it.

VALIDATION_FIXTURE_ALLOWED_VARIABLES="\
VALIDATION_TEST_MODE \
VALIDATION_TEST_ROOT \
VALIDATION_TEST_SIDE_EFFECT_MARKER \
VALIDATION_TEST_CONTAINER_SMOKE \
VALIDATION_TEST_CPU \
VALIDATION_TEST_GPU \
VALIDATION_TEST_NODE_ADMISSION \
VALIDATION_TEST_RDMA \
VALIDATION_TEST_ROCE \
VALIDATION_TEST_STORAGE"

validation_fixture_active() {
    [ "${VALIDATION_TEST_MODE:-}" = "1" ]
}

# Must be called by every suite that supports fixtures, before any probing.
validation_fixture_guard() {
    local names
    names="${VALIDATION_FIXTURE_ALLOWED_VARIABLES}"
    if ! python3 - "${names}" <<'PY'
import os
import sys

allowed = set(sys.argv[1].split())
present = sorted(name for name in os.environ if name.startswith("VALIDATION_TEST_"))
unknown = [name for name in present if name not in allowed]
if unknown:
    raise SystemExit("unknown validation fixture override: " + ",".join(unknown))
if os.environ.get("VALIDATION_TEST_MODE") != "1":
    leaked = [name for name in present if name != "VALIDATION_TEST_MODE"]
    if leaked:
        raise SystemExit(
            "validation fixture overrides require VALIDATION_TEST_MODE=1: "
            + ",".join(leaked)
        )
PY
    then
        return 2
    fi
    if validation_fixture_active; then
        validation_fixture_root >/dev/null || return 2
    fi
}

validation_fixture_root() {
    python3 - "${VALIDATION_TEST_ROOT:-}" <<'PY'
import os
import stat
import sys
from pathlib import Path

raw = sys.argv[1]
if not raw:
    raise SystemExit("fixture mode requires VALIDATION_TEST_ROOT")
if any(ord(character) < 32 for character in raw):
    raise SystemExit("VALIDATION_TEST_ROOT contains control characters")
root = Path(raw)
if not root.is_absolute() or root != Path(os.path.normpath(raw)) or ".." in root.parts:
    raise SystemExit("VALIDATION_TEST_ROOT must be a normalized absolute path")
try:
    status = root.lstat()
except OSError as error:
    raise SystemExit(f"cannot stat VALIDATION_TEST_ROOT: {error}") from error
if not stat.S_ISDIR(status.st_mode) or stat.S_ISLNK(status.st_mode):
    raise SystemExit("VALIDATION_TEST_ROOT must be a real directory")
if status.st_uid != os.geteuid() or stat.S_IMODE(status.st_mode) & 0o077:
    raise SystemExit("VALIDATION_TEST_ROOT must be owner-only and owned by the caller")
if stat.S_IMODE(status.st_mode) & 0o700 != 0o700:
    raise SystemExit("VALIDATION_TEST_ROOT must grant owner read/write/search access")
if root.resolve() != root:
    raise SystemExit("VALIDATION_TEST_ROOT cannot contain symlink components")
print(root)
PY
}

# Echoes the validated fixture directory named by an allowlisted variable, or
# nothing when fixture mode is inactive or that variable is unset. A suite treats a
# non-empty result as "use the manifest, probe nothing".
validation_fixture_dir() {
    local variable="$1"
    local value root
    validation_fixture_active || return 0
    value="$(printf '%s' "${!variable:-}")"
    [ -n "${value}" ] || return 0
    root="$(validation_fixture_root)" || return 2
    python3 - "${root}" "${value}" "${variable}" <<'PY'
import os
import sys
from pathlib import Path

root, raw, label = sys.argv[1], sys.argv[2], sys.argv[3]
root_path = Path(root)
candidate = Path(raw)
if not candidate.is_absolute():
    candidate = root_path / candidate
if candidate != Path(os.path.normpath(str(candidate))):
    raise SystemExit(f"{label} must be a normalized path")
resolved = candidate.resolve()
if resolved == root_path or root_path not in resolved.parents:
    raise SystemExit(f"{label} escapes the protected fixture root")
if not (resolved / "manifest.json").is_file():
    raise SystemExit(f"{label} has no manifest.json: {resolved}")
print(resolved)
PY
}

# Some suites select a synthesized fixture by name rather than by directory, which
# keeps a case that has no observable hardware analogue out of the tree.
validation_fixture_name() {
    local variable="$1"
    validation_fixture_active || return 0
    printf '%s' "${!variable:-}"
}
