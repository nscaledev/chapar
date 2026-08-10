---
name: chapar-vlad-image
description: Modify or debug the Chapar container-image pipeline — planning, injection, preflight, registries, source custody, or publication. Use for chapar image and containers/images work.
---

# Chapar image pipeline

The pipeline is `chapar image` (`src/chapar/image/`): `resolve`, `preflight`,
`build`, `verify-release`, `publish`. It consumes a verified immutable
release directory (`--release-dir`) and the committed registries —
`containers/images/targets.json` (target facts), `containers.json`
(digest-pinned bases; public IDs stay `nvidia-vlad` and `ubuntu-hpcsim`),
and `sources-lock.json` (source custody).

`sources-lock.json` is globally `blocked`: no real image build, import,
export, or publication until every category and platform descriptor is
resolved and approved. A resolved category never overrides the global block.
`--plan-only` is the only mode useful on a workstation — pure reads.

Preserve the injection invariants (`docs/container-injection.md`): store
prefixes copied at their identical absolute paths under `/opt/chapar`,
link/run closure complete, the base rootfs additive-only and provably
undisturbed, modules opt-in. Delivery requires `container` in
`CHAPAR_DELIVER` unless `--force`. Sealed images go through
`chapar image publish` with expected sha256/size.

Test with `uv run --group dev pytest tests/image`. Enroot operations,
per-architecture preflight, and container smoke are operator gates.
