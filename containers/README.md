# Chapar Environment Containers

This directory holds the container image pipeline shared by every Chapar
environment. It is organized by *selected container* (one base image, one
Chapar environment) rather than by environment, because a single pipeline now
serves more than one environment.

A promoted environment release is layered into a digest-locked base image so
the resulting artifact is self-contained and needs no NFS mount at run time.
Two containers are currently selected:

| Base id | Base image | Environment | Targets | Status |
|---|---|---|---|---|
| `nvidia-vlad` (default) | NVIDIA HPC-benchmarks 26.02 | vlad | `linux-x86_64-v4`, `linux-aarch64-gb300` | base pending lock resolution |
| `ubuntu-hpcsim` | `ubuntu:24.04` | hpcsim | `linux-x86_64-generic` | base digest locked and resolved |

`ubuntu-hpcsim` deliberately does **not** use an NVIDIA-branded base: hpcsim
policy (`AGENTS.md`) builds its own CUDA/GDR stack via Spack rather than
relying on OS-provided CUDA, so a vendor-neutral Ubuntu base matches that
policy instead of contradicting it.

## Layout

- `images/`: the shared Pyxis/Enroot image pipeline —
  - `build-image.sh`: layers a promoted release into the selected base (`--base
    nvidia-vlad|ubuntu-hpcsim`) and exports the Enroot squashfs.
  - `preflight.sh`: fail-closed host preflight for the builder/validator/
    publisher roles.
  - `targets.json`: the target registry (arch, spack_target, cuda_arch),
    shared across bases.
  - `sources-lock.json`: the digest lock every base's OCI reference resolves
    from — never a floating tag.
  - `site-contract.schema.json` / `site-contract.example.json`: the host-owned
    contract (runner roles, per-target partition/constraint).
  - `tests/`: `validate-locks.sh`, `preflight-test.sh`.

## Manual build procedure

The complete manual nscale/Vlad source, release, validation, and `.sqsh`
procedure is [`docs/nscale-vlad-manual-build.md`](../docs/nscale-vlad-manual-build.md).
This catalog intentionally does not copy its runnable command sequence. The
production source lock is still blocked, so repository QA performs no live
source, Spack, image, Slurm, or deployment action. The runbook separates
disposable repository fixtures from shared and live operator paths, and labels
the builder, validator, and publisher steps as future operator gates.

The historical `vlad-image` name remains in runtime paths and host contracts;
it is internal naming, not a new base id. Use only the builder-defined base ids
`nvidia-vlad` and `ubuntu-hpcsim`.

## Building an image

`containers/images/build-image.sh` follows the same Enroot conventions as
fleet-manager's `images/build.sh` — `enroot import` / `create` / `start --root
--rw` / `export`, atomic `.partial.$$` writes, and `ENROOT_*` paths under one
build root — with three deliberate differences:

1. **Digest, not tag.** fleet-manager imports bases by tag (e.g.
   `hpc-benchmarks:26.02`). Chapar's `sources-lock.json` `floating_input_rule`
   forbids tags as locked values, so each base is resolved to its per-platform
   descriptor digest from the lock and copied with `skopeo` before import. The
   script refuses to run for any base while the lock's overall `status` is
   `blocked` or any category is unresolved — even a base whose own category is
   individually resolved (`ubuntu_base_oci` today) stays gated until the whole
   lock reaches `complete`.
2. **Base-id-tagged artifacts.** fleet-manager's `.sqsh` names carry no
   architecture, which its own runbook flags as a footgun requiring a per-arch
   `--cache-dir`. Chapar names by base id and target
   (`nvidia-vlad+26.02-linux-x86_64-v4.sqsh`), so artifacts for different
   bases, environments, or architectures can never collide.
3. **Runtime closure only.** Only the explicit root specs and their transitive
   link/run dependency closure are injected, each at the *same absolute
   prefix* it was built at — Spack embeds absolute RPATHs, so a relocated
   prefix would not resolve. Build-only dependencies are excluded.

A release's own `metadata.txt` (written by `release.sh`) must match the
selected base's environment — pointing `--base nvidia-vlad` at an hpcsim
release, or `--base ubuntu-hpcsim` at a vlad release, fails closed rather than
producing a mismatched image. A target not in the selected base's own target
list (e.g. `--base ubuntu-hpcsim --target linux-aarch64-gb300`) fails closed
the same way.

Modulefiles land at `/opt/chapar/modulefiles/<arch>` and are activated by
`module use` only — nothing already on the base image's PATH or
LD_LIBRARY_PATH is disturbed, so on `nvidia-vlad` the base's own MPI/HPL/NCCL
entrypoints under `/workspace` keep working; the environment's own stack is
opt-in via `module load`.

See the canonical runbook for all runnable commands and role gates. Do not
invent or duplicate a second command sequence here.

Tests for this pipeline need `python3` with `jsonschema`:

```bash
containers/images/tests/validate-locks.sh --self-test
containers/images/tests/preflight-test.sh
ci/tests/vlad-image-provisioning-test.sh
```
