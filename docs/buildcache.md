# Chapar Buildcache And ccache Policy

Chapar uses one configured Spack binary buildcache root and one compiler ccache
root for Chapar environments. hpcsim can configure both in the ignored local
`envs/hpcsim/hpcsim-site.env` file copied from
`envs/hpcsim/hpcsim-site.env.example`.

```text
${CHAPAR_BUILDCACHE_ROOT}/rocky9
${CHAPAR_BUILDCACHE_ROOT}/rocky10
${CHAPAR_CCACHE_ROOT}/rocky9
${CHAPAR_CCACHE_ROOT}/rocky10
```

By default, `CHAPAR_SHARED_CACHE_ROOT` is `~/.spack/chapar/cache`, with
buildcache and ccache roots below it as `buildcache` and `ccache`. Use different
cache roots for clusters or datacenters that should not share artifacts. Sharing
cache roots across incompatible security boundaries can leak paths, compiler
metadata, and binary artifacts.

## Scope Placement

Keep the buildcache mirror in Chapar Spack scopes, not in `envs/hpcsim/spack.yaml`.

The Rocky system scopes define the same mirror name, `chapar-buildcache`, with
URLs rooted at `${CHAPAR_BUILDCACHE_ROOT}/<os>`. This makes the cache visible to:

- release builds driven by `envs/hpcsim/release.sh`
- generic sbatch builds submitted by `ci/submit-env-build.sh` or directly
  through `ci/sbatch-env-build.sh`
- future Chapar environments that inherit the same scopes

Release builds generate a temporary command-line scope with the same mirror name.
That scope points to the same cache location but controls `autopush` through
`PUBLISH_BUILDCACHE`. This prevents lower-precedence persistent scope settings
from forcing release jobs to publish when the operator explicitly disables cache
publishing.

Do not move this mirror into an environment file unless the desired behavior is
for only that one environment to see the cache. The intended behavior is broader:
all trusted Chapar installs at the same site should share the cache.

## Mirror Semantics

The mirror uses:

```yaml
source: false
binary: true
signed: false
autopush: true
```

`source: false` keeps `${CHAPAR_BUILDCACHE_ROOT}/<os>` dedicated to Spack binary
cache metadata and binary tarballs. Source mirrors and downloaded source archives
should not be mixed into this binary cache.

`signed: false` matches the current Chapar publishing model, which uses unsigned
buildcache pushes. Do not flip this to `true` without a key rollout plan that
creates signing keys, signs publisher output, installs and trusts public keys on
all builders/users, and defines whether ordinary users are allowed to sign shared
cache entries.

`autopush: true` means ordinary user installs using these scopes can publish
successful builds into the shared cache. This requires trusted filesystem
permissions. The security boundary is the site cache directory ACL/group
membership. If that trust model changes, make user paths read-only and keep
publishing limited to release builders.

## Shared ccache

`etc/init.sh`, `envs/hpcsim/release.sh`, and the sbatch helpers export:

```text
CCACHE_DIR=${CHAPAR_CCACHE_ROOT}/<os>
CCACHE_TEMPDIR=<job-local temp directory>
CCACHE_UMASK=002
CCACHE_COMPILERCHECK=${CHAPAR_CCACHE_COMPILERCHECK:-content}
```

Keep `CCACHE_TEMPDIR` job-local. Do not put ccache temporary files on the shared
ccache root; concurrent compilers on network filesystems should only share the
finished cache entries.

Set `CHAPAR_CCACHE_MAXSIZE` in `envs/hpcsim/hpcsim-site.env` to cap each
OS-specific ccache directory. The release helper applies it with
`ccache --max-size` when `ccache` is available.

## One-Time Migration

`envs/hpcsim/release.sh build` does not automatically migrate legacy cache
contents. Run migration explicitly when retiring an old cache directory for the
selected `HPCSIM_ROOT`:

```bash
OS_NAME=rocky9 envs/hpcsim/release.sh migrate-buildcache
OS_NAME=rocky10 envs/hpcsim/release.sh migrate-buildcache
```

The explicit migration is intentionally conservative:

- It copies from the selected legacy cache path into `${CHAPAR_BUILDCACHE_ROOT}/<os>`.
- It requires the source cache to carry Chapar's current padded install-tree
  layout marker. Unmarked pre-padding caches are not migrated by default because
  they can fail relocation with `CannotGrowString`.
- It never deletes old cache directories.
- It does not overwrite destination files.
- It uses an atomic NFS-safe lock directory at `<cache>.migration.lock`.
- It refreshes the buildcache index after copying so the next install can reuse
  migrated binaries.
- It writes `.legacy-buildcache-migration-complete` in the destination so repeat
  invocations become no-ops unless `--force` is used.

The legacy source path checked by the release helper is:

```text
<hpcsim_root>/<os>/buildcache
```

Set `HPCSIM_ROOT` to the release root being retired before running migration. Do
not copy binary caches built under a different install root into the current cache
unless you have validated that their prefixes are relocatable.

Current hpcsim release builds use `install_tree.padded_length: 256`. If the
destination cache already contains unmarked pre-padding payloads, the release
helper quarantines `blobs`, `v3`, and legacy index payloads under a hidden
`.incompatible-install-tree-padded-256-*` directory before using the cache. This
preserves old files for audit while preventing Spack from selecting binaries that
cannot relocate into the padded store.

After a successful one-time migration and verification build, retire old cache
directories manually so future runs cannot accidentally reuse stale artifacts.

## Admin Setup

Prepare the shared release root, cache roots, and any optional shared
install/module roots with trusted group ownership and setgid permissions before
enabling broad user autopush. The current public hpcsim layout uses
`HPCSIM_PUBLIC_ROOT=/share/base`, an empty `CHAPAR_INSTALL_TREE_ROOT`, and
`CHAPAR_MODULE_ROOT=/share/base/modulefiles`:

```bash
mkdir -p "${HPCSIM_PUBLIC_ROOT}"
mkdir -p "${HPCSIM_PUBLIC_ROOT}/rocky9/releases" "${HPCSIM_PUBLIC_ROOT}/rocky10/releases"
mkdir -p "${HPCSIM_PUBLIC_ROOT}/rocky9/store" "${HPCSIM_PUBLIC_ROOT}/rocky10/store"
mkdir -p "${CHAPAR_BUILDCACHE_ROOT}/rocky9" "${CHAPAR_BUILDCACHE_ROOT}/rocky10"
mkdir -p "${CHAPAR_CCACHE_ROOT}/rocky9" "${CHAPAR_CCACHE_ROOT}/rocky10"
[ -n "${CHAPAR_INSTALL_TREE_ROOT:-}" ] && mkdir -p "${CHAPAR_INSTALL_TREE_ROOT}"
[ -n "${CHAPAR_MODULE_ROOT:-}" ] && mkdir -p "${CHAPAR_MODULE_ROOT}"
chgrp -R <trusted-chapar-group> "${HPCSIM_PUBLIC_ROOT}"
chmod -R g+rwX "${HPCSIM_PUBLIC_ROOT}"
find "${HPCSIM_PUBLIC_ROOT}" -type d -exec chmod 2775 {} +
chgrp -R <trusted-chapar-group> "${CHAPAR_BUILDCACHE_ROOT}" "${CHAPAR_CCACHE_ROOT}"
chmod -R g+rwX "${CHAPAR_BUILDCACHE_ROOT}" "${CHAPAR_CCACHE_ROOT}"
find "${CHAPAR_BUILDCACHE_ROOT}" "${CHAPAR_CCACHE_ROOT}" -type d -exec chmod 2775 {} +
[ -n "${CHAPAR_INSTALL_TREE_ROOT:-}" ] && chgrp -R <trusted-chapar-group> "${CHAPAR_INSTALL_TREE_ROOT}"
[ -n "${CHAPAR_INSTALL_TREE_ROOT:-}" ] && chmod -R g+rwX "${CHAPAR_INSTALL_TREE_ROOT}"
[ -n "${CHAPAR_INSTALL_TREE_ROOT:-}" ] && find "${CHAPAR_INSTALL_TREE_ROOT}" -type d -exec chmod 2775 {} +
[ -n "${CHAPAR_MODULE_ROOT:-}" ] && chgrp -R <trusted-chapar-group> "${CHAPAR_MODULE_ROOT}"
[ -n "${CHAPAR_MODULE_ROOT:-}" ] && chmod -R g+rwX "${CHAPAR_MODULE_ROOT}"
[ -n "${CHAPAR_MODULE_ROOT:-}" ] && find "${CHAPAR_MODULE_ROOT}" -type d -exec chmod 2775 {} +
```

Use the group that represents users and builders allowed to publish shared binary
artifacts and shared ccache entries. The release helper and preparation script
can also create these directories when `CHAPAR_SHARED_GROUP` and
`CHAPAR_SHARED_DIR_MODE` are set in `envs/hpcsim/hpcsim-site.env` and the
current user has permission.
