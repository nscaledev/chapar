#!/usr/bin/env bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH -J chapar-software-build
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

for required in CHAPAR_ROOT CHAPAR_SOFTWARE_SET CHAPAR_TARGET CHAPAR_RELEASE_ID; do
    [ -n "${!required:-}" ] || { echo "ERROR: ${required} is required from the explicit submission export" >&2; exit 2; }
done
case "${CHAPAR_ROOT}" in
    /*) ;;
    *) echo "ERROR: CHAPAR_ROOT must be an absolute path" >&2; exit 2 ;;
esac
case "${CHAPAR_ROOT}" in
    *,*|*[[:space:]]*) echo "ERROR: CHAPAR_ROOT cannot contain commas or whitespace" >&2; exit 2 ;;
esac

RELEASE_HELPER="${CHAPAR_ROOT}/envs/software/release.sh"
[ -x "${RELEASE_HELPER}" ] || { echo "ERROR: missing tuple-bound release helper: ${RELEASE_HELPER}" >&2; exit 2; }
echo "tuple: ${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}"
echo "release id: ${CHAPAR_RELEASE_ID}"
# release.sh re-resolves the site settings on the compute node itself, so the
# site file must be readable here; the exported identity pins the tuple.
exec bash "${RELEASE_HELPER}" build "${CHAPAR_RELEASE_ID}"
