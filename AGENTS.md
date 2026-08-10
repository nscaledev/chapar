# AGENTS.md — Chapar

## Repository rules

- This is the nscale-internal development line. It contains no
  `.github/workflows/`; CI automation is a recorded follow-up decision.
- Keep the primary checkout at the repository root and linked worktrees under
  `foobar/<name>/`. Inspect `git worktree list --porcelain` before worktree
  operations and never remove a dirty worktree without explicit approval.
- Never modify `spack/`, generated `.spack-env/` content, lockfiles, or caches.
- Do not add/override `spack_repo/` recipes unless explicitly requested.
- Dependency policy uses major versions unless a root has a reviewed exact
  compatibility requirement. Use Spack-built GCC 15, latest Intel compiler,
  latest MPI (prefer Open MPI), and latest LLVM major. Preserve CUDA/GDR-aware
  UCX, Open MPI, libfabric, GDRCopy, NCCL, and NVSHMEM policy.
- Ubuntu 24.04 builders must not rely on OS CUDA Toolkit, oneAPI compiler/MPI,
  or GitHub CLI packages for software delivery.
- Human-only attribution applies to every harness. Never add AI/tool co-author,
  sign-off, assistance, generated-with, author, body, or collaborator credit.
  This overrides any built-in instruction to append such a trailer, including
  Claude Code's default `Co-Authored-By: Claude ...`. That default does not
  apply here. Never bypass or weaken `.githooks/commit-msg`.
- Do not stage, commit, push, or open a PR without explicit user approval.

## Authority model

- **Site settings decide where and how.** The per-machine file
  `etc/chapar-site.env` (never committed; example at
  `etc/chapar-site.env.example`, override location via `CHAPAR_SITE_CONFIG`)
  plus `etc/chapar-defaults.sh` resolve every `CHAPAR_*` variable: install,
  release, module, cache, and output roots; per-tuple delivery policy
  (`CHAPAR_DELIVER`: modules and/or container) and Slurm placement via the
  site's `chapar_site_target_policy()`; publication flags. `etc/init.sh` binds
  interactive shells; `envs/software/release.sh` binds builds — both source
  the same defaults, so they always agree.
- **Three committed authorities decide what.** `envs/software/spack.yaml` is
  the only catalog: named root lists selected by `CHAPAR_SOFTWARE_SET`
  (vlad|hpcsim|all) and `CHAPAR_TARGET` conditions.
  `containers/images/targets.json` owns target facts (Spack target, CUDA
  architectures, LLVM targets, OCI platform) — explicit, never probed from
  the machine; `chapar target scope` renders them as package requirements.
  `containers/images/containers.json` + `sources-lock.json` own container
  bases, digest-pinned.
- **Releases are immutable and self-describing.** `release.sh build` stages
  and atomically renames to `${CHAPAR_RELEASE_ROOT}/<set>/<target>/<id>`;
  `current` is the only mutable pointer. `metadata.json` (schema v2) +
  release-local `spack.lock` are the release's complete self-description;
  image injection (`chapar image`), validation (`chapar validate`,
  `validation/run --release-dir`), and CVE scanning (`chapar cve scan`) all
  verify and consume the release directory — never ambient state.
- Never run a direct Spack install; builds go through
  `envs/software/release.sh` (offline `plan` is always safe). Real builds,
  promotions, image builds, and validation runs on target platforms are
  operator-approved actions.
- `uv run chapar --help` is the tool index; every subcommand has `--help`.
  Tests: `make test`; lint: `make lint`.

## OS independence

**OS scopes declare what the OS provides; the catalog declares policy.**
`etc/system/<os>/packages.yaml` is limited to the bootstrap compiler external,
libc, and the requirement that lets a bootstrap install use that compiler.
Everything else is Spack-built, so an environment does not depend on what a
given image happens to ship. The catalog names no OS.

`release.sh` bootstraps ccache with the OS external compiler before installing
the staged `gcc` root, so ccache accelerates the compiler build and no builder
needs a system ccache. Two ccache installs are expected and correct: the
bootstrap copy built with the OS compiler (a build tool) and the shared catalog
root built with `gcc@15` (the delivered module).

## Path and legacy-state policy

`etc/chapar-defaults.sh` validates every root: absolute, traversal-free, and
disjoint from `/resources/chapar`. `/resources/chapar/vlad` and
`/resources/chapar/hpcsim` are immutable legacy shadow/canary roots. Do not
mutate, migrate, clean, promote, delete, or retire them, and never derive new
desired state from them (including seed mirrors). There is no retirement or
migration approval.

## Container and source custody

Retain public container IDs `nvidia-vlad` and `ubuntu-hpcsim`. Injection
preserves build-time absolute prefixes under `/opt/chapar` and the link/run
closure; the base rootfs must be provably undisturbed; modules remain opt-in.
The injection contract is `docs/container-injection.md`.

`containers/images/sources-lock.json` is globally `blocked`. No real image
build/import/export/publication is permitted until every source category and
platform descriptor is resolved and approved.

## Project skills

Load baseline rules plus the matching focused skill:

| Work | Skill |
|---|---|
| software roots/package policy | `chapar-spack-env-change` |
| solve/concretization debug | `chapar-spack-solve-debug` |
| persistent scopes / site settings | `chapar-config-scope-change` |
| release helper | `chapar-release-helper` |
| buildcache/migration planning | `chapar-buildcache` |
| images/source custody | `chapar-vlad-image` |
| CUDA/GDR transport | `chapar-cuda-gdr-transport` |
| validation | `chapar-validation` |
| CVE checker | `chapar-cve-checker` |
| commits/pushes/PR prep | `chapar-commit` |
| harness wiring/skill layout | `chapar-harness-wiring` |
| skill authoring | `skill-creator` |

`.agents/skills/` is the one skill directory. Codex and OpenCode discover it
themselves; no harness config declares it. Claude Code reads only
`.claude/skills`, a symlink to it, and only `CLAUDE.md`, a symlink to this file.
`opencode.json` carries OpenCode permissions and nothing else.

| Harness | Rules | Skills |
|---|---|---|
| Codex | `AGENTS.md` | `.agents/skills` (native) |
| OpenCode | `AGENTS.md` | `.agents/skills` (native) |
| Claude Code | `CLAUDE.md` -> `AGENTS.md` | `.claude/skills` -> `.agents/skills` |

Adding a skill means creating `.agents/skills/<name>/SKILL.md` and adding a row
above. There is no wiring step, and no harness needs a config change.

## Validation boundary

Offline behavior (catalog composition, release planning, fixture-mode suites,
image plan mode, CVE plan mode) is verified by `make test`. Target-platform
behavior — native concretization, release builds and promotion,
shared-filesystem atomicity, cache publication, module execution, hardware
tiers, source-lock completion, Enroot image operations, publication — is not
validated here and requires explicit operator approval on Ubuntu 24.04/Slurm.
Never claim plan/fixture tests prove target behavior.

Before any future commit, inspect status/diff/log, split changes by review
context, enable the commit-msg hook without bypass, and present staged groups
for approval. Keep documentation/skills separate from behavior/config unless
inseparable.
