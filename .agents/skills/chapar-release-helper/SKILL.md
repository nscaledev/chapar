---
name: chapar-release-helper
description: Modify or debug the Chapar release helper at envs/software/release.sh, including plan, staged builds, promotion, module publication, and release metadata.
---

# Chapar release helper

`envs/software/release.sh` is site-settings-bound: identity
(`CHAPAR_SOFTWARE_SET`, `CHAPAR_TARGET`, overridable with `--set/--target`)
and every path root come from `etc/chapar-defaults.sh`; target facts come
from `containers/images/targets.json`. `plan` is always safe and is the only
subcommand to run in an agent session.

Preserve the invariants: staging directory atomically renamed to the
immutable `${CHAPAR_RELEASE_ROOT}/<set>/<target>/<release-id>`; the two-pass
ccache bootstrap (OS-compiler ccache with `config:ccache` false, then true —
two ccache installs are correct); hash-free `{name}/{version}` root modules;
`current` as the only mutable pointer, moved by `promote`; release-local
`spack.lock` + `metadata.json` (schema v2) as the release's complete
self-description verified by `chapar.common.release`.

Keep the delivery gates intact: `publish-modules` requires `modules` in
`CHAPAR_DELIVER`, `promote` requires `PUBLISH_CURRENT=true`, buildcache
publication requires `PUBLISH_BUILDCACHE=true`.

Test with `bash envs/software/tests/release-helper-plan-test.sh` (also run
by `make test`). Real builds, promotion, and module publication are operator
gates on a builder; never claim a plan proved them.
