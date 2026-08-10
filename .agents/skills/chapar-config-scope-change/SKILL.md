---
name: chapar-config-scope-change
description: Modify Chapar persistent Spack scopes under etc/system or etc/user, or the site settings machinery in etc/chapar-defaults.sh and etc/chapar-site.env.example.
---

# Chapar configuration scope and site settings change

`etc/system/<os>/` declares only what the OS provides: the bootstrap compiler
external, libc, and the requirement letting a bootstrap install use it.
`etc/user/` carries paths and policy as `$CHAPAR_*` interpolations — Spack
leaves an undefined `$VAR` literal in scope YAML, so `etc/chapar-defaults.sh`
must unconditionally export every variable `etc/user` interpolates.

Site values live in `etc/chapar-site.env` (never committed; example at
`etc/chapar-site.env.example`, alternate location via `CHAPAR_SITE_CONFIG`).
Resolution order: caller-exported variables, then the site file, then
built-in defaults. Per-tuple delivery and Slurm placement come from the
site's `chapar_site_target_policy()`.

Preserve the path guards in `chapar-defaults.sh`: every root absolute,
traversal-free, and disjoint from the immutable `/resources/chapar` legacy
roots. Keep OS scopes free of ordinary link-time libraries and keep the
catalog OS-free.

Test with `bash etc/tests/site-env-test.sh` (also run by `make test` via
`tests/shell`). Native concretization against changed scopes is an operator
gate.
