# CVE scanning

How to scan a release's package inventory for CVEs, and how the scheduled
checker is deployed.

## What is scanned

The inventory is the release's own record: `chapar cve scan` verifies the
release directory (`metadata.json` digests, identity, target facts) and reads
the concrete roots — name and version — from the release-local `spack.lock`.
Nothing is inferred from a live install tree, module tree, or catalog, so a
finding always names software that release actually built.

## Running a scan

```bash
uv run chapar cve scan --release-dir "$CHAPAR_RELEASE_ROOT/vlad/linux-x86_64-v4/20260809a" --plan
```

Three escalation levels:

- `--plan` — fully offline. Prints the verified inventory (policy plus
  package list) and returns before any configuration or network access. Safe
  anywhere; use it to confirm what a scan would cover.
- `--dry-run` — queries NVD (and OSV unless `--no-osv`) but creates no GitHub
  issue; findings print as `DRY-RUN` lines. This is also the default: with
  neither flag, `CHAPAR_CVE_DRY_RUN` (default true) keeps the scan dry.
- `--live` — creates GitHub issues. Requires `GITHUB_TOKEN` and a configured
  `github_repo` (config file or `--github-repo`). An explicit external
  action; never run it as a side effect of documentation or fixture work.

Useful narrowing flags: `--package <name>` (repeatable), `--max-packages N`,
`--lookback-days N` (0 disables date filtering; NVD windows cap at 120),
`--severity-threshold {NONE,LOW,MEDIUM,HIGH,CRITICAL}`, `--nvd-delay`,
`--config` (default `ci/cve-checker-config.json`), `--state-dir`.

## Summaries and deduplication

- **Nemotron summaries:** each deterministic finding may be summarized by a
  local OpenAI-compatible Nemotron endpoint (`NEMOTRON_BASE_URL`; skipped
  when empty or with `--no-nemotron`). The model only writes the summary
  text — whether a CVE matches a package is decided by the NVD/OSV matching,
  never by the model.
- **Issue dedupe markers:** every issue body embeds an HTML-comment marker
  identifying the package and CVE. Before creating an issue the checker
  searches the repository for that marker and skips existing ones, so
  repeated scans do not duplicate issues.

## Scheduled deployment on nemoclaw

The checker runs as a hardened systemd oneshot on the `nemoclaw` VM:

```bash
# on nemoclaw, from the checkout at /opt/chapar-cve-checker:
bash ci/install-cve-checker-nemoclaw.sh              # install units + config
bash ci/install-cve-checker-nemoclaw.sh --enable-timer
```

The installer creates the unprivileged `chapar-cve-agent` user, installs
`etc/systemd/chapar-cve-checker.service` and `.timer`, the checker config,
and — if absent — `/etc/chapar/cve-checker.env` from
`etc/cve-checker.env.example`. Edit that env file before enabling anything:

- `CHAPAR_CVE_RELEASE_DIR` — the immutable release directory to scan (the
  directory basename must equal its recorded release ID; the service passes
  it as `--release-dir`).
- `CHAPAR_CVE_DRY_RUN` — keep `true` until a smoke run confirms issue output
  and dedupe behavior.
- `NVD_API_KEY`, `GITHUB_TOKEN` (contents:read + issues:write only),
  `NEMOTRON_BASE_URL`/`NEMOTRON_MODEL`/`NEMOTRON_API_KEY`, and the optional
  `CHAPAR_CVE_REQUIRE_PROXY`/`HTTPS_PROXY` pair.

The service unit is heavily sandboxed (`ProtectSystem=strict`, no
capabilities, `/resources` and container sockets inaccessible, writable only
in `/var/lib/chapar-cve-checker`). To surface the VM in the repository runner
UI, `ci/register-nemoclaw-runner.sh --token <registration-token>` registers a
dedicated GitHub Actions runner under a separate no-sudo user; note this
repository line intentionally carries no `.github/workflows/`, so the runner
has nothing to execute until a workflow is added elsewhere.
