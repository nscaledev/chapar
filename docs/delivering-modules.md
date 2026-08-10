# Delivering modules

How a built release becomes the module tree users see, and how to roll back.

## Layout and pointer semantics

```
${CHAPAR_MODULE_ROOT}/<set>/<target>/
  <release-id>   symlink to the modulefiles/<arch> directory of that release
  current        symlink to <release-id>: the promoted release
```

Releases are immutable; the two symlinks are the only mutable state. Module
names are hash-free `{name}/{version}` (for example `openmpi/5.0.7`), so a
promotion changes which release backs a name without changing the name.

The same pointer pair exists under the release root:
`${CHAPAR_RELEASE_ROOT}/<set>/<target>/current` names the promoted release
directory itself, which is what validation and image tooling default to.

## Publish

`publish-modules` links `${CHAPAR_MODULE_ROOT}/<set>/<target>/<release-id>` to
the release's single architecture directory. It requires the site delivery
policy for the tuple to include `modules` (`CHAPAR_DELIVER`, see
`etc/README.md`):

```bash
bash envs/software/release.sh publish-modules 20260809a --set vlad --target linux-x86_64-v4
```

This makes the release loadable by explicit path without affecting anyone
using `current`.

## Promote

`promote` repoints `current` — both the release-root pointer and, when the
release has published modulefiles, the module-root pointer. It is gated by
`PUBLISH_CURRENT=true` so a site can forbid ad-hoc promotion:

```bash
PUBLISH_CURRENT=true bash envs/software/release.sh promote 20260809a --set vlad --target linux-x86_64-v4
```

The links are replaced atomically (symlink to a temporary name, then rename),
so a reader never sees a missing `current`.

`build --promote` chains build, publish-modules (when the delivery policy
includes modules), and promote in one run.

## Rollback

Rollback is promotion of the previous release — no rebuild, no file moves:

```bash
PUBLISH_CURRENT=true bash envs/software/release.sh promote 20260808a --set vlad --target linux-x86_64-v4
```

Shells that resolved `current` before the repoint keep the release they
resolved; new shells get the repointed one.

## Consuming modules

Print the exact `module use` line for one release:

```bash
bash envs/software/release.sh module-use 20260809a --set vlad --target linux-x86_64-v4
```

Follow the promoted release instead:

```bash
module use "$CHAPAR_MODULE_ROOT/vlad/linux-x86_64-v4/current"
module avail
```

Login shells pick the promoted release up automatically through either of:

- `source etc/init.sh` — interactive setup: resolves site settings, binds the
  repository Spack scopes, configures ccache, and runs `module use` on the
  `current` pointer for the configured `<set>/<target>` (warns if nothing is
  promoted yet).
- `etc/profile.d/zz-chapar.sh` — a host-wide profile hook that does only the
  `module use`, silently, and never aborts a login shell. Set
  `CHAPAR_PROFILE_DISABLE=1` to opt a shell out.

Both go through `etc/chapar-defaults.sh`, so they agree with builds about
every path.

## Module systems

`CHAPAR_MODULE_SYSTEMS` (default `tcl`) chooses which module trees the build
generates; `tcl` is mandatory and `lmod` may be added:

```bash
CHAPAR_MODULE_SYSTEMS="tcl lmod" bash envs/software/release.sh build 20260809a --set vlad --target linux-x86_64-v4
```

tcl modules land in `<release>/modulefiles/<arch>`, lmod in `<release>/lmod`.
Publication and the `current` pointers cover the tcl tree; generated modules
never autoload dependencies and never carry hashes in their names.
