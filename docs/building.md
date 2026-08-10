# Building a release

How to build one immutable Chapar release for one software set and target.
Planning is safe anywhere; the build itself runs on a builder (marked below).

## Prerequisites

- `uv` and Spack installed, site settings in place — see
  `docs/site-onboarding.md`.
- An identity: `CHAPAR_SOFTWARE_SET` (`vlad`, `hpcsim`, or `all`) and
  `CHAPAR_TARGET` (a key of `containers/images/targets.json`). Set them in
  `etc/chapar-site.env` or pass `--set`/`--target` per invocation.
- A release ID you choose, lowercase alphanumeric with `._-`, for example a
  date stamp: `20260809a`.

## Plan, then build

`plan` is offline and read-only: it prints every path and policy value the
build would use.

```bash
bash envs/software/release.sh plan 20260809a --set vlad --target linux-x86_64-v4
```

On a builder (builder-only):

```bash
bash envs/software/release.sh build 20260809a --set vlad --target linux-x86_64-v4
```

Add `--promote` to publish modules and repoint `current` in the same run
(requires `PUBLISH_CURRENT=true`; see `docs/delivering-modules.md`).

The build stages into
`${CHAPAR_RELEASE_ROOT}/<set>/<target>/.staging/<id>.<run-id>` and atomically
renames to `${CHAPAR_RELEASE_ROOT}/<set>/<target>/<id>` on success. A failed
build removes its staging directory; a duplicate release ID is refused.

## What the build does

1. Copies the catalog (`envs/software/spack.yaml`) into the staging directory,
   so the release builds what was reviewed even if the checkout changes
   mid-build.
2. Pins its Spack scopes to `etc/system` and `etc/user` and renders a
   command-line scope: install tree, build stage, mirrors, modules, and the
   per-target package requirements from `chapar target scope` (saved as
   `target-scope.yaml`).
3. Bootstraps ccache in two passes. Spack resolves `ccache` from `PATH` and
   aborts if `config:ccache: true` while it is missing, so pass 1 renders the
   scope with `ccache: false` and installs ccache with the OS external
   compiler (declared in `etc/system/<os>/packages.yaml`); pass 2 re-renders
   with `ccache: true` for everything else. Two ccache installs are expected:
   the bootstrap copy (a build tool) and the catalog root built with `gcc@15`
   (the delivered module).
4. Concretizes, installs the staged root (`gcc`) first so the compiler build
   itself goes through ccache, then installs the rest of the environment into
   the shared padded store.
5. Generates hash-free `{name}/{version}` tcl (and optionally lmod) modules
   for the concrete roots, refusing duplicate names.
6. Writes `metadata.json` (schema v2) and publishes the release atomically.

## What lands in the release directory

```
${CHAPAR_RELEASE_ROOT}/<set>/<target>/<id>/
  spack.yaml            verbatim copy of the catalog this release built
  target-scope.yaml     the rendered per-target package requirements
  spack.lock            release-local lock: the concrete record of the build
  metadata.json         identity, target facts, roots, digests, policy
  modulefiles/<arch>/   generated tcl modules (one architecture directory)
```

`metadata.json` plus `spack.lock` are the release's complete self-description;
image injection, validation, and CVE scanning verify and consume them.

## Submitting via Slurm

`make submit` wraps `ci/submit-env-build.sh`, which resolves Slurm placement
from the site policy function (`CHAPAR_SLURM_PARTITION` is required):

```bash
make submit SOFTWARE_SET=vlad TARGET=linux-x86_64-v4 RELEASE_ID=20260809a
make submit SOFTWARE_SET=vlad TARGET=linux-x86_64-v4 RELEASE_ID=20260809a DRY_RUN=true
# equivalently:
bash ci/submit-env-build.sh --set vlad --target linux-x86_64-v4 --release-id 20260809a --dry-run
```

`--dry-run` verifies the plan and submits nothing. The sbatch job runs
`ci/sbatch-env-build.sh` with a closed export list, so only identity and the
site-config location reach the job.

## Buildcache

Two kinds of binary mirror, both rendered into the build's command-line scope:

- **Seed mirrors** (`CHAPAR_SEED_MIRRORS`, space-separated absolute paths) are
  ordered read-only inputs consulted before building. They never receive
  autopush and may not point under `/resources/chapar`.
- **The writable cache** is `${CHAPAR_BUILDCACHE_ROOT}/<target>`, unsigned.
  Publication is gated by `PUBLISH_BUILDCACHE=true`, which both enables
  autopush during the build and triggers a final indexed push.

To push an existing release's roots after the fact (builder-only in execute
mode):

```bash
bash ci/push-buildcache.sh --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" --plan
PUBLISH_BUILDCACHE=true bash ci/push-buildcache.sh --release-dir <release> --execute
```

Migrating a legacy cache is plan-only in `ci/push-buildcache.sh`
(`--plan-migration <source>`); execution is a separate, copy-only,
non-overwriting step:

```bash
bash envs/software/release.sh migrate-buildcache 20260809a --legacy-source /path/to/old/cache \
    --set vlad --target linux-x86_64-v4
```

Both refuse a source under the immutable legacy roots `/resources/chapar/*`.

## Padded install tree

The store is padded (`__spack_path_placeholder__` chains) so binaries can be
relocated from the buildcache into any store whose prefix is no longer than
the padding. `etc/chapar-install-tree.sh` detects the placeholder chain an
existing store already commits to and reproduces the same `padded_length`, so
successive builds keep identical prefix lengths. That continuity is what keeps
buildcache reuse and container injection (which copies prefixes at their exact
absolute paths) working; a store re-padded to a different length would orphan
every cached binary.
