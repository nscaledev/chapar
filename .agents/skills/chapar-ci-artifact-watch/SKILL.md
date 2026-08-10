---
name: chapar-ci-artifact-watch
description: Inspect live Chapar build or validation artifacts and progress when an operator supplies a release directory and site settings.
---

# Chapar artifact watch

There is no GitHub Actions workflow; live artifacts exist only where an
operator has run `release.sh`, `make submit`, `chapar image build`, or
`validation/run` against explicit site settings. Do not invent an artifact
root: use the release directory the operator names, or derive roots from the
site settings they supply (`etc/chapar-defaults.sh` resolution). The
immutable legacy roots `/resources/chapar/vlad` and
`/resources/chapar/hpcsim` are never current desired state.

Know the layout: releases at `${CHAPAR_RELEASE_ROOT}/<set>/<target>/<id>`
(immutable; `current` is the promotion pointer; `metadata.json` + release
`spack.lock` are the identity — verify before trusting), build/submission
logs under the repository `slogs/`, module trees under
`${CHAPAR_MODULE_ROOT}`, image outputs and receipts under
`${CHAPAR_CONTAINER_OUTPUT_ROOT}`, validation results under
`${CHAPAR_VALIDATION_ROOT}` namespaced by tuple/release/run id.

Distinguish process/timestamp churn from advancing immutable artifacts.
Watching is read-only: do not submit, retry, promote, publish, clean, or
repair without new authorization, and report identity or digest mismatches
as blockers rather than working around them.
