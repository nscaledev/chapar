---
name: chapar-validation
description: Modify or debug release-bound Chapar validation plans, suites, fixture mode, result manifests, verdicts, or result placement under validation/.
---

# Chapar validation

Validation binds to one immutable release directory: `uv run chapar validate
plan --release-dir <release>` verifies digests/identity/target facts and
derives the module tree and expected root inventory from the release itself;
`./validation/run --release-dir <release> <suite>|all|list` dispatches the
sbatch suites; `uv run chapar validate analyze` does outlier analysis of a
suite's results directory. Results land under `CHAPAR_VALIDATION_ROOT`,
namespaced by tuple, release, and run id (site settings supply the root and
`CHAPAR_SLURM_*`; `CHAPAR_DRY_RUN=1` prints instead of submitting).

Suites record outcomes through `verdict.sh` and let
`validation_result_finalize` own the exit code (PASS/WARN 0, FAIL 1, SKIP
77); never write a verdict or exit status by hand. The result-manifest
contract (`validation/lib/result-manifest.schema.json`) includes the release
identity block — recorded from the release's `metadata.json` plus the
run-time `spack.lock` digest, all-or-nothing so evidence never names half a
release. Keep the bound-suite list in `result-manifest.sh` equal to the
schema's `suite` enum. Hardware expectations belong in tracked
`validation/config/capability.yaml`.

Every hardware suite must stay runnable offline through its
`validation/fixtures/` cases with `VALIDATION_TEST_MODE=1`; `make test` runs
those fixture suites. Offline fixtures prove the evaluators, never a GPU, a
fabric, or a filesystem — real runs are operator gates.
