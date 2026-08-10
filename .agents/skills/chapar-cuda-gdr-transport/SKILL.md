---
name: chapar-cuda-gdr-transport
description: Change or diagnose CUDA/GDR-aware UCX, Open MPI, libfabric, GDRCopy, NCCL, or NVSHMEM policy in the Chapar software catalog.
---

# Chapar CUDA/GDR transport

Edit shared/root policy only in `envs/software/spack.yaml`. Target-specific
CUDA architecture and native target facts come from
`containers/images/targets.json` and are applied through the per-target
scope (`chapar target scope`). Preserve CUDA/GDR-aware UCX, Open MPI,
libfabric, GDRCopy, NCCL, and NVSHMEM support; do not disable transport
features to bypass a downstream failure.

Use the catalog tests (`uv run --group dev pytest tests/catalog`) and
inspect the composed root list for each affected set/target with
`uv run chapar catalog list`. Native concretization, compiler/link checks,
drivers, InfiniBand, multi-node MPI, NCCL, and performance tests are
deferred operator gates on target platforms; offline composition evidence
does not validate them.
