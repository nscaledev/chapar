#!/usr/bin/env bash
# Root-owned atomic install of a per-machine site settings file to
# /etc/chapar/site.env. Consumers find it via CHAPAR_SITE_CONFIG; a checkout
# copy at etc/chapar-site.env works without this installer.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: sudo etc/install-site-settings.sh --source PATH [--destination PATH]

Validates the source with etc/chapar-defaults.sh, then installs it atomically
(root-owned, mode 0644) to the destination (default /etc/chapar/site.env).
Point CHAPAR_SITE_CONFIG at the destination in profiles or unit files.
USAGE
}

SOURCE=""
DESTINATION="/etc/chapar/site.env"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) [ "$#" -ge 2 ] || { echo "ERROR: --source requires a value" >&2; exit 2; }; SOURCE="$2"; shift 2 ;;
        --destination) [ "$#" -ge 2 ] || { echo "ERROR: --destination requires a value" >&2; exit 2; }; DESTINATION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "${SOURCE}" ] || { echo "ERROR: --source is required" >&2; exit 2; }
[ -r "${SOURCE}" ] || { echo "ERROR: source is not readable: ${SOURCE}" >&2; exit 2; }
case "${DESTINATION}" in
    /*) ;;
    *) echo "ERROR: destination must be an absolute path" >&2; exit 2 ;;
esac

ETC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The settings must validate before they can become machine state. Run in a
# clean environment so the caller's exports cannot mask a broken file.
env -i HOME="${HOME:-/root}" USER="${USER:-root}" PATH="${PATH}" \
    CHAPAR_SITE_CONFIG="${SOURCE}" bash -c ". '${ETC_DIR}/chapar-defaults.sh'" ||
    { echo "ERROR: source did not validate against etc/chapar-defaults.sh" >&2; exit 1; }

install -d -m 0755 "$(dirname "${DESTINATION}")"
TEMPORARY="$(mktemp "$(dirname "${DESTINATION}")/.site.env.XXXXXX")"
cp "${SOURCE}" "${TEMPORARY}"
chown root:root "${TEMPORARY}" 2>/dev/null || true
chmod 0644 "${TEMPORARY}"
mv -f "${TEMPORARY}" "${DESTINATION}"
echo "installed: ${DESTINATION}"
