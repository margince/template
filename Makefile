# Margince instance template.
#
# core/ is upstream Margince as a submodule, never edited. extensions/ holds the
# instance's own units (none in the template).

SHELL := /usr/bin/env bash

# git's repository location variables never reach a recipe. git sets them when
# it runs a hook, and inherited they make the script suites' throwaway
# repositories act on this one (scripts/git-env.test.sh).
unexport GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
.DEFAULT_GOAL := help

CORE := core
# Upstream's root and backend/ Makefiles both define build, test, check and
# migrate. Every delegation below names which one it means.
MAKE_CORE := $(MAKE) -C $(CORE)/backend

# Piped through rewrite_staged_paths so a gate names extensions/<unit>/… here
# rather than the scratch copy under core/. See scripts/lib.sh.
REWRITE := | { . $(CURDIR)/scripts/lib.sh; rewrite_staged_paths; }

.PHONY: help init config config-check config-sync hooks \
	stage unstage compose watch new-unit new-instance deploy-init deploy host-bootstrap host-admin-password local-up local-down local-admin-password release license u u-fe u-check \
	core-status core-branch core-restore core-check core-pr core-check-pin \
	check check-instance check-template check-public template-sync check-composition build test test-extensions arch ext-imports \
	check-ext-migrations check-manifests check-docs drift test-scripts test-cli test-lifecycle secret-scan test-secret-scan \
	fe-install fe-test fe-test-ext fe-typecheck-composed fe-ds-gates fe-lint \
	dev dev-fresh dev-stop dev-logs seed-dev seed-demo verify-demo run \
	infra-up infra-down infra-logs infra-reset db-up migrate \
	lint fmt package smoke toolcheck test-integration test-integration-ext ci \
	desktop desktop-mirror desktop-kit desktop-win-kit \
	desktop-install desktop-run desktop-connect desktop-seed \
	desktop-verify desktop-status desktop-logins desktop-psql desktop-dsn \
	desktop-clean trial \
	aio aio-up aio-down aio-reset aio-logins aio-logs aio-smoke aio-scripts \
	update-core clean

help: ## Show the lanes
	@grep -hE '^[a-z][a-z0-9-]*:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@# The pattern rules cannot match the grep above, and they are the only escape
	@# hatch out of the named set, so they are printed by hand.
	@printf "  \033[36m%-22s\033[0m %s\n" "core-root-<lane>" "any core ROOT lane, staged first"
	@printf "  \033[36m%-22s\033[0m %s\n" "core-backend-<lane>" "any core BACKEND lane, staged first"

# ─────────────────────────────── setup ────────────────────────────────

## install — one command from a fresh clone to a working checkout.
##
## `init` assumed a toolchain and went straight into core's install, so a
## machine missing one failed deep inside somebody else's Makefile with a
## message about that Makefile. The preflight runs first and names every gap at
## once. INSTALL_TOOLS=1 lets brew fill the ones it can — opt-in, because
## installing software on a machine is the owner's decision, not a lane's.
install: ## Everything needed to start: check prerequisites, then init
	@$(if $(INSTALL_TOOLS),bash scripts/preflight.sh tools,true)
	@bash scripts/preflight.sh check
	@$(MAKE) init

preflight: ## Report missing prerequisites without changing anything
	@bash scripts/preflight.sh check

init: ## Check out core, install dev deps, hooks and config
	git submodule update --init --recursive
	$(MAKE) -C $(CORE) install
	$(MAKE) hooks
	$(MAKE) config
	@$(MAKE) toolcheck
	@echo
	@echo "ready. next:"
	@echo "  make dev                 the full stack (starts the database)"
	@echo "  make u NAME=<unit>       one unit's tests, seconds"
	@echo "  make new-unit NAME=x     scaffold a unit"
	@# Flagged at init rather than left for `make watch` to discover: watch is
	@# the lane you reach for mid-task, which is the worst moment to find out
	@# a dependency is missing.
	@command -v fswatch >/dev/null || echo "note: fswatch is not installed — 'make watch' needs it (brew install fswatch)"

## PHONY matters here: the config/ directory would otherwise satisfy the target.
config: ## Create .env.local and config/, stage them into core/, refresh go.work
	@bash scripts/config-init.sh
	@bash scripts/gowork.sh
	@bash scripts/tsconfig-editor.sh

config-check: ## Are our config files still in step with core's examples?
	@bash scripts/config-check.sh

config-sync: ## Write the .env keys core's example has and ours lacks (commented)
	@bash scripts/config-sync.sh

## toolcheck — the tools here must be the ones CI runs. The pinned pnpm version
## is read out of core's own workflow rather than restated, and only the MAJOR is
## compared: pnpm 10 and 11 read different files for the same setting, which is
## how a lane goes green locally and red in CI on a config nobody touched.
toolcheck: ## Verify local tool versions match core's CI
	@bash scripts/toolcheck.sh

hooks: ## Install the git hooks (pre-push runs test-scripts)
	git config core.hooksPath .githooks
	@echo "hooks: core.hooksPath -> .githooks"

# ────────────────────────────── staging ───────────────────────────────

stage: ## Copy extensions/* into core/extensions/ (every lane depends on this)
	@bash scripts/stage.sh
	@# Our env and deployment config are staged the same way and for the same
	@# reason: core reads them at those paths, and a copy that only `make config`
	@# refreshed would serve a lane the settings of an earlier edit.
	@bash scripts/config-init.sh stage
	@# Refreshes the two files that exist for EDITORS: go.work for gopls,
	@# tsconfig.json for tsserver. Both are written only when the unit set
	@# changed, so this does not churn their mtimes. They are a PAIR — a unit
	@# imports the host in both languages, so wiring only one leaves every
	@# unit's frontend/ red in the editor while the build passes.
	@bash scripts/gowork.sh
	@bash scripts/tsconfig-editor.sh

unstage: ## Remove our staged units, leaving a pristine core checkout
	@bash scripts/unstage.sh

compose: stage ## Run upstream's composer over the staged set
	@# Piped: the composer is the first thing a new unit fails, and it names the
	@# offending file by ABSOLUTE path inside the submodule.
	@set -o pipefail; $(MAKE_CORE) composition 2>&1 $(REWRITE)
	@# Discard the composed frontend workspace's lockfile, because the composer
	@# has just rewritten that workspace's MEMBER SET and the lockfile describes
	@# the old one. Core's lane installs there without --no-frozen-lockfile, and
	@# pnpm's default flips to frozen under CI — so a stale lockfile is
	@# ERR_PNPM_OUTDATED_LOCKFILE rather than a re-resolve. It bites here on every
	@# run, not occasionally: `make check` installs once with core's members and
	@# again with ours, so the second install always disagrees with the first.
	@#
	@# Deleting it is safe and cheap: the file is generated, it lives under
	@# ignored build output, and a fresh resolve comes from the store. Remove this
	@# once upstream's fix lands (margince/margince#2251) — the flag
	@# belongs in core's lane, and this is the downstream half of the same repair.
	@rm -f $(CORE)/build/composition-frontend/workspace/pnpm-lock.yaml
	@bash scripts/sync-manifests.sh

## Staging is a copy, so Vite watches the copy and never sees an edit here. A
## symlinked frontend layer would fix it properly; the composer refuses one
## (docs/superpowers/notes/spike-b-frontend-symlink.md). Needs fswatch.
watch: ## Re-stage units whenever a source file changes
	@command -v fswatch >/dev/null || { echo "watch: needs fswatch (brew install fswatch)" >&2; exit 1; }
	@echo "watch: re-staging on change under extensions/ — ctrl-c to stop"
	@fswatch -o extensions/ | while read -r _; do \
		printf 'watch: change detected, re-staging\n'; \
		bash scripts/stage.sh >/dev/null && printf 'watch: staged\n' || printf 'watch: stage FAILED\n'; \
	done

# ───────────────────────────── inner loop ─────────────────────────────

new-unit: ## Scaffold a unit from scripts/unit-skeleton (NAME=<name>)
	@bash scripts/new-unit.sh "$(NAME)"

## u — ONE unit's tests plus the cheap policy gates. The gates are in here
## deliberately: they are seconds, so a policy failure should be the fastest
## failure you see, not the slowest. ~14s warm.
u: compose ## One unit's tests + policy gates (NAME=<unit>)
	@[ -n "$(NAME)" ] || { echo "u: pass NAME=<unit>, e.g. make u NAME=acme-sync" >&2; exit 1; }
	@[ -d extensions/$(NAME) ] || { echo "u: no such unit: extensions/$(NAME)" >&2; exit 1; }
	@echo "== go test: $(NAME)"
	@# In the STAGED copy: the composed go.work `use`s core/extensions/<unit>, so
	@# `go test` in the source dir fails with "directory prefix . does not contain
	@# modules listed in go.work". The copy is byte-identical.
	@# Both sides of that check must resolve from the SAME path kind: $(CURDIR) is
	@# make's physical cwd (symlinks resolved), but a RELATIVE `cd` stays on the
	@# shell's logical $PWD. Under a symlinked checkout (macOS puts every `mktemp
	@# -d` under /var/folders, itself a symlink to /private/var/folders) the two
	@# diverge by the /private prefix, and go reports the same "directory prefix"
	@# error even from the staged copy. Making the `cd` absolute from $(CURDIR)
	@# keeps both physical, so they agree.
	@cd $(CURDIR)/$(CORE)/extensions/$(NAME) && GOWORK=$(CURDIR)/$(CORE)/build/composition/go.work go test ./...
	@echo "== policy gates"
	@# Piped through REWRITE like every other delegating lane: without it a
	@# finding names core/extensions/<unit>/…, the staged copy that must not be
	@# edited and that the next compose overwrites.
	@set -o pipefail; $(MAKE) -C $(CORE) ext-imports 2>&1 $(REWRITE)
	@set -o pipefail; $(MAKE) -C $(CORE) fitness-jurisdiction 2>&1 $(REWRITE)
	@$(MAKE) compose >/dev/null
	@$(MAKE) check-manifests

## Separate from `u` because it is neither per-unit nor fast: core's fe-test-ext
## installs the composed workspace, builds the whole SPA and runs EVERY unit's
## vitest suite with no filter.
##
## NO NAME= filter, deliberately. core's fe-test-ext ends in a bare
## `pnpm test:ext` and forwards no arguments, so there is nothing downstream to
## pass a filter to. Accepting NAME= here would take the argument and ignore it,
## which is worse than not offering one. Making it filterable is a change to
## core's lane — which is what `make core-branch` is now for.
u-fe: compose ## Every unit's screen suite (not per-unit; slow)
	@$(MAKE) -C $(CORE) fe-test-ext

u-check: u ## One unit, plus the screen suites and the composed typecheck (NAME=<unit>)
	@$(MAKE) u-fe
	@$(MAKE) -C $(CORE) fe-typecheck-composed

# ─────────────────────────────── gates ────────────────────────────────

## check runs in TWO passes, and has to. Core's own `check` includes
## TestEveryEnabledExtensionIsTracked, which asserts every unit under
## extensions/ is tracked BY CORE — false by construction for a staged unit, so
## that lane can never pass with ours present. Pass 1 therefore runs upstream's
## gate on a PRISTINE checkout (delegated wholesale, so no copy of its gate list
## lives here to go stale); pass 2 runs the gates that can see our units.
## check-public runs here only when .template-version is ABSENT — i.e. only in
## the template itself, never in an instance. An instance inherits
## scripts/check-public.sh unchanged (it is template-owned) but has no reason
## to run it: it is not the thing that gets published, and it may legitimately
## carry the client's own private values.
check: toolcheck check-instance check-template $(if $(wildcard .template-version),,check-public) test-scripts test-secret-scan secret-scan ## The full gate: upstream's own, then the composed set
	@echo "== pass 1: upstream's own gate, units unstaged"
	@$(MAKE) unstage
	@$(MAKE) -C $(CORE) check
	@echo "== pass 2: the composed gates, units staged"
	@$(MAKE) lint check-composition build test-extensions arch \
		fe-test-ext fe-typecheck-composed fe-ds-gates ext-imports \
		check-ext-migrations check-manifests check-docs drift

## ci — the one command that means "what CI would say".
##
## Two words because `check` already IS the aggregate: it takes toolcheck,
## test-scripts, test-secret-scan and secret-scan as prerequisites and runs
## lint (whose first leg is the gofmt check, so format is covered without
## mutating anything), the composed build, every unit's test lane, the arch
## fitness tests, the screen suites and the composed typecheck. Restating those
## here would put the dependency graph in a second place to drift from.
##
## What ci adds is the database check has never had, plus the two assertions
## that used to live ONLY in the workflow file — the pinned core commit, and the
## submodule coming out of a build pristine. While those were CI-only, `make ci`
## could pass on a tree CI rejects, which is the one thing this lane exists to
## rule out.
##
## SEQUENTIAL, and it has to be. Every leg drives staging — `check` pass 1 runs
## `unstage`, and test-integration-ext's `compose` prerequisite runs `stage`,
## which rm -rf's and recopies each staged unit. As sibling prerequisites under
## `make -j` those race, and a lane would test a half-copied tree or leave
## residue in core/ that a later gate misreads. Recipe lines run in order.
##
## The core-clean check is LAST because it is the only one that asserts what the
## whole run left behind, and it needs an unstaged tree to do it.
ci: ## Everything check runs, plus the real-database and submodule lanes
	@$(MAKE) check
	@$(MAKE) test-integration-ext
	@$(MAKE) core-check-pin
	@$(MAKE) unstage
	@bash scripts/check-core-clean.sh
	@echo
	@echo "ci: all lanes passed"

## Every variable is passed single-quoted, from its unexpanded value: inside
## double quotes a DISPLAY_NAME holding `"`, a backtick or `$` would be cut
## short, run as a command, or expanded. Each `'` becomes '\'' (close, escaped
## quote, reopen).
new-instance: ## Create your instance repository from this template (NAME=, DISPLAY_NAME=, DIR=, DOMAIN=, SSH=, ADMIN_EMAIL=, PUSH=1 OWNER=)
	@NAME='$(subst ','\'',$(value NAME))' \
		DISPLAY_NAME='$(subst ','\'',$(value DISPLAY_NAME))' \
		DIR='$(subst ','\'',$(value DIR))' \
		DOMAIN='$(subst ','\'',$(value DOMAIN))' \
		SSH='$(subst ','\'',$(value SSH))' \
		ADMIN_EMAIL='$(subst ','\'',$(value ADMIN_EMAIL))' \
		PUSH='$(subst ','\'',$(value PUSH))' \
		OWNER='$(subst ','\'',$(value OWNER))' \
		bash scripts/new-instance.sh

release: ## Tag and push a release (VERSION=vX.Y.Z or vX.Y.Z-rc.N); release.yml builds it
	@# env -u: as with deploy below, make exports its command-line variables
	@# and its own MAKEFLAGS to the recipe. release.sh's own `git push` runs
	@# this repository's pre-push hook when one is installed, an unrelated
	@# `make test-scripts` that would otherwise inherit MAKEFLAGS and
	@# silently re-apply RELEASE_CHECK_TARGET (or VERSION) as if they were
	@# ITS OWN command-line overrides. release.sh receives its settings as
	@# plain, non-MAKEFLAGS environment variables instead.
	@env -u VERSION -u MAKEFLAGS -u MAKELEVEL -u MFLAGS \
		RELEASE_REMOTE='$(subst ','\'',$(value RELEASE_REMOTE))' \
		RELEASE_BRANCH='$(subst ','\'',$(value RELEASE_BRANCH))' \
		RELEASE_CHECK_TARGET='$(subst ','\'',$(value RELEASE_CHECK_TARGET))' \
		bash scripts/release.sh '$(subst ','\'',$(value VERSION))'

deploy-init: ## Scaffold a deploy environment and register it in instance.yaml (ENV=, ADAPTER=host|hook, DOMAIN=, SSH=, ADMIN_EMAIL=)
	@ENV='$(subst ','\'',$(value ENV))' \
		ADAPTER='$(subst ','\'',$(value ADAPTER))' \
		DOMAIN='$(subst ','\'',$(value DOMAIN))' \
		SSH='$(subst ','\'',$(value SSH))' \
		ADMIN_EMAIL='$(subst ','\'',$(value ADMIN_EMAIL))' \
		bash scripts/deploy-init.sh

deploy: ## Deploy this instance to an environment in instance.yaml (ENV=, VERSION=, ALLOW_DIRTY=1)
	@# env -u: make exports its command-line variables (ENV, VERSION) and its
	@# own MAKEFLAGS to the recipe, and a hook that runs make would inherit
	@# them as overrides. deploy.sh receives both as arguments instead.
	@env -u ENV -u VERSION -u MAKEFLAGS -u MAKELEVEL -u MFLAGS \
		ALLOW_DIRTY='$(subst ','\'',$(value ALLOW_DIRTY))' bash scripts/deploy.sh '$(subst ','\'',$(value ENV))' '$(subst ','\'',$(value VERSION))'

host-bootstrap: ## Install Docker and Compose on a new server for a host environment (ENV=)
	@# Single-quoted like deploy's arguments, so a quote in ENV stays data.
	@bash scripts/deploy/host/bootstrap.sh '$(subst ','\'',$(value ENV))'

host-admin-password: ## Print the generated first admin password of a host environment (ENV=)
	@bash scripts/deploy/host/admin-password.sh '$(subst ','\'',$(value ENV))'

## local-up — run the images of VERSION= (make package VERSION=<v>) on this
## machine with the host adapter's compose and Caddy files: https://localhost,
## PostgreSQL, Redis, the generated keys and admin password. State is kept in
## .local/ (ignored by git); a second run keeps the keys, password and data.
local-up: ## Run a built release on https://localhost (VERSION=; MARGINCE_LICENSE in the environment for production mode)
	@bash scripts/local.sh up '$(subst ','\'',$(value VERSION))'

local-down: ## Stop the local stack; WIPE=1 also removes its data and .local/
	@WIPE='$(subst ','\'',$(value WIPE))' bash scripts/local.sh down

local-admin-password: ## Print the generated first admin password of the local stack
	@bash scripts/local.sh admin-password

license: ## Obtain a production license into a file (OUT=<file>); see docs/license.md
	@test -n "$(OUT)" || { echo "license: pass OUT=<file>" >&2; exit 2; }
	@bash scripts/license.sh production "$(OUT)"

check-instance: ## instance.yaml is valid and names the tag core/ is at
	@cd scripts/cli && GOWORK=off go run . check -file $(CURDIR)/instance.yaml -core $(CURDIR)/$(CORE)

check-template: ## Template-owned paths match the template commit this instance merged; instance.mk only adds targets
	@bash scripts/check-instance-mk.sh
	@bash scripts/check-template.sh

template-sync: ## Merge margince/template's main into this instance and record it in .template-version
	@bash scripts/template-sync.sh

test-cli: ## The template CLI's own tests
	@cd scripts/cli && GOWORK=off go vet ./... && GOWORK=off go test ./...

test-lifecycle: ## The whole instance lifecycle in a scratch instance (slow; KEEP=1 keeps it)
	@KEEP='$(subst ','\'',$(value KEEP))' bash scripts/lifecycle.test.sh

## The composition is generated, so "it compiles" is not evidence on its own —
## this is the gate that proves the tree can be rebuilt.
check-composition: compose ## Reproducibility: regeneration must be byte-identical
	@$(MAKE_CORE) check-composition

build: compose ## Build the composed binaries
	@set -o pipefail; $(MAKE_CORE) build 2>&1 $(REWRITE)

## Our units' own tests plus the arch gates — the suites that can pass with our
## units staged. Upstream's full backend suite runs in `check` pass 1.
test: test-extensions arch ## Our units' tests + the composed arch gates

## Each unit is its own Go module, so upstream's ./... never reaches it.
test-extensions: compose ## Every staged unit's own test lane
	@set -o pipefail; $(MAKE_CORE) test-extensions 2>&1 $(REWRITE)

## The import boundary for OUR units runs here or nowhere: the composed tree is
## the only place extensions_arch_test.go can see them. Named tests rather than
## core's whole `test` lane — see `check`. -count=1 because they scan files
## outside their package, which Go's test cache cannot key.
##
## The PACKAGE is found rather than named. It was `backend/` itself until
## upstream moved the fitness tests into `backend/gates/`, and a hardcoded `.`
## then failed with "no Go files in core/backend" — which at least fails loudly.
## A hardcoded `./gates` would not: the day upstream moves them again, `go test`
## on a package whose tests have left reports ok, and the import boundary this
## repository exists to hold stops being checked without a word.
ARCH_TESTS := TestExtensionsImportOnlyTheAllowlistedSurface|TestSurfaceMarkerLivesOnlyUnderPkg|TestCompositionWiredOnlyFromCmd
arch: compose ## Upstream's arch fitness tests over the composed tree
	@# Absolute `cd` from $(CURDIR), same reason as `u`'s go test call: it must
	@# agree with GOWORK's $(CURDIR)-based path under a symlinked checkout.
	@set -o pipefail; cd $(CURDIR)/$(CORE)/backend \
		&& pkg="$$(grep -rl 'func TestExtensionsImportOnlyTheAllowlistedSurface' \
			--include='*_test.go' . | head -1 | xargs -r dirname)"; \
		[ -n "$$pkg" ] || { \
			echo "arch: upstream no longer carries TestExtensionsImportOnlyTheAllowlistedSurface" >&2; \
			echo "      anywhere under core/backend. The import boundary for our units is" >&2; \
			echo "      unheld until this target is pointed at whatever replaced it." >&2; \
			exit 1; }; \
		echo "arch: $(ARCH_TESTS) in $$pkg"; \
		GOWORK=$(CURDIR)/$(CORE)/build/composition/go.work go test -count=1 "$$pkg" \
			-run '$(ARCH_TESTS)' 2>&1 $(REWRITE)

ext-imports: compose ## The unit import allowlist
	@set -o pipefail; $(MAKE) -C $(CORE) ext-imports 2>&1 $(REWRITE)

## This gate needs a database. It starts one only when a unit under
## $(CORE)/extensions declares a migrations/ layer. Core ships units with
## migrations of its own — openchannel is one — so once units are staged the
## condition is normally true and the database starts on every run. An
## instance's own units with migrations are covered by the same scan.
##
## ARMED OFF THE TREE rather than by a plain `db-up` prerequisite, which is how
## core's own lane and CI both decide: the scan decides whether the cluster is
## needed, not a fixed rule. An unconditional prerequisite would start Postgres
## even for a gate that is about to exit 0.
##
## Scanned in $(CORE)/extensions, not our own extensions/: `stage` (compose's
## prerequisite) copies our units in there, and core's own shipped units are
## already there alongside them. Checking our extensions/ here would miss
## core's own migrations and never start the cluster for the template, which
## ships no units of its own.
check-ext-migrations: compose ## Unit migration rules
	@if ls -d $(CORE)/extensions/*/migrations >/dev/null 2>&1; then \
		echo "check-ext-migrations: a unit declares migrations/ — starting the test cluster"; \
		$(MAKE) db-up; \
	fi
	@$(MAKE) -C $(CORE) check-ext-migrations

## Its own target, not a line inside `u`, because three callers need it: the
## per-unit lane, the aggregate gate, and CI. See scripts/check-manifests.sh for
## why it is two checks.
check-manifests: ## Unit manifests are committed and current
	@bash scripts/check-manifests.sh

## The cheap, mechanical half of keeping the docs honest. It cannot tell whether
## a target does what the prose claims — only a human reading the recipe can —
## but a documented command that does not exist is caught for free.
check-docs: ## Every `make <target>` the docs name exists
	@bash scripts/check-docs.sh

## Public-template gate (spec Section 7): no tracked or staged file names a
## private repository, host, organization or service. Only docs/superpowers/
## and scripts/check-public.patterns itself may. `check` above adds this only
## when .template-version is absent — see the comment there.
check-public: ## No private repository/host/organization/service is named (template only)
	@bash scripts/check-public.sh

drift: compose ## Generated artifacts match their sources
	@$(MAKE_CORE) drift

## lint — the tier core holds its own units to, over OURS. Core's lint-modules
## and gofmt gates enumerate with `git ls-files`, so they see only what CORE
## tracks and walk straight past a staged copy. Same tools, same configs:
## gofmt, golangci-lint per unit module, craft, and biome over unit frontends.
lint: ## gofmt + golangci-lint + craft + biome over extensions/
	@bash scripts/lint.sh

fmt: ## Format extensions/ in place (gofmt -w, biome safe fixes)
	@bash scripts/fmt.sh

## Synthetic trees only: no submodule, about a second. The fastest gate here and
## the one most likely to catch a staging regression.
test-scripts: ## The staging scripts' own tests
	@bash scripts/lib.test.sh
	@bash scripts/git-env.test.sh
	@bash scripts/new-unit.test.sh
	@bash scripts/update-core.test.sh
	@bash scripts/toolcheck.test.sh
	@bash scripts/core-contrib.test.sh
	@bash scripts/preflight.test.sh
	@bash scripts/check-manifests.test.sh
	@bash scripts/check-public.test.sh
	@bash scripts/build-info.test.sh
	@bash scripts/desktop-kit.test.sh
	@bash scripts/workflow-wiring.test.sh
	@bash scripts/desktop-arch.test.sh
	@bash scripts/check-instance-mk.test.sh
	@bash scripts/check-template.test.sh
	@bash scripts/template-sync.test.sh
	@bash scripts/new-instance.test.sh
	@bash scripts/deploy-init.test.sh
	@bash scripts/local.test.sh
	@bash scripts/deploy.test.sh
	@bash scripts/license.test.sh
	@bash scripts/release.test.sh
	@bash scripts/package.test.sh
	@bash scripts/smoke.test.sh
	@bash scripts/trial.test.sh
	@bash scripts/aio.test.sh
	@bash scripts/aio-install.test.sh
	@if command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -NonInteractive -File scripts/aio-install.test.ps1; \
	  else echo "aio-install.test.ps1: skipped (pwsh is not installed; CI runs it)"; fi
	@bash scripts/deploy/host/render.test.sh
	@bash scripts/deploy/host.test.sh
	@bash scripts/deploy/host/bootstrap.test.sh
	@$(MAKE) test-cli

## Reads a `git archive HEAD` export, not the working tree: gitleaks ignores
## .gitignore, and this checkout holds core/ plus staged copies.
secret-scan: ## No hardcoded credential reaches main
	@bash scripts/secret-scan.sh

test-secret-scan: ## Prove the secret gate still catches
	@bash scripts/secret-scan.test.sh

# ────────────────────────────── frontend ──────────────────────────────

fe-install: ## Install the composed frontend's deps
	@$(MAKE) -C $(CORE) fe-install

## fe-test is core's PLAIN (un-composed) SPA suite, so it needs no compose.
fe-test: ## Core's SPA unit suite (un-composed)
	@$(MAKE) -C $(CORE) fe-test

fe-test-ext: compose ## Our units' own screen suites (the composed lane)
	@set -o pipefail; $(MAKE) -C $(CORE) fe-test-ext 2>&1 $(REWRITE)

fe-typecheck-composed: compose ## Typecheck the SPA against the composed contract
	@$(MAKE) -C $(CORE) fe-typecheck-composed

## fe-ds-gates — core's design-system gates, over OUR units' screens.
##
## Driven by core's recipe rather than a list kept here, so a gate added upstream
## joins this lane by itself — but through scripts/fe-ds-gates.sh, which drops
## the ONE command in that recipe that cannot mean anything downstream. It is
## diff-scoped against core's own origin/main, and a pinned submodule has no
## branch for that to be about; the script says so at length.
##
## It reaches our units only because `compose` staged them: the gates sweep
## <core>/extensions/*/frontend, which IS our units for the length of this run.
## Upstream widened check-font-lock.sh and check-space-tokens.sh to that tier in
## 792f0a45 — before it, a unit's fonts and spacing tokens were ungated here and
## nothing said so.
##
## Cheap on purpose: shell greps plus two bash fitness tests, no pnpm install and
## no vitest, which is why the light gate can afford it.
fe-ds-gates: compose ## The design-system gates over our units' screens
	@set -o pipefail; bash scripts/fe-ds-gates.sh 2>&1 $(REWRITE)

fe-lint: compose ## Biome over the composed frontend
	@$(MAKE) -C $(CORE) fe-lint

# ───────────────────────────── dev stack ──────────────────────────────

## dev — Postgres, Redis, the api, the worker and Vite, with our units in it.
## `stage` rather than `compose`: dev.sh runs the composer itself.
##
## A BARE `make dev` CLAIMS THE MACHINE — it kills every margince
## api/worker/vite, evicts whatever holds :8080 and drops stray margince_dev_*
## databases. Use DEV_SLUG=<name> when another worktree has a stack up; a
## slugged stack sweeps nothing and gets its own database and ports.
dev: stage ## The composed dev stack (DEV_SLUG=<name> for an isolated one)
	@$(MAKE) -C $(CORE) dev DEV_SLUG=$(DEV_SLUG)

dev-fresh: stage ## The dev stack on a rebuilt database (DEV_SLUG=<name>)
	@$(MAKE) -C $(CORE) dev-fresh DEV_SLUG=$(DEV_SLUG)

## Bare, this stops EVERY stack on the machine — the mirror of what a bare
## `make dev` sweeps.
dev-stop: ## Stop the dev stack (DEV_SLUG=<name>, DROP=1 drops its database)
	@$(MAKE) -C $(CORE) dev-stop DEV_SLUG=$(DEV_SLUG) DROP=$(DROP)

dev-logs: ## Tail the stack's log (ROLE=, LEVEL=, FOLLOW=0 N=, ALL=1)
	@$(MAKE) -C $(CORE) dev-logs DEV_SLUG=$(DEV_SLUG) ROLE=$(ROLE) LEVEL=$(LEVEL) \
		ALL=$(ALL) FOLLOW=$(FOLLOW) N=$(N)

## A cold `make dev` boots an installation whose admin password must be replaced
## before the account works at all. This performs that first login, lands on the
## documented demo-password-123, and adds the demo records. Idempotent.
seed-dev: ## Demo workspace + records on the running stack (needs make dev)
	@$(MAKE) -C $(CORE) seed-dev

## seed-demo — the commercial demo dataset, on a running stack.
##
## DATASET is core's own variable and keeps its meaning; only the RESOLUTION is
## done here. core derives its own default from its own git-common-dir, which
## under a submodule is <instance>/.git/modules/core — so core's default lands
## inside a git directory that can never hold a dataset checkout. There is no
## default here either, and deliberately: the only sensible default would name
## the dataset's own (private) repository, in every message this builds from
## it. DATASET is required instead, with a message.
##
## Routed through dataset_path whenever it IS given. A bare `?=` took a
## command-line value verbatim, so a relative `DATASET=../some-dir` passed the
## test -f below (resolved from the instance root) and then reached
## `$(MAKE) -C core`, which resolves it from core/ — a different directory. An
## absolute path is the only spelling both sides agree on.
##
## DATASET_GIVEN is what the CALLER typed, captured BEFORE the override below
## resolves it. The desktop lanes need that distinction and this is the only
## place it survives: after the override, DATASET is either resolved to an
## absolute path or still empty, and `$(origin DATASET)` reads "override"
## whether or not anyone passed one. A desktop installation carries its own
## data/demo, and preferring it over an explicit DATASET is only possible
## while "nobody said" is still visible.
DATASET_GIVEN := $(DATASET)
override DATASET := $(if $(DATASET),$(shell . $(CURDIR)/scripts/lib.sh; dataset_path "$(DATASET)"))

seed-demo: ## Fill the running stack from the demo dataset (DATASET=<path> required)
	@[ -n "$(DATASET)" ] || { \
	  echo "seed-demo: DATASET=<path> required — clone the demo dataset repository, then:" >&2; \
	  echo "  make seed-demo DATASET=/path/to/it" >&2; \
	  exit 1; }
	@test -f "$(DATASET)/datasets/v1/demo.json" || { \
	  echo "seed-demo: no dataset at $(DATASET)" >&2; \
	  exit 1; }
	@$(MAKE) -C $(CORE) seed-demo DATASET="$(DATASET)" SEED_ARGS="$(SEED_ARGS)"

verify-demo: ## Re-run the demo seeder's verify pass, writing nothing
	@$(MAKE) -C $(CORE) verify-demo DATASET="$(DATASET)"

run: dev ## Alias for dev, kept because older notes use it

# ──────────────────────────── containers ──────────────────────────────
# These act on the SHARED compose project, so they are not private to this
# checkout: infra-down stops another worktree's stack too.

infra-up: ## Start Postgres, Redis and MinIO
	@$(MAKE_CORE) infra-up

infra-down: ## Stop the containers, KEEPING their data
	@$(MAKE_CORE) infra-down

infra-logs: ## Tail the containers' logs
	@$(MAKE_CORE) infra-logs

## DESTRUCTIVE, and the one lane here that destroys data nobody can get back: it
## drops the compose VOLUMES, so every database on that server goes — another
## checkout's included. Want just your own database rebuilt? `make dev-fresh`.
infra-reset: ## DESTRUCTIVE: wipe the containers' volumes, then bring them back
	@$(MAKE_CORE) infra-reset

db-up: ## Start the database and Redis
	@$(MAKE_CORE) db-up

migrate: compose ## Apply migrations, ours included
	@$(MAKE_CORE) migrate

test-integration: compose ## Core's integration lane, composed
	@$(MAKE_CORE) test-integration

## test-integration-ext — our units against a REAL database.
##
## Core's integration lane cannot do this job: its
## scripts/test-integration-parallel.sh sets GO_DIRS=(backend), so it never
## discovers an extension module. Three units ship migrations/ and, before this
## lane, nothing ever executed that SQL against a cluster.
test-integration-ext: compose db-up ## Unit migrations + unit integration tests, on a real database
	@set -o pipefail; bash scripts/test-integration-ext.sh $(REWRITE)

# ───────────────────────────── packaging ──────────────────────────────

## package — the api, worker and web images, with our units in them. Built from
## CORE's Dockerfile and bake file, so there is no second build definition here
## to drift from upstream's; staging is what puts our units in the context, and
## the Dockerfile's own gen-composition step folds them in.
##
## ROLE=api builds one. VERSION= overrides the tag (default: this repo's tag or
## short SHA). REPO= overrides the name. ALLOW_DIRTY=1 permits a throwaway build
## from an uncommitted tree. The images are loaded into the local image store;
## PUSH=1 (with REGISTRY=) pushes them for every platform in PLATFORMS= instead.
package: compose ## Build the role images with our units (ROLE=, VERSION=, REPO=, PLATFORMS=, PUSH=1)
	@bash scripts/package.sh

## smoke — run the three images built by `make package VERSION=<v>` with a
## temporary PostgreSQL and Redis on a private network, and check them: api
## answers /readyz, web answers /, worker is running. Removes everything it
## started. SMOKE_TIMEOUT= (seconds, default 180) bounds each wait; SMOKE_SETTLE=
## (seconds, default 10) is how long the worker must stay running.
smoke: ## Start the role images with a temporary database and check them (VERSION=, SMOKE_TIMEOUT=, SMOKE_SETTLE=)
	@bash scripts/smoke.sh "$(VERSION)"

# ─────────────────────────── desktop build ────────────────────────────

# Core's build writes here; DESKTOP_OUT is our mirror of it, outside the
# submodule. Both are ignored (core/.gitignore, .gitignore).
DESKTOP_SRC := $(CORE)/build/desktop/margince
DESKTOP_OUT := build/desktop/margince

## Empty when VERSION is unset, so the flag is absent rather than passed with an
## empty value — build-info.sh distinguishes the two, and `--version ""` would
## name the build the empty string instead of falling back to the derived one.
VERSION_FLAG := $(if $(VERSION),--version $(VERSION),)

## SEEDED=1 re-stamps a folder whose database was filled in the build: the demo
## loader and the seeder it drives come OUT, and the README stops describing a
## dataset the recipient no longer has to fetch.
SEEDED_FLAG := $(if $(SEEDED),--seeded,)

## desktop — the self-contained macOS folder (Postgres, bus, api, worker, web,
## launcher; no Docker), with our units composed into it. ~5 min on the first
## run, which compiles Postgres; minutes after that.
##
## Upstream owns the build — core/desktop/, documented in
## core/docs/how-to/build-the-desktop-app.md. This lane exists for two reasons
## that are ours rather than upstream's: `compose` runs first, so the folder is
## built from a tree with our units staged in it, and `desktop-mirror` copies
## the result out of the submodule afterwards.
##
## It calls core's three stages directly rather than going through the
## `core-root-%` rule, because that rule re-STAGES and `compose` has just done
## it. Until core commit 50f57116 there was a second, sharper reason: core's
## build-app.sh installed only the root pnpm workspace, so every unit screen
## failed to resolve react and this lane carried the missing install itself.
## Upstream does that install now, and refuses loudly if the composed workspace
## is absent, so the workaround is gone.
##
## VERSION= names the build. It reaches the folder through desktop-kit, which
## writes it into BUILD-INFO.txt and runtime/build-info.json — the only record
## an unzipped folder has of what it is. A release lane passes its tag; left
## unset it is derived, and scripts/build-info.sh owns that rule.
desktop: compose ## The self-contained macOS desktop folder, with our units (VERSION=)
	@$(MAKE) -C $(CORE) desktop-deps
	@$(MAKE) -C $(CORE) desktop-app
	@$(MAKE) -C $(CORE) desktop-dist
	@$(MAKE) desktop-mirror
	@$(MAKE) desktop-kit VERSION="$(VERSION)"

## desktop-mirror — copy the built folder out of the submodule into ./build/.
##
## Reachable on its own so a re-mirror does not rebuild. Two reasons it exists
## at all: core's `make clean` drops core/build/ wholesale, and an artifact of
## this installation reads better outside upstream's tree than inside it.
##
## It does NOT make the folder runnable, and the message below says so rather
## than letting the launcher be the one to explain it. macOS caps a unix socket
## path at 103 bytes; the launcher appends /data/sockets/.s.PGSQL.5432 (27) to
## the install root, so the root must be <= 76 bytes. This checkout's path is
## 79 before `build/desktop/margince` is added, so NO in-tree location can run
## — moving it here saves 5 bytes against a 26-byte deficit. Copy it out.
desktop-mirror: ## Re-copy the built desktop folder into ./build/desktop/
	@test -d $(DESKTOP_SRC) || { \
		echo "desktop-mirror: $(DESKTOP_SRC) does not exist — run 'make desktop' first" >&2; exit 1; }
	@rm -rf $(DESKTOP_OUT)
	@mkdir -p $(dir $(DESKTOP_OUT))
	@cp -Rp $(DESKTOP_SRC) $(DESKTOP_OUT)
	@echo "desktop: $(DESKTOP_OUT) ($$(du -sh $(DESKTOP_OUT) | cut -f1))"
	@echo "desktop: it cannot run from here (socket path > 103 bytes). Next:"
	@echo "         make desktop-install   copy it to $(DESKTOP_DEST)"
	@echo "         make desktop-run       start it"
	@echo "         make desktop-seed      fill it from the demo dataset"
	@echo "         make desktop-connect   start it reachable by Claude (tunnel + MCP)"

## ────────────────────────── the demo-data loader ──────────────────────────
##
## `make seed-demo` needs this repository, a Go toolchain and a composed
## workspace. Nobody who downloads a zip has any of the three — so the seeder
## ships INSIDE the folder as a binary, driven by a script beside it and a
## README that tells a non-technical reader where to put the dataset. That is
## the "kit", and scripts/desktop-kit/ is its source.
##
## The dataset itself never ships: it is a private repository. What ships is an
## empty data/demo and the instruction to fill it.
##
## `make desktop` stamps the macOS folder automatically. This is reachable on
## its own so a change to the loader does not mean a 20-minute rebuild.
desktop-kit: compose ## Stamp the loader and the build info into the folder (VERSION=, SEEDED=1)
	@DATASET="$(DATASET)" bash scripts/desktop.sh kit --dir $(DESKTOP_OUT) --os darwin $(VERSION_FLAG) $(SEEDED_FLAG)

## desktop-win-kit — the same, for a Windows folder built elsewhere (DIR=).
##
## Takes DIR because we cannot produce that folder here: upstream builds it with
## PowerShell ON a Windows host — pgvector has no build system but nmake against
## MSVC, and Redis needs MSYS2 — so `make desktop-win` is not a lane this
## repository can run. The seeder is the one half that DOES cross-build (pure Go,
## CGO_ENABLED=0), so this stamps a folder wherever it is: on the Windows host
## after `make -C core desktop-win`, or on a copy mounted here.
desktop-win-kit: compose ## Stamp the loader into a Windows desktop folder (DIR=, VERSION=)
	@test -n "$(DIR)" || { \
		echo "desktop-win-kit: DIR= is required — the path to a built margince-windows folder" >&2; exit 1; }
	@DATASET="$(DATASET)" bash scripts/desktop.sh kit --dir "$(DIR)" --os windows $(VERSION_FLAG) $(SEEDED_FLAG)

## trial — a production-mode desktop bundle with a trial license, for a client
## to evaluate on a laptop (design Section 9.4). It obtains the license first
## (scripts/license.sh trial; MARGINCE_TRIAL_LICENSE, or the license API), runs
## `make desktop`, and writes dist/trial/<name>-<v>-<platform>/. FORCE=1
## replaces an existing one.
trial: ## Build a trial desktop bundle with a trial license (VERSION=, FORCE=1)
	@bash scripts/trial.sh "$(VERSION)"

# ─────────────────────────── all-in-one image ─────────────────────────

## aio — one image with all of Margince, for non-technical testers (design
## docs/superpowers/specs/2026-09-30-all-in-one-image-design.md). Built from
## the role images of VERSION; runs `make package` when one is missing.
aio: ## Build the all-in-one image <repo>/all-in-one:<v> (VERSION=, DATASET=, PUSH=1)
	@bash scripts/aio.sh build "$(VERSION)"

aio-smoke: ## Run the all-in-one image on a temporary volume and check it (VERSION=, AIO_SMOKE_TIMEOUT=)
	@bash scripts/aio.sh smoke "$(VERSION)"

aio-up: ## Start the all-in-one image here; installs Docker when it is missing (VERSION=)
	@bash scripts/aio.sh up "$(VERSION)"

aio-down: ## Stop the all-in-one container; the data is kept
	@bash scripts/aio.sh down

aio-reset: ## Delete the all-in-one container and its data (asks first)
	@bash scripts/aio.sh reset

aio-logins: ## The address and the accounts of the running all-in-one container
	@bash scripts/aio.sh logins

aio-logs: ## The last 200 log lines of the all-in-one container
	@bash scripts/aio.sh logs

aio-scripts: ## Write dist/aio/<v>/install.sh and install.ps1 for testers (VERSION=)
	@bash scripts/aio.sh scripts "$(VERSION)"

# ──────────────────────── using the desktop folder ────────────────────
#
# The build produces a folder that cannot run where it was built, whose
# credentials live inside it, and whose seeding path is NOT `make seed-demo` —
# that lane is bound to the dev stack (core/config/margince-admin-password,
# :8080, the compose MinIO). These lanes are the gestures that were prose, and
# they need no Docker: the installation carries its own database and its own
# object storage. scripts/desktop.sh says why they are a script and not recipes.

## Where an installation lives. Short on purpose: the database socket path is
## capped at 103 bytes and the launcher refuses a folder that busts it.
DESKTOP_DEST ?= $(HOME)/Margince

desktop-install: ## Copy the built folder somewhere it can run (DESKTOP_DEST=~/Margince)
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh install

desktop-run: ## Start the installed desktop app in the foreground (DESKTOP_DEST=)
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh run

## desktop-connect — the same start, reachable by an agent.
##
## Three things have to be true together for Claude or ChatGPT to call this
## installation, and the folder's own "Connect to Claude.command" does all
## three: mcp.connector_enabled in margince.yaml, a tunnel to the app's port,
## and that tunnel's address in margince.env as MARGINCE_PUBLIC_BASE_URL.
##
## The tunnel is cloudflared, which needs no account. MARGINCE_TUNNEL=ngrok
## switches providers, and is inferred when NGROK_DOMAIN or NGROK_AUTHTOKEN is
## set — ngrok is what buys a RESERVED domain, and so an address that survives a
## restart. ngrok v3 opens no anonymous tunnel, which is why it is not default.
##
## The api mounts /mcp only when the deployment declares the connector, and it
## REFUSES TO BOOT with that declared and no public base URL — so none of the
## three is optional and the tunnel has to exist before the api starts.
##
## It publishes the whole installation, not just /mcp: the agent's consent flow
## is a browser sign-in on the public address, so the login page is on it too.
desktop-connect: ## Start it behind a public address, with MCP on (DESKTOP_DEST=)
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh connect

## desktop-seed — the commercial demo dataset, into a RUNNING installation.
##
## `compose` first, for the same reason core/backend's own seed-demo depends on
## composition: the seeder resolves the composed workspace, and an unstaged one
## has none of our units in it. DATASET= points at the dataset checkout; without
## it, a dataset already copied into the installation (data/demo) is used, and
## otherwise the lane refuses with a message. LIMIT= seeds fewer companies — but
## barely, and a small
## value FAILS: -limit truncates the company list alone while deals and contracts
## are seeded whole and resolve their company by domain, so the floor is the
## deepest company any of them names (193 of 198 today). docs/desktop-build.md
## measures it. SEED_ARGS= passes anything
## else through to the seeder (-dry-run, -limit N).
desktop-seed: compose ## Fill the running desktop app from the demo dataset (DATASET=, LIMIT=)
	@DEST="$(DESKTOP_DEST)" DATASET="$(DATASET_GIVEN)" bash scripts/desktop.sh seed \
		$(if $(LIMIT),-limit $(LIMIT),) $(SEED_ARGS)

desktop-verify: compose ## Re-run the seeder's verify pass on the desktop app, writing nothing
	@DEST="$(DESKTOP_DEST)" DATASET="$(DATASET_GIVEN)" bash scripts/desktop.sh verify

desktop-status: ## Where the installation is, whether it is up, how to sign in
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh status

## The sign-in screen says "accounts come from your administrator" and nothing
## else, so the accounts have to be discoverable from here.
desktop-logins: ## Every account that can sign in to the desktop app, and its password
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh logins

desktop-psql: ## psql on the desktop app's database, using the psql it ships
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh psql

desktop-dsn: ## How to point psql or a GUI client at the desktop app's database
	@DEST="$(DESKTOP_DEST)" bash scripts/desktop.sh dsn

desktop-clean: ## Remove both desktop build folders
	@rm -rf $(DESKTOP_OUT)
	@$(MAKE) -C $(CORE) desktop-clean 2>/dev/null || true

# ───────────────────────────── upstream ───────────────────────────────

## TWO pattern rules, not one: core's root and backend Makefiles both define
## build, test, check and migrate, so a single core-% would silently pick one.
core-root-%: stage ## Run any core ROOT lane, e.g. make core-root-storybook
	@$(MAKE) -C $(CORE) $*

core-backend-%: stage ## Run any core BACKEND lane, e.g. make core-backend-vet
	@$(MAKE_CORE) $*

core-status: ## Where core/ is: branch, pinned sha, ahead/behind, dirty
	@bash scripts/core-contrib.sh status

## The invariant "core/ moves only by update-core" was documentation until this
## lane existed. Cheap (one fetch) and in the push path, because the state it
## catches is one CI can be GREEN on — see scripts/core-contrib.sh.
core-check-pin: ## The pinned core commit is really on upstream's main
	@bash scripts/core-contrib.sh check-pin

core-branch: ## Start a core contribution branch (NAME=<type>/<slug>)
	@bash scripts/core-contrib.sh branch "$(NAME)"

core-restore: ## Return core/ to the commit this repo pins
	@bash scripts/core-contrib.sh restore

## core-pr — DCO first, because upstream's check BLOCKS the merge and an
## unsigned push costs a review cycle to discover. The push target is probed
## rather than configured: the team can write to origin, an outside contributor
## needs a fork, and a flag would be got wrong by whichever half did not read
## this comment.
core-pr: ## Verify sign-off, push the core branch, open the PR
	@bash scripts/core-contrib.sh pr

## core-check — upstream's OWN merge gate, on a pristine tree. This is the same
## work `make check` does in pass 1, addressable on its own: a core change is
## judged by core's gate, and running it here means the verdict arrives before
## the push rather than from CI afterwards.
core-check: ## Upstream's merge gate over core/, units unstaged
	@$(MAKE) unstage
	@$(MAKE) -C $(CORE) check

## The bump is a reviewable commit here: it is the only way core/ ever changes,
## and a composed build must pass before it lands. config-check and
## check-instance run after: a new core often needs new settings, and
## instance.yaml must name the tag core/ is now at.
update-core: ## Move core/ to a core release tag and record it in instance.yaml (REF=<tag>)
	@bash scripts/update-core.sh "$(REF)"
	@$(MAKE) config
	@$(MAKE) config-check
	@$(MAKE) check-instance
	@echo "run 'make check' before committing the bump"

clean: unstage ## Unstage and drop upstream's build output
	@$(MAKE_CORE) clean 2>/dev/null || true

# ──────────────────────────── instance.mk ─────────────────────────────

## Targets only this instance needs. instance.mk is instance-owned and
## optional. It may add targets; it must not redefine a template target, and
## it may assign only variables named INSTANCE_* (make check-template refuses
## both).
-include instance.mk
