# Vlad

Vlad is a focused HPC and AI cluster validation environment. Its portable root
set provides Open MPI as the sole MPI runtime.

## MPI and GPU transport

The Open MPI root is CUDA aware and uses the verbs and UCX fabric layers. Vlad
keeps the GPU transport path enabled through CUDA aware UCX and libfabric,
including GDRCopy where supported. The environment also retains its CUDA,
NCCL, and GPU architecture policy for validation tools.

Intel MPI and Intel MPI Benchmarks are intentionally absent from Vlad's
portable root set. This keeps the environment's MPI contract centered on the
Open MPI runtime and avoids presenting Intel MPI modules or benchmark roots as
available Vlad components.

## Microarchitecture target

Vlad selects `x86_64_v4` (AVX-512F/BW/CD/DQ/VL) for the `x86_64` target family
and `aarch64` for the `aarch64` family. The two `packages: all: require` rules in
`spack.yaml` are conditional on those families and remain scoped to Vlad, so no
other environment re-concretizes. The environment also keeps:

- `concretizer: targets: granularity: microarchitecture` — overrides
  `etc/system/base/concretizer.yaml`, which keeps `generic` for everything else.
  `host_compatible` stays `true`, so a builder that cannot execute v4 cannot
  silently emit v4 binaries.

Before native concretization, require the builder family to match the intended
image family and inspect a fresh concrete metadata-only spec:

```bash
test "$(spack arch --family)" = "$EXPECTED_NATIVE_FAMILY"
spack -e envs/vlad spec --fresh --yaml zlib target="$(spack arch --family)" > native-spec.yaml
python3 envs/vlad/tests/target-policy-test.py \
  --assert-concrete-yaml native-spec.yaml \
  --expected-target "$EXPECTED_CONCRETE_TARGET"
```

Use `EXPECTED_NATIVE_FAMILY=x86_64` with
`EXPECTED_CONCRETE_TARGET=x86_64_v4`, or use `aarch64` for both values on the
Grace builder. These are family, spec, and concrete-target gates only; they do
not claim a package build succeeded. After all gates pass, the operator may run
the deferred `spack -e envs/vlad concretize -f` step through the approved
release procedure.

The matching image target is `linux-x86_64-v4` in
`containers/images/targets.json`; its runtime preflight requires CPUID and
ELF `x86-64-v4` evidence. The portable `linux-x86_64-generic` target and its
`x86-64-v1` contract are unchanged (and is what hpcsim's `ubuntu-hpcsim`
container builds on — see `containers/README.md`).

## Container delivery

Vlad is delivered as a Pyxis image, not only as an NFS release tree: the
promoted release's runtime closure is injected into the digest-locked
**NVIDIA HPC-benchmarks 26.02** base (id `nvidia-vlad`, the pipeline's
default), built for both architectures:

| Base id | Base image | Targets |
|---|---|---|
| `nvidia-vlad` | NVIDIA HPC-benchmarks 26.02 | `linux-x86_64-v4`, `linux-aarch64-gb300` |

The manual nscale/Vlad source, release, and `.sqsh` procedure is
[`docs/nscale-vlad-manual-build.md`](../../docs/nscale-vlad-manual-build.md). It
is the only catalog for runnable operator commands. The
`nvidia_hpc_benchmarks_oci` category remains unresolved and the production
source lock remains blocked, so repository QA does not build or publish an
image. Shared and live paths belong to future operator gates; disposable
repository fixtures are the QA surface.

## Building Vlad

Build and publish Vlad releases only through the release helper:

```bash
envs/vlad/release.sh build <id> [--promote]
```

The helper assembles a release in staging, generates its release-local module
files, and promotes it only when `--promote` is requested. Use the helper's
`status`, `module-use`, `promote`, and `publish-modules` commands for the
corresponding release operations. Do not install the environment through a
separate Spack command, because that bypasses the versioned release workflow.

Site paths, cache roots, and publication settings belong in a local
`envs/vlad/vlad-site.env`, copied from `vlad-site.env.example`.
