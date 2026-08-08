# Chapar

Chapar describes software once, resolves it for a reviewed data-center target,
and passes the resulting immutable selection to release, cache, CI, image,
validation, and CVE consumers. The repository currently provides offline
contracts and plan surfaces only. It contains no active data-center contract
and no GitHub Actions workflow.

## Authorities

- `envs/software/spack.yaml` is the sole active root-spec and package-policy
  catalog. Its top-level `specs:` is empty; the resolver creates the effective
  manifest.
- `containers/images/targets.json` owns target facts.
- `containers/images/containers.json` owns the public container IDs
  `nvidia-vlad` and `ubuntu-hpcsim` and their accepted sets/targets.
- `datacenters/<id>/datacenter.json` and
  `datacenters/<id>/targets/<target>/contract.json` are reviewed desired-state
  snapshots generated from Cookiecutter input. Data-center contracts may
  allow or deny registry IDs but cannot redefine them.
- `containers/images/sources-lock.json` owns external-source custody. Its
  global status is `blocked`, so every real image build remains blocked even
  where one category is resolved.

`datacenters/example-lab` and the example context are disposable fixtures with
`status: example`; no tracked file contains active site values. Create an
active contract only through a separate review of real, non-secret site input.

## Canonical offline flow

The following is the only complete runnable operator sequence in the docs. It
uses disposable directories and performs no Spack build, Slurm submission,
module load, image import, publication, or live-path mutation.

```bash
set -euo pipefail
WORK_ROOT=""
cleanup() {
  if [ -n "${WORK_ROOT:-}" ] && [ -d "$WORK_ROOT" ]; then
    rm -rf -- "$WORK_ROOT"
  fi
}
trap cleanup EXIT

TEMP_ROOT="$(python3 -c 'import os, tempfile; print(os.path.realpath(tempfile.gettempdir()))')"
WORK_ROOT="$(mktemp -d "$TEMP_ROOT/chapar-offline.XXXXXX")"
sed "s#/tmp/chapar-example#$WORK_ROOT/site#g" \
  cookiecutter/chapar-datacenter/examples/example-context.yaml \
  > "$WORK_ROOT/context.yaml"
uv run tools/chapar_datacenter_template.py render \
  "$WORK_ROOT/context.yaml" \
  --output-root "$WORK_ROOT"
uv run tools/chapar_datacenter_template.py validate-tree \
  "$WORK_ROOT/datacenters/example-lab"

RESOLVED="$WORK_ROOT/resolved"
SELECTION_SHA256="$(uv run tools/chapar_resolve.py \
  --catalog "$PWD/envs/software/spack.yaml" \
  --targets "$PWD/containers/images/targets.json" \
  --containers "$PWD/containers/images/containers.json" \
  --datacenter "$WORK_ROOT/datacenters/example-lab/datacenter.json" \
  --contract "$WORK_ROOT/datacenters/example-lab/targets/linux-x86_64-generic/contract.json" \
  --datacenter-id example-lab \
  --software-set hpcsim \
  --target linux-x86_64-generic \
  --release-id offline-release \
  --run-id offline-run \
  --output-dir "$RESOLVED")"
printf '%s\n' "$SELECTION_SHA256" > "$RESOLVED/selection.sha256"

bash envs/software/release.sh plan \
  --selection "$RESOLVED/selection.json" \
  --selection-digest "$SELECTION_SHA256"
python3 ci/selection-plan.py \
  --selection "$RESOLVED/selection.json" \
  --selection-digest "$SELECTION_SHA256" \
  --contract "$WORK_ROOT/datacenters/example-lab/targets/linux-x86_64-generic/contract.json" \
  --datacenter example-lab --software-set hpcsim \
  --target linux-x86_64-generic \
  --release-id offline-release --run-id offline-run
CHAPAR_DRY_RUN=1 ./validation/run \
  --selection "$RESOLVED/selection.json" \
  --selection-digest "$SELECTION_SHA256" \
  --contract "$WORK_ROOT/datacenters/example-lab/targets/linux-x86_64-generic/contract.json" \
  integrity-test
python3 ci/cve-checker.py --plan \
  --selection "$RESOLVED/selection.json" \
  --selection-digest-file "$RESOLVED/selection.sha256"
```

The resolver writes `selection.json`, `spack.yaml`, and `target-policy.yaml`
and prints the selection digest; the operator records that exact value as
`selection.sha256` beside them. The policy tuple is
`datacenter/software-set/target`; `release-id` and `run-id` are invocation
identity. Consumers recompute the selection digest and reject ambient path,
profile, environment, partition, or publication overrides.

The CI submission dry run requires the generated contract to be installed at
`datacenters/<id>/targets/<target>/contract.json`. The disposable renderer
deliberately writes elsewhere, so the sequence above exercises its underlying
planner without installing a fake active contract.

## Path taxonomy

Every target contract declares these classes explicitly:

- durable writable: install tree, releases, modulefiles, writable buildcache,
  ccache, container outputs, receipts, and evidence;
- ordered read-only inputs: software catalog, target registry, container
  registry, source lock, and optional seed mirror;
- temporary: release staging, Spack build stage, image staging, validation
  work, and resolver work.

The resolver namespaces mutable outputs by data center, software set, target,
release ID, and/or run ID as appropriate. Sharing is forbidden unless both
contracts opt into the exact path class. Seed mirrors are always read-only.

`/resources/chapar/vlad` and `/resources/chapar/hpcsim` are immutable legacy
shadow/canary roots. The resolver rejects overlap with `/resources/chapar`.
This work grants no migration, retirement, deletion, promotion, or mutation
approval for either root.

## Historical inventory

The canonical exact historical inventory is
`envs/software/tests/fixtures/historical-root-inventory.json`. Generate the
full exact spec delta with `envs/software/tests/inventory.py`; the block below
is machine-checked against that source.

<!-- software-inventory:begin -->
```json
{
  "counts": {
    "hpcsim": 75,
    "hpcsim_only": 48,
    "shared": 27,
    "variant_difference_packages": 10,
    "vlad": 42,
    "vlad_only": 15
  },
  "package_name_differences": {
    "hpcsim_only": [
      "adios2", "cdo", "cgns", "eccodes", "exodusii", "ffmpeg", "fftw",
      "gdb", "hdf5", "hdf5-vol-async", "imagemagick",
      "intel-mpi-benchmarks", "intel-oneapi-mpi", "libffi", "libpressio",
      "nccmp", "nco", "ncview", "neovim", "netcdf-c", "netcdf-fortran",
      "netlib-scalapack", "npm", "nvshmem", "openblas", "parallel-netcdf",
      "pkgconf", "pulseaudio", "seacas", "silo", "sz", "tcl", "tk",
      "tmux", "valgrind", "zfp"
    ],
    "vlad_only": ["ccache", "extrae", "ipm", "mpip", "py-mpi4py", "py-py-spy"]
  },
  "variant_difference_packages": [
    "babelstream", "caliper", "hwloc", "nccl", "nccl-tests", "nvbandwidth",
    "nvtop", "openmpi", "python", "ucx"
  ]
}
```
<!-- software-inventory:end -->

Package-name differences do not hide variant differences: the exact report
records both. The current catalog preserves provenance classifications and
deterministically composes `vlad`, `hpcsim`, and union `all` selections.

## Deferred target-platform gates

Offline contract and selection behavior is verified; target-platform behavior
not validated. A human operator must separately approve and run, on matching
Ubuntu 24.04 builders/Slurm nodes:

- Spack concretization and versioned release build/promotion;
- shared-filesystem atomic-rename and ownership/group checks;
- buildcache publication or any legacy-cache migration;
- Slurm submission and integrity, GPU, RDMA, MPI, NCCL, or I/O validation;
- source-lock completion, Enroot import/export, `.sqsh` validation, and image
  publication for each registry-approved tuple;
- the container-injection checks that need a real rootfs: the pre/post rootfs
  inventory diff, the release-versus-base glibc comparison, the in-image
  unshadowing check, and `validation/tests/container-smoke.sbatch`. See
  `docs/container-injection.md` for the host-versus-image split those enforce.

No platform command above is claimed to have run. See the focused docs for
contracts and gates; they link here instead of duplicating this sequence.
