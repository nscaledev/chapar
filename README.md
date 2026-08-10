# Chapar

Chapar builds a reproducible, Spack-based HPC software stack and delivers it
two ways — as tcl modulefiles on a shared filesystem, and/or injected into
Pyxis/Enroot container images (for example NVIDIA hpc-benchmarks) — for
x86_64 and aarch64 targets. What to build and where everything lives is
decided by one per-machine site settings file; which packages exist is decided
by one reviewed catalog.

## Goals

- One catalog (`envs/software/spack.yaml`) with three composable software
  sets: `vlad` (cluster validation: benchmarks, profilers, GPU transport),
  `hpcsim` (simulation/visualization), and `all` (the union).
- Explicit targets, never probed: `linux-x86_64-generic`, `linux-x86_64-v4`,
  `linux-aarch64-generic`, `linux-aarch64-gb300` — facts (Spack target, CUDA
  architectures, LLVM targets, OCI platform) live in
  `containers/images/targets.json`.
- Immutable releases: every build stages into a temporary directory and is
  atomically renamed to `…/<set>/<target>/<release-id>`; a `current` symlink
  is the only mutable pointer, so rollback is repointing a link.
- Delivery per target, chosen in site settings: modulefiles, container
  injection, or both — from the same build.
- OS independence: the OS scope provides only the bootstrap compiler;
  everything else is Spack-built, currently on Ubuntu 24.04 builders.

## Layout

```
etc/                  site settings, Spack config scopes, shell setup
  chapar-site.env.example   copy to chapar-site.env and edit for your machine
  chapar-defaults.sh        resolves and validates every CHAPAR_* setting
  init.sh                   source this to work interactively
  system/ user/             persistent Spack scopes (OS bootstrap / $CHAPAR_* paths)
envs/software/        the catalog (spack.yaml) and the release driver (release.sh)
src/chapar/           the operator CLI: uv run chapar --help
containers/images/    target/container registries, source custody lock
validation/           Slurm validation suites and their offline fixtures
ci/                   Slurm submission, buildcache push, CVE deployment
docs/                 task guides — see docs/README.md
tests/                pytest suite: make test
```

## Quick start

```bash
git clone <chapar-repo-url> chapar && cd chapar

# 1. Tools: uv (runs the CLI) and Spack (builds the stack)
curl -LsSf https://astral.sh/uv/install.sh | sh
bash etc/install-spack.sh

# 2. Site settings: where things install, what to build, how to deliver it
cp etc/chapar-site.env.example etc/chapar-site.env
"${EDITOR:-vi}" etc/chapar-site.env

# 3. Bind the shell: Spack scopes, ccache, promoted modules (if any)
source etc/init.sh

# 4. Explore
uv run chapar --help
uv run chapar catalog list --set vlad --arch aarch64
uv run chapar target list
```

With no site file at all, everything defaults to a private tree under
`~/.spack/chapar` — safe for a workstation. Set `CHAPAR_INSTALL_MODE=public`
and `CHAPAR_PUBLIC_ROOT=/shared/chapar` in the site file for a cluster.

## Building a release

A release is identified by software set + target + release id. Offline, on
any machine, print exactly what a build would do:

```bash
bash envs/software/release.sh plan 20260809a --set vlad --target linux-x86_64-v4
```

On a builder (directly, or via Slurm):

```bash
bash envs/software/release.sh build 20260809a --set vlad --target linux-x86_64-v4
# or, submitting to the partition the site settings declare for this tuple:
make submit SOFTWARE_SET=vlad TARGET=linux-x86_64-v4 RELEASE_ID=20260809a
make submit SOFTWARE_SET=vlad TARGET=linux-x86_64-v4 RELEASE_ID=20260809a DRY_RUN=true
```

The build bootstraps ccache with the OS compiler, concretizes the catalog for
the selected set and target, installs into the shared padded store, generates
hash-free `{name}/{version}` tcl modules, and publishes the immutable release
with its own `spack.lock` and `metadata.json`. Details: `docs/building.md`.

## Delivering modules

```bash
bash envs/software/release.sh publish-modules 20260809a --set vlad --target linux-x86_64-v4
PUBLISH_CURRENT=true bash envs/software/release.sh promote 20260809a --set vlad --target linux-x86_64-v4
module use "$CHAPAR_MODULE_ROOT/vlad/linux-x86_64-v4/current"
module avail
```

`publish-modules` requires the site delivery policy for the tuple to include
`modules` (`CHAPAR_DELIVER`). Login shells that source `etc/init.sh` (or the
`etc/profile.d/zz-chapar.sh` hook) pick up the promoted release
automatically. Details: `docs/delivering-modules.md`.

## Building a container image

The same release can be injected into a registered base image — the store
prefixes are copied in at their identical absolute paths under `/opt/chapar`,
modules stay opt-in, and the base image is proven undisturbed:

```bash
uv run chapar image preflight --mode build
uv run chapar image build --base nvidia-vlad --target linux-x86_64-v4 \
    --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" \
    --image-id vlad-20260809a --plan-only
# drop --plan-only on a builder; then seal the validated image:
uv run chapar image publish --source <sqsh> --destination-directory <dir> \
    --destination-name <name>.sqsh --expected-sha256 <sha> --expected-size <bytes>
```

Real image builds stay blocked until `containers/images/sources-lock.json`
reaches `status: complete` (the NVIDIA base image needs an authenticated
fetch to pin). Details: `docs/container-images.md` and
`docs/container-injection.md` for the injection contract.

## Validating a release

```bash
./validation/run --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" list
CHAPAR_DRY_RUN=1 ./validation/run --release-dir <release> all
./validation/run --release-dir <release> node-smoke        # sbatch on a cluster
uv run chapar validate analyze --suite node-smoke --results-dir <results>
```

Details: `docs/validation.md`. Only offline fixture behavior is verified in
this checkout; suite behavior on real hardware is a separate, operator-run
gate.

## CVE scanning

```bash
uv run chapar cve scan --release-dir <release> --plan
```

The scan inventory is the release's own `spack.lock` roots. Details:
`docs/cve.md`.

## Configuration model

Precedence, lowest to highest: Spack defaults → `etc/system` (OS bootstrap
externals only) → `etc/user` (paths via `$CHAPAR_*`) → the build's own
command-line scope. The `$CHAPAR_*` values come from your environment, then
`etc/chapar-site.env`, then built-in defaults — resolved and validated by
`etc/chapar-defaults.sh`, which both `etc/init.sh` and `release.sh` source,
so interactive shells and builds always agree. The full variable table is in
`etc/README.md`.

## Development

```bash
make test    # pytest: CLI, image pipeline, validation planning, shell suites
make lint    # ruff + basedpyright over src/ and tests/
```

## Documentation

Task guides are indexed in `docs/README.md`. Agent/contributor rules are in
`AGENTS.md`.
