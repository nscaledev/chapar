# Site onboarding

Setting up Chapar on a new machine — a workstation or a cluster login/build
node. Everything machine-specific lives in one site settings file; the
repository itself is identical everywhere.

## 1. Install the tools

```bash
git clone <chapar-repo-url> chapar && cd chapar
curl -LsSf https://astral.sh/uv/install.sh | sh    # uv runs the CLI and tests
bash etc/install-spack.sh                          # Spack to ~/.local/opt/spack
```

`CHAPAR_SPACK_ROOT` relocates the Spack checkout; `SPACK_REF` pins a ref.

## 2. Create the site settings

```bash
cp etc/chapar-site.env.example etc/chapar-site.env
"${EDITOR:-vi}" etc/chapar-site.env
```

The file is sourced bash. Every assignment uses `: "${VAR:=value}"`, so a
variable you export in the environment wins over the site file, and the site
file wins over the built-in defaults. Work through the groups:

- **Identity** — `CHAPAR_SOFTWARE_SET` (`vlad`|`hpcsim`|`all`) and
  `CHAPAR_TARGET` (a key of `containers/images/targets.json`, see
  `docs/targets.md`). Deliberate choices, never probed from the machine; an
  interactive shell may leave the target unset until needed.
- **Roots** — `CHAPAR_INSTALL_MODE=home` (default) keeps everything under
  `CHAPAR_HOME_ROOT` (`~/.spack/chapar`), safe for a workstation. For a
  cluster set `CHAPAR_INSTALL_MODE=public` and
  `CHAPAR_PUBLIC_ROOT=/shared/chapar` (or similar).
- **Derived per-root overrides** — store, releases, modules, buildcache,
  ccache, build stage, container output, and validation roots each default
  under the chosen root and can be overridden individually
  (`CHAPAR_INSTALL_TREE_ROOT`, `CHAPAR_RELEASE_ROOT`, … — full table in
  `etc/README.md`). A node-local `CHAPAR_BUILD_STAGE_ROOT` is worth setting
  on clusters.
- **Seed mirrors** — `CHAPAR_SEED_MIRRORS`: space-separated absolute paths of
  read-only binary caches consulted before building.
- **Policy** — `CHAPAR_MODULE_SYSTEMS` (`tcl`, optionally plus `lmod`),
  ccache tuning, and the publication defaults `PUBLISH_BUILDCACHE`,
  `PUBLISH_CURRENT`, `PUBLISH_MODULES` (all default `false`; operators or CI
  set them per action).
- **Per-tuple policy** — declare `chapar_site_target_policy()` to vary
  delivery and Slurm placement by software set and target. It runs after the
  identity is final. A worked multi-target example:

```bash
chapar_site_target_policy() {
    case "${CHAPAR_SOFTWARE_SET}:${CHAPAR_TARGET}" in
        vlad:linux-aarch64-gb300)
            CHAPAR_DELIVER="modules container"   # both, from the same build
            CHAPAR_CONTAINER_BASE=nvidia-vlad    # required with "container"
            CHAPAR_SLURM_PARTITION=gb300
            CHAPAR_SLURM_CONSTRAINT=gb300
            ;;
        vlad:linux-x86_64-*)
            CHAPAR_DELIVER="modules"
            CHAPAR_SLURM_PARTITION=gpu
            ;;
        hpcsim:*)
            CHAPAR_DELIVER="modules"
            CHAPAR_SLURM_PARTITION=cpu
            ;;
        *)
            CHAPAR_DELIVER="modules"
            ;;
    esac
    CHAPAR_SLURM_ACCOUNT=hpc
    CHAPAR_SLURM_QOS=normal
}
```

If the function is absent, every tuple gets `CHAPAR_DELIVER="modules"` and no
Slurm placement.

## 3. Bind a shell and check

```bash
source etc/init.sh
uv run chapar target list
bash envs/software/release.sh plan smoketest --set vlad --target linux-x86_64-v4
```

The plan prints every resolved path; nothing is created.

## 4. Optional: machine-wide settings

To serve all users (and systemd services) from one root-owned file instead of
a per-checkout copy:

```bash
sudo bash etc/install-site-settings.sh --source etc/chapar-site.env
# installs to /etc/chapar/site.env (override with --destination)
export CHAPAR_SITE_CONFIG=/etc/chapar/site.env   # in profiles or unit files
```

The installer validates the file against `etc/chapar-defaults.sh` in a clean
environment before installing it atomically; a broken file never becomes
machine state. Consumers resolve `CHAPAR_SITE_CONFIG` first, then the
checkout's `etc/chapar-site.env`, then built-in defaults.

To make the repository's Spack scopes the ambient ones for plain `spack`
invocations (optional — `etc/init.sh` and builds already pin them):

```bash
bash etc/link-scopes.sh --user        # ~/.spack -> etc/user
sudo bash etc/link-scopes.sh --system # /etc/spack -> etc/system
```

Existing non-symlink destinations are backed up with a timestamp.

## Misconfiguration fails closed

`etc/chapar-defaults.sh` validates everything at resolution time and refuses
to continue on: an unknown software set or install mode; `public` mode
without `CHAPAR_PUBLIC_ROOT`; any root that is not an absolute, traversal-free
path; a `CHAPAR_MODULE_SYSTEMS` or `CHAPAR_DELIVER` entry outside the allowed
words (and `container` without `CHAPAR_CONTAINER_BASE`); a
`CHAPAR_SITE_CONFIG` that points at an unreadable file. Any root or seed
mirror that equals or overlaps `/resources/chapar` is rejected outright —
those are immutable legacy roots and no new state may touch or derive from
them. `bash etc/tests/site-env-test.sh` exercises these refusals offline.
