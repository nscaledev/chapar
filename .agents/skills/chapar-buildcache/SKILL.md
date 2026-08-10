---
name: chapar-buildcache
description: Modify or debug Chapar buildcache planning, seed mirrors, publication, or migration policy.
---

# Chapar buildcache

The writable buildcache lives at `${CHAPAR_BUILDCACHE_ROOT}/<target>`, one
per target. Read-only seed mirrors are the site's opt-in
`CHAPAR_SEED_MIRRORS` list — never derived from `/resources/chapar`, whose
legacy caches stay immutable. Autopush from a build follows
`PUBLISH_BUILDCACHE=true`; the default is no publication.

`ci/push-buildcache.sh --release-dir <release>` is plan-by-default:
`--execute` pushes the verified release's roots to the site cache and again
requires `PUBLISH_BUILDCACHE=true`. Migration from a legacy cache is
plan-only via `release.sh migrate-buildcache <id> --legacy-source <path>` —
any future execution must stay copy-only, non-overwriting, non-deleting,
and separately approved.

Binary reuse depends on padding continuity: `etc/chapar-install-tree.sh`
detects the placeholder depth an existing store commits to and reproduces
it, so never bypass its helpers when rendering a scope. Real publication,
index refresh, and reuse verification are operator gates on a builder.
