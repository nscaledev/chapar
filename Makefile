SOFTWARE_SET ?=
TARGET ?=
RELEASE_ID ?=
DRY_RUN ?= false
WORKTREE_ROOT ?= foobar
WORKTREE_START ?= HEAD
MAKE_TARGETS := help build submit test lint clean-locks git-ssh-setup worktree
WORKTREE_BRANCH_GOALS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
WORKTREE_BRANCH ?= $(or $(BRANCH),$(firstword $(WORKTREE_BRANCH_GOALS)))

.PHONY: help build submit test lint clean-locks git-ssh-setup worktree FORCE

ifeq ($(firstword $(MAKECMDGOALS)),worktree)
ifeq ($(BRANCH),)
ifneq ($(WORKTREE_BRANCH),)
ifneq ($(filter $(WORKTREE_BRANCH),$(MAKE_TARGETS)),)
$(error branch name "$(WORKTREE_BRANCH)" conflicts with a Make target; use make worktree BRANCH=$(WORKTREE_BRANCH))
endif
.PHONY: $(WORKTREE_BRANCH)
$(WORKTREE_BRANCH):
	@:
endif
endif
endif

ifneq ($(filter build submit,$(MAKECMDGOALS)),)
ifeq ($(strip $(SOFTWARE_SET)),)
$(error SOFTWARE_SET is required)
endif
ifeq ($(strip $(TARGET)),)
$(error TARGET is required)
endif
ifeq ($(strip $(RELEASE_ID)),)
$(error RELEASE_ID is required)
endif
endif

help:
	@printf '%s\n' \
	  'Chapar targets:' \
	  '  make submit            Submit one software tuple build to Slurm' \
	  '  make build             Alias for submit' \
	  '  make test              Run the pytest suite (uv run --group dev pytest)' \
	  '  make lint              ruff + basedpyright over src and tests' \
	  '  make clean-locks        Always refuses to remove tracked locks' \
	  '  make git-ssh-setup      Configure repo-local SSH for GitHub pushes' \
	  '  make worktree <name>    Create $(WORKTREE_ROOT)/<name> on branch <name>' \
	  '' \
	  'Variables required by build/submit (paths and policy come from the site' \
	  'settings, etc/chapar-site.env):' \
	  '  SOFTWARE_SET TARGET RELEASE_ID' \
	  '  DRY_RUN=true verifies a plan without submitting it'

test:
	uv run --group dev pytest

lint:
	uv run --group dev ruff check src tests
	uv run --group dev basedpyright src

build: submit

submit:
	bash ./ci/submit-env-build.sh --set "$(SOFTWARE_SET)" --target "$(TARGET)" --release-id "$(RELEASE_ID)" $(if $(filter true,$(DRY_RUN)),--dry-run)

clean-locks:
	@printf '%s\n' 'error: clean-locks cannot remove tracked release locks' >&2; exit 2

git-ssh-setup:
	bash ./etc/setup-git-ssh.sh

worktree:
	@if [ -z "$(WORKTREE_BRANCH)" ]; then \
		printf 'error: usage: make worktree <branch-name>\n' >&2; \
		exit 2; \
	fi; \
	if [ "$(words $(WORKTREE_BRANCH_GOALS))" -gt 1 ] && [ -z "$(BRANCH)" ]; then \
		printf 'error: provide exactly one branch name\n' >&2; \
		exit 2; \
	fi; \
	name="$(WORKTREE_BRANCH)"; \
	path="$(WORKTREE_ROOT)/$$name"; \
	mkdir -p "$$(dirname "$$path")"; \
	if git show-ref --verify --quiet "refs/heads/$$name"; then \
		git worktree add "$$path" "$$name"; \
	else \
		git worktree add -b "$$name" "$$path" "$(WORKTREE_START)"; \
	fi

FORCE:
