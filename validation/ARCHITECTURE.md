# Release-bound validation architecture

Validation consumes one immutable release directory, not an environment name
or an architecture directory scan. `chapar validate plan` (called by
`validation/run` for every suite) verifies the release — its `metadata.json`
digests against the bytes on disk, its directory name against the recorded
release ID so a mutable `current` pointer is refused, and its recorded target
facts against the committed registry — then derives:

- canonical software-set/target/release identity;
- the release/validation-run result namespace;
- one exact module tree (the release's own `modulefiles/<arch>`);
- the expected root inventory and root-specific checks from the release-local
  `spack.lock` — the roots that were actually built, not what a catalog
  promised;
- Slurm placement from the site settings (`CHAPAR_SLURM_*`), which also
  supply the results root (`CHAPAR_VALIDATION_ROOT`); site settings
  contribute only what is not a release fact.

A missing or tampered release file, an unknown target, or diverged target
facts fail before submission or module loading. Integrity remains
hardware-free: module availability, basic executable/version behavior,
shared-library resolution, and language-runtime checks. Hardware/interconnect
tiers preserve exit 77 as SKIP and the existing PASS/WARN/FAIL/SKIP JSON and
Prometheus formats.

## Suite result contract

Ten suites are bound to a shared result contract in `validation/lib`. A bound
suite calls `validation_result_init`, records outcomes through `verdict.sh`, and
exits; the installed EXIT trap writes `summary.json`, `suite.prom`, and a
schema-checked `suite-manifest.json`, then converts the verdict into the exit code
(`PASS`/`WARN` 0, `FAIL` 1, `SKIP` 77). Verdict escalation is monotone, so no later
check can clear an earlier failure, and the command's own exit status outranks an
optimistic recorded verdict.

A manifest binds its evidence to the release under test through the release
identity block: `{software_set, target, release_id, run_id,
release_lock_sha256}` — the first four read from the release's
`metadata.json`, the digest computed from its `spack.lock` at run time. Every
field is required when the block is present, so evidence can never name half
a release; fixture and standalone runs bind to no release and carry no block.

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

Injection follows the discipline the image preflight established: fixtures
apply only when `VALIDATION_TEST_MODE=1`, every override name is allowlisted so
a typo cannot leave a suite probing real hardware, an override set outside test
mode is fatal so fixture plumbing cannot reach a production run, and the
fixture root must be a real, owner-only, symlink-free directory owned by the
caller. Each harness also stubs schedulers and hardware tools onto `PATH` and
asserts none was invoked.

Hardware expectations live in tracked `validation/config/capability.yaml`
beside `network.yaml` — never in the site settings or an ad-hoc environment
variable. Site settings decide where results go and how jobs are placed; what
the hardware is expected to look like is reviewed, committed state.

`CHAPAR_DRY_RUN=1` exercises plan rendering only; it does not submit Slurm,
load a module, or touch target paths. `/resources/chapar/vlad` and
`/resources/chapar/hpcsim` remain immutable legacy shadow/canary roots and are
never validation discovery inputs.

Offline fixture and plan behavior is verified by `make test`; target-platform
behavior is not validated here. Slurm placement and every integrity, GPU,
RDMA, MPI, NCCL, I/O, topology, or performance execution on real hardware
requires explicit operator approval.
