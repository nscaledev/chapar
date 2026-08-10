# Validation

Runtime validation suites for HPC/AI clusters running Chapar-built software.
Suites validate hardware, interconnects, MPI/NCCL transports, I/O, profilers,
and ML frameworks on real cluster hardware, and every run binds to one
immutable release directory. The operator guide is `docs/validation.md`; the
result contract and fixture architecture are in `validation/ARCHITECTURE.md`.

## Quick start

```bash
# List all available tests
./validation/run list

# Run a single test against the promoted release
./validation/run node-smoke

# Bind to an explicit release instead of the current pointer
./validation/run --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" node-smoke

# Run everything; print plans only
./validation/run --release-dir <release> all
CHAPAR_DRY_RUN=1 ./validation/run --release-dir <release> all
```

Without `--release-dir` the promoted release
`${CHAPAR_RELEASE_ROOT}/${CHAPAR_SOFTWARE_SET}/${CHAPAR_TARGET}/current` is
used; the pointer is resolved to the concrete immutable release before
anything is planned or submitted. Tests submit Slurm batch jobs by default
(placement from `CHAPAR_SLURM_*`); inside an existing allocation they run
inline.

## What reaches a job

`validation/run` submits with a **closed** `--export` list. A job receives:

- `CHAPAR_RELEASE_DIR` — the resolved immutable release directory;
- `RESULTS_ROOT` — the suite's results directory for this run;
- `CHAPAR_VALIDATION_ROOT` — the site validation root;
- `CHAPAR_CONTAINER_BASE` and `CHAPAR_CONTAINER_OUTPUT_ROOT`, when set —
  container facts for `container-smoke`;
- `CHAPAR_CONTAINER_IMAGE` + `CHAPAR_CONTAINER_IMAGE_SHA256`, when both are
  set — the sealed `.sqsh` under test (`container-smoke` verifies the path
  and SKIPs when absent);
- only with `VALIDATION_TEST_MODE=1`: the allowlisted `VALIDATION_TEST_*`
  fixture variables.

Nothing else in the caller's environment reaches a submitted job — in
particular there are no `CHAPAR_MODULE_<NAME>` version overrides: the module
tree and versions come from the release itself. Knobs read by the suites
directly (`CHAPAR_NODES`, `CHAPAR_TIME`, `CHAPAR_KEEP_MODULES=1`,
`MPI_RDMA_BYTES`, `MPI_RDMA_ITERS`, `PROFILER`, `IO_TEST_DIR`, …) therefore
take effect only for inline runs inside an existing allocation, or when a
suite is launched with `sbatch` directly.

## Suite results and fixtures

Ten suites are bound to the shared result contract in `validation/lib`
(`container-smoke`, `cpu-platform`, `gpu-topology`, `node-admission`,
`nvlink-p2p`, `rdma-link-check`, `rocev2-pairwise`, `slurm-placement`,
`storage-burnin`, `vast`). They emit `summary.json`, `suite.prom` and a
schema-checked `suite-manifest.json` carrying the release identity block
(`{software_set, target, release_id, run_id, release_lock_sha256}`), and
their exit code follows the verdict: `PASS`/`WARN` 0, `FAIL` 1, `SKIP` 77.

A local run produces `manual` provenance and is never CI-authoritative; a runner
must supply `VALIDATION_RUN_ID` and a timezone-aware `VALIDATION_RUN_ISSUED_AT`.

Every hardware suite runs offline against recorded observations under
`validation/fixtures/`, driven by `validation/tests/test-*-fixtures.sh`. Hardware
expectations are tracked in `validation/config/capability.yaml`. See
`ARCHITECTURE.md` for the contract and the fixture-injection rules.

## Available tests

`./validation/run list` is authoritative; the tables below are reference for
the long-standing suites.

### Hardware validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `node-smoke` | Memory bandwidth (likwid), GPU P2P (nvbandwidth), PAPI counters, cuda-memtest, hwloc/lscpu topology | 1 | 1 | 15m |
| `gpu-stress` | Per-GPU cuda-memtest and optional gpu-burn (8h) | 1 | 1 | 8h |
| `hpc-challenge` | HPL, HPCG, STREAM, BabelStream benchmarks | 1 | — | 4h |

### Node health validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `gemm-pulse` | Repeated GPU GEMM; flags throttling/fail-slow via coefficient of variation | 1 | 1 | 5m |
| `ib-link-check` | Validates IB HCA count, link state, width, speed against `config/network.yaml` | 1 | — | 2m |
| `nccl-transport-check` | NCCL all_reduce; asserts the selected transport matches `config/network.yaml` | 1 | 1 | 5m |

These tests emit machine-readable verdicts (`PASS`/`WARN`/`FAIL`/`SKIP`) as JSON
plus Prometheus exposition files (`.prom`) suitable for a node_exporter
textfile collector. They exit `77` when the required hardware is absent.

### Interconnect validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `ib-pairwise` | OSU latency/bandwidth/bidirectional, qperf, optional ib_write_bw | 2 | — | 30m |
| `mpi-collective` | IMB-MPI1 (Allreduce/Alltoall/Bcast), OSU collectives, NCCL all_reduce | 4 | 1 | 1h |
| `transport` | UCX device/transport listing, Open MPI MCA params, libfabric providers, NCCL transport probe | 2 | 1 | 30m |

### MPI/RDMA validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `openmpi-cpu` | Open MPI CPU Sendrecv ring test | 2 | — | 10m |
| `openmpi-gpu` | Open MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |
| `intelmpi-cpu` | Intel MPI CPU Sendrecv ring test | 2 | — | 10m |
| `intelmpi-gpu` | Intel MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |

The MPI RDMA tests verify end-to-end RDMA data integrity across nodes. The GPU
variants additionally validate CUDA-aware MPI transport.

### I/O validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `io` | POSIX/MPI-IO IOR, mdtest metadata, h5bench HDF5, fio | 4 | — | 1h |

### Software stack validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `profiling` | Validates profiler interposition (caliper, darshan, mpip, ipm, extrae, hpctoolkit, tau, scorep, scalasca, likwid) | 2 | — | 30m |
| `frameworks` | PyTorch distributed all_reduce with MPI backend + mpi4py | 2 | 1 | 30m |

The node health tests read cluster-specific expectations (IB link manifest,
expected NCCL transport) from `validation/config/network.yaml`; edit that
file to match your cluster. The `profiling` suite selects one profiler per
run via `PROFILER=tau` (inline runs, see above).

## Results

```
${CHAPAR_VALIDATION_ROOT}/<set>/<target>/<release-id>/<run-id>/<suite>/...
```

One validation-run ID namespaces every suite a single invocation submits.
Analyze a suite's results with MAD-based outlier detection:

```bash
uv run chapar validate analyze --suite node-smoke --threshold 2.0 \
  --results-dir "$CHAPAR_VALIDATION_ROOT/vlad/linux-x86_64-v4/20260809a/<run-id>/node-smoke"
```

## Adding a new test

1. Create `validation/tests/<name>.sbatch` using an existing test as a template
2. Start with `# DESCRIPTION: One-line description of what this validates`
3. Add `#SBATCH` directives for default resources
4. Set up the results directory under `$RESULTS_ROOT` (use the standard
   pattern from existing tests) and load modules from the release the job
   receives as `CHAPAR_RELEASE_DIR`
5. Run commands that write output to `$RESULTS_DIR`

The test passes if it exits 0. Exit code `77` means the test was skipped
because its hardware requirements are not met on the node (reported as `SKIP`
by `./validation/run all`, not a failure). Any other non-zero exit is a
failure.
