# Targets

A target is an explicit description of the machines a release will run on.
Targets are never probed from the running machine: every fact lives in the
registry `containers/images/targets.json`, and `CHAPAR_TARGET` selects one by
key.

```bash
uv run chapar target list                # all targets and facts, as JSON
uv run chapar target scope --target linux-x86_64-v4   # rendered Spack scope
```

## The registered targets

| Target | `spack_target` | `native_arch` | `oci_platform` | `llvm_targets` | `cuda_arch` |
|---|---|---|---|---|---|
| `linux-x86_64-generic` | `x86_64` | `x86_64` | `linux/amd64` | `x86`, `nvptx` | 80…121 (full list) |
| `linux-x86_64-v4` | `x86_64_v4` | `x86_64` | `linux/amd64` | `x86`, `nvptx` | 80…121 (full list) |
| `linux-aarch64-generic` | `aarch64` | `aarch64` | `linux/arm64` | `aarch64`, `nvptx` | 80…121 (full list) |
| `linux-aarch64-gb300` | `aarch64` | `aarch64` | `linux/arm64` | `aarch64`, `nvptx` | `103` only |

The full CUDA list is `80, 86, 87, 89, 90, 90a, 100, 103, 110, 120, 121`.
The generic targets per ISA are the portable delivery; `linux-x86_64-v4`
narrows the ISA level (AVX-512) and `linux-aarch64-gb300` narrows the CUDA
architecture list — it differs from `linux-aarch64-generic` in nothing else.

## What each fact drives

- **`spack_target`** becomes `packages:all:require: target=<value>` in the
  rendered scope, so every package — including transitive dependencies —
  builds for that microarchitecture.
- **`cuda_arch`** becomes `cuda_arch=<list>` requirements on the
  CUDA-consuming packages: unconditionally on `gdrcopy`, `nccl`,
  `nccl-tests`, `nvbandwidth`, `nvshmem`, and `nvtop`, and conditionally
  (`when: +cuda`) on `babelstream`, `caliper`, `hwloc`, `libfabric`,
  `openmpi`, and `ucx`.
- **`llvm_targets`** becomes `llvm:require: targets=<list>` — which code
  generators LLVM builds (host ISA plus `nvptx` for CUDA).
- **`oci_platform`** selects the per-platform descriptor when a base image is
  imported for injection (`containers/images/sources-lock.json` records one
  digest per platform), and **`native_arch`** is what `chapar image
  preflight` compares against the host's `uname -m`.

## How the scope reaches a build

`envs/software/release.sh` runs `chapar target scope --target $CHAPAR_TARGET
--output <scope dir>` and includes the result in the build's command-line
scope, the highest-precedence layer of the configuration chain
(`etc/README.md`). Expressing the facts as `packages:` requirements — rather
than decorating root specs — is deliberate: it binds transitive instances
(for example `gdrcopy` under `ucx`) that root-spec decoration cannot reach.
The rendered file is archived in each release as `target-scope.yaml`.

The catalog itself names no target. Its root lists vary only by
`CHAPAR_SOFTWARE_SET` and, for a few x86-only roots, on
`CHAPAR_TARGET` starting with `linux-x86_64-`.

## Adding a target

1. Add a key to `containers/images/targets.json` with all five facts
   (`oci_platform`, `native_arch`, `spack_target`, `llvm_targets`,
   `cuda_arch`). A microarchitecture variant of an existing target can be a
   near-copy — `linux-aarch64-gb300` is `linux-aarch64-generic` with
   `cuda_arch` narrowed to `103`.
2. If container delivery should be allowed, add the target to the relevant
   container's `allowed_targets` in `containers/images/containers.json`, and
   record its platform descriptor in `sources-lock.json` when the lock is
   resolved.
3. Check the per-target tables in `src/chapar/image/preflight.py`
   (`BUILD_TOOLS`, `RUNTIME_FEATURES`, `RUNTIME_DIAGNOSTICS`) — image
   preflight fails on a target those tables do not know.
4. Verify the rendering and plan offline:

```bash
uv run chapar target scope --target <new-target>
bash envs/software/release.sh plan smoketest --set vlad --target <new-target>
```

Site settings then opt machines in per tuple via
`chapar_site_target_policy()` (`docs/site-onboarding.md`). Note that
`linux-aarch64-generic` and `linux-aarch64-gb300` share `spack_target`
`aarch64`, so their store prefixes share an architecture directory — release
identity, not the store path, is what tells them apart.
