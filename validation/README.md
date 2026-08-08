# Validation

This directory contains runtime validation tests for HPC/AI clusters running Chapar-built software environments. Tests validate hardware, interconnects, MPI/NCCL transports, I/O, profilers, and ML frameworks on real cluster hardware.

> **`validation/ARCHITECTURE.md` is authoritative where this file disagrees with
> it.** Parts of this document predate selection-bound validation and are still
> being corrected. In particular: every suite requires a verified
> `--selection`/`--selection-digest`/`--contract`, results are written under the
> contract's `validation_work` root rather than `validation/results/`, and the
> `CHAPAR_MODULE_<NAME>` and `CHAPAR_PARTITION` overrides described below are not
> passed through by `validation/run` — its `--export` list is closed.

## Suite results and fixtures

Ten suites are bound to the shared result contract in `validation/lib`
(`container-smoke`, `cpu-platform`, `gpu-topology`, `node-admission`,
`nvlink-p2p`, `rdma-link-check`, `rocev2-pairwise`, `slurm-placement`,
`storage-burnin`, `vast`). They emit `summary.json`, `suite.prom` and a
schema-checked `suite-manifest.json`, and their exit code follows the verdict:
`PASS`/`WARN` 0, `FAIL` 1, `SKIP` 77.

A local run produces `manual` provenance and is never CI-authoritative; a runner
must supply `VALIDATION_RUN_ID` and a timezone-aware `VALIDATION_RUN_ISSUED_AT`.

Every hardware suite runs offline against recorded observations under
`validation/fixtures/`, driven by `validation/tests/test-*-fixtures.sh`. Hardware
expectations are tracked in `validation/config/capability.yaml`. See
`ARCHITECTURE.md` for the contract and the fixture-injection rules.

## Quick Start

```bash
# List all available tests
./validation/run list

# Run a single test
./validation/run node-smoke

# Run all tests
./validation/run all

# See options
./validation/run --help
```

Tests submit Slurm batch jobs by default. If already inside a Slurm allocation, they run inline.

## Available Tests

### Hardware Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `node-smoke` | Memory bandwidth (likwid), GPU P2P (nvbandwidth), PAPI counters, cuda-memtest, hwloc/lscpu topology | 1 | 1 | 15m |
| `gpu-stress` | Per-GPU cuda-memtest and optional gpu-burn (8h) | 1 | 1 | 8h |
| `hpc-challenge` | HPL, HPCG, STREAM, BabelStream benchmarks | 1 | — | 4h |

### Node Health Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `gemm-pulse` | Repeated GPU GEMM; flags throttling/fail-slow via coefficient of variation | 1 | 1 | 5m |
| `ib-link-check` | Validates IB HCA count, link state, width, speed against `config/network.yaml` | 1 | — | 2m |
| `nccl-transport-check` | NCCL all_reduce; asserts the selected transport matches `config/network.yaml` | 1 | 1 | 5m |

These tests emit machine-readable verdicts (`PASS`/`WARN`/`FAIL`/`SKIP`) as JSON
plus Prometheus exposition files (`.prom`) suitable for a node_exporter
textfile collector. They exit `77` when the required hardware is absent.

### Interconnect Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `ib-pairwise` | OSU latency/bandwidth/bidirectional, qperf, optional ib_write_bw | 2 | — | 30m |
| `mpi-collective` | IMB-MPI1 (Allreduce/Alltoall/Bcast), OSU collectives, NCCL all_reduce | 4 | 1 | 1h |
| `transport` | UCX device/transport listing, Open MPI MCA params, libfabric providers, NCCL transport probe | 2 | 1 | 30m |

### MPI/RDMA Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `openmpi-cpu` | Open MPI CPU Sendrecv ring test | 2 | — | 10m |
| `openmpi-gpu` | Open MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |
| `intelmpi-cpu` | Intel MPI CPU Sendrecv ring test | 2 | — | 10m |
| `intelmpi-gpu` | Intel MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |

The MPI RDMA tests verify end-to-end RDMA data integrity across nodes. The GPU variants additionally validate CUDA-aware MPI transport.

### I/O Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `io` | POSIX/MPI-IO IOR, mdtest metadata, h5bench HDF5, fio | 4 | — | 1h |

### Software Stack Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `profiling` | Validates profiler interposition (caliper, darshan, mpip, ipm, extrae, hpctoolkit, tau, scorep, scalasca, likwid) | 2 | — | 30m |
| `frameworks` | PyTorch distributed all_reduce with MPI backend + mpi4py | 2 | 1 | 30m |

## Environment Configuration

Tests use sensible defaults for module versions and resource requests. Override
any setting via environment variables. The node health tests additionally read
cluster-specific expectations (IB link manifest, expected NCCL transport) from
`validation/config/network.yaml`; edit that file to match your cluster.

### Module Overrides

Each software module has a `CHAPAR_MODULE_<NAME>` variable. Set it to override which module version loads:

```bash
# Use a different CUDA version
CHAPAR_MODULE_CUDA=cuda/12.8 ./validation/run node-smoke

# Use a different Open MPI
CHAPAR_MODULE_OPENMPI=openmpi/5.0.7 ./validation/run ib-pairwise
```

Complete list of module variables:

| Variable | Default | Used By |
|----------|---------|---------|
| `CHAPAR_MODULE_CUDA` | cuda/13 | GPU tests |
| `CHAPAR_MODULE_OPENMPI` | openmpi/5 | MPI tests |
| `CHAPAR_MODULE_UCX` | ucx/1.20.1 | transport |
| `CHAPAR_MODULE_NCCL` | nccl/2.29.7-1 | mpi-collective, transport |
| `CHAPAR_MODULE_NCCL_TESTS` | nccl-tests | mpi-collective, transport |
| `CHAPAR_MODULE_LIBFABRIC` | libfabric/2 | transport |
| `CHAPAR_MODULE_HWLOC` | hwloc | node-smoke |
| `CHAPAR_MODULE_LIKWID` | likwid | node-smoke |
| `CHAPAR_MODULE_PAPI` | papi | node-smoke |
| `CHAPAR_MODULE_NVBANDWIDTH` | nvbandwidth | node-smoke |
| `CHAPAR_MODULE_CUDA_MEMTEST` | cuda-memtest | node-smoke, gpu-stress |
| `CHAPAR_MODULE_OSU_MICRO_BENCHMARKS` | osu-micro-benchmarks | ib-pairwise, mpi-collective |
| `CHAPAR_MODULE_INTEL_MPI_BENCHMARKS` | intel-mpi-benchmarks | mpi-collective |
| `CHAPAR_MODULE_QPERF` | qperf | ib-pairwise |
| `CHAPAR_MODULE_IOR` | ior | io |
| `CHAPAR_MODULE_MDTEST` | mdtest | io |
| `CHAPAR_MODULE_H5BENCH` | h5bench | io |
| `CHAPAR_MODULE_FIO` | fio | io |
| `CHAPAR_MODULE_HPL` | hpl | hpc-challenge |
| `CHAPAR_MODULE_HPCG` | hpcg | hpc-challenge |
| `CHAPAR_MODULE_STREAM` | stream | hpc-challenge |
| `CHAPAR_MODULE_BABELSTREAM` | babelstream | hpc-challenge |
| `CHAPAR_MODULE_OPENBLAS` | openblas | hpc-challenge |
| `CHAPAR_MODULE_PY_TORCH` | py-torch | frameworks |
| `CHAPAR_MODULE_PY_MPI4PY` | py-mpi4py | frameworks |
| `CHAPAR_MODULE_INTEL_ONEAPI_MPI` | intel-oneapi-mpi | intelmpi-* tests |
| `CHAPAR_MODULE_CALIPER` | caliper | profiling |
| `CHAPAR_MODULE_DARSHAN` | darshan-runtime | profiling |
| `CHAPAR_MODULE_MPIP` | mpip | profiling |
| `CHAPAR_MODULE_IPM` | ipm | profiling |
| `CHAPAR_MODULE_EXTRABE` | extrae | profiling |
| `CHAPAR_MODULE_HPCTOOLKIT` | hpctoolkit | profiling |
| `CHAPAR_MODULE_TAU` | tau | profiling |
| `CHAPAR_MODULE_SCOREP` | scorep | profiling |
| `CHAPAR_MODULE_SCALASCA` | scalasca | profiling |
| `CHAPAR_MODULE_LIKWID_PROF` | likwid | profiling |

### Resource Overrides

| Variable | Effect | Example |
|----------|--------|---------|
| `CHAPAR_PARTITION` | Slurm partition | `CHAPAR_PARTITION=gpu ./validation/run node-smoke` |
| `CHAPAR_NODES` | Override node count | `CHAPAR_NODES=8 ./validation/run mpi-collective` |
| `CHAPAR_TIME` | Override time limit | `CHAPAR_TIME=02:00:00 ./validation/run hpc-challenge` |

### Runtime Overrides

| Variable | Effect | Example |
|----------|--------|---------|
| `CHAPAR_KEEP_MODULES=1` | Skip `module purge` — use pre-loaded environment | `CHAPAR_KEEP_MODULES=1 ./validation/run node-smoke` |
| `CHAPAR_DRY_RUN=1` | Print what would run without executing | `CHAPAR_DRY_RUN=1 ./validation/run all` |
| `RESULTS_ROOT` | Custom results directory | `RESULTS_ROOT=/shared/results ./validation/run node-smoke` |

### MPI RDMA Test Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `MPI_RDMA_BYTES` | 8388608 | Message size in bytes |
| `MPI_RDMA_ITERS` | 100 | Ring iterations |
| `MPI_LAUNCHER` | mpirun | MPI launcher command |
| `MPI_LAUNCHER_ARGS` | (varies by MPI) | Launcher arguments |

### Profiling Test Override

```bash
# Select a specific profiler
PROFILER=tau ./validation/run profiling
PROFILER=scorep ./validation/run profiling
```

## Results

Each test writes results to `validation/results/<test>/<job-id>/<node>/`. The directory contains per-command output files named after each command.

To analyze results with MAD-based outlier detection:

```bash
python3 validation/analyze/outliers.py --suite node-smoke --threshold 2.0 \
  --results-dir validation/results/node-smoke/
```

## Adding a New Test

1. Create `validation/tests/<name>.sbatch` using an existing test as a template
2. Start with `# DESCRIPTION: One-line description of what this validates`
3. Add `#SBATCH` directives for default resources
4. Set up the results directory (use the standard pattern from existing tests)
5. Use `CHAPAR_MODULE_<NAME>` variables for module loads
6. Run commands that write output to `$RESULTS_DIR`

The test passes if it exits 0. Exit code `77` means the test was skipped
because its hardware requirements are not met on the node (reported as `SKIP`
by `./validation/run all`, not a failure). Any other non-zero exit is a
failure.

## Output Artifacts

Results are collected under `validation/results/<test>/<run-id>/<nodelist>/`:

```
validation/results/
├── node-smoke/
│   └── 20260725T120000/
│       └── node01/
│           ├── likwid_mem.csv
│           ├── nvbw.csv
│           ├── cuda_memtest_gpu0.log
│           └── ...
├── ib-pairwise/
│   └── ...
└── ...
```
