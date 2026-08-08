# Selection-aware validation architecture

Validation consumes resolver output, not an environment name or architecture
directory scan. `validation/selection.py` verifies `selection.json`, its exact
digest, and the target contract, then derives:

- canonical data-center/software-set/target identity;
- release/run result namespace;
- one exact module tree;
- exact selected root inventory and root-specific checks;
- contract partition, constraint, account, and QoS.

Mixed paths, unknown targets, missing roots, digest mismatch, or contract drift
fail before submission or module loading. Integrity remains hardware-free:
module availability, basic executable/version behavior, shared-library
resolution, and language-runtime checks. Hardware/interconnect tiers preserve
exit 77 as SKIP and existing PASS/WARN/FAIL/SKIP JSON and Prometheus formats.

## Suite result contract

Ten suites are bound to a shared result contract in `validation/lib`. A bound
suite calls `validation_result_init`, records outcomes through `verdict.sh`, and
exits; the installed EXIT trap writes `summary.json`, `suite.prom`, and a
schema-checked `suite-manifest.json`, then converts the verdict into the exit code
(`PASS`/`WARN` 0, `FAIL` 1, `SKIP` 77). Verdict escalation is monotone, so no later
check can clear an earlier failure, and the command's own exit status outranks an
optimistic recorded verdict.

Provenance is what makes the manifest useful. A local run gets a generated
`manual-` run id and `ci_authoritative: false`. A CI runner must supply
`VALIDATION_RUN_ID` and a timezone-aware `VALIDATION_RUN_ISSUED_AT`; stale, naive,
future, and re-used identities are refused. Schema validity alone does not make
evidence authoritative — a manual manifest is schema-valid by design — so CI
consumers must use `validation_result_validate_runner_manifest`. Suites never write
tier manifests: only a post-job collector with `sacct` authority can, which is why
a suite manifest records an outcome and nothing about scheduler state.

Suites outside the bound list keep their own JSON and Prometheus artifacts. The
list in `result-manifest.sh` must stay equal to the `suite` enum in
`result-manifest.schema.json`.

## Offline hardware fixtures

Hardware suites are exercisable without hardware. In fixture mode a suite loads
recorded observations from a JSON manifest instead of probing, and the evaluator
below that branch is identical either way; a fixture also declares its own expected
verdict, so it asserts a result rather than merely exercising a path.

Injection follows the discipline `containers/images/preflight.sh` established:
fixtures apply only when `VALIDATION_TEST_MODE=1`, every override name is
allowlisted so a typo cannot leave a suite probing real hardware, an override set
outside test mode is fatal so fixture plumbing cannot reach a production run, and
the fixture root must be a real, owner-only, symlink-free directory owned by the
caller. Each harness also stubs schedulers and hardware tools onto `PATH` and
asserts none was invoked.

Hardware expectations live in tracked `validation/config/capability.yaml` beside
`network.yaml` — never in an ambient site file or environment variable, which
`AGENTS.md` and `etc/README.md` both refuse.

The canonical disposable flow is in `README.md`. Its dry run exercises plan
rendering only; it does not submit Slurm, load a module, or touch target paths.
`/resources/chapar/vlad` and `/resources/chapar/hpcsim` remain immutable legacy
shadow/canary roots and are never validation discovery inputs.

Future platform approval is required for Slurm placement and every integrity,
GPU, RDMA, MPI, NCCL, I/O, topology, or performance execution. Offline contract
and selection behavior is verified; target-platform behavior not validated.
