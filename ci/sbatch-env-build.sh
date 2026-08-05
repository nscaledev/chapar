#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH -J chapar-env-build
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

: "${CHAPAR_ROOT:=$HOME/chapar}"
: "${ENV_NAME:=hpcsim}"
: "${ENV_PATH:=envs/${ENV_NAME}}"
: "${CHAPAR_ENV_ROOT:=}"
: "${OS_NAME:?set OS_NAME, for example rocky9 or rocky10}"
: "${CHAPAR_ENV_ACTION:=build}"
: "${CHAPAR_ENV_BUILD_MODE:=auto}"
: "${PUBLISH_CURRENT:=false}"
: "${PUBLISH_MODULES:=false}"
: "${PUBLISH_BUILDCACHE:=true}"
: "${CHAPAR_CONCRETIZE_TIMEOUT:=}"

detect_build_jobs() {
    local cpus="${SLURM_CPUS_ON_NODE:-}"

    if [ -z "${cpus}" ] && [ -n "${SLURM_JOB_CPUS_PER_NODE:-}" ]; then
        cpus="${SLURM_JOB_CPUS_PER_NODE%%,*}"
        cpus="${cpus%%(*}"
    fi
    if [ -z "${cpus}" ]; then
        cpus="${SLURM_CPUS_PER_TASK:-}"
    fi
    if [ -z "${cpus}" ] && command -v nproc >/dev/null 2>&1; then
        cpus="$(nproc)"
    fi
    case "${cpus}" in
        ''|*[!0-9]*|0) cpus=1 ;;
    esac

    printf '%s\n' "${cpus}"
}

build_jobs="$(detect_build_jobs)"
: "${SPACK_INSTALL_ARGS:=-j ${build_jobs}}"

case "${ENV_NAME}" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: ENV_NAME must match [A-Za-z0-9._-]+, got ${ENV_NAME}" >&2; exit 2 ;;
esac

case "${ENV_PATH}" in
    envs/*) ;;
    *) echo "ERROR: ENV_PATH must be under envs/: ${ENV_PATH}" >&2; exit 2 ;;
esac

case "${OS_NAME}" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: OS_NAME must match [A-Za-z0-9._-]+, got ${OS_NAME}" >&2; exit 2 ;;
esac

if [ -n "${CHAPAR_ENV_ROOT}" ]; then
    case "${CHAPAR_ENV_ROOT}" in
        /*) ;;
        *) echo "ERROR: CHAPAR_ENV_ROOT must be an absolute path: ${CHAPAR_ENV_ROOT}" >&2; exit 2 ;;
    esac
    if [ "${ENV_NAME}" = "hpcsim" ]; then
        export HPCSIM_ROOT="${CHAPAR_ENV_ROOT}"
    elif [ -z "${CHAPAR_HOME_ROOT:-}" ]; then
        export CHAPAR_HOME_ROOT="${CHAPAR_ENV_ROOT}/${OS_NAME}"
    fi
fi

case "${CHAPAR_ENV_ACTION}" in
    concretize|build) ;;
    *) echo "ERROR: CHAPAR_ENV_ACTION must be concretize or build, got ${CHAPAR_ENV_ACTION}" >&2; exit 2 ;;
esac

case "${CHAPAR_ENV_BUILD_MODE}" in
    auto|release|spack) ;;
    *) echo "ERROR: CHAPAR_ENV_BUILD_MODE must be auto, release, or spack, got ${CHAPAR_ENV_BUILD_MODE}" >&2; exit 2 ;;
esac

if [ "${CHAPAR_ENV_ACTION}" = build ] && [ "${CHAPAR_ENV_BUILD_MODE}" = spack ]; then
    echo "ERROR: direct Spack build mode is forbidden; use CHAPAR_ENV_BUILD_MODE=release" >&2
    exit 2
fi

case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_CURRENT must be true or false, got ${PUBLISH_CURRENT}" >&2; exit 2 ;;
esac

case "${PUBLISH_MODULES}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_MODULES must be true or false, got ${PUBLISH_MODULES}" >&2; exit 2 ;;
esac

case "${PUBLISH_BUILDCACHE}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_BUILDCACHE must be true or false, got ${PUBLISH_BUILDCACHE}" >&2; exit 2 ;;
esac

mkdir -p "${CHAPAR_ROOT}/slogs" "$HOME/chapar-diagnostics"
job_id="${SLURM_JOB_ID:-manual}"
release_date="$(date -u +%Y%m%d)"
: "${RELEASE_ID:=${ENV_NAME}-${OS_NAME}-${release_date}}"

diag_dir="$HOME/chapar-diagnostics/${SLURM_JOB_NAME:-chapar-env-build}_${job_id}_${ENV_NAME}_${OS_NAME}"
mkdir -p "$diag_dir"
exec > >(tee -a "$diag_dir/run.log") 2>&1

if [ -d /scratch ] && [ -w /scratch ]; then
    fast_base="${CHAPAR_FAST_BASE:-/scratch/$USER/chapar-spack}"
else
    fast_base="${CHAPAR_FAST_BASE:-${TMPDIR:-/tmp}/$USER/chapar-spack}"
fi

fast_root="${fast_base}/${job_id}-${ENV_NAME}-${OS_NAME}"
export TMPDIR="${fast_root}/tmp"
export SPACK_USER_CACHE_PATH="${fast_root}/spack-user-cache"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-${fast_root}/ccache-tmp}"
export PIP_CONFIG_FILE=/dev/null
mkdir -p "$TMPDIR" "$SPACK_USER_CACHE_PATH" "$CCACHE_TEMPDIR"

cleanup() {
    status=$?
    echo
    echo "diagnostic dir: $diag_dir"
    echo "fast root: $fast_root"
    echo "chapar root: $CHAPAR_ROOT"
    echo "env name: $ENV_NAME"
    echo "env path: $ENV_PATH"
    echo "os name: $OS_NAME"
    echo "release id: $RELEASE_ID"
    exit "$status"
}
trap cleanup EXIT

cd "$CHAPAR_ROOT"
[ -r "${ENV_PATH}/spack.yaml" ] || { echo "ERROR: missing environment: ${ENV_PATH}/spack.yaml" >&2; exit 2; }
source "${CHAPAR_ROOT}/etc/init.sh"

echo "started: $(date -Is)"
echo "batch host: $(hostname -f 2>/dev/null || hostname)"
echo "job id: $job_id"
echo "diagnostic dir: $diag_dir"
echo "fast root: $fast_root"
echo "chapar root: $CHAPAR_ROOT"
echo "env name: $ENV_NAME"
echo "env path: $ENV_PATH"
echo "env root: ${CHAPAR_ENV_ROOT:-unset}"
echo "action: $CHAPAR_ENV_ACTION"
echo "mode: $CHAPAR_ENV_BUILD_MODE"
echo "git head: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "os name: $OS_NAME"
echo "release id: $RELEASE_ID"
echo "publish buildcache: $PUBLISH_BUILDCACHE"
echo "publish current: $PUBLISH_CURRENT"
echo "publish modules: $PUBLISH_MODULES"
echo "build jobs: $build_jobs"
echo "spack install args: $SPACK_INSTALL_ARGS"
echo "spack user cache: $SPACK_USER_CACHE_PATH"
echo "ccache dir: ${CCACHE_DIR:-unset}"
echo "ccache temp: ${CCACHE_TEMPDIR:-unset}"
echo

build_mode="$CHAPAR_ENV_BUILD_MODE"
if [ "$build_mode" = auto ]; then
    if [ "$CHAPAR_ENV_ACTION" = build ]; then
        build_mode=release
    else
        build_mode=spack
    fi
fi

case "$build_mode" in
    release)
        [ "$CHAPAR_ENV_ACTION" = build ] || { echo "ERROR: release mode only supports CHAPAR_ENV_ACTION=build" >&2; exit 2; }
        [ -x "${ENV_PATH}/release.sh" ] || { echo "ERROR: missing release helper: ${ENV_PATH}/release.sh" >&2; exit 2; }
        echo "==> Release status before build"
        OS_NAME="$OS_NAME" bash "${ENV_PATH}/release.sh" status
        echo
        echo "==> Building ${ENV_NAME} release for ${OS_NAME}"
        OS_NAME="$OS_NAME" \
        PUBLISH_BUILDCACHE="$PUBLISH_BUILDCACHE" \
        CHAPAR_CONCRETIZE_TIMEOUT="$CHAPAR_CONCRETIZE_TIMEOUT" \
        SPACK_INSTALL_ARGS="$SPACK_INSTALL_ARGS" \
        bash "${ENV_PATH}/release.sh" build "$RELEASE_ID"
        if [ "$PUBLISH_CURRENT" = true ]; then
            echo
            echo "==> Promoting ${OS_NAME} ${ENV_NAME} release"
            OS_NAME="$OS_NAME" bash "${ENV_PATH}/release.sh" promote "$RELEASE_ID"
        elif [ "$PUBLISH_MODULES" = true ]; then
            echo
            echo "==> Publishing ${OS_NAME} ${ENV_NAME} modules"
            OS_NAME="$OS_NAME" bash "${ENV_PATH}/release.sh" publish-modules "$RELEASE_ID"
        fi
        echo
        echo "==> Module use command for this release"
        OS_NAME="$OS_NAME" bash "${ENV_PATH}/release.sh" module-use "$RELEASE_ID"
        ;;
    spack)
        [ "$CHAPAR_ENV_ACTION" = concretize ] || { echo "ERROR: Spack mode only supports CHAPAR_ENV_ACTION=concretize" >&2; exit 2; }
        echo "==> Concretizing ${ENV_PATH}"
        spack -e "$ENV_PATH" concretize -f
        ;;
esac

echo
echo "completed: $(date -Is)"
