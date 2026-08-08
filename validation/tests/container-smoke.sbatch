#!/usr/bin/env bash
# DESCRIPTION: Pyxis container smoke - injected release loads and keeps the base image intact
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --job-name=container-smoke

# Runs the selected release from inside its sealed .sqsh under Pyxis. This is the
# only validation test that exercises a container, and it is the source of the
# pyxis-smoke.txt artifact that ci/vlad_source_approval/image_receipts.py digests
# into the runtime receipt.
#
# Custody: the image path must lie inside the selection's own container_outputs
# root and match a digest supplied alongside it. An ambient path is refused, the
# same way every other consumer refuses ambient authority.
#
# Exit 77 means SKIP: this node advertises no Pyxis/Enroot, so there is nothing to
# validate here. Never a pass.

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(cd "${validation_dir}/.." && pwd)"
if [ -n "${ENV_NAME:-}" ] || [ -n "${MODULE_PATH:-}" ]; then
    echo "ERROR: ENV_NAME and MODULE_PATH are obsolete selection overrides" >&2
    exit 2
fi
selection="${CHAPAR_SELECTION:?CHAPAR_SELECTION is required}"
selection_digest="${CHAPAR_SELECTION_DIGEST:?CHAPAR_SELECTION_DIGEST is required}"
contract="${CHAPAR_TARGET_CONTRACT:?CHAPAR_TARGET_CONTRACT is required}"
# A sealed image is an input this test cannot derive, and no image exists until an
# operator has produced and sealed one. Absent, there is nothing to validate, so
# this is a SKIP -- the same treatment a node that advertises no Pyxis gets.
if [ -z "${CHAPAR_CONTAINER_IMAGE:-}" ] || [ -z "${CHAPAR_CONTAINER_IMAGE_SHA256:-}" ]; then
    echo "SKIP: CHAPAR_CONTAINER_IMAGE and CHAPAR_CONTAINER_IMAGE_SHA256 are unset" >&2
    exit 77
fi
image="${CHAPAR_CONTAINER_IMAGE}"
image_sha256="${CHAPAR_CONTAINER_IMAGE_SHA256}"

identity="$(python3 "$validation_dir/selection.py" shell --selection "$selection" --selection-digest "$selection_digest" --contract "$contract" --test container-smoke)"
IFS=$'\t' read -r datacenter software_set target _module_path result_namespace _partition _constraint _account _qos <<< "$identity"
run_id="${SLURM_JOB_ID:-unknown-run}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-$result_namespace}/container-smoke/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"
SUMMARY="${RESULTS_DIR}/summary.json"
SMOKE="${RESULTS_DIR}/pyxis-smoke.txt"

# The in-image module destination is a container-registry fact, and the outputs
# root is a selection fact. Neither is re-derived from the environment.
read -r container_outputs module_destination <<< "$(python3 - "$selection" "$repository_root/containers/images/containers.json" <<'PY'
import json
import sys

selection = json.load(open(sys.argv[1]))
registry = json.load(open(sys.argv[2]))["containers"]
selected = selection["containers"]
if len(selected) != 1:
    raise SystemExit("selection must name exactly one container for a container smoke test")
print(selection["paths"]["container_outputs"], registry[selected[0]]["module_destination"])
PY
)"

case "$image" in
    "${container_outputs}"/*) ;;
    *)
        echo "ERROR: container image is outside the selected container_outputs root" >&2
        exit 2
        ;;
esac
if [ -L "$image" ] || [ ! -f "$image" ]; then
    echo "ERROR: container image must be a regular file, not a symlink: $image" >&2
    exit 2
fi
observed="$(sha256sum "$image" | awk '{print $1}')"
if [ "$observed" != "$image_sha256" ]; then
    echo "ERROR: container image digest mismatch" >&2
    exit 2
fi

if ! command -v enroot >/dev/null 2>&1; then
    echo "SKIP: node advertises no enroot runtime" >&2
    exit 77
fi
if ! srun --help 2>&1 | grep -q -- '--container-image'; then
    echo "SKIP: node advertises no Pyxis SPANK plugin" >&2
    exit 77
fi

echo "=== $datacenter/$software_set/$target container smoke ===" >&2
echo "image: $image" >&2
echo "sha256: $observed" >&2

# Root module checks come from the selection, so this asserts the same inventory
# the bare-metal integrity test asserts -- just resolved inside the container.
checks_file="${RESULTS_DIR}/root-checks.tsv"
python3 "$validation_dir/selection.py" checks \
    --selection "$selection" --selection-digest "$selection_digest" \
    --contract "$contract" --test container-smoke >"$checks_file"

in_container="$(cat <<INNER
set -u
status=0
note() { printf '%s\n' "\$1"; }

# --- the base image must be intact and must still win by default -------------
note "== base image =="
for tool in python3 mpirun nvcc cmake; do
    resolved="\$(command -v "\$tool" 2>/dev/null || true)"
    case "\$resolved" in
        "") note "absent: \$tool" ;;
        ${module_destination}/*)
            note "SHADOWED: \$tool -> \$resolved"
            status=1 ;;
        *) note "base: \$tool -> \$resolved" ;;
    esac
done

# --- opt-in activation --------------------------------------------------------
note "== activation =="
if ! command -v module >/dev/null 2>&1; then
    note "FAIL: no module command in the image"
    exit 1
fi
module use "${module_destination}"/* 2>/dev/null || true
note "modulepath: \${MODULEPATH:-unset}"

while IFS=\$'\t' read -r module_name check_cmd check_desc; do
    [ -n "\$module_name" ] || continue
    printf '  %s (%s) ... ' "\$module_name" "\$check_desc"
    if module load "\$module_name" 2>/dev/null && eval "\$check_cmd" >/dev/null 2>&1; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        status=1
    fi
done <"$checks_file"

# --- accelerated transports, from inside the container ------------------------
# Mirrors validation/tests/transport.sbatch. The kernel-coupled halves come from
# the host (/dev/infiniband, /dev/gdrdrv, the NVIDIA driver); the userspace halves
# must come from the injected release, so this is where the split is proven.
note "== transports =="
if command -v ucx_info >/dev/null 2>&1; then
    transports="\$(ucx_info -d 2>/dev/null || true)"
    for expected in _mlx5 cuda_ipc gdr_copy; do
        if printf '%s' "\$transports" | grep -q -- "\$expected"; then
            note "ucx: \$expected present"
        else
            note "FAIL ucx: \$expected absent"
            status=1
        fi
    done
else
    note "FAIL: ucx_info unavailable after module load"
    status=1
fi
if command -v fi_info >/dev/null 2>&1; then
    providers="\$(fi_info 2>/dev/null || true)"
    for expected in verbs shm; do
        if printf '%s' "\$providers" | grep -q -- "\$expected"; then
            note "libfabric: \$expected present"
        else
            note "FAIL libfabric: \$expected absent"
            status=1
        fi
    done
else
    note "FAIL: fi_info unavailable after module load"
    status=1
fi
exit "\$status"
INNER
)"

rc=0
srun --container-image="$image" \
     --container-readonly \
     --no-container-mount-home \
     --export=ALL,PYTHONNOUSERSITE=1 \
     bash -c "$in_container" >"$SMOKE" 2>&1 || rc=$?
cat "$SMOKE" >&2

verdict=pass
[ "$rc" -eq 0 ] || verdict=fail
python3 - "$SUMMARY" "$datacenter" "$software_set" "$target" "$image" "$observed" "$verdict" "$rc" <<'PY'
import json
import sys

path, datacenter, software_set, target, image, digest, verdict, rc = sys.argv[1:]
json.dump(
    {
        "test": "container-smoke",
        "datacenter": datacenter,
        "software_set": software_set,
        "target": target,
        "image_path": image,
        "image_sha256": digest,
        "verdict": verdict,
        "exit_code": int(rc),
    },
    open(path, "w"),
    indent=2,
    sort_keys=True,
)
PY
cat "$SUMMARY"
echo "=== $datacenter/$software_set/$target container smoke: $verdict ===" >&2
exit "$rc"
