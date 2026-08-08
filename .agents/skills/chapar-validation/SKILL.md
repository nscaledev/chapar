---
name: chapar-validation
description: Modify or debug selection-aware Chapar validation plans, root/module inventory, integrity checks, hardware tiers, verdicts, or result placement under validation/.
---

# Chapar validation

Validation requires `selection.json`, its exact digest, and the matching target
contract. It derives one module tree, exact selected roots/checks, Slurm
placement, and a tuple/release/run result namespace. Do not restore environment
dispatch or architecture-directory scanning.

Integrity remains hardware-free. Preserve exit 77 as SKIP and stable
PASS/WARN/FAIL/SKIP JSON and Prometheus fields. Unknown/mixed selections,
missing roots, and contract/digest drift fail before module load/submission.

Suites bound to the result contract in `validation/lib` record outcomes through
`verdict.sh` and let `validation_result_finalize` own the exit code; do not write
a verdict or exit status by hand. Keep the bound-suite list in
`result-manifest.sh` equal to the `suite` enum in `result-manifest.schema.json`.
Manual runs are never CI-authoritative. Hardware expectations belong in tracked
`validation/config/capability.yaml`, never an ambient site file, and every
hardware suite must stay runnable offline through its `validation/fixtures/`
cases with `VALIDATION_TEST_MODE=1`.

Run parser/dry-run fixtures only unless the user explicitly approves target
execution. Never claim a plan ran Slurm, loaded modules, or validated hardware.
`/resources/chapar/vlad` and `/resources/chapar/hpcsim` are immutable legacy
shadow/canary roots, not discovery inputs. Offline contract and selection
behavior is verified; target-platform behavior not validated.
