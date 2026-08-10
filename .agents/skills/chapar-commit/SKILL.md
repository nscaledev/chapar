---
name: chapar-commit
description: Prepare Chapar commits, pushes, or PR branches with human-only attribution, intentional splits, protected-state checks, and explicit publication approval.
---

# Chapar commit workflow

Before staging, inspect status, unstaged/staged diffs, worktrees, recent log,
source-lock status, and workflow absence. Separate catalog/scopes, release/CI,
image custody, validation/CVE, and docs/skills by review context.

Commits are authored solely by the human maintainer. Never include AI/tool
co-author, sign-off, assistance, generated-with, author, body, or collaborator
credit. Enable `.githooks/commit-msg` by copying it into `.git/hooks`; never
bypass or weaken it.

Do not stage, commit, push, amend, force-push, or open a PR until the user has
approved the exact split and action. `/resources/chapar/vlad` and
`/resources/chapar/hpcsim` remain immutable legacy shadow/canary roots, and
`containers/images/sources-lock.json` remains globally blocked unless separately
approved and proven otherwise.

Commit messages explain motivation, approach, constraints, and validation.
Distinguish offline contract evidence from deferred target-platform gates.
