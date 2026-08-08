# Container injection contract

How a selected Chapar release is delivered into a Pyxis/Enroot container without
disturbing the software the base image already provides. Authority stays where it
already is: `containers/images/containers.json` declares the injection and
runtime requirements, `containers/images/targets.json` declares target facts, and
a reviewed `datacenters/<id>` target contract declares paths and publication.

## Mechanism

`containers/images/build-image.sh` copies each installed store prefix into the
Enroot rootfs at the **identical absolute path** it was built at. No relocation
happens, so nothing rewrites an RPATH, no `patchelf` runs, and the binaries in the
image are the same bytes that were validated on the builder. This is what
`containers.json` declares as `injection_requirements.prefix_policy:
build-time-absolute`, with `closure_deptypes: ["link", "run"]` — build-only
dependencies are excluded.

Because the store root is at once a builder path and an in-image path, a target
contract that selects a container must declare `install_tree` under the reserved
`/opt/chapar` namespace. That is enforced in three places that must agree:
`tools/chapar_config/paths.py` (`CONTAINER_PREFIX`), `envs/software/release.sh`,
and `datacenters/schemas/target-contract.schema.json`. Builders must provide
`/opt/chapar` as a **bind mount** onto real storage — image planning rejects a
store root with a symlinked component.

## What must come from the host, and what must be baked

Enroot's hooks inject **devices and sysfs, never userspace transport libraries**.
Getting this split wrong is the difference between a release that runs at fabric
speed and one that silently cannot load.

Host-provided; must never be baked into the image:

| Component | Provided by |
|---|---|
| `libcuda.so.1`, `libnvidia-ml`, `libnvidia-ptxjitcompiler`, `nvidia-smi`, `/dev/nvidia*` | `nvidia-container-cli`, from enroot's `98-nvidia.sh` |
| `/dev/gdrdrv` (GDRCopy kernel device) | `98-nvidia.sh`, when the `--compute` capability is requested |
| `/dev/nvidia-caps-imex-channels` (NVLink IMEX domains) | `98-nvidia.sh` |
| `/dev/infiniband/*`, `/sys/class/infiniband*` and their `abi_version` | `99-mellanox.sh`, gated on `MELLANOX_VISIBLE_DEVICES` |
| `nvidia`, `nvidia_uvm`, `nvidia_peermem`, `gdrdrv`, `mlx5_core`, `ib_uverbs` kernel modules | the host kernel |
| `PMIX_*`/`PMI_*`/`SLURM_*` and the `PMIX_SERVER_TMPDIR` bind | Slurm, via enroot's `50-slurm-pmi.sh` |
| glibc (`libc`, `libm`, `libdl`, `libpthread`, `librt`) | the base image — `etc/system/<os>/packages.yaml` declares `glibc buildable: false`, so glibc is an external and is never in the store |

Release-provided; injected from the store:

- the CUDA **toolkit** (`cuda@13`), NCCL, and the accelerated transports: UCX with
  `+mlx5_dv+dm+ib_hw_tm+cma`, libfabric `fabrics=mlx,rxm,verbs,shm`, Open MPI 5
  with `fabrics=verbs,ucx,cma schedulers=slurm ^pmix@6`;
- `rdma-core` userspace — `libibverbs`, `librdmacm`, `libmlx5`. This is
  deliberate: `99-mellanox.sh` injects no MOFED userspace, and the uverbs uABI is
  version-negotiated (which is why the hook bind-mounts `abi_version`);
- `libgdrapi` from `gdrcopy` — only the kernel device comes from the host;
- `gcc-runtime`, so `libstdc++`, `libgomp` and `libgfortran` come from the
  release's own compiler rather than from whatever the base image ships.

`build-image.sh` enforces the split rather than documenting it: the injected
closure is parsed for `DT_NEEDED`, and any soname that is neither inside the
closure nor on the host-provided list fails the build.

## Non-interference rules

1. **No process-wide environment.** Activation is a MODULEPATH-only
   `/etc/profile.d/zz-chapar-image.sh` that runs `module use` and nothing else.
   No `PATH`, `LD_LIBRARY_PATH`, `PYTHONPATH`, `ld.so.conf.d` drop-in, or
   `ENTRYPOINT`. Injected modulefiles are scanned and rejected if they set
   `LD_LIBRARY_PATH`, `LD_PRELOAD`, `PYTHONPATH` or `PYTHONHOME`, because those
   reach every process in the container, including the base image's own.
   (Pyxis defaults to no container entrypoint, so an entrypoint-based activation
   would conflict with it as well as being process-wide.)
2. **RPATH, not RUNPATH.** `DT_RPATH` is inherited down the dependency chain and
   outranks `LD_LIBRARY_PATH`, so the base image's own `LD_LIBRARY_PATH` cannot
   hijack an injected binary. `DT_RUNPATH` loses that precedence, so an object
   linked with it fails the audit. `config:shared_linking:bind` stays `false`:
   binding absolute library paths into the ELF would be wrong for a stack whose
   `libcuda.so.1` arrives at run time at a path that is not the builder's.
3. **No CUDA stub on a search path.** `+cuda` builds link the toolkit's `libcuda`
   stub. A stub directory surviving in an RPATH would shadow the real driver, so
   any `stubs` component fails the audit.
4. **glibc is one-directional.** A binary records the symbol versions it needs and
   an older libc cannot satisfy them, so the release's highest required
   `GLIBC_2.N` must be no newer than the base image's. Read from the release's own
   binaries and from the base rootfs, and compared before export.
5. **Nothing is overwritten.** Every injection destination must be absent from the
   base image; a collision fails the build with no override. After injection the
   rootfs is diffed against a pre-injection inventory: no deletions, no modified
   file or symlink, no directory mode changes, and every addition under a declared
   destination.
6. **The base image's own tools still win by default.** Before any `module load`,
   `python3`, `mpirun`, `nvcc` and `cmake` must still resolve to base-image paths.

## Site conditions to check, not assume

- `50-slurm-pmi.sh` ships in enroot's `conf/hooks/extra/` and is **not enabled by
  default**. Without it in `/etc/enroot/hooks.d`, an in-container PMIx never sees
  the host's `PMIX_*` and `srun --mpi=pmix` fails in ways that look like an MPI
  bug. PMIx wire compatibility between Slurm's PMIx and the release's `pmix@6` is
  also not guaranteed for every version pair — pin and test, or fall back to
  `--mpi=pmi2`.
- `ENROOT_MOUNT_HOME` and Pyxis's `--container-mount-home` are site-dependent.
  A mounted home shares `~/.local/lib/python3.x/site-packages` between the
  container's python and the release's, so jobs should set `PYTHONNOUSERSITE=1`.
- `/tmp` is a tmpfs inside the container (enroot's `conf/mounts/10-system.fstab`),
  which is one reason the reserved store namespace is `/opt/chapar` and not a
  temporary path.

## A non-RDMA target would need new policy

Catalog transport policy is conditioned on `platform=linux` and is correct for
every registered target, which is NVIDIA plus ConnectX on both ISAs. It is not
generic: `libfabric` carries `fabrics=mlx,rxm,verbs,shm` with `tcp` deliberately
excluded so a silent TCP fallback cannot hide an RDMA misconfiguration. A target
with no RDMA device would therefore have no working provider at all. Registering
one means adding a real transport axis to the target registry and to
`tools/chapar_config/render.py`, not relaxing the catalog.

## Validation status

Offline contract and selection behavior is verified; target-platform behavior not
validated. The closure audit, modulefile content check, publication gate and
registry/contract binding are exercised by
`containers/images/tests/build-image-plan-test.sh` against synthetic releases.
The rootfs inventory diff, the glibc comparison against a real base image, and the
in-image unshadowing check require an actual `enroot create` and are deferred to
an approved operator session, as is every command in
`validation/tests/container-smoke.sbatch`. `containers/images/sources-lock.json`
is globally `blocked`, so no real image build is permitted today.
