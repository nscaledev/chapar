---
name: chapar-harness-wiring
description: Maintain Chapar harness wiring and project skills — the shared .agents/skills directory, the CLAUDE.md and .claude/skills symlinks, AGENTS.md, and OpenCode permissions.
---

# Chapar harness wiring

One rules file and one skill directory serve every harness.

| Harness | Rules | Skills |
|---|---|---|
| Codex | `AGENTS.md` | `.agents/skills` (native) |
| OpenCode | `AGENTS.md` | `.agents/skills` (native) |
| Claude Code | `CLAUDE.md` -> `AGENTS.md` | `.claude/skills` -> `.agents/skills` |

`.agents/skills` is the canonical location because Codex scans `.agents/skills`
from the working directory up to the repository root, and OpenCode auto-scans
`.opencode/skills`, `.claude/skills`, and `.agents/skills`. Claude Code reads
only `CLAUDE.md` and `.claude/skills`, and follows symlinks in both, so it needs
two links rather than two copies.

The consequence worth protecting: **no configuration declares a skill path.**
`opencode.json` is OpenCode permissions and nothing else. If you find yourself
adding a `skills` key, a `.claude/skills/<name>` entry, or a second rules file,
the layout has regressed.

## Adding a skill

Create `.agents/skills/<name>/SKILL.md` and add a row to the Project Skills
table in `AGENTS.md`. There is no wiring step.

## Changing OpenCode permissions

`opencode.json` validates against `https://opencode.ai/config.json`, which its
own `$schema` key names. Validate after editing rather than assuming a key
exists — `skills.paths`, `instructions`, and the `"*"` wildcard are all real,
and other plausible-looking keys are not.

Permission values are `allow`, `ask`, or `deny`. The default is `"*": "deny"`,
so an omitted command prompts rather than failing. Allow offline, plan-shaped
work — `uv run chapar ...` inspection, `release.sh plan`, `make test`/`make
lint` — and leave anything with a real effect — a release build, a Slurm
submission, an image import or export — to prompt. Check an allowlist edit
against the current entry points, not historical ones: retired scripts like
`tools/chapar_resolve.py` must not linger in the list.

## Skill content rules

Software skills route through the catalog (`envs/software/spack.yaml`), the
site settings (`etc/chapar-site.env` via `etc/chapar-defaults.sh`), and
verified immutable release directories. Distinguish offline evidence from
deferred operator platform gates, preserve the immutable legacy roots, retain
the public container IDs, and link to the runnable sequences in `README.md`
instead of duplicating them.

Use `skill-creator` for substantive edits. Validate frontmatter with
`python3 .agents/skills/skill-creator/scripts/quick_validate.py`, then check
the wiring above, stale authority references, human-only attribution, and
`git diff --check`. The offline gate (`ci/tests/software-specs-offline-gate.sh`)
validates every chapar skill's frontmatter; run it after any change here.
