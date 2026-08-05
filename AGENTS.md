# AGENTS.md — Chapar

## Rules

- **Branch scope:** This repository is the nscale-internal development line. It carries no `.github/workflows/` — how environment builds run in CI is not yet decided; `docs/ci-github-actions.md` holds the proposed GitHub Actions design and must be agreed before any workflow files are added. Deployment targets Ubuntu 24.04 LTS (the NVIDIA-supported LTS used by the Slurm appliances and fleet manager on current clusters).
- NEVER modify `spack/` submodule. All local policy lives in `etc/` and `envs/`.
- Do not add or override package recipes in `spack_repo/` unless the user explicitly asks to add a package there.
- NEVER edit generated/lock files (`.spack-env/`, lockfiles, caches).
- DO NOT pin dependency minor/patch versions on concretization. Use major version only (`gcc@15` not `gcc@15.2.0`).
- **GCC:** hpcsim targets Ubuntu 24.04 LTS and uses one Spack-built GCC 15 compiler stack for the whole environment. Use the OS GCC only to bootstrap GCC 15.
- **Python/Tk:** hpcsim may expose multiple Python minor-version roots. Keep `+tkinter` only on explicit Python root specs, or on root specs that truly need a Tk-enabled Python dependency. Package-wide `python:` policy should constrain allowed minor versions only; do not add package-wide `+tkinter`.
- **Intel compiler:** Always use the latest available version.
- **MPI:** Always use the latest available version. Prefer Open MPI.
- **GPUDirect:** hpcsim Linux transport layers must keep CUDA/GDR-capable builds. Keep UCX, Open MPI, and libfabric CUDA-aware with GDRCopy where supported; do not disable CUDA/GDR transport support to work around downstream build failures.
- **Ubuntu builders:** Do not install or rely on OS CUDA Toolkit, OS Intel oneAPI compiler/MPI, or GitHub CLI OS packages for hpcsim builds. CUDA, Intel MPI, and any future Intel compiler dependency must come from Spack unless the user explicitly changes this policy.
- **LLVM:** Always use the latest available major version. For LLVM 15+, do not add `+cuda`; Spack marks that variant obsolete. Use NVPTX targets/offload variants as needed, and prefer latest LLVM over downgrading only to satisfy LLVM `+cuda`.
- **Build cache:** Prefer binary caching (`spack mirror`) over building from source.
- **Shared install tree:** The cross-environment package store lives at `/resources/chapar/install/linux-<os>-<arch>/`. It uses a flat `{name}-{version}-{hash}` projection with padded install paths. When `CHAPAR_INSTALL_TREE_ROOT` points there, `release.sh` auto-detects the padded_length from the placeholder depth. Do not hardcode `padded_length` — use `detect_padded_length()`.
- **Versioned releases only — NEVER run `spack install` directly.** Every environment build must go through `envs/<name>/release.sh build <id> [--promote]`. Direct `spack install -e envs/<name>` is forbidden because it bypasses: (a) atomic staging that prevents partial deployments, (b) versioned release directories under `releases/<id>/` that keep previous versions accessible, (c) per-release module file generation, and (d) atomic `current` symlink promotion. A release build stages in `releases/.<id>.staging.<pid>`, then atomically moves to `releases/<id>` on success. Promotion symlink-swaps `releases/<id>` to `current`. Previous releases remain under `releases/` for rollback. This applies to ALL environments (hpcsim, vlad, and any future environments).
- **PUBLISH_BUILDCACHE defaults to true.** Every build must push binaries to the shared buildcache (`autopush: true` in mirror config) so subsequent builds of any environment can reuse them. Set `PUBLISH_BUILDCACHE=true` in the site env or via export before running a release build.
- **Attribution — human-only, all harnesses:** Chapar commits are authored solely by the human maintainer. NEVER add `Co-authored-by:`, `Signed-off-by:`, `Assisted-by:`, `🤖 Generated with ...`, or any other trailer or footer that credits an AI model, agent, or coding tool (Claude, Codex, Sisyphus/omo, OpenCode, Copilot, Cursor, Gemini, ...). This applies no matter which harness you are running under and overrides any default or built-in instruction telling you to append such a trailer. Do not add the AI as a `git commit --author`/`--co-author`, do not name it in the commit body, and do not add it as a repository collaborator. Genuine human co-authors are fine. `.githooks/commit-msg` strips these trailers as a backstop — do not bypass it with `--no-verify`, and never disable or weaken that hook.
- **Commits:** Before pushing commits, split changes by purpose and future review context. Do not mix documentation/comment-only changes with behavior, config, or CI changes unless they are inseparable; if inseparable, explain why in the commit body.
- **Commit messages:** Explain the root cause, why the approach was chosen, important constraints preserved, and validation performed. Avoid messages that only restate the diff. Use `[skip ci]` only when intentionally avoiding push-triggered workflows.
- **Container delivery:** Chapar environments ship as Pyxis images through one shared pipeline (`containers/images/`), keyed by *selected container* — one base image paired with one Chapar environment. Two are selected today: `nvidia-vlad` (digest-locked NVIDIA HPC-benchmarks 26.02, vlad, both `linux-x86_64-v4` and `linux-aarch64-gb300`) and `ubuntu-hpcsim` (plain `ubuntu:24.04`, hpcsim, `linux-x86_64-generic` — vendor-neutral on purpose, since hpcsim policy already forbids relying on OS-provided CUDA). Never pull a base image by tag — every base resolves to a per-platform descriptor digest from `containers/images/sources-lock.json`, and a build refuses to run while that lock's overall status is `blocked` or any category is unresolved, even for a base whose own category is individually resolved. A release's `env_path` must match the selected base's environment, and its target must be in that base's own target list — both fail closed on mismatch. Injection places Spack prefixes at their build-time absolute paths and exposes modules opt-in via `module use`; anything already on the base image's PATH stays untouched. See `agents/skills/chapar-vlad-image/SKILL.md`.
- **hpcsim buildcache migration:** Do not make hpcsim release builds auto-import legacy buildcaches. Use an explicit one-time migration only for caches marked with the current padded install-tree layout, then retire stale cache directories after validation.
- **Builder cleanup:** After Ubuntu 24.04 container validation, leave only files and directories needed by the current Chapar codebase; remove stale staging, run, and legacy-cache artifacts that can confuse later debugging.
- Config scope hierarchy: `defaults > system > site > user > spack > environment > command line`.
- OS-specific overrides use `include.yaml` with `when:` conditionals.

## Key Paths

| Path | Purpose |
|------|---------|
| `etc/system/` | Machine-level configs (providers, mirrors, build settings) |
| `etc/system/base/` | Cross-platform: concretizer, config, mirrors, packages, repos |
| `etc/system/{ubuntu24.04,linux}/` | OS-specific external packages |
| `etc/user/` | Per-user configs (install_tree, build_stage, modules) |
| `etc/user/base/` | Cross-platform user settings |
| `envs/hpcsim/spack.yaml` | Canonical hpcsim environment entry point |
| `envs/hpcsim/release.sh` | hpcsim release, module, and buildcache helper |
| `envs/hpcsim/hpcsim-site.env.example` | Template for local site roots, shared buildcache, shared ccache, and group policy |
| `envs/vlad/spack.yaml` | vlad validation environment (x86_64_v4 target; CUDA-aware Open MPI stack) |
| `containers/images/` | Shared Pyxis image pipeline (nvidia-vlad, ubuntu-hpcsim): build-image.sh, preflight.sh, targets.json, sources-lock.json, site contract, tests |
| `ci/register-vlad-image-runner.sh` | Registers builder/validator/publisher image runners against nscaledev/chapar |
| `ci/install-vlad-image-site-contract.sh` | Installs the host-owned site contract to `/etc/chapar/vlad-image/` |
| `docs/ci-github-actions.md` | Proposed GitHub Actions CI design (no workflow files exist in this repo) |
| `AGENTS.md` | Canonical repository guidance, shared by all agent runtimes |
| `CLAUDE.md` | Claude Code entry point; imports `AGENTS.md` (Claude Code does not read `AGENTS.md`) |
| `agents/skills/` | Canonical project skills; loaded by OpenCode/Codex via `opencode.json` |
| `.claude/skills` | Single symlink to `agents/skills/` so Claude Code discovers the same skills |
| `.githooks/commit-msg` | Strips AI/agent attribution trailers from commit messages (enable per clone) |
| `etc/init.sh` | Shell initializer (source to bind to this checkout) |
| `etc/link-scopes.sh` | Symlink configs into `/etc/spack` / `~/.spack` |
| `/resources/chapar/install/linux-<os>-<arch>/` | Shared install tree (cross-environment package store) |
| `/resources/chapar/vlad/` | vlad release root (releases, modulefiles, current symlink) |
| `/resources/chapar/hpcsim/` | hpcsim release root (releases, modulefiles, current symlink) |

## Workflows

**Add a package:** Edit `envs/hpcsim/spack.yaml`. Keep root specs in the `definitions:` section and package requirements in the `packages:` section. Add OS-specific tuning with `when: os=ubuntu24.04` only where required by real platform differences. Run `spack -e envs/hpcsim concretize -f` on an Ubuntu builder to verify.

**Add an OS:** Create `etc/system/{os}/packages.yaml` (externals: compiler, glibc, system libs). Register in `etc/system/include.yaml` and `etc/user/include.yaml`.

**Release (all environments):** Every environment at `envs/<name>/` follows the same workflow:
1. Copy `<env>-site.env.example` to `<env>-site.env` and fill local roots/cache/group policy.
2. Run `envs/<name>/release.sh build <release-id> [--promote]` — atomic staging, per-release module generation, symlink promotion.
3. NEVER run `spack install -e envs/<name>` directly — this bypasses versioning and can corrupt the active deployment.
4. Previous releases remain under `releases/<id>/` and are accessible via `module use releases/<id>/modulefiles/<arch>`.
5. The `current` symlink always points to the production release.

**Deploy config:** Run `etc/link-scopes.sh` or source `etc/init.sh`.

## Project Skills

Chapar keeps project-local agent skill playbooks under `agents/skills/`. When a task
matches one of these areas, load the matching skill if the runtime exposes it;
otherwise read the skill's `SKILL.md` before changing files.

| Task | Skill |
|------|-------|
| Spack environment package/root spec or package policy changes under `envs/<name>` | `agents/skills/chapar-spack-env-change/SKILL.md` |
| Spack concretization failures, solver timeouts, provider conflicts, or config layering debug | `agents/skills/chapar-spack-solve-debug/SKILL.md` |
| Persistent Spack scope changes under `etc/system` or `etc/user` | `agents/skills/chapar-config-scope-change/SKILL.md` |
| Commits, pushes, branch prep, or PR prep | `agents/skills/chapar-commit/SKILL.md` |
| hpcsim release helper changes in `envs/hpcsim/release.sh` | `agents/skills/chapar-release-helper/SKILL.md` |
| Buildcache layout, migration, quarantine, index refresh, or publication | `agents/skills/chapar-buildcache/SKILL.md` |
| Vlad Pyxis image pipeline — base injection, sources lock, site contract, preflight, image runner provisioning | `agents/skills/chapar-vlad-image/SKILL.md` |
| Live CI/CD progress inspection via mounted artifact roots, logs, stores, releases, modulefiles, or caches | `agents/skills/chapar-ci-artifact-watch/SKILL.md` |
| CUDA/GDR transport work involving UCX, Open MPI, libfabric, GDRCopy, NCCL, or NVSHMEM | `agents/skills/chapar-cuda-gdr-transport/SKILL.md` |
| CVE checker agent, CodeQL code scanning, security scan config, Nemotron summaries, or issue workflow changes | `agents/skills/chapar-cve-checker/SKILL.md` |
| Cluster validation tests under `validation/` — integrity test, hardware/interconnect tiers, verdict outputs | `agents/skills/chapar-validation/SKILL.md` |
| Local Spack package overlay recipe or patch changes under `spack_repo/chapar_plus` | `agents/skills/chapar-spack-repo-overlay/SKILL.md` |
| OpenCode config, agent skill layout, skill migration, or project skill policy changes | `agents/skills/chapar-opencode-skills/SKILL.md` |
| Creating or improving `agents/skills` | `agents/skills/skill-creator/SKILL.md` |
| Manual nscale/Vlad source, release, or `.sqsh` work | `docs/nscale-vlad-manual-build.md` and `agents/skills/chapar-vlad-image/SKILL.md` |
| Visual diff help when VS Code CLI is available | `agents/skills/vscode/SKILL.md` |
| External web search when Brave Search credentials are configured | `agents/skills/brave-search/SKILL.md` |

`AGENTS.md` is baseline repository guidance, not a skill. Use it together with
the matching skill playbook when both apply.

### Harness wiring

Each runtime discovers these files differently, so the same content is exposed three ways
with no duplicated copies:

| Runtime | Rules | Skills |
|---------|-------|--------|
| OpenCode | `AGENTS.md` | `opencode.json` → `skills.paths: ["agents/skills"]` |
| Codex / omo | `AGENTS.md` | same `opencode.json` paths |
| Claude Code | `CLAUDE.md`, which imports `AGENTS.md` with `@AGENTS.md` | `.claude/skills` → symlink to `agents/skills/` |

Claude Code reads `CLAUDE.md`, not `AGENTS.md`, and discovers skills only under
`.claude/skills/`. That path is not configurable, so the symlink is the bridge; it is a
single directory symlink rather than one per skill, which means adding a skill under
`agents/skills/<name>/` needs no wiring step and cannot drift. Keep the rules wiring
intact when renaming a rule file, otherwise a rule silently stops applying under one
harness.

A fully shared directory (for example a single `.agents/`) is not possible today: Claude
Code hardcodes `.claude/skills`, while OpenCode and Codex take a configured path. Any
other name would still need this symlink, so `agents/skills/` stays the source of truth.
`.claude/` otherwise holds only Claude-specific local settings, which are untracked.

The canonical manual nscale/Vlad source and image procedure is
[`docs/nscale-vlad-manual-build.md`](docs/nscale-vlad-manual-build.md). Project catalogs link to it rather than
copying runnable commands. The historical `vlad-image` name is retained only
for internal runtime paths, units, and environment variables; it does not add
another base id. Repository remediation uses disposable fixtures and never
changes shared or live paths. Future operator gates cover those paths after
source approval, while the production source lock remains blocked.

Instruction files are context, not enforcement — no harness guarantees compliance. Rules
that must hold regardless live in `.githooks/`.

## Commit Workflow

When asked to commit or push:

- Inspect `git status`, `git diff`, and recent `git log` before staging.
- Identify separate change contexts before committing, such as docs-only, behavior/config, CI, release tooling, and policy.
- Create separate commits for separate contexts even if the changes came from one user request.
- Prefer a short subject plus a body that records why the change exists and what risk it reduces.
- Never credit an AI model, agent, or coding tool in the commit. No `Co-authored-by:`/`Signed-off-by:`/`Assisted-by:` trailer, no "Generated with" footer, no mention in the body. See the attribution rule under **Rules** — it applies under every harness.
- Enable the hook once per clone so the attribution rule is enforced locally: `cp .githooks/commit-msg .git/hooks/commit-msg && chmod +x .git/hooks/commit-msg`. Copy rather than symlink — a symlink dangles on branches where the file is not tracked, and git treats a broken-symlink hook as absent.
- Do not amend or rewrite pushed history unless the user explicitly asks.
- If a bad commit split is discovered after push, prefer leaving it or creating corrective commits over force-pushing `main`.

## Commands

| Action | Command |
|--------|---------|
| Concretization check | `spack -e envs/hpcsim concretize -f` |
| Inspect package DAG | `spack spec <pkg>` |
| Check config layering | `spack config blame <scope>` |
| Build & promote (hpcsim) | `envs/hpcsim/release.sh build <id> --promote` |
| Build & promote (vlad) | `envs/vlad/release.sh build <id> --promote` |
| Check buildcache publication | `spack buildcache update-index file://${CHAPAR_BUILDCACHE_ROOT}/$(detect_os)` |

## Conventions

- YAML: 2-space indent
- Package specs alphabetically sorted
- External packages: `externally_managed: true` + `buildable: False`
- Targets per-platform (e.g., `target: [x86_64_v4]` for Linux builders). Keep the
  target and any `concretizer: targets:` granularity override in the
  environment's own `spack.yaml`, not in `etc/system/base/concretizer.yaml` —
  that scope is shared, so changing it re-concretizes every other environment.
  `vlad` is the worked example.
- Virtual providers in priority order (`mpi: [openmpi, mpich]`)

## Integrity Validation

Every environment must pass integrity validation after every successful build.
Integrity validation verifies that all modules load and their basic tools
execute — without requiring GPUs, InfiniBand, or multi-node hardware.

Run via:
```bash
ENV_NAME=vlad ./validation/run integrity-test
ENV_NAME=hpcsim ./validation/run integrity-test
```

Until CI is in place, run this manually after every build+promote — the
proposed CI (`docs/ci-github-actions.md`) makes it a required gate.
Failure blocks the release from being considered production-ready.

### What integrity validation checks
- Module loads successfully
- Binary/executable is on PATH and runs (--version or equivalent)
- Shared library dependencies are met (no missing .so at runtime)
- Key language runtimes work (Python imports, compiler version checks)

### What integrity validation does NOT check
- GPU device availability or CUDA kernel execution
- InfiniBand/RDMA connectivity or MPI multi-node communication
- NCCL all-reduce or GPU-direct transport paths
- Performance benchmarks or throughput measurements
- I/O subsystem or filesystem performance

These are separate deeper validation tiers that require specialized hardware.

## Adding a New Environment

Every environment at `envs/<name>/` needs the following files and changes to make the full CI/CD chain work:

### Checklist

| # | File / Change | Purpose | Template Source |
|---|---------------|---------|-----------------|
| 1 | `envs/<name>/spack.yaml` | Spack environment with root specs and package policy | New |
| 2 | `envs/<name>/release.sh` | Build, promote, modules, buildcache — versioned release workflow | Copy from `envs/vlad/release.sh`, search/replace `vlad` → `<name>` |
| 3 | `envs/<name>/<name>-site.env.example` | Template for local site roots, buildcache, ccache, group policy | Copy from `envs/hpcsim/hpcsim-site.env.example` |
| 4 | `etc/profile.d/zz-chapar-<name>.sh` | Profile.d script that `module use`s the current release | Copy from `etc/profile.d/zz-chapar-vlad.sh`, replace `/resources/chapar/vlad/` → `/resources/chapar/<name>/` |
| 5 | `validation/tests/integrity-test.sbatch` | Add `<name>)` case with `check` calls for each root module | Model on `vlad)` or `hpcsim)` blocks already in the file |
| 6 | CI wiring | Not yet decided for this repository — see `docs/ci-github-actions.md` for the proposed GitHub Actions design | Proposal only; no workflow files exist here |

### Deployment path conventions

- **NFS root**: `/resources/chapar/<name>/` — must reside on an NFS mount shared across cluster nodes (CI enforces this at build time).
- **OS subdirectory**: `/resources/chapar/<name>/<os>/` (e.g. `ubuntu24.04`).
- **Architecture subdirectory**: `<os>/<arch>/` (e.g. `linux-ubuntu24.04-x86_64_v3`), derived from the generated release content, not `spack arch`.
- **Release directory**: `<os>/<arch>/releases/<release-id>/` — immutable after staging rename (staging happens at `<os>/.<id>.staging.<pid>` because the arch is only known after module generation). Legacy releases at `<os>/releases/<id>` remain promotable.
- **`current` symlink**: `<os>/<arch>/current → releases/<release-id>` — atomically swapped on promote. Promote also removes any legacy `<os>/current` symlink.
- **Stable module path**: `<os>/<arch>/modulefiles → current/modulefiles/<arch>` — the user-facing `module use` target, updated on promote.
- **Module artifacts**: `<os>/<arch>/releases/<release-id>/modulefiles/<arch>/` (release-local until promotion).
- **Spack install store**: `<os>/store/` (shared across releases; kept at OS level because the store path must exist before the arch is known), or the shared cross-environment install tree when `CHAPAR_INSTALL_TREE_ROOT` is set.
- **Buildcache**: `<env_root>/../cache/buildcache/<name>/<os>/` or a shared cross-env cache root.
- **Cc cache**: `<env_root>/../cache/ccache/<os>/`.

### Release.sh auto-repair on promote

Both `vlad/release.sh` and `hpcsim/release.sh` `cmd_promote()` handle a corner case where a stale directory (not a symlink) exists at the `current` path:

```bash
if [ -e "${CURRENT_LINK}" ] && [ ! -L "${CURRENT_LINK}" ]; then
    echo "==> Removing stale 'current' directory: ${CURRENT_LINK}"
    rm -rf "${CURRENT_LINK}"
fi
```

A new environment's release.sh should include the same guard.

### Auto-promote policy

Promotion is a per-environment decision made at build invocation
(`release.sh build <id> --promote`, or `PUBLISH_CURRENT=true` in the sbatch
wrappers). Historical policy, to preserve when CI is reintroduced: vlad
auto-promotes on every successful build; hpcsim builds without touching
`current` and promotes only on an explicit operator request. See
`docs/ci-github-actions.md` for how the proposed CI encodes this.

### Release.sh differences from env to env

When copying `release.sh` for a new environment, adjust:

1. **Script header / UX constants**: Change `VLAD_ROOT`/`HPCSIM_ROOT` to `<NAME>_ROOT`, `vlad` → `<name>` in all echo messages, scope temp dir prefix.
2. **`usage()` and help text**: Change env name references.
3. **`resolve_<name>_root()` / `validate_<name>_root()`**: Rename the resolver function.
4. **`set_paths()`**: `OS_ROOT="${<NAME>_ROOT}/${OS_NAME}"`, `CURRENT_LINK="${OS_ROOT}/current"`.
5. **Scope temp dir**: `mktemp -d "${TMPDIR:-/tmp}/<name>-release-scope.XXXXXX"` and similar build_stage paths.
6. **`prepare_release_roots()`**: Update echo labels.
7. **`cmd_build()`**: Update the first echo line (`Building <name> release`). Keep GCC and LLVM preinstall if the env targets Ubuntu.
8. **`cmd_promote()` / `cmd_publish_modules()` / `cmd_status()`**: Update echo labels. Keep the stale-directory guard.
9. **`cleanup_build()`**: No env-specific changes needed.
10. **Module policy**: Keep Open MPI / Intel MPI / CUDA stub policy if the env has those packages; remove or skip otherwise (the functions are idempotent — they check for matching module files).

### Integrity test entry

The integrity test dispatches on `ENV_NAME` in a `case` block. Add:

```bash
<name>)
    check "gcc"       "gcc --version"            "compiler runs"
    check "cmake"     "cmake --version"          "cmake runs"
    # ... one check per root module ...
    ;;
```

Until CI is in place, run integrity validation manually after every successful build; the proposed CI makes it a required gate. Failure blocks the release from being considered production-ready.

### Test the chain locally

Before pushing, validate the release flow on an Ubuntu 24.04 builder (a Slurm
builder node, or any host with the site roots mounted):

```bash
# concretize only (no install)
source ./etc/init.sh
spack -e envs/<name> concretize -f

# full build with promote (interactive Slurm wrapper)
bash ci/submit-env-build.sh --env <name> --os ubuntu24.04 --publish-current true

# or directly, without Slurm
bash envs/<name>/release.sh build <release-id> --promote
```

How builds should run in CI is not yet decided; `docs/ci-github-actions.md`
holds the proposed GitHub Actions design.
