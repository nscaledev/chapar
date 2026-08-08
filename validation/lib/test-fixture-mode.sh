#!/usr/bin/env bash
set -euo pipefail

# Offline test for the fixture injection gate. The gate exists so that fixture
# plumbing cannot reach a production run and a mistyped override cannot leave a
# suite quietly probing real hardware, so both of those are asserted here rather
# than assumed.

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validation/lib/fixture-mode.sh
source "${lib_dir}/fixture-mode.sh"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/chapar-fixture-mode.XXXXXX")"
temporary="$(cd "${temporary}" && pwd -P)"
chmod 700 "${temporary}"
cleanup() { rm -rf -- "${temporary}"; }
trap cleanup EXIT

root="${temporary}/root"
mkdir -p "${root}/case-a"
chmod 700 "${root}"
printf '{"verdicts": {"cpu-platform": "PASS"}}\n' > "${root}/case-a/manifest.json"
mkdir -p "${root}/case-empty"
mkdir -p "${temporary}/outside/case-b"
printf '{}\n' > "${temporary}/outside/case-b/manifest.json"

expect_ok() {
    local label="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        printf 'unexpectedly refused: %s\n' "${label}" >&2
        exit 1
    fi
}

expect_refused() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'unexpectedly accepted: %s\n' "${label}" >&2
        exit 1
    fi
}

# Production runs: no overrides present, nothing to validate.
expect_ok 'clean production environment' env -u VALIDATION_TEST_MODE bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

# A fixture override outside test mode is the dangerous case: it must be fatal,
# not ignored.
expect_refused 'fixture override without test mode' env -u VALIDATION_TEST_MODE VALIDATION_TEST_CPU="${root}/case-a" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

# A mistyped override name must not be silently discarded.
expect_refused 'unknown override name' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" VALIDATION_TEST_CPUU="${root}/case-a" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

expect_refused 'test mode without a root' env VALIDATION_TEST_MODE=1 -u VALIDATION_TEST_ROOT bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

# Group or world access to the fixture root would let another identity steer a
# validation outcome.
chmod 755 "${root}"
expect_refused 'group-readable fixture root' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"
chmod 700 "${root}"

ln -s "${root}" "${temporary}/root-link"
expect_refused 'symlinked fixture root' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${temporary}/root-link" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

expect_ok 'valid fixture root' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_guard
"

# A resolved fixture directory is echoed for the suite to load.
resolved="$(env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" VALIDATION_TEST_CPU="${root}/case-a" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_dir VALIDATION_TEST_CPU
")"
[ "${resolved}" = "${root}/case-a" ] || {
    printf 'resolved fixture directory was %s\n' "${resolved}" >&2
    exit 1
}

# Relative names resolve inside the root rather than the caller's directory.
resolved="$(env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" VALIDATION_TEST_CPU="case-a" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_dir VALIDATION_TEST_CPU
")"
[ "${resolved}" = "${root}/case-a" ] || {
    printf 'relative fixture directory resolved to %s\n' "${resolved}" >&2
    exit 1
}

expect_refused 'fixture directory outside the root' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" VALIDATION_TEST_CPU="${temporary}/outside/case-b" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_dir VALIDATION_TEST_CPU
"

expect_refused 'fixture directory without a manifest' env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" VALIDATION_TEST_CPU="${root}/case-empty" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_dir VALIDATION_TEST_CPU
"

# An unset override in test mode means "probe normally", not an error.
resolved="$(env VALIDATION_TEST_MODE=1 VALIDATION_TEST_ROOT="${root}" bash -c "
    source '${lib_dir}/fixture-mode.sh'
    validation_fixture_dir VALIDATION_TEST_CPU
")"
[ -z "${resolved}" ] || {
    printf 'unset override produced %s\n' "${resolved}" >&2
    exit 1
}

printf 'fixture mode: overrides are allowlisted, rooted, and inert outside test mode\n'
