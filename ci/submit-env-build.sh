#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/submit-env-build.sh --set ID --target ID --release-id ID [--dry-run]

Identity selects what to build; everything else (paths, Slurm placement,
delivery and publication policy) comes from the site settings via
etc/chapar-defaults.sh. --set/--target override CHAPAR_SOFTWARE_SET and
CHAPAR_TARGET for this submission. Slurm placement comes from the site
policy function (CHAPAR_SLURM_PARTITION, _CONSTRAINT, _ACCOUNT, _QOS).
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="${CHAPAR_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
case "${CHAPAR_ROOT}" in
    /*) ;;
    *) echo "ERROR: CHAPAR_ROOT must be an absolute path" >&2; exit 2 ;;
esac
case "${CHAPAR_ROOT}" in
    *,*|*[[:space:]]*) echo "ERROR: CHAPAR_ROOT cannot contain commas or whitespace" >&2; exit 2 ;;
esac
export CHAPAR_ROOT

SOFTWARE_SET=""
TARGET=""
RELEASE_ID=""
DRY_RUN=false
declare -A SEEN=()

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 requires a value" >&2
        exit 2
    fi
}

set_once() {
    local option="$1"
    local value="$2"
    if [ -n "${SEEN[${option}]:-}" ]; then
        echo "ERROR: duplicate identity selector: ${option}" >&2
        exit 2
    fi
    SEEN["${option}"]=1
    printf -v "$3" '%s' "${value}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --set|--software-set) require_value "$@"; set_once --set "$2" SOFTWARE_SET; shift 2 ;;
        --target) require_value "$@"; set_once "$1" "$2" TARGET; shift 2 ;;
        --release-id) require_value "$@"; set_once "$1" "$2" RELEASE_ID; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --selection|--selection-digest|--datacenter|--run-id)
            echo "ERROR: $1 was retired; identity comes from the site settings (see etc/chapar-site.env.example)." >&2
            exit 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "${RELEASE_ID}" ] || { echo "ERROR: --release-id is required" >&2; exit 2; }

# Export overrides before the defaults run so the site policy function sees
# the final tuple, then resolve settings exactly as release.sh will.
[ -z "${SOFTWARE_SET}" ] || export CHAPAR_SOFTWARE_SET="${SOFTWARE_SET}"
[ -z "${TARGET}" ] || export CHAPAR_TARGET="${TARGET}"
# shellcheck source=../etc/chapar-defaults.sh
. "${CHAPAR_ROOT}/etc/chapar-defaults.sh" || exit 2
[ -n "${CHAPAR_TARGET}" ] || { echo "ERROR: --target is required (or set CHAPAR_TARGET in the site settings)" >&2; exit 2; }
[ -n "${CHAPAR_SLURM_PARTITION}" ] || { echo "ERROR: site settings declare no Slurm partition for ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}" >&2; exit 2; }

echo "tuple: ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}"
echo "release id: ${RELEASE_ID}"
echo "partition: ${CHAPAR_SLURM_PARTITION}"
echo "constraint: ${CHAPAR_SLURM_CONSTRAINT:-none}"
echo "account: ${CHAPAR_SLURM_ACCOUNT:-none}"
echo "qos: ${CHAPAR_SLURM_QOS:-none}"
echo "deliver: ${CHAPAR_DELIVER}"
echo "publication: buildcache=${PUBLISH_BUILDCACHE} modules=${PUBLISH_MODULES} promote=${PUBLISH_CURRENT}"
bash "${CHAPAR_ROOT}/envs/software/release.sh" plan "${RELEASE_ID}"

if "${DRY_RUN}"; then
    echo "dry-run: verified plan only; no sbatch submission or filesystem creation"
    exit 0
fi

WRAPPER="${CHAPAR_ROOT}/ci/sbatch-env-build.sh"
[ -x "${WRAPPER}" ] || { echo "ERROR: missing sbatch wrapper: ${WRAPPER}" >&2; exit 2; }
EXPORTS="NONE,CHAPAR_ROOT=${CHAPAR_ROOT},CHAPAR_SOFTWARE_SET=${CHAPAR_SOFTWARE_SET},CHAPAR_TARGET=${CHAPAR_TARGET},CHAPAR_RELEASE_ID=${RELEASE_ID}"
if [ -n "${CHAPAR_SITE_CONFIG:-}" ]; then
    EXPORTS="${EXPORTS},CHAPAR_SITE_CONFIG=${CHAPAR_SITE_CONFIG}"
fi
SBATCH_ARGS=(--chdir "${CHAPAR_ROOT}" --partition "${CHAPAR_SLURM_PARTITION}")
[ -z "${CHAPAR_SLURM_CONSTRAINT}" ] || SBATCH_ARGS+=(--constraint "${CHAPAR_SLURM_CONSTRAINT}")
[ -z "${CHAPAR_SLURM_ACCOUNT}" ] || SBATCH_ARGS+=(--account "${CHAPAR_SLURM_ACCOUNT}")
[ -z "${CHAPAR_SLURM_QOS}" ] || SBATCH_ARGS+=(--qos "${CHAPAR_SLURM_QOS}")
sbatch "${SBATCH_ARGS[@]}" --export "${EXPORTS}" "${WRAPPER}"
