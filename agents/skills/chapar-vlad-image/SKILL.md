---
name: chapar-vlad-image
description: Modify or debug manual nscale/Vlad source, release, and .sqsh work, including the shared Chapar image pipeline, digest-locked bases, source lock, site contract, preflight, and image runner provisioning. Use for containers/images/, ci/register-vlad-image-runner.sh, ci/install-vlad-image-site-contract.sh, or their tests. Follow docs/nscale-vlad-manual-build.md for the runnable operator procedure.
---

# Chapar Image Pipeline

Use this playbook for everything under `containers/images/` and the
image-runner provisioning scripts in `ci/`. The pipeline and its provisioning
infrastructure keep the historical `vlad-image` internal name in runtime paths,
systemd units, and environment variable prefixes, even though the shared
pipeline also serves hpcsim. Do not introduce another base id or rename that
internal name. The canonical manual source, release, and `.sqsh` procedure is
[`docs/nscale-vlad-manual-build.md`](../../../docs/nscale-vlad-manual-build.md);
link to it rather than copying its runnable command sequence.

## What this pipeline is

Environments are delivered as self-contained Pyxis images, consumed with
`srun --container-image=<sealed .sqsh>`. Each **selected container** pairs one
base image with one Chapar environment and its own target list:

| Base id | Base image | Environment | Targets | Status |
|---|---|---|---|---|
| `nvidia-vlad` (default) | NVIDIA HPC-benchmarks 26.02 | vlad | `linux-x86_64-v4`, `linux-aarch64-gb300` | base's own OCI category unresolved |
| `ubuntu-hpcsim` | `ubuntu:24.04` | hpcsim | `linux-x86_64-generic` | base's own OCI category resolved |

`ubuntu-hpcsim` is deliberately not NVIDIA-branded: hpcsim policy builds its
own CUDA/GDR stack via Spack rather than relying on an OS-provided CUDA
toolkit, so a vendor-neutral base matches that policy. `linux-x86_64-v4`
runtime preflight demands CPUID and ELF `x86-64-v4` evidence;
`linux-aarch64-gb300` is GB300 (Grace) nodes.

`build-image.sh` injects the promoted release's explicit roots plus their
link/run dependency closure at the **same absolute prefixes** they were built
at (Spack embeds absolute RPATHs; padded `__spack_path_placeholder__` chains
are descended automatically). Modulefiles land at
`/opt/chapar/modulefiles/<arch>` and are activated by `module use` only —
nothing already on the base image's PATH/LD_LIBRARY_PATH is disturbed; the
environment's own stack is opt-in via `module load`.

Two cross-checks fail closed before any injection happens:

- The release's `metadata.txt` `env_path` must match the selected base's
  environment (`--base nvidia-vlad` against an hpcsim release, or vice versa,
  is rejected).
- `--target` must be in the selected base's own target list (`--base
  ubuntu-hpcsim --target linux-aarch64-gb300` is rejected — hpcsim has no
  aarch64 policy).

## Files

```text
containers/images/build-image.sh          # release -> .sqsh injection
containers/images/preflight.sh            # fail-closed host preflight (build|runtime|publisher)
containers/images/targets.json            # target registry (arch, spack_target, cuda_arch) -- shared across bases
containers/images/sources-lock.json       # digest lock; overall status must be "complete" to build any base
containers/images/site-contract.*.json    # host-owned roles/partitions schema + example
containers/images/tests/                  # validate-locks.sh, preflight-test.sh
ci/register-vlad-image-runner.sh          # builder/validator/publisher runner registration
ci/install-vlad-image-site-contract.sh    # installs /etc/chapar/vlad-image/site-contract.{json,sha256}
ci/tests/vlad-image-provisioning-test.sh  # provisioning fixture suite
docs/ci-github-actions.md                 # proposed CI wiring (no workflows exist)
```

## Rules

- **Never pull a base by tag.** Every base resolves to a per-platform
  descriptor digest from `sources-lock.json`; the lock's `floating_input_rule`
  forbids tags, branches, and `latest` as locked values. `build-image.sh`
  refuses to run for ANY base while the lock's overall `status` is `blocked`
  or any category is unresolved — even when that base's own category
  (`ubuntu_base_oci`) is individually resolved. Do not weaken that gate.
- **Fail closed everywhere.** Preflight, the installer, and the runner scripts
  reject symlinked/writable/unowned inputs before any side effect. Tests
  assert the absence of side effects; keep that property when editing.
- **Injection is path-exact.** Never relocate prefixes, never prune the
  link/run closure, never switch the profile script to a PATH/LD_LIBRARY_PATH
  prepend.
- **Adding a base** = a new `BASES` entry in `build-image.sh` (image, tag,
  lock_category, env, env_path, targets allow-list) + a matching entry in
  `preflight.sh`'s smaller `BASES` dict (lock_category, image) + a new locked
  OCI category in `sources-lock.json` + `validate-locks.sh`'s `oci_bases`
  dict/`category_validators` registration + a base-specific in-image verify
  check in `build-image.sh`'s `verify()`.
- **Adding a target** = entries in `targets.json`, `preflight.sh`
  (`EXPECTED_TARGETS`, `X86_ISA_LEVEL` if x86, `RUNTIME_FEATURES`,
  `RUNTIME_DIAGNOSTICS`, `BUILD_TOOLS`), the site-contract schema + example,
  `register-vlad-image-runner.sh` `EXPECTED_TARGETS`, and all three test
  fixtures. Two bases sharing one target's `oci_platform` (both x86 targets on
  `linux/amd64`) must name the same descriptor — one descriptor per OCI
  platform, not per target — this is `validate-locks.sh`'s `oci_bases`/
  `make_oci_validator` invariant.
- **BUILD_TOOLS has no Docker.** `build-image.sh` is enroot-only for every
  target; do not reintroduce a docker-buildx/buildkit requirement into
  `preflight.sh`'s `BUILD_TOOLS`.
- The env build itself must go through `envs/<env>/release.sh build <id>
  [--promote]`; the image build consumes the release's `spack.lock` and
  `metadata.txt` (including `env_path`), never a live Spack.

## Validation

Tests need `python3` with `jsonschema`:

```bash
containers/images/tests/validate-locks.sh --self-test
containers/images/tests/preflight-test.sh
ci/tests/vlad-image-provisioning-test.sh
```

For `build-image.sh` changes, exercise `--plan-only` against a fixture release
(spack.lock + metadata.txt with the right `env_path` + store) for **each**
base — it must resolve the closure and refuse blocked locks, missing
prefixes, env_path mismatches, out-of-allow-list targets, and unknown bases,
all without touching enroot.

## Known-unverified items

Before first real build, confirm on the builder: the `enroot import` form for
digest-pinned bases (`oci-archive://` vs digest `docker://`), the
`nvidia-vlad` base's rootfs glibc ≥ 2.39 (vlad builds on Ubuntu 24.04 — the
`ubuntu-hpcsim` base is Ubuntu 24.04 itself, so this does not apply to it),
and that `module`/`environment-modules` exists in each base (or add it
digest-locked). See `docs/ci-github-actions.md` open items.
