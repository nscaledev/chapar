# Building container images

How a built release is layered into a registered base image and delivered as
a Pyxis/Enroot `.sqsh`. The injection mechanism and its non-interference rules
are specified in `docs/container-injection.md`; this guide is the operator
flow.

All commands take `--help`. Plan modes are safe anywhere; everything else is
builder-only and currently blocked by the source lock (see below).

## Inputs

- A verified release directory (`docs/building.md`), whose delivery policy
  should include `container` (`CHAPAR_DELIVER` at build time).
- A base container from `containers/images/containers.json`: `nvidia-vlad`
  (accepts set `vlad`, all four targets) or `ubuntu-hpcsim` (accepts
  `hpcsim`, `linux-x86_64-generic`).
- Digest-pinned base image facts in `containers/images/sources-lock.json`.

## 1. Preflight the host

`chapar image preflight` runs fail-closed checks for one of three roles:
`build` (produces a candidate), `runtime` (validates a sealed candidate under
Slurm/Pyxis), `publisher` (seals a validated candidate). Start with the plan,
which resolves identity and paths without probing the host:

```bash
uv run chapar image preflight --mode build --image-id vlad-20260809a --plan-only
uv run chapar image preflight --mode build --image-id vlad-20260809a   # on the builder
```

Identity comes from `--release-dir` when given, otherwise from the site
settings environment (`CHAPAR_SOFTWARE_SET`, `CHAPAR_TARGET`,
`CHAPAR_CONTAINER_BASE`). Runtime and publisher modes additionally require
`--sha256` of the sealed candidate.

## 2. Build the image

Always plan first — `--plan-only` is pure reads and works on a workstation.
It verifies the release, resolves the base digest, walks the runtime closure,
and runs the ELF audit, so a non-self-contained release fails here rather
than on a builder:

```bash
uv run chapar image build --base nvidia-vlad --target linux-x86_64-v4 \
    --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" \
    --image-id vlad-20260809a --plan-only
```

Drop `--plan-only` on a builder to import the base by digest (skopeo +
enroot), inject the closure, prove the base rootfs undisturbed, and export.
Useful extras: `--output-dir` overrides the derived artifact directory,
`--enroot-build-root` relocates enroot scratch, `--keep-container` keeps the
working container for debugging.

**Delivery-policy gate:** a real build refuses a release whose recorded
`deliver` policy omits `container`. `--force` is the explicit operator
override for a one-off image from a modules-only release; `--plan-only` is
never gated.

## 3. Output layout

Without `--output-dir`, artifacts stage under:

```
${CHAPAR_CONTAINER_OUTPUT_ROOT}/<set>/<target>/staging/<image-id>/
  <base>+<tag>-<target>.sqsh          the exported image
  <base>+<tag>-<target>.sqsh.sha256   digest sidecar
  <base>+<tag>-<target>.sqsh.size     size sidecar
```

## 4. Validate the candidate

Run the runtime preflight against the sealed digest, then the container smoke
suite, which loads the injected release under Pyxis and checks the base image
is intact (`validation/tests/container-smoke.sbatch`; see
`docs/validation.md`):

```bash
CHAPAR_CONTAINER_IMAGE=<path-to-sqsh> CHAPAR_CONTAINER_IMAGE_SHA256=<sha> \
    ./validation/run --release-dir <release> container-smoke
```

## 5. Publish

Publication is a hard-link seal of the validated `.sqsh` into the durable
image root, verified against the expected digest and size:

```bash
uv run chapar image publish --source <sqsh> --destination-directory <dir> \
    --destination-name <name>.sqsh --expected-sha256 <sha> --expected-size <bytes>
```

`--self-test` exercises the publisher's own refusal paths. Consumers then run
`srun --container-image=<sealed path>`.

Two inspection helpers: `chapar image resolve` prints the resolved
container/software-set/target tuple from the registries, and
`chapar image verify-release --release-dir <release>` re-verifies a release's
digests, identity, and target facts.

## The source lock is blocked

`containers/images/sources-lock.json` has `status: blocked`, and every
consumer fails closed on it: no real image import, build, export, or
publication is permitted (plan modes still work). Completing it requires, for
every category its contract lists, immutable digests recorded from the
canonical source — most notably an authenticated fetch of the
`nvcr.io/nvidia/hpc-benchmarks` OCI index to pin the per-platform descriptor
and config digests, plus Ubuntu snapshot/key/package pins and checksummed
builder tools. The lock is usable only when `status` is `complete` and
`unresolved` is empty.
