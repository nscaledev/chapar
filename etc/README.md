# Chapar configuration: scopes and site settings

Two kinds of configuration live under `etc/`: persistent Spack scopes
(`etc/system`, `etc/user`) and the site settings machinery that resolves
every `CHAPAR_*` variable (`chapar-defaults.sh`, `chapar-site.env`).

## Scope layout and precedence

Spack configuration layers, lowest to highest precedence:

```
Spack defaults  →  etc/system  →  etc/user  →  build command-line scope
```

- **`etc/system/`** declares only what the OS provides: the bootstrap
  compiler external, libc, and the requirement that lets a bootstrap install
  use that compiler (`etc/system/<os>/packages.yaml`). `include.yaml` selects
  the OS overlay with Spack's own `when: os == "<id>"` condition —
  `ubuntu24.04` today, `linux` as an empty fallback, `base` always. Nothing
  architecture-shaped belongs here; architecture comes from the target
  registry (`docs/targets.md`).
- **`etc/user/`** carries policy expressed against `$CHAPAR_*` variables —
  the install-tree root and projection, build-stage list, module defaults.
  Spack leaves an undefined `$VAR` literal in scope YAML, which is why
  `chapar-defaults.sh` exports every interpolated variable unconditionally.
- **The command-line scope** is rendered per build by
  `envs/software/release.sh`: the concrete install tree with its padding, the
  run's build stage, seed and writable mirrors, module roots, and the
  per-target package requirements from `chapar target scope`. It exists only
  for the build and is archived in the release (`target-scope.yaml`).

`etc/init.sh` and `release.sh` pin `SPACK_SYSTEM_CONFIG_PATH`/
`SPACK_USER_CONFIG_PATH` at these directories, so `~/.spack` and `/etc/spack`
never leak into a Chapar build. `etc/link-scopes.sh [--all|--user|--system]`
optionally symlinks those ambient locations here too, backing up any existing
non-symlink destination.

Two settled scope decisions: `config:shared_linking` stays `type: rpath` with
`bind: false` (RPATH outranks a container's `LD_LIBRARY_PATH`, and binding
absolute library paths would be wrong for a stack whose `libcuda.so.1`
arrives at run time — see `docs/container-injection.md`), and the install
tree projection keeps its architecture component so multi-target stores and
container injection can select one architecture's subtree.

## Site settings resolution

`etc/chapar-defaults.sh` is sourced (never executed) by every consumer —
`etc/init.sh`, `etc/profile.d/zz-chapar.sh`, `envs/software/release.sh`,
`validation/run`, and the `ci/` scripts — so they all derive identical
values. Resolution order, highest to lowest:

1. Variables already exported by the caller.
2. The site file: `${CHAPAR_SITE_CONFIG}` if set (unreadable is fatal),
   otherwise `etc/chapar-site.env` (optional; example committed as
   `etc/chapar-site.env.example`, installer at `etc/install-site-settings.sh`).
3. Built-in defaults: a private per-user layout under `~/.spack/chapar`.

After identity is final, a site-declared `chapar_site_target_policy()` runs
for per-tuple delivery and Slurm placement; then everything is validated
(absolute traversal-free paths, allowed word lists, no overlap with the
immutable legacy roots `/resources/chapar/*`) and exported. Failures return
non-zero without exiting the sourcing shell. `bash etc/tests/site-env-test.sh`
checks the defaulting, layering, policy, and guard behavior offline.

## Variable table

Identity and roots:

| Variable | Default | Meaning |
|---|---|---|
| `CHAPAR_SITE_CONFIG` | unset | Alternative site-file location. |
| `CHAPAR_SOFTWARE_SET` | `all` | `vlad`, `hpcsim`, or `all`. |
| `CHAPAR_TARGET` | empty | Key of `containers/images/targets.json`; required for builds, images, validation. |
| `CHAPAR_INSTALL_MODE` | `home` | `home` or `public`. |
| `CHAPAR_HOME_ROOT` | `~/.spack/chapar` | Private root for `home` mode. |
| `CHAPAR_PUBLIC_ROOT` | empty | Shared root; required in `public` mode. |
| `CHAPAR_ENV_ROOT` | derived | The active root (home or public). |
| `CHAPAR_INSTALL_TREE_ROOT` | `$CHAPAR_ENV_ROOT/store` | Shared padded Spack store. |
| `CHAPAR_RELEASE_ROOT` | `$CHAPAR_ENV_ROOT/releases` | Immutable releases: `<set>/<target>/<id>` + `current`. |
| `CHAPAR_MODULE_ROOT` | `$CHAPAR_ENV_ROOT/modulefiles` | Published modules: `<set>/<target>/{<id>,current}`. |
| `CHAPAR_BUILDCACHE_ROOT` | `$CHAPAR_ENV_ROOT/cache/buildcache` | Writable binary cache, `/<target>` namespaced. |
| `CHAPAR_CCACHE_ROOT` | `$CHAPAR_ENV_ROOT/cache/ccache` | Shared compiler cache, `/<target>` namespaced. |
| `CHAPAR_BUILD_STAGE_ROOT` | `$TMPDIR/$USER/chapar-stage` | Scratch build stage (node-local is best). |
| `CHAPAR_CONTAINER_OUTPUT_ROOT` | `$CHAPAR_ENV_ROOT/images` | Exported `.sqsh` images and receipts. |
| `CHAPAR_VALIDATION_ROOT` | `$CHAPAR_ENV_ROOT/validation` | Validation results. |
| `CHAPAR_SEED_MIRRORS` | empty | Space-separated read-only seed buildcaches. |
| `CHAPAR_SHARED_GROUP` / `CHAPAR_SHARED_DIR_MODE` | empty / `2775` | Optional group/mode for public roots. |

Policy and publication:

| Variable | Default | Meaning |
|---|---|---|
| `CHAPAR_MODULE_SYSTEMS` | `tcl` | Module systems to generate; `tcl` mandatory, `lmod` optional. |
| `CHAPAR_CCACHE_COMPILERCHECK` | `content` | ccache compiler-check mode. |
| `CHAPAR_CCACHE_MAXSIZE` | empty | Optional ccache size cap. |
| `PUBLISH_BUILDCACHE` | `false` | Gates buildcache autopush and `ci/push-buildcache.sh --execute`. |
| `PUBLISH_CURRENT` | `false` | Gates `release.sh promote`. |
| `PUBLISH_MODULES` | `false` | CI intent flag for module publication. |

Per-tuple policy (set by `chapar_site_target_policy()`, defaulted afterwards):

| Variable | Default | Meaning |
|---|---|---|
| `CHAPAR_DELIVER` | `modules` | Word list `modules` and/or `container`; gates `release.sh publish-modules` and `chapar image build`. |
| `CHAPAR_CONTAINER_BASE` | empty | `containers.json` key; required when `CHAPAR_DELIVER` contains `container`. |
| `CHAPAR_SLURM_PARTITION` / `_CONSTRAINT` / `_ACCOUNT` / `_QOS` | empty | Slurm placement for build and validation submission; empty means no flag. |

Not resolved by the defaults but recognized elsewhere: `CHAPAR_SPACK_ROOT`
(Spack checkout, `etc/init.sh`), `CHAPAR_RUN_ID` (overrides the generated
build run ID, `release.sh`), `CHAPAR_PROFILE_DISABLE` (skips the profile
hook), and the validation-run knobs listed in `docs/validation.md`.

## Shell entry points

- **`etc/init.sh`** (interactive; `source` it): resolves site settings, finds
  Spack (installing hint via `etc/install-spack.sh`), pins the repository
  scopes and a temporary user cache, configures per-target ccache variables,
  and runs `module use` on the promoted `current` module tree for the
  configured tuple — warning when nothing is promoted yet.
- **`etc/profile.d/zz-chapar.sh`** (login shells): the same defaults
  resolution, then only the `module use`, silently; it never aborts or spams
  a login shell that has no site settings or promoted release.
- **`etc/install-site-settings.sh`** (root): validates a site file against
  `chapar-defaults.sh` in a clean environment, then installs it atomically to
  `/etc/chapar/site.env` (mode 0644, root-owned) for `CHAPAR_SITE_CONFIG`
  consumers, including systemd units.

`etc/chapar-install-tree.sh` holds the shared install-tree padding helpers
(`docs/building.md`), and `etc/systemd/` plus `etc/cve-checker.env.example`
belong to the CVE checker deployment (`docs/cve.md`).
