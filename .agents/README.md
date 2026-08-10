# Chapar project skills

`.agents/skills/` is the one skill directory. Codex and OpenCode discover it
themselves, and Claude Code reaches the same files through the `.claude/skills`
symlink. Nothing declares a skill path in configuration, so there is no wiring
to keep in step. `AGENTS.md` holds the baseline rules and the harness table;
focused skills hold workflow detail.

Adding a skill means creating `.agents/skills/<name>/SKILL.md` and adding a row
to the Project Skills table in `AGENTS.md`. That is the whole procedure.

## Conventions

All software workflows start from the catalog (`envs/software/spack.yaml`
with its named root lists), the per-machine site settings
(`etc/chapar-site.env` resolved by `etc/chapar-defaults.sh`), and verified
immutable release directories under `${CHAPAR_RELEASE_ROOT}`. Skills must
not invent ambient authority beyond those, and must not copy the runnable
flows out of `README.md` — link to them instead.

Keep the public `nvidia-vlad` and `ubuntu-hpcsim` container IDs. Distinguish
offline evidence (`make test`, plan modes, fixtures) from operator platform
gates.

Validate edited skills with the local `skill-creator` validator and preserve the
human-only attribution policy.
