# Public Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the template public-ready and complete the remaining lifecycle: release, license client, trial, single-server deployment, lifecycle test, and guides (issues T13, T16, T7, T15, T8, T10 part 2, T12).

**Architecture:** Bash scripts in `scripts/` with one `*.test.sh` each, wired into the `Makefile` and `make test-scripts`; the Go CLI in `scripts/cli` for `instance.yaml`; GitHub workflows in `.github/workflows/`; template-owned deployment files in `scripts/deploy/host/`.

**Tech Stack:** Bash (macOS 3.2 and Linux 5), GNU Make 3.81+, Go (`GOWORK=off`), Docker Buildx and Compose v2, Caddy 2, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-24-client-instance-template-design.md` (revised 2026-09-28). The spec is binding; read the sections named in each task.

## Global Constraints

- Release version pattern: `^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$`. Matches: `v1.2.0`, `v0.1.0`, `v1.3.0-rc.1`, `v10.0.12`. Does not match: `1.2.0`, `v1.2`, `v1.2.0-rc.0`, `v1.2.0-rc1`, `v1.2.0-beta.1`.
- Ordering: semantic versioning; `vX.Y.Z-rc.N` is older than `vX.Y.Z`; rc numbers compare numerically.
- Core release tags stay `v0.0.x` and are unaffected.
- Images: `<REGISTRY>/<name>/api|web|worker:<version>`, or `<name>/<role>:<version>` without `REGISTRY`. `<name>` is `name` from `instance.yaml`.
- Adapters: `hook` and `host`.
- No file outside `docs/superpowers/` and `scripts/check-public.patterns` names a private repository, private host, private organization, or private service (spec Section 7).
- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, source `scripts/lib.sh` for `ROOT`, `CORE`, `die`, `instance_get`, `instance_validate`, `image_repo`; Bash 3.2 compatible (no `mapfile`, no `${var,,}`, no associative arrays).
- Every new script has `scripts/<path>.test.sh` in the style of `scripts/deploy.test.sh` (scratch directory, `ok`/`fail`, non-zero exit on any failure) and is added to `test-scripts` in the `Makefile`.
- Tests unset `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX`, disable commit signing (`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false`), and set author and committer identity by environment, as `scripts/lifecycle.test.sh` lines 33–47 do.
- Tests need no network, server, registry, or license service. `ssh`, `scp`, `docker`, `curl` are replaced by stub scripts placed first on `PATH`.
- No secret or license value is printed or written to a log. Files that hold one are created with mode 600.
- Every `make <target>` named in `README.md`, `AGENTS.md`, `CLAUDE.md`, `docs/*.md` exists (`make check-docs`).
- Documentation: technical standard English; short declarative sentences; tables for options.
- Commits: Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- After every task: `make test-scripts`, `make test-cli`, and `make check-docs` pass.

## Review Focus

1. `make release` with a version equal to or older than an existing release (including `v1.2.0-rc.1` after `v1.2.0`) fails and leaves no tag locally or on the remote. Task 4 tests this.
2. A `host` deployment whose `docker compose up` fails on the server rolls back to the previous release directory and leaves `current` pointing at it. Task 7 tests this.
3. A secret listed in `deploy/<env>/secrets` whose value contains spaces, `$`, quotes, or `#` reaches the server's `.env` unchanged and is not printed. Task 7 tests this.
4. `scripts/license.sh` never prints the license or the account token, including on an HTTP error. Task 3 tests this.
5. `make check-public` catches a private reference in an untracked-to-tracked new file and in a workflow file. Task 2 tests this.

---

### Task 1: Remove `flavor`; accept `host` and `-rc.N`

**Files:**
- Modify: `scripts/cli/instance.go`, `scripts/cli/get.go`, `scripts/cli/*_test.go`
- Modify: `scripts/lib.sh` (`image_repo`; add `RELEASE_VERSION_RE`, `is_release_version`), `scripts/lib.test.sh`
- Modify: `scripts/new-instance.sh`, `scripts/new-instance.test.sh`, `Makefile:253-256` (remove `VENDOR`)
- Modify: `scripts/deploy.sh`, `scripts/deploy.test.sh`, `.github/workflows/deploy.yml`, `scripts/workflow-wiring.test.sh`
- Modify: `scripts/update-core.test.sh`, `scripts/lifecycle.test.sh`, `instance.yaml`, `README.md`, `docs/create-an-instance.md`

**Interfaces:**
- Produces in `lib.sh`:

```bash
# A template or instance release version (design Section 10).
RELEASE_VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$'
is_release_version() { [[ "${1:-}" =~ $RELEASE_VERSION_RE ]]; }

# image_repo — <REGISTRY>/<name>, or <name> without REGISTRY.
image_repo() {
  local name
  name="$(instance_get name)" || return 1
  if [ -n "${REGISTRY:-}" ]; then
    printf '%s/%s\n' "${REGISTRY%/}" "$name"
  else
    printf '%s\n' "$name"
  fi
}
```

- Produces in the CLI: `instance.yaml` keys `name`, `display_name`, `core`, `deploy.<env>.adapter`; `flavor` is an unknown key and is refused; adapters `hook`, `host`; the error for another adapter reads `deploy.<env>.adapter: "<value>" is not an adapter (want hook or host)`.

- [ ] **Step 1: Update the tests first.** CLI: remove `Flavor` from every fixture; add a case that `flavor: a/margince` is refused as an unknown key; add a case that `adapter: host` is valid; replace the `d13` case with `adapter: d13` refused by the generic adapter message. `lib.test.sh`: `image_repo` returns `acme` without `REGISTRY` and `registry.example.com/acme` with `REGISTRY=registry.example.com/`; `is_release_version` accepts and refuses every example in Global Constraints. `new-instance.test.sh`: remove the `VENDOR` case; assert the created `instance.yaml` has exactly the keys `name`, `display_name`, `core`. `deploy.test.sh`: fixtures without `flavor`; `IMAGE_API` is `acme/api:v1.0.0`; `VERSION=v1.0.0-rc.1` is accepted; `VERSION=v1.0.0-rc.0` and `VERSION=v1.0` are refused naming the pattern. `workflow-wiring.test.sh`: `deploy.yml` checks `"$REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$`. `lifecycle.test.sh`: the image assertion becomes `apply v0.1.0 lifecycle-demo/api:v0.1.0`.
- [ ] **Step 2: Run** `make test-cli; bash scripts/lib.test.sh; bash scripts/new-instance.test.sh; bash scripts/deploy.test.sh; bash scripts/workflow-wiring.test.sh`. Expected: the changed cases fail.
- [ ] **Step 3: Implement.** CLI: delete the `Flavor` field, pattern, getter case, and validation. `get.go` unknown-key message: `(want name, display_name, core, deploy.<env>.adapter)`. `lib.sh` as above; `deploy.sh` uses `is_release_version` and says `it must match $RELEASE_VERSION_RE, e.g. v1.2.0`. `deploy.yml` uses the literal pattern. `new-instance.sh`: no `VENDOR`, writes `name`, `display_name`, `core`; the success line reads `new-instance: created <dir> (core <tag>)`. `instance.yaml`: remove `flavor`. Docs: remove `flavor` and `VENDOR`, describe the image names from Global Constraints.
- [ ] **Step 4: Run** the tests of Step 2 plus `make test-scripts` and `make check-instance`. Expected: pass.
- [ ] **Step 5: Commit** `refactor!: drop flavor; images are <registry>/<name>/<role>; accept host and -rc.N`.

### Task 2: No private references; `make check-public`

**Files:**
- Create: `scripts/check-public.sh`, `scripts/check-public.test.sh`, `scripts/check-public.patterns`
- Modify: `Makefile` (`check-public` target; add to `check` only when `.template-version` does not exist; `test-scripts`)
- Modify: `.github/workflows/lifecycle.yml`, `scripts/workflow-wiring.test.sh` (guard)
- Modify: `.github/workflows/desktop-macos.yml`, `.github/workflows/desktop-windows.yml`, `.github/workflows/release.yml` (dataset variables)
- Modify: `scripts/new-instance.sh`, `scripts/new-instance.test.sh` (`OWNER` required with `PUSH=1`), `scripts/template-sync.sh`
- Modify: `Makefile:484-506`, `scripts/desktop.sh`, `scripts/lib.sh:280-296`, `scripts/lib.test.sh`, `scripts/build-info.sh` comments, `README.md`, `AGENTS.md`, `docs/*.md`

**Interfaces:**
- Produces: `make check-public` → `bash scripts/check-public.sh`. Exit 0 when no tracked file (outside `docs/superpowers/` and `scripts/check-public.patterns`) matches any pattern; exit 1 and print `file:line: pattern` for each match otherwise. Patterns: one extended regular expression per line, case-insensitive; `#` starts a comment line.

Requirements:
- `scripts/check-public.patterns` contains at least: `gradionhq`, `gradion\.com`, `margince-constellation`, `constellation`, `district[- ]?13`, `\bd13\b`, `nfq`, `margince-automation-world`, `margince-gradion`, `margince-d13-deploy`, `margince-release`, `margince-demo-database`. Check with `git grep -n -i -E -f <patterns>` over tracked files, excluding the two paths by pathspec (`':!docs/superpowers/' ':!scripts/check-public.patterns'`). Also scan staged new files (`git grep --cached`) so a newly added file is caught before commit.
- Replace every current match (list them with the script once it exists). Examples of the replacements: the lifecycle guard becomes `if: hashFiles('.template-version') == ''`; `make new-instance PUSH=1` without `OWNER` fails with `new-instance: PUSH=1 needs OWNER=<github owner>`; `template-sync.sh` suggests `git remote add template <template-url>`; the desktop workflows use `vars.DATASET_REPOSITORY` and `secrets.DATASET_DEPLOY_KEY` (seed only when both are set, the existing "ships empty" notice otherwise); the default local dataset path in `lib.sh` and `desktop.sh` becomes `DATASET=<path>` required with a message, no default sibling directory name; comments that name a private repository describe it generically ("the demo dataset repository").
- `check-public.test.sh`: scratch git repository with a copy of the script and patterns; cases: clean tree passes; a committed file with `gradionhq/x` fails naming file and line; a staged but uncommitted new file fails; a match under `docs/superpowers/` passes; a match in `.github/workflows/x.yml` fails; uppercase `GRADIONHQ` fails.

- [ ] **Step 1:** Write `scripts/check-public.test.sh` and the guard test change in `workflow-wiring.test.sh`. Run them. Expected: fail.
- [ ] **Step 2:** Implement `check-public.sh`, the patterns file, and the `Makefile` targets. Run `bash scripts/check-public.test.sh`. Expected: pass.
- [ ] **Step 3:** Run `make check-public` in the repository, fix every match as required above, and update the tests the fixes affect (`new-instance.test.sh`, `lib.test.sh`, `workflow-wiring.test.sh`).
- [ ] **Step 4:** Run `make check-public`, `make test-scripts`, `make check-docs`. Expected: pass.
- [ ] **Step 5: Commit** `feat: make check-public; remove private references`.

### Task 3: License client

**Files:**
- Create: `scripts/license.sh`, `scripts/license.test.sh`
- Modify: `Makefile` (`license` target, `test-scripts`)

**Interfaces:**
- Produces: `bash scripts/license.sh <trial|production> <file>`; exit 0 after writing `<file>` (mode 600); prints `license: <kind> license written to <file>` and, when known, `license: expires <expires_at>`. `make license OUT=<file>` → `bash scripts/license.sh production "$(OUT)"` (fails when `OUT` is empty).
- Consumes: `instance_get name`, `instance_get core`.

Behavior (spec Section 9.3):
1. Arguments: kind is `trial` or `production`; file is given; otherwise exit 2 with usage.
2. If `MARGINCE_TRIAL_LICENSE` (trial) or `MARGINCE_LICENSE` (production) is non-empty, write it to `<file>`, print `license: using <VAR> (no request made)`, exit 0.
3. If `MARGINCE_LICENSE_API` or `MARGINCE_ACCOUNT_TOKEN` is empty, exit 1 naming the empty ones and the variable of step 2.
4. Request with `curl -sS -o <tmp body> -w '%{http_code}' -X POST -H "Authorization: Bearer ..." -H 'Content-Type: application/json' --data <json> "$MARGINCE_LICENSE_API/v1/licenses"`. The token is passed through a curl config file on standard input (`-K -` with `header = "Authorization: Bearer <token>"`), so it never appears in the process list. JSON body: `{"kind":"<kind>","instance":"<name>","core":"<core>"}`.
5. HTTP 201: read `license` and `expires_at` with `python3 -c 'import json,sys; ...'`; an empty `license` is an error. Write the file with `umask 077`. Any other status: print `license: the license service answered <status>: <error message or "no message">` and exit 1. A curl failure (exit ≠ 0): print `license: cannot reach $MARGINCE_LICENSE_API` and exit 1. Nothing is written on failure; a pre-existing `<file>` is left unchanged.
6. The temporary body file is removed on exit.

- [ ] **Step 1: Write `scripts/license.test.sh`.** Scratch instance with `lib.sh`, `license.sh`, a valid `instance.yaml` (the CLI directory copied, as `deploy.test.sh` does). A stub `curl` on `PATH` reads its behavior from files the test writes (status code, body, exit code) and records its arguments and standard input to a log. Cases: bad kind → exit 2; missing file argument → exit 2; `MARGINCE_TRIAL_LICENSE=abc` → file contains `abc`, mode 600, curl not called; `MARGINCE_LICENSE` for production likewise; no API variables → exit 1 naming `MARGINCE_LICENSE_API` and `MARGINCE_ACCOUNT_TOKEN`; 201 with `{"license":"jwt-value","expires_at":"2026-12-31T00:00:00Z"}` → file contains `jwt-value`, output contains `expires 2026-12-31T00:00:00Z`, request body contains `"kind":"trial"`, `"instance":"acme"`, `"core":"v0.0.2"`; 403 with `{"error":"account suspended"}` → exit 1, message contains `403` and `account suspended`, file absent; 201 with empty license → exit 1; curl exit 7 → exit 1 with "cannot reach"; token `tok-secret-123` and license `jwt-value` never appear in combined stdout/stderr of any case, and the token does not appear in the recorded curl arguments; existing file unchanged after a failure.
- [ ] **Step 2: Run** `bash scripts/license.test.sh`. Expected: fail.
- [ ] **Step 3: Implement** `scripts/license.sh` and the `license` target:

```make
license: ## Obtain a production license into a file (OUT=<file>); see docs/license.md
	@test -n "$(OUT)" || { echo "license: pass OUT=<file>" >&2; exit 2; }
	@bash scripts/license.sh production "$(OUT)"
```

- [ ] **Step 4: Run** `bash scripts/license.test.sh` and `make test-scripts`. Expected: pass.
- [ ] **Step 5: Commit** `feat(license): license client for the public license API`.

### Task 4: `make release`

**Files:**
- Create: `scripts/release.sh`, `scripts/release.test.sh`
- Modify: `Makefile` (`release` target, `test-scripts`)

**Interfaces:**
- Consumes: `is_release_version`, `RELEASE_VERSION_RE` (Task 1).
- Produces: `make release VERSION=<v>` → `bash scripts/release.sh "<v>"`. Environment: `RELEASE_REMOTE` (default `origin`), `RELEASE_BRANCH` (default `main`), `RELEASE_CHECK_TARGET` (default `check`). Also produces `version_newer <a> <b>` in `scripts/lib.sh`: exit 0 when release version `a` is newer than `b` under the Global Constraints ordering, 1 otherwise.

Behavior, in order; each failure exits 1 before a tag exists (spec Section 9.2):
1. `VERSION` given and `is_release_version`; else name the pattern.
2. `git status --porcelain` is empty.
3. `git fetch --tags <remote> <branch>` succeeds and `HEAD` is an ancestor of `<remote>/<branch>`.
4. Tag absent locally (`git rev-parse -q --verify refs/tags/<v>`) and on the remote (`git ls-remote --tags <remote> refs/tags/<v>` empty).
5. For every tag matching the pattern, `version_newer <v> <tag>`; on failure print `release: <v> is not newer than <tag>`.
6. `make <RELEASE_CHECK_TARGET>` passes (print `release: running make <target>` first).
7. `git tag -a <v> -m "release <v>"`; `git push <remote> refs/tags/<v>`; on push failure `git tag -d <v>` and exit 1.
8. Print `release: pushed <v>; release.yml builds it`.

`version_newer` implementation:

```bash
# version_newer <a> <b> — 0 when release version a is newer than b (semver;
# vX.Y.Z-rc.N is older than vX.Y.Z; rc numbers compare numerically).
version_newer() {
  local a="${1#v}" b="${2#v}" ar=0 br=0 i
  case "$a" in *-rc.*) ar="${a##*-rc.}"; a="${a%-rc.*}" ;; esac
  case "$b" in *-rc.*) br="${b##*-rc.}"; b="${b%-rc.*}" ;; esac
  local IFS=.
  set -- $a $b
  for i in 1 2 3; do
    eval "local x=\${$i} y=\${$((i+3))}"
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  # Same X.Y.Z: a final release (rc 0) is newer than any rc of it.
  [ "$ar" -eq 0 ] && [ "$br" -ne 0 ] && return 0
  [ "$ar" -ne 0 ] && [ "$br" -ne 0 ] && [ "$ar" -gt "$br" ] && return 0
  return 1
}
```

- [ ] **Step 1: Write tests.** In `lib.test.sh`, `version_newer` cases: `v1.2.0 > v1.1.9`, `v1.10.0 > v1.9.0`, `v2.0.0 > v1.99.99`, `v1.2.0 > v1.2.0-rc.3`, `v1.2.0-rc.10 > v1.2.0-rc.9`, `v1.2.1-rc.1 > v1.2.0`; not newer: `v1.2.0` vs `v1.2.0`, `v1.2.0-rc.1` vs `v1.2.0`, `v1.1.0` vs `v1.2.0`. Write `scripts/release.test.sh`: scratch bare `origin`, a clone with `scripts/lib.sh`, `scripts/release.sh`, the CLI directory and a `Makefile` whose `check` and `check-instance` targets append to a log and fail when a file `FAIL_CHECK` exists; `main` pushed. Cases: missing VERSION; `1.0.0`; `v1.0.0-rc.0`; dirty tree; untracked file; HEAD not on `origin/main`; tag exists locally; tag exists only on the remote; `v1.2.0` after `v1.2.0` exists; `v1.2.0-rc.1` after `v1.2.0` exists; failing check → no tag locally or remotely; success → annotated tag on the remote pointing at HEAD, check ran once; push failure (bare repository `pre-receive` hook exiting 1) → no local tag; `RELEASE_CHECK_TARGET=check-instance` runs that target.
- [ ] **Step 2: Run** `bash scripts/lib.test.sh; bash scripts/release.test.sh`. Expected: fail.
- [ ] **Step 3: Implement** `version_newer`, `scripts/release.sh`, and:

```make
release: ## Tag and push a release (VERSION=vX.Y.Z or vX.Y.Z-rc.N); release.yml builds it
	@bash scripts/release.sh "$(VERSION)"
```

- [ ] **Step 4: Run** both tests and `make test-scripts`. Expected: pass.
- [ ] **Step 5: Commit** `feat(release): make release checks and pushes a release tag`.

### Task 5: `make smoke` and `release.yml`

**Files:**
- Create: `scripts/smoke.sh`, `scripts/smoke.test.sh`
- Modify: `Makefile` (`smoke` target, `test-scripts`), `.github/workflows/release.yml`, `scripts/workflow-wiring.test.sh`, `scripts/package.sh` (only if needed for `PLATFORMS` and `--load`/`--push`)

**Interfaces:**
- Consumes: `image_repo`, `is_release_version` (Task 1); `make package VERSION=<v>` (existing).
- Produces: `make smoke VERSION=<v>` → `bash scripts/smoke.sh "<v>"`; exit 0 when the three images start and answer; `SMOKE_TIMEOUT` (default 180 seconds).

Requirements (spec Section 9.2):
- First read `core/docs/deployment.md` (roles, two-role database model, environment variables, health checks, order of operations) and the `docker run` smoke steps in `core/.github/workflows/release.yml`. Use the same variables and the same database bootstrap (`core/scripts/deploy/db-bootstrap.sql`). Record the variables used in the task report.
- `smoke.sh`: validates VERSION; checks the three images exist locally (`docker image inspect`) before starting anything; creates a network `margince-smoke-<random>`, starts `pgvector/pgvector:pg16` and `redis:7`, bootstraps the database, starts `api`, `worker`, `web`; polls `api` `/readyz` (from a container on the same network, or a published port on 127.0.0.1) until 200 or timeout; checks `web` `/` answers 200; checks `worker` is running; removes every container and the network it created in an `EXIT` trap; on failure prints `docker logs --tail 100` for each Margince container.
- `release.yml`: trigger `on: push: tags: ['v*']`; the version job checks the tag with the release pattern (literal) and the on-`main` check (keep the existing messages); prerelease is `true` for `-rc.N`. New job `images` (needs `version`, `full-check`) on `ubuntu-latest`: checkout with submodules, the Go/Node/pnpm setup that `full-check.yml` uses for `make compose`, `make package VERSION=<v>` (platforms from `vars.PLATFORMS`, default `linux/amd64`, loaded locally), `make smoke VERSION=<v>`; when `vars.REGISTRY` is set: `docker login` with `secrets.REGISTRY_USERNAME`/`REGISTRY_PASSWORD` (password on standard input), push the three images, and write their digests to a job output; otherwise output the note `images were not pushed: REGISTRY is not set`. `publish` needs `images` and writes the release notes with the core version (from `instance.yaml`), the instance commit, and the digests or the note, then creates the GitHub Release (`--prerelease` for `-rc.N`).
- `smoke.test.sh`: stub `docker` and `curl`; cases: invalid VERSION exits 1 before any docker call; missing image exits 1 before any container starts; success removes all containers and the network; readiness timeout (`SMOKE_TIMEOUT=2`) exits 1, prints logs, and still removes everything; worker not running exits 1.
- `workflow-wiring.test.sh`: tag trigger, version pattern, `images` runs `make package` and `make smoke`, push only under `vars.REGISTRY`, `publish` needs `images`, `--prerelease` only for `-rc`.

- [ ] **Step 1:** Read the core files and write the variable list into the report.
- [ ] **Step 2:** Write `scripts/smoke.test.sh` and the wiring checks. Run. Expected: fail.
- [ ] **Step 3:** Implement `smoke.sh`, the `smoke` target, and the workflow.
- [ ] **Step 4:** Run `bash scripts/smoke.test.sh`, `bash scripts/workflow-wiring.test.sh`, `make test-scripts`. Expected: pass. If Docker is available, also run `make package VERSION=v0.0.0-rc.1 ALLOW_DIRTY=1 && make smoke VERSION=v0.0.0-rc.1` and report the outcome.
- [ ] **Step 5: Commit** `feat(release): release.yml builds, smoke-tests, and pushes the role images`.

### Task 6: `host` deployment files

**Files:**
- Create: `scripts/deploy/host/compose.yaml`, `scripts/deploy/host/Caddyfile`, `scripts/deploy/host/render.sh`, `scripts/deploy/host/render.test.sh`
- Modify: `Makefile` (`test-scripts`)

**Interfaces:**
- Consumes: the variables `deploy.sh` exports (spec Section 9.5).
- Produces: `bash scripts/deploy/host/render.sh <out-dir>` — builds one release directory locally from `DEPLOY_DIR` and the environment: `compose.yaml` and `Caddyfile` (copied), `config/margince.yaml` (copied from `DEPLOY_DIR`), `.env` (mode 600) with one `NAME=value` line per name in `DEPLOY_DIR/secrets` plus `IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER`, `HOST_DOMAIN`, `API_REPLICAS`, `WORKER_REPLICAS`, `COMPOSE_PROFILES` (`local-data` unless both `MARGINCE_DSN` and `MARGINCE_REDIS` are set, empty otherwise). Also produces `host_env_get <key> [default]` in `scripts/deploy/host/render.sh`'s sibling library `scripts/deploy/host/lib.sh`: reads `KEY=VALUE` lines of `DEPLOY_DIR/host.env` without executing them.

Requirements (spec Section 9.6):
- `compose.yaml`: project name from the caller (`-p margince-<name>`); services `api`, `web`, `worker` (images `${IMAGE_API}` and so on, `deploy.replicas` from `API_REPLICAS`/`WORKER_REPLICAS`, `env_file: .env`, `restart: unless-stopped`, the configuration mounted read-only at the path core expects), `postgres` (`pgvector/pgvector:pg16`, volume `pgdata`, initialized with core's `scripts/deploy/db-bootstrap.sql` as described in `core/docs/deployment.md`, passwords from `../../shared/data.env`), `redis` (`redis:7`, volume `redisdata`); `postgres` and `redis` have `profiles: [local-data]`; `caddy` (`caddy:2`, ports 80 and 443, volumes `caddydata`, `caddyconfig`, the `Caddyfile` mounted read-only). The application's database and Redis addresses default to the local services when `local-data` is active. Follow `core/docs/deployment.md` for the variable names, the api-before-worker order, and the health check.
- `Caddyfile`: site `{$HOST_DOMAIN}`; `/v1*`, `/oauth*`, `/.well-known*`, `/mcp*` reverse-proxied to `api:8080`; everything else to `web:8080`; `/healthz`, `/readyz`, `/metrics` answered 404 by Caddy.
- `.env` values are written exactly (use `printf '%s=%s\n'`; a value with a newline is refused with a message naming the variable, not the value). A listed name without a value exits 1 naming the variable.
- `render.test.sh`: cases: files present with the right modes; `.env` holds a value with spaces, `$`, `#`, and quotes unchanged; a missing secret fails naming it and prints no value; `COMPOSE_PROFILES` is `local-data` by default and empty with both external addresses set; `host_env_get` returns defaults and ignores comment lines and lines like `HOST_SSH=$(rm -rf /)` literally (no execution); when `docker compose` is available, `docker compose -f <out>/compose.yaml --env-file <out>/.env config -q` passes (skip with a printed notice when Docker is absent).

- [ ] **Step 1:** Read `core/docs/deployment.md` and `core/scripts/deploy/*`. Write the variable and routing decisions into the report.
- [ ] **Step 2:** Write `render.test.sh`. Run. Expected: fail.
- [ ] **Step 3:** Implement `lib.sh`, `render.sh`, `compose.yaml`, `Caddyfile`.
- [ ] **Step 4:** Run `bash scripts/deploy/host/render.test.sh` and `make test-scripts`. Expected: pass.
- [ ] **Step 5: Commit** `feat(deploy): host deployment files (compose, Caddy, release directory)`.

### Task 7: `host` adapter steps and `make host-bootstrap`

**Files:**
- Create: `scripts/deploy/host.sh`, `scripts/deploy/host.test.sh`, `scripts/deploy/host/bootstrap.sh`, `scripts/deploy/host/bootstrap.test.sh`
- Modify: `scripts/deploy.sh` (`DEPLOY_STATE_DIR`), `scripts/deploy.test.sh`, `Makefile` (`host-bootstrap` target, `test-scripts`)

**Interfaces:**
- Consumes: `render.sh <out-dir>` and `host_env_get` (Task 6); the adapter protocol of `scripts/deploy/hook.sh` (`check`, `has <step>` with exit 0/1/2, steps).
- Produces: `DEPLOY_STATE_DIR` in `deploy.sh` (created with `mktemp -d` before `check`, exported, removed in an `EXIT` trap). `make host-bootstrap ENV=<env>` → `bash scripts/deploy/host/bootstrap.sh <env>`.

Requirements (spec Section 9.6):
- SSH: `ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<file from HOST_KNOWN_HOSTS> [-i <file from HOST_SSH_KEY>] "$HOST_SSH" ...`; the key and known-hosts files are written with mode 600 into `DEPLOY_STATE_DIR`. Uploads with `scp` using the same options. Remote paths are quoted.
- `check`, `preflight`, `apply`, `verify`, `rollback` exactly as the table in spec Section 9.6. `has` answers 0 for the four steps and 2 for anything else.
- `apply`: remote `readlink "$HOST_DIR/current"` → basename written to `DEPLOY_STATE_DIR/previous` (empty file when absent); render into a local temporary directory; create `$HOST_DIR/shared/data.env` once with random passwords (mode 600) when it does not exist; upload to `$HOST_DIR/releases/<v>/`; remote `docker login` when `REGISTRY_USERNAME` is set (password on standard input); `docker compose -p margince-<name> -f releases/<v>/compose.yaml --env-file releases/<v>/.env pull` and `up -d --remove-orphans`; `ln -sfn releases/<v> current`; remove release directories beyond the five newest (never `current` or `previous`).
- `verify`: poll remote `docker compose ... exec -T api wget -q -O /dev/null http://127.0.0.1:8080/readyz` and `docker compose ... ps --status running --services` containing `worker`, every 5 seconds up to `HOST_VERIFY_TIMEOUT`; then, unless `HOST_VERIFY_PUBLIC=0`, `curl -sS -o /dev/null -w '%{http_code}' https://$HOST_DOMAIN/` must be 100–499.
- `rollback`: previous non-empty → `up -d --remove-orphans` with the previous release directory and point `current` at it; previous empty → `docker compose ... down` for the new release and exit 1 with `deploy: no previous release to roll back to`.
- `bootstrap.sh <env>`: reads `host.env`; over SSH detects `/etc/os-release` (`ubuntu` 22.04/24.04, `amzn` 2023; others exit 1 naming the OS); installs Docker Engine and the Compose plugin with the distribution's documented method only when `docker compose version` fails; adds the SSH user to the `docker` group; prints what it changed or `host-bootstrap: <host> is ready (nothing to change)`.
- `host.test.sh`: builds a scratch instance (as `deploy.test.sh` does) with `deploy: { prod: { adapter: host } }` and a `deploy/prod/` directory; stubs `ssh` and `scp` that execute the remote command locally inside a scratch "server" root (rewrite `$HOST_DIR` to a scratch path) and a stub `docker` whose results are driven by files; stub `curl`. Cases: first deploy creates `releases/v1.0.0`, `current` → it, `.env` mode 600, `shared/data.env` created once; second deploy records `previous=v1.0.0` and points `current` to `v1.1.0`; `compose up` failure rolls back to `v1.0.0` and `current` points to `v1.0.0`; verify timeout rolls back; first deploy with failing verify runs `down` and fails with "no previous release"; missing secret fails preflight with nothing uploaded; missing `HOST_KNOWN_HOSTS` fails preflight; seven deployments keep five release directories plus none deleted that is `current`; a secret value with spaces, `$`, quotes, and `#` reaches the server `.env` unchanged and never appears in the output; `REGISTRY_PASSWORD` never appears in the output or in the recorded `ssh` arguments.
- `bootstrap.test.sh`: stub `ssh` returning a chosen `/etc/os-release` and `docker compose version` result; cases: ready server changes nothing; Ubuntu 24.04 without Docker runs the install commands; unknown OS fails.

- [ ] **Step 1:** Write `host.test.sh`, `bootstrap.test.sh`, and a `deploy.test.sh` case that `DEPLOY_STATE_DIR` exists during steps and is removed afterwards. Run. Expected: fail.
- [ ] **Step 2:** Implement `DEPLOY_STATE_DIR`, `host.sh`, `bootstrap.sh`, and:

```make
host-bootstrap: ## Install Docker and Compose on a new server for a host environment (ENV=)
	@bash scripts/deploy/host/bootstrap.sh "$(ENV)"
```

- [ ] **Step 3:** Run `bash scripts/deploy/host.test.sh`, `bash scripts/deploy/host/bootstrap.test.sh`, `bash scripts/deploy.test.sh`, `make test-scripts`. Expected: pass.
- [ ] **Step 4: Commit** `feat(deploy): host adapter and make host-bootstrap`.

### Task 8: `make trial`

**Files:**
- Create: `scripts/trial.sh`, `scripts/trial.test.sh`
- Modify: `scripts/cli/instance.go`, `scripts/cli/get.go`, CLI tests (`data.dataset`), `Makefile` (`trial` target, `test-scripts`), `.gitignore` (`dist/`)

**Interfaces:**
- Consumes: `scripts/license.sh trial <file>` (Task 3), `is_release_version` (Task 1), `make desktop VERSION=<v>` and the desktop kit (`scripts/desktop.sh`, `scripts/desktop-kit/`, `Makefile` desktop section).
- Produces: `make trial VERSION=<v>` → `bash scripts/trial.sh "<v>"`; output `dist/trial/<name>-<v>-<platform>/`. CLI: optional `data.dataset` matching `^[^@\s]+@[^@\s]+$`; `cli get data.dataset` exits 2 when absent.

Requirements (spec Section 9.4):
- Order: VERSION valid (`is_release_version`); output directory absent or `FORCE=1`; `scripts/license.sh trial <tmp file>` (fail before the build); `${TRIAL_DESKTOP_CMD:-make desktop} VERSION=<v>`; copy `build/desktop/margince` to the output; write the license and production mode into the environment file the bundle's launcher reads (find it in `scripts/desktop-kit/` and `scripts/desktop.sh`; use `MARGINCE_LICENSE` and the production mode variable named in `core/docs/deployment.md`); when `data.dataset` is set, place the dataset reference where `make desktop-seed DATASET=` expects it and print the seeding command; write `TRIAL.txt` with name, version, core version, and the license expiry decoded from the JWT `exp` claim when present (decode the payload segment with base64 in Python; never print the token).
- Platform: `uname -s`/`uname -m` → `macos-arm64`, `macos-x64`, `windows-x64` (MINGW/MSYS); anything else exits 1 naming it.
- `trial.test.sh`: `TRIAL_DESKTOP_CMD` points to a stub that creates a fake `build/desktop/margince/` with the environment file; cases: no license → fails and the stub never ran; `MARGINCE_TRIAL_LICENSE=jwt.payload.sig` (payload with `exp`) → license and production mode in the environment file, not printed, `TRIAL.txt` has the expiry date; output directory name; existing output refused without `FORCE=1`, replaced with it; `data.dataset` set → seeding command printed.

- [ ] **Step 1:** Read the desktop kit; record in the report which file the launcher reads.
- [ ] **Step 2:** Write the tests. Run. Expected: fail.
- [ ] **Step 3:** Implement, with:

```make
trial: ## Build a trial desktop bundle with a trial license (VERSION=, FORCE=1)
	@bash scripts/trial.sh "$(VERSION)"
```

- [ ] **Step 4:** Run `bash scripts/trial.test.sh`, `make test-cli`, `make test-scripts`. Expected: pass.
- [ ] **Step 5: Commit** `feat(trial): make trial builds a production-mode bundle with a trial license`.

### Task 9: Lifecycle test: release and `host` deployment

**Files:**
- Modify: `scripts/lifecycle.test.sh`

Requirements (spec Section 12):
- After the unit step: bare `$WORK/origin.git` as `origin` of the scratch instance; push `main`; `make -s release VERSION=v0.1.0 RELEASE_CHECK_TARGET=check-instance`; assert the tag is in `origin.git`; assert a second `make -s release VERSION=v0.1.0 ...` fails.
- The hook deployment uses `v0.1.0` from the release; the rollback case commits, pushes, and releases `v0.1.1` with `make release` before deploying it.
- New step "deploy through the host adapter": `deploy/prod/` with `host.env` (`HOST_SSH=test@server`, `HOST_DOMAIN=demo.example.test`), `config/margince.yaml`, `secrets` (`MARGINCE_LICENSE`); `instance.yaml` gains `prod: { adapter: host }`; stubs for `ssh`, `scp`, `docker`, `curl` (reuse the stub approach of `scripts/deploy/host.test.sh`; copy the stub scripts into the scratch directory); `MARGINCE_LICENSE=test HOST_KNOWN_HOSTS='server ssh-ed25519 AAAA' make -s deploy ENV=prod VERSION=v0.1.0`; assert the scratch server has `releases/v0.1.0` and `current` pointing to it.
- Header comment lists release and host deployment; trial is covered by `trial.test.sh`.

- [ ] **Step 1:** Implement the steps.
- [ ] **Step 2:** Run `make test-lifecycle` (slow). Expected: `lifecycle: all steps passed`.
- [ ] **Step 3: Commit** `test(lifecycle): release and host deployment steps`.

### Task 10: Guides and status

**Files:**
- Create: `docs/deploy.md`, `docs/license.md`, `docs/trial.md`
- Modify: `docs/release.md` (rewrite), `docs/create-an-instance.md`, `docs/README.md`, `README.md`, `AGENTS.md`
- Modify: spec Section 13 statuses and header status; `docs/superpowers/plans/2026-09-24-issue-breakdown.md` statuses

Requirements:
- `docs/release.md`: `make release`, the version pattern and ordering, what `release.yml` does, `REGISTRY`/`REGISTRY_USERNAME`/`REGISTRY_PASSWORD`/`PLATFORMS`, pre-releases, `make smoke` locally.
- `docs/deploy.md`: the four steps and variables; `hook` with an example; `host` end to end for AWS EC2 — launch an Ubuntu 24.04 or Amazon Linux 2023 instance, security group 22/80/443, DNS for `HOST_DOMAIN`, `make host-bootstrap`, `deploy/<env>/` files, `HOST_SSH_KEY`, `HOST_KNOWN_HOSTS` (`ssh-keyscan` and verifying the fingerprint), external RDS/ElastiCache, `deploy.yml` with a GitHub Environment, rollback limits, backups (EBS snapshots) as the client's responsibility.
- `docs/license.md`: the variables, `make license OUT=`, storing the license as an environment secret, the API contract (copy of spec Section 9.3).
- `docs/trial.md`: `make trial`, license variables, output, first start, seeding.
- `docs/README.md` lists every guide and every plan; `README.md` and `AGENTS.md` describe the public template (no Constellation, no D13).
- Spec Section 13: T13, T16, T7, T15, T8, T10, T12 marked Done; header status "Approved design; implemented".

- [ ] **Step 1:** Write the documents and status updates.
- [ ] **Step 2:** Run `make check-docs`, `make check-public`, `make test-scripts`. Expected: pass.
- [ ] **Step 3: Commit** `docs: release, deploy, license and trial guides; implementation status`.
