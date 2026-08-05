# Proposed GitHub Actions CI for Chapar environment builds

**Status: proposal.** This repository carries no `.github/workflows/` today.
The previous Incus-on-Rocky CI was removed with the Ubuntu 24.04 migration.
This document proposes replacing the maintainer's former *local* Incus
container with nscale's actual self-hosted-runner conventions, surveyed
directly from other `nscaledev` repositories (`github-runner`, `image-builder`,
`fleetmanager-slurm-appliance`, and the standard Go-service `ci.yaml`/
`release.yaml` pair used by `nks-core`, `cluster-api-provider-nscale`, and
others). Nothing below exists until it is agreed and implemented.

Manual operators should follow the [canonical nscale Vlad source and image
build runbook](nscale-vlad-manual-build.md); this document does not activate
that procedure.

## What CI must produce

Two selected containers, three target builds total. Vlad has exactly two native
target builds, and hpcsim has exactly one. The repository-wide total is exactly
three builds total, Vlad two plus hpcsim one:

| Base id | Base image | Environment | Targets |
|---|---|---|---|
| `nvidia-vlad` | `nvcr.io/nvidia/hpc-benchmarks:26.02` (digest-locked) | vlad | `linux-x86_64-v4`, `linux-aarch64-gb300` |
| `ubuntu-hpcsim` | `ubuntu:24.04` (digest-locked) | hpcsim | `linux-x86_64-generic` |

Each artifact is a Pyxis image: a promoted environment release's runtime
closure, injected at build-time absolute paths into the digest-locked base by
`containers/images/build-image.sh`, consumed via
`srun --container-image=<sealed path>`.

## What "the procedure in nscale" actually is

The maintainer's prior workflow — a local Incus container used as an ad hoc
build host — has a direct nscale-standard replacement, not a GitHub-hosted
runner:

**Self-hosted runners are provisioned as dedicated VMs, not ephemeral
containers, and registered into their own named runner group.** The
`nscaledev/github-runner` repo's `static-runner/` module is Terraform +
Ansible that provisions Ubuntu 24.04 OpenStack VMs and configures each as a
GitHub Actions runner (Ansible roles: `common`, `docker`, `tools`,
`github_runner`). The runner role registers at the **organization** level
with a **runner group** name
(`github_runner_runner_group`, default `"Default"`) and a label set
(`github_runner_runner_labels`, default
`self-hosted,linux,x64,ubuntu-24.04,docker,kvm`). `nscaledev/image-builder`'s
own static pool is registered under the group `nscale-static-runner`, and
that group is restricted in GitHub's org settings to the `image-builder` repo
alone (`github-runner`'s README: "configured in GitHub to only be available to
that project"). Chapar needs the same treatment with its **own** group — e.g.
`nscale-chapar-builder` — provisioned the same way and scoped to
`nscaledev/chapar` only. It must not reuse `nscale-static-runner` (that
group's GitHub-side restriction is image-builder-specific) or the generic
`nscale-k8s` pool (see below — too ephemeral and unprivileged for a multi-hour
Spack build against the shared NFS install tree).

**A second, lightweight runner pool (`nscale-k8s`) exists for orchestration,
not heavy builds.** This is GitHub's Actions Runner Controller (ARC) on
Kubernetes (`nscaledev/github-runner`'s `gh-arc/` image) — ephemeral,
on-demand pods, currently using privileged DIND (the README flags this as a
known weakness, planned to move to Kaniko). `image-builder`'s
`template-build.yml` targets `nscale-k8s` for cheap steps (matrix resolution,
secret loading, artifact signing/distribution) and reserves the static pool
only for the actual build job. Chapar's workflow should split the same way:
the Spack build and image injection run on the static `nscale-chapar-builder`
group (they need the NFS-mounted site roots, real disk, and can run for
hours); everything else — the lock-gate check, artifact packaging, validation
dispatch — can run on `nscale-k8s`.

**Job-to-job data goes through `actions/upload-artifact` /
`download-artifact`, never `needs.<job>.outputs`.** This is not a Chapar
preference; it is a documented, repeated workaround across
`fleetmanager-slurm-appliance` and `image-builder`: both repos' workflows have
inline comments stating that job-output handoff came through empty even when
the producing step's own output was set correctly in-job, and both use
artifacts instead. Chapar's image pipeline already writes an artifact's own
`.sha256` file (`build-image.sh`), so the same file is the natural thing to
upload/download between the build and publish jobs.

**Cross-repo access uses a short-lived GitHub App token, not a personal access
token.** `nks-core`, `cluster-api-provider-nscale`, and `image-builder` all
mint one per job with `actions/create-github-app-token`, backed by
`vars.NSCALE_ACTIONS_APP_ID` / `secrets.NSCALE_ACTIONS_APP_PK` (the "Nscale
Actions" GitHub App). Chapar's pipeline does not currently need cross-repo
access; adopt this only if a future step needs to read another private
`nscaledev` repo.

**Runner registration credentials are host-provisioning-time secrets, not
workflow secrets — this Chapar already gets right.**
`github_runner_access_token` is a Terraform/Ansible variable at VM
provisioning time, never a GitHub Actions secret read by a workflow run; it
never appears in any `.github/workflows/*.yml` in `github-runner`. Chapar's
`ci/register-vlad-image-runner.sh` and `ci/install-vlad-image-site-contract.sh`
already follow this: registration/removal tokens and the site contract are
root-owned 0600 files on the runner host, supplied to the *provisioning*
script, not to a workflow. No change needed here — just confirmation that the
existing design already matches nscale's convention.

**Secrets a workflow does need come from 1Password, not repo/environment
secrets, for anything beyond the built-in `GITHUB_TOKEN`.**
`1password/load-secrets-action` (configure + load, service-account token in
`secrets.OP_SERVICE_ACCOUNT_TOKEN`) is how `image-builder` reaches OpenStack
credentials, S3 keys, and Vault tokens. Chapar's CVE checker already uses a
simpler local `/etc/chapar/cve-checker.env` model for its own, unrelated
secrets; that is out of scope here and not something this proposal changes.
If the image pipeline later needs a workflow-visible secret (for example, NGC
credentials if the `nvidia_hpc_benchmarks_oci` lock resolution needs
authentication), it should come from 1Password the same way, not a new GitHub
secret.

**Container images that fit the Docker/OCI model go to GHCR; large,
non-container artifacts go to S3.** `nks-core`'s `release.yaml` is the
standard shape: `docker/login-action` against `ghcr.io` using the built-in
`GITHUB_TOKEN` (with `packages: write`), then `make images -e
RELEASE=1 VERSION=...` pushes tagged images and a Helm chart as an OCI
artifact. `image-builder` instead exports its large OS-level VM images to a
VAST-backed S3 bucket, because those are not container images at all.
Chapar's `.sqsh` artifacts are Enroot squashfs files, not OCI image layers, so
neither fits cleanly without extra tooling (an ORAS push to GHCR as a generic
artifact would work but is unverified here). This proposal keeps the already-
built, already-tested design: the shared NFS site root
(`preflight.sh --mode publisher` sealing into
`<image_root>/<target>/releases/<release-id>/`), matching how every other
Chapar artifact (releases, modulefiles, buildcache) is already distributed.
Revisit GHCR/ORAS or S3 only if a site needs image distribution off the shared
NFS mount.

## Pipeline shape

```
lock-gate (nscale-k8s) ──► build-env (nscale-chapar-builder, per env×arch) ──► build-images (nscale-chapar-builder, per base×arch) ──► validate (nscale-chapar-builder) ──► publish (nscale-chapar-builder)
```

1. **lock-gate** (`nscale-k8s` — cheap, no site access needed):
   - `containers/images/tests/validate-locks.sh --require-complete` — fails
     the run while `sources-lock.json`'s overall status is `blocked` or any
     category is unresolved. This holds even after a specific base's own
     category resolves (`ubuntu_base_oci` already has: it is fully resolved
     against the real `ubuntu:24.04` digest, but the lock as a whole is still
     `blocked` on five other categories, so builds for *both* bases stay
     gated until every category clears). This is the supply-chain gate: no
     tag-based pulls, ever.
   - `containers/images/tests/preflight-test.sh` and
     `ci/tests/vlad-image-provisioning-test.sh` as cheap regression suites
     (need `python3` + `jsonschema`).

2. **build-env** — matrix over `(env, arch)` pairs (vlad×2, hpcsim×1 = 3
   jobs), each on the `nscale-chapar-builder` static group:
   - `preflight.sh --mode build --base <base> --target <target> ...` —
     fail-closed host check (pinned tools, NFS, free space, contract
     identity, and now a skopeo-inspect probe against the *selected* base's
     own locked descriptor).
   - `source etc/init.sh && envs/<env>/release.sh build <release-id>` — never
     `spack install` directly. `--promote` only when the `promote` input is
     true (vlad: promote every successful build; hpcsim: operator-explicit
     only, per existing policy).
   - `ENV_NAME=<env> ./validation/run integrity-test` — release is not
     production-ready until this passes.
   - `PUBLISH_BUILDCACHE=true` so later rebuilds and the other architecture
     reuse binaries.

3. **build-images** — matrix over `(base, target)` pairs (3 jobs), each on the
   static group:
   - `build-image.sh --base <nvidia-vlad|ubuntu-hpcsim> --target <target>
     --release-dir <promoted release> --image-id <id> --candidate-root
     <candidates>` — resolves the base by digest from the lock, cross-checks
     the release's `env_path` against the base's environment, injects the
     runtime closure, verifies in-rootfs, exports
     `<base>+<tag>-<target>.sqsh` plus its `.sha256` into the candidate root.
   - Upload the `.sqsh` + `.sha256` as a build artifact (not a job output) for
     the validate/publish jobs to consume.

4. **validate** — matrix over the same three `(base, target)` pairs, on the static group (the
   validator role needs the same site/hardware access as the builder):
   - Download the artifact from step 3.
   - `preflight.sh --mode runtime --target <target> --sha256 <artifact sha>`
     — for `linux-x86_64-v4` this enforces CPUID and ELF `x86-64-v4` evidence
     on the actual node class. Runtime/publisher checks are target-scoped,
     not base-scoped (`preflight.sh` only reads `--base` in build mode, to
     pick which locked descriptor to skopeo-inspect); `--base` is accepted
     everywhere but unused outside that one check.
   - An `srun --container-image=<candidate .sqsh>` smoke job: `module use
     /opt/chapar/modulefiles/<arch>`, load each root module, run its
     `--version` check. For `nvidia-vlad` additionally run the NVIDIA
     `/workspace` HPL entrypoint in a one-node dry-run.

5. **publish** — on the static group, per artifact that validated:
   - Download the artifact.
   - `preflight.sh --mode publisher --target <target> --sha256 <sha>` then an
     atomic move of the sealed candidate into
     `<image_root>/<target>/releases/<release-id>/`.

## Open items before implementation

1. Resolve `sources-lock.json` to `complete`: lock the
   `nvidia_hpc_benchmarks_oci` index/descriptor digests (needs `skopeo` and
   NGC reachability/credentials on a builder — `ubuntu_base_oci` is already
   resolved and needed no credentials, since Docker Hub serves that image
   anonymously).
2. Provision the `nscale-chapar-builder` static runner group
   (`nscaledev/github-runner`'s `static-runner/` Terraform + Ansible, pointed
   at a new OpenStack project/VMs) and have it restricted to
   `nscaledev/chapar` in GitHub's org runner-group settings.
3. Confirm `enroot import` accepts the `oci-archive://` (or digest
   `docker://`) form used by `build-image.sh` on the builder's enroot
   version.
4. Confirm the `nvidia-vlad` base's glibc compatibility: vlad builds on
   Ubuntu 24.04 / glibc 2.39. (`ubuntu-hpcsim`'s base is Ubuntu 24.04 itself,
   so this does not apply to it.)
5. Ensure `environment-modules` (or Lmod) is present in each base or added as
   a digest-locked package, otherwise the injected modulefiles are inert.
6. Decide artifact retention on the shared NFS image root: candidate roots are
   scratch; sealed releases are immutable; how many image releases to keep per
   target.
