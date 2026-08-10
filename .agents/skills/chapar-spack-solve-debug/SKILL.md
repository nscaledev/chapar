---
name: chapar-spack-solve-debug
description: Diagnose Chapar Spack solver failures for a catalog software set and target. Use for concretization timeouts, provider conflicts, variants, target policy, or configuration layering.
---

# Chapar solve debugging

The environment under diagnosis is the catalog itself: export
`CHAPAR_SOFTWARE_SET` and `CHAPAR_TARGET` and `envs/software/spack.yaml`
composes the matching root lists through its `when:` conditions. Verify the
target is registered with `uv run chapar target list`; its facts (Spack
target, CUDA architectures) are explicit, never probed.

Configuration layers, lowest to highest: Spack defaults, `etc/system` (OS
bootstrap externals only), `etc/user` (`$CHAPAR_*` interpolations), then the
build's own `-C` scope that `release.sh` renders — which embeds the
per-target requirements from `uv run chapar target scope <target>`. Blame a
layer before blaming a spec.

`spack -e envs/software spec ...` and `spack -e envs/software concretize`
are builder/operator actions on the pinned Spack — never claim an offline
session ran them. Preserve latest compiler/MPI/LLVM policy and CUDA/GDR
transport requirements; do not weaken constraints solely to make a solve
pass. Record whether evidence is offline composition evidence or native
Spack evidence.
