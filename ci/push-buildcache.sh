#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/push-buildcache.sh --release-dir PATH [--plan|--execute]
       ci/push-buildcache.sh --release-dir PATH --plan-migration SOURCE

--plan is the default and performs no filesystem or cache command.
--execute pushes the release's installed roots to the site writable buildcache
(${CHAPAR_BUILDCACHE_ROOT}/<target>) and requires PUBLISH_BUILDCACHE=true in
the site settings. A release directory is a complete Spack environment
(spack.yaml + spack.lock), so the push runs against it directly.
Migration is intentionally plan-only: future execution must remain copy-only,
non-overwriting, and non-deleting and requires separate operator approval.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR=""
MODE="plan"
MIGRATION_SOURCE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release-dir) [ "$#" -ge 2 ] || { echo "ERROR: --release-dir requires a value" >&2; exit 2; }; RELEASE_DIR="$2"; shift 2 ;;
        --plan) MODE="plan"; shift ;;
        --execute) MODE="execute"; shift ;;
        --plan-migration) [ "$#" -ge 2 ] || { echo "ERROR: --plan-migration requires a value" >&2; exit 2; }; MODE="migration-plan"; MIGRATION_SOURCE="$2"; shift 2 ;;
        --selection|--selection-sha256|--contract)
            echo "ERROR: $1 was retired; bind to a release directory (see etc/chapar-site.env.example)" >&2; exit 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "${RELEASE_DIR}" ] || { echo "ERROR: --release-dir is required" >&2; exit 2; }

# Verify the release and read its identity; refuses tampered bytes and the
# mutable `current` pointer.
IDENTITY="$(PYTHONPATH="${REPO_ROOT}/src" python3 -c '
import sys
from pathlib import Path
from chapar.common.release import verify_release
release = verify_release(Path(sys.argv[1]))
print(f"{release.software_set}\t{release.target}\t{release.release_id}")
' "${RELEASE_DIR}")" || exit 2
IFS=$'\t' read -r SOFTWARE_SET TARGET RELEASE_ID <<<"${IDENTITY}"

export CHAPAR_SOFTWARE_SET="${SOFTWARE_SET}" CHAPAR_TARGET="${TARGET}"
# shellcheck source=../etc/chapar-defaults.sh
. "${REPO_ROOT}/etc/chapar-defaults.sh" || exit 2
DESTINATION="${CHAPAR_BUILDCACHE_ROOT}/${TARGET}"

echo "release: ${RELEASE_DIR}"
echo "tuple: ${SOFTWARE_SET}/${TARGET}/${RELEASE_ID}"
echo "destination: ${DESTINATION}"
echo "publish_buildcache: ${PUBLISH_BUILDCACHE}"

case "${MODE}" in
    plan)
        echo "plan: spack -e ${RELEASE_DIR} buildcache push --unsigned --update-index --allow-missing file://${DESTINATION}"
        echo "plan only: no filesystem or cache command was run"
        ;;
    execute)
        [ "${PUBLISH_BUILDCACHE}" = true ] || { echo "ERROR: site settings forbid buildcache publication (PUBLISH_BUILDCACHE)" >&2; exit 1; }
        command -v spack >/dev/null 2>&1 || { echo "ERROR: required command 'spack' not found" >&2; exit 1; }
        mkdir -p "${DESTINATION}"
        spack -e "${RELEASE_DIR}" buildcache push --unsigned --update-index --allow-missing "file://${DESTINATION}"
        ;;
    migration-plan)
        [ -d "${MIGRATION_SOURCE}" ] || { echo "ERROR: migration source is not a directory" >&2; exit 1; }
        RESOLVED="$(realpath -e -- "${MIGRATION_SOURCE}")" || { echo "ERROR: migration source cannot be resolved" >&2; exit 1; }
        case "${RESOLVED}" in /resources/chapar|/resources/chapar/*) echo "ERROR: migration source overlaps protected legacy path" >&2; exit 1 ;; esac
        echo "migration plan: cp -nR ${RESOLVED}/. ${DESTINATION}/"
        echo "plan only: migration execution requires separate operator approval (use release.sh migrate-buildcache)"
        ;;
esac
