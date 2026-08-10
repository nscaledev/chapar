# Validating a release

How to run the validation suites against one immutable release and read the
results. Reference material (per-suite details, result contract) is in
`validation/README.md` and `validation/ARCHITECTURE.md`.

## The dispatcher

`validation/run` binds every suite to one release directory:

```bash
./validation/run list                                    # available suites
./validation/run --release-dir <release> node-smoke      # one suite
./validation/run --release-dir <release> all             # every suite
CHAPAR_DRY_RUN=1 ./validation/run --release-dir <release> all   # plans only
```

Without `--release-dir` it uses the promoted release,
`${CHAPAR_RELEASE_ROOT}/${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}/current`
(site settings via `etc/chapar-defaults.sh`), and resolves that pointer to
the concrete immutable release before anything is planned or submitted — a
job never chases a moving `current`.

Outside a Slurm allocation, suites are submitted with `sbatch --wait` using
the site placement (`CHAPAR_SLURM_PARTITION`, `_CONSTRAINT`, `_ACCOUNT`,
`_QOS`); inside one they run inline. Exit codes: `0` pass, `77` skip
(requirements not met — reported, not a failure), anything else fail.

The `--export` list a job receives is closed: the release directory, its
results root, `CHAPAR_VALIDATION_ROOT`, the container facts and sealed-image
variables when set (for `container-smoke`), and — only in fixture mode — the
allowlisted `VALIDATION_TEST_*` variables. Nothing else in your environment
reaches a job.

## Planning and analysis

`chapar validate plan` is what the dispatcher calls; run it directly to see
exactly what one suite would do. It verifies the release (digests, identity,
target facts), derives the module tree and expected root inventory from the
release itself, and renders the plan:

```bash
uv run chapar validate plan --release-dir <release> --test node-smoke
uv run chapar validate plan --release-dir <release> --format checks   # per-root module checks
```

`--format` selects `plan` (JSON), `shell` (tab-separated identity/paths), or
`checks`; `--run-id` and `--results-root` override the derived results
placement, and `--seal-dir` writes read-only copies of `metadata.json` and
`spack.lock` as submission evidence.

Analyze a suite's results with MAD-based outlier detection:

```bash
uv run chapar validate analyze --suite node-smoke --results-dir <results> [--threshold 2.0] [--prometheus]
```

Supported suites: `node-smoke`, `ib-pairwise`, `mpi-collective`,
`hpc-challenge`, `io`, `profiling`, `gpu-stress`, `transport`, `frameworks`.

## The suites

`./validation/run list` prints every suite with its one-line description
(from `validation/tests/<name>.sbatch`). Broadly:

- **Node hardware:** `node-smoke`, `node-admission`, `cpu-platform`,
  `gpu-topology`, `gpu-stress`, `gemm-pulse`, `nvlink-p2p`.
- **Fabric:** `ib-link-check`, `ib-pairwise`, `rdma-link-check`,
  `rocev2-pairwise`, `nccl-transport-check`, `transport`.
- **MPI:** `mpi-collective`, `openmpi-cpu`, `openmpi-gpu`, `intelmpi-cpu`,
  `intelmpi-gpu`.
- **Storage and I/O:** `io`, `storage-burnin`, `vast`.
- **Software stack:** `module-smoke`, `integrity-test`, `profiling`,
  `frameworks`, `hpc-challenge`, `slurm-placement`, `container-smoke`.

## Results

```
${CHAPAR_VALIDATION_ROOT}/<set>/<target>/<release-id>/<run-id>/<suite>/...
```

One validation-run ID namespaces every suite a single `./validation/run`
invocation submits; `chapar validate plan` generates `manual-<utc>` IDs for
ad-hoc runs, and a CI runner supplies its own.

Suites bound to the shared result contract (`validation/lib`) write
`summary.json`, `suite.prom`, and a schema-checked `suite-manifest.json`
whose verdict maps to the exit code (`PASS`/`WARN` 0, `FAIL` 1, `SKIP` 77).
The manifest records the release identity block —
`{software_set, target, release_id, run_id, release_lock_sha256}` — taken
from the release's `metadata.json` plus the run-time digest of its
`spack.lock`, so evidence can never name half a release.

## Fixture mode (offline)

Hardware suites can run without hardware against recorded observations under
`validation/fixtures/`, driven by the `validation/tests/test-*-fixtures.sh`
harnesses. Fixtures apply only when `VALIDATION_TEST_MODE=1`; override names
are allowlisted, an override set outside test mode is fatal, and each fixture
declares its own expected verdict, so a fixture run asserts a result rather
than merely exercising a path. `make test` wires these harnesses in.

## The platform boundary

Offline fixture runs and `CHAPAR_DRY_RUN=1` plans verify the suites' logic
and the release binding — they prove nothing about real hardware. Suite
behavior on actual nodes (GPUs, fabric, storage, Slurm placement) is a
separate, operator-approved gate on the target platform; never present a
fixture pass as hardware evidence.
