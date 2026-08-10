# Chapar task guides

Operator-facing, task-oriented guides. Start with the repository `README.md`
for the model and the quick start; `AGENTS.md` carries the contributor and
agent rules.

| Guide | Covers |
|---|---|
| [`site-onboarding.md`](site-onboarding.md) | New machine or site: tools, the site settings file, per-tuple policy, machine-wide install, fail-closed validation. |
| [`targets.md`](targets.md) | The target registry: the four targets, what each fact drives, how the rendered scope reaches builds, adding a target. |
| [`building.md`](building.md) | Building a release end to end: plan/build, ccache bootstrap, the release directory, Slurm submission, buildcache and seed mirrors, install-tree padding. |
| [`delivering-modules.md`](delivering-modules.md) | Publishing modules, promotion and rollback via the `current` pointer, how login shells consume a release. |
| [`container-images.md`](container-images.md) | Preflight, plan, build, validate, and publish a Pyxis/Enroot image from a release; the source-lock block. |
| [`container-injection.md`](container-injection.md) | The injection contract: mechanism, host-vs-image split, non-interference rules. |
| [`validation.md`](validation.md) | Running suites against a release, plans and analysis, results layout, fixture mode, the platform boundary. |
| [`cve.md`](cve.md) | CVE scanning a release: plan/dry-run/live, summaries and dedupe, the nemoclaw deployment. |

Reference documentation elsewhere in the tree:

- `etc/README.md` — configuration scopes, site settings resolution, and the
  complete `CHAPAR_*` variable table.
- `envs/software/README.md` — the generated catalog reference (regenerate
  with `uv run chapar catalog readme --render`; never edit by hand).
- `containers/README.md` — the container and target registry facts.
- `validation/ARCHITECTURE.md` — the validation result contract and fixture
  architecture; `validation/README.md` for per-suite reference.
