SPACK_INIT := ./etc/init.sh
ENV := hpcsim
RELEASE_ID ?=
SPACK_INSTALL_ARGS ?=
WORKTREE_ROOT ?= foobar
WORKTREE_START ?= HEAD
MAKE_TARGETS := help build release promote module-use check clean-locks git-ssh-setup worktree
WORKTREE_BRANCH_GOALS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
WORKTREE_BRANCH ?= $(or $(BRANCH),$(firstword $(WORKTREE_BRANCH_GOALS)))

.PHONY: help build release promote module-use check clean-locks git-ssh-setup worktree FORCE

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

ifneq ($(filter build,$(MAKECMDGOALS)),)
ifeq ($(strip $(ENV)),)
$(error ENV is required for build)
endif
ifeq ($(strip $(RELEASE_ID)),)
$(error RELEASE_ID is required for build)
endif
endif

help:
	@printf '%s\n' \
	  'Chapar hpcsim targets:' \
	  '  make build              Build a versioned release (requires ENV and RELEASE_ID)' \
	  '  make release            Build a staged hpcsim release under the site-configured root' \
	  '  make promote            Promote RELEASE_ID for the current OS' \
	  '  make module-use         Print module use command for RELEASE_ID or current' \
	  '  make check              Validate the hpcsim environment config' \
	  '  make clean-locks        Remove generated hpcsim lockfile' \
	  '  make git-ssh-setup      Configure repo-local SSH for GitHub pushes' \
	  '  make worktree <name>    Create $(WORKTREE_ROOT)/<name> on branch <name>' \
	  '' \
	  'Variables:' \
	  '  RELEASE_ID=$(RELEASE_ID) (required for build; generated for release; current for module-use)' \
	  '  SPACK_INSTALL_ARGS=$(SPACK_INSTALL_ARGS)' \
	  '  BRANCH=                 Optional branch name for make worktree BRANCH=<name>' \
	  '  WORKTREE_ROOT=$(WORKTREE_ROOT)' \
	  '  WORKTREE_START=$(WORKTREE_START) (used when creating a new branch)'

build:
	SPACK_INSTALL_ARGS="$(SPACK_INSTALL_ARGS)" bash ./envs/$(ENV)/release.sh build "$(RELEASE_ID)"

release:
	bash -lc 'source $(SPACK_INIT) && release_id="$(RELEASE_ID)" && : "$${release_id:=$$(date -u +%Y%m%d%H%M%S)}" && SPACK_INSTALL_ARGS="$(SPACK_INSTALL_ARGS)" bash ./envs/$(ENV)/release.sh build "$${release_id}"'

promote:
	bash -lc 'source $(SPACK_INIT) && test -n "$(RELEASE_ID)" && bash ./envs/$(ENV)/release.sh promote "$(RELEASE_ID)"'

module-use:
	bash -lc 'source $(SPACK_INIT) && release_id="$(RELEASE_ID)" && if [ -n "$${release_id}" ]; then bash ./envs/$(ENV)/release.sh module-use "$${release_id}"; else bash ./envs/$(ENV)/release.sh module-use; fi'

check:
	bash -lc 'source $(SPACK_INIT) && spack -e ./envs/$(ENV) config get config >/dev/null && spack -e ./envs/$(ENV) config get packages >/dev/null && spack -e ./envs/$(ENV) config get modules >/dev/null'

clean-locks:
	rm -f envs/$(ENV)/spack.lock

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
