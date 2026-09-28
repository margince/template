# Default Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new instance works with every default feature on its first deployment or local run: generated instance keys, persistent file storage, a scaffolded `deploy/<env>/`, an early license check, and a one-command local run.

**Architecture:** Extends the `host` adapter (`scripts/deploy/host.sh`, `scripts/deploy/host/`), adds `scripts/deploy-init.sh` and `scripts/local.sh`, and small changes to the desktop kit and `scripts/smoke.sh`. Bash with one `*.test.sh` per script, wired into `make test-scripts`.

**Tech Stack:** Bash (macOS 3.2 and Linux 5), GNU Make, Docker Compose ≥ 2.30, Caddy 2, the Go CLI in `scripts/cli`.

**Spec:** `docs/superpowers/specs/2026-09-24-client-instance-template-design.md`, Section 9.7 (binding), with Sections 9.5 and 9.6.

## Global Constraints

- Generated values: `MARGINCE_KEYVAULT_ROOT_KEY` = base64 (standard) of 32 random bytes; `MARGINCE_CONNECTOR_STATE_KEY` = hex of 32 random bytes (64 hex characters); `MARGINCE_WEBHOOK_KEY` = base64 (standard) of 32 random bytes; `MARGINCE_ADMIN_PASSWORD` = 24 random characters from `[A-Za-z0-9]`.
- Generated files are created once, mode 600, and never overwritten (`umask 077` and `set -C`, as `data.env` is created in `scripts/deploy/host.sh`).
- Precedence in the `api` and `worker` containers: `shared/data.env`, then `shared/instance.env`, then the release `.env` (a value the client lists in `secrets` wins).
- Default file storage: `MARGINCE_BLOBSTORE_PATH=/app/data/blobs` on the named volume `blobs`, mounted in `api` and `worker`, unless `MARGINCE_BLOBSTORE_ENDPOINT` is set.
- Production mode means `MARGINCE_ENV` is unset or not `dev`/`test`.
- No secret value is printed, placed on a command line, or written to a log. The admin password is shown only by the explicit commands `make host-admin-password ENV=<env>` and `make local-admin-password`.
- Core variable names and formats come from `core/docs/reference/configuration.md` and `core/docs/deployment.md`; do not invent variables.
- Scripts: `set -euo pipefail`, source `scripts/lib.sh`, Bash 3.2 compatible. Tests use stubs (`scripts/deploy/host/test-stubs/`), need no network or server, and run with stdin from `/dev/null`.
- No private organization, host, or service names (`make check-public`).
- Every `make <target>` named in docs exists (`make check-docs`).
- Commits: Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- After every task: `make test-scripts </dev/null`, `make test-cli`, `make check-docs`, `make check-public` pass.

## Review Focus

1. A redeploy never regenerates `instance.env` or `data.env`, even when `apply` fails half-way. Task 1 tests this.
2. A client value in `secrets` for one of the generated names wins over `instance.env`. Task 1 tests this.
3. `make deploy-init` never overwrites an existing `deploy/<env>/` or an existing `deploy.<env>` entry in `instance.yaml`. Task 2 tests this.
4. `make local-up` twice keeps the same keys, admin password, and data. Task 3 tests this.
5. A production-mode environment without `MARGINCE_LICENSE` fails `preflight` before anything is uploaded. Task 1 tests this.

---

### Task 1: Generated instance keys, file storage, and the license check in the `host` adapter

**Files:**
- Modify: `scripts/deploy/host.sh`, `scripts/deploy/host/compose.yaml`, `scripts/deploy/host/render.sh`, `scripts/deploy/host/lib.sh` (if helpers are shared)
- Modify: `scripts/deploy/host.test.sh`, `scripts/deploy/host/render.test.sh`, `scripts/deploy/host/test-stubs/*` (only if the stubs need a new command)
- Modify: `Makefile` (`host-admin-password` target)

**Interfaces:**
- Produces: `$HOST_DIR/shared/instance.env` with the four lines `MARGINCE_KEYVAULT_ROOT_KEY=`, `MARGINCE_CONNECTOR_STATE_KEY=`, `MARGINCE_WEBHOOK_KEY=`, `MARGINCE_ADMIN_PASSWORD=` (the last only when `secrets` does not list `MARGINCE_ADMIN_PASSWORD`). Task 3 reuses the same file format and a shared generator function.
- Produces: a generator the server script and Task 3 can both use. Put the remote-safe generation snippet (POSIX sh, `od`/`tr` or `openssl` when present) in one place, e.g. `scripts/deploy/host/gen-instance-env.sh`, which writes the file given as its argument only when it does not exist.
- Produces: `make host-admin-password ENV=<env>` → prints the admin password from `$HOST_DIR/shared/instance.env` over SSH (or says it was provided through `secrets`).

Requirements:
- `apply` creates `instance.env` exactly like `data.env` (once, mode 600, noclobber), before `up`.
- `compose.yaml`: `api` and `worker` read `env_file` in the order `../../shared/data.env`, `../../shared/instance.env`, `.env` (all `format: raw`); the worker keeps its blanked `MARGINCE_ADMIN_PASSWORD` and `MARGINCE_OWNER_DSN`. `web` still gets no env file.
- File storage: `api` and `worker` get `MARGINCE_BLOBSTORE_PATH: /app/data/blobs` and the named volume `blobs` at `/app/data/blobs`, unless `MARGINCE_BLOBSTORE_ENDPOINT` is set (then no default path; render.sh decides via compose interpolation or a profile — pick one and explain). Check in core which process user owns `/app` and make sure the volume is writable by it (read core's Dockerfile `api`/`worker` stages; set the volume ownership with an init step only if needed).
- `preflight` license check per Global Constraints: the effective `MARGINCE_ENV` is the value in `secrets` + environment (default production). In production mode, `MARGINCE_LICENSE` must be listed in `secrets` and have a value; otherwise fail with `deploy: <env> runs in production mode and needs MARGINCE_LICENSE: list it in deploy/<env>/secrets and set it (or set MARGINCE_ENV=test for a test environment)`.
- Tests (host.test.sh / render.test.sh): first apply creates `instance.env` with the four keys in the right formats (check lengths and alphabets, never print them); a second apply leaves it byte-identical; a failed apply followed by a new apply leaves it identical; a `secrets` value for `MARGINCE_WEBHOOK_KEY` reaches the api's effective environment ahead of `instance.env` (assert the env_file order in the rendered compose config and, with Docker available, the effective value); `MARGINCE_ADMIN_PASSWORD` in `secrets` means no generated admin password; production mode without license fails preflight with nothing uploaded; `MARGINCE_ENV=test` without license passes; the rendered config shows the `blobs` volume and `MARGINCE_BLOBSTORE_PATH` for api and worker, and none of it when `MARGINCE_BLOBSTORE_ENDPOINT` is set; `make host-admin-password` prints the stub server's generated password and nothing else.

- [ ] Step 1: Write the failing tests. Run them. Expected: fail.
- [ ] Step 2: Implement. Run `bash scripts/deploy/host.test.sh </dev/null`, `bash scripts/deploy/host/render.test.sh </dev/null`, `make test-scripts </dev/null`. Expected: pass.
- [ ] Step 3: Commit `feat(deploy): host generates instance keys and admin password; persistent file storage; license check`.

### Task 2: `make deploy-init`

**Files:**
- Create: `scripts/deploy-init.sh`, `scripts/deploy-init.test.sh`
- Modify: `Makefile` (`deploy-init` target, `test-scripts`)

**Interfaces:**
- Consumes: the CLI (`scripts/cli`) for reading and validating `instance.yaml`; the `host.env`, `secrets`, and `config/margince.yaml` formats of the `host` adapter.
- Produces: `make deploy-init ENV=<env> [ADAPTER=host|hook] [DOMAIN=<host>] [SSH=<user@host>] [ADMIN_EMAIL=<email>]` → `bash scripts/deploy-init.sh`.

Requirements (spec Section 9.7):
- Validates `ENV` with the environment-name rule; refuses an existing `deploy/<env>/` and an existing `deploy.<env>` key.
- `host`: requires `DOMAIN` and `SSH`; writes `deploy/<env>/host.env` (`HOST_SSH`, `HOST_DOMAIN`), `deploy/<env>/secrets` (a comment header explaining the file and the generated keys, then `MARGINCE_LICENSE`), `deploy/<env>/config/margince.yaml` (`version: 1`; `workspace` with the instance `display_name`, `base_currency: EUR`, `timezone: UTC` — each with a comment to change it; `bootstrap_admin` with `ADMIN_EMAIL` default `admin@<DOMAIN>`, `display_name: Admin`, `password_file: secrets/admin-password`; `mcp.connector_enabled: false`; an `email:` block with `enabled: false` and commented SMTP fields). Validate the written config against `core/config/margince.schema.json` if a validator is available offline; at least follow its keys exactly (read the schema).
- `hook`: writes `deploy/<env>/hooks/apply.sh` with a comment that lists the exported variables.
- Adds `  <env>: { adapter: <adapter> }` under `deploy:` in `instance.yaml` (creating `deploy:` when absent) without reformatting the rest of the file, then runs `make check-instance`'s validation (`cli check`) and fails, restoring `instance.yaml`, if it is invalid.
- Prints the next steps: set `MARGINCE_LICENSE`, `make host-bootstrap ENV=<env>`, `make deploy ENV=<env> VERSION=<v>`.
- Tests: host scaffold files and contents; hook scaffold; refusal on existing directory or key (nothing changed); invalid ENV; missing DOMAIN/SSH for host; `instance.yaml` stays valid and keeps its other lines.

- [ ] Step 1: Write the failing tests. Run. Expected: fail.
- [ ] Step 2: Implement. Run the test and `make test-scripts </dev/null`. Expected: pass.
- [ ] Step 3: Commit `feat(deploy): make deploy-init scaffolds a deploy environment`.

### Task 3: `make local-up` / `make local-down`

**Files:**
- Create: `scripts/local.sh`, `scripts/local.test.sh`
- Modify: `Makefile` (`local-up`, `local-down`, `local-admin-password` targets, `test-scripts`), `.gitignore` (`.local/`)

**Interfaces:**
- Consumes: `scripts/deploy/host/render.sh` (release/ + shared/ layout), the generator from Task 1, `data.env` format from `scripts/deploy/host.sh`, `image_repo`, `is_release_version`.
- Produces: `make local-up VERSION=<v>`, `make local-down [WIPE=1]`, `make local-admin-password`.

Requirements (spec Section 9.7):
- `local-up`: validates VERSION; checks the three images exist locally (suggest `make package VERSION=<v>` when not); builds `.local/` like a server root (`releases/<v>/`, `shared/` with `data.env` and `instance.env` created once, `current`); uses a built-in local deploy directory (`HOST_DOMAIN=localhost`, a config like Task 2's with the instance `display_name`, `MARGINCE_ENV=test` unless `MARGINCE_LICENSE` is set); runs `docker compose -p <name>-local ... up -d` with `--env-file compose.env`; waits until `https://localhost/` answers (curl `-k`, timeout 180 s); prints the URL, the admin email, `make local-admin-password`, and that the browser will warn about Caddy's local certificate.
- Ports 80 and 443 must be free; if not, fail naming the process using them (`lsof`) before starting anything.
- `local-down`: `docker compose ... down`, with `-v` and removal of `.local/` only when `WIPE=1`.
- Running `local-up` twice (same or new VERSION) keeps keys, admin password, and data.
- Tests with stubs for `docker`, `curl`, `lsof`: files created with modes; second run keeps `instance.env`/`data.env` byte-identical; missing image fails before compose; busy port fails; `local-down` without `WIPE` keeps `.local/`, with `WIPE=1` removes it and passes `-v`; the admin password is printed only by `local-admin-password`.

- [ ] Step 1: Write the failing tests. Run. Expected: fail.
- [ ] Step 2: Implement. Run the test and `make test-scripts </dev/null`. If Docker is available and ports 80/443 are free, run `make local-up VERSION=<an existing local tag>` for real, then `make local-down WIPE=1`, and report the outcome.
- [ ] Step 3: Commit `feat: make local-up runs a built release on localhost`.

### Task 4: Desktop kit webhook key and smoke keys

**Files:**
- Modify: `scripts/desktop-kit/setup.command`, `scripts/desktop-kit/setup.ps1`, `scripts/desktop-kit.test.sh`
- Modify: `scripts/smoke.sh`, `scripts/smoke.test.sh`

Requirements:
- The desktop kit generates `MARGINCE_WEBHOOK_KEY` (base64 of 32 bytes) exactly as it generates `MARGINCE_KEYVAULT_ROOT_KEY` (same helper, same "only when absent" rule, same message style), in both the macOS and Windows scripts. Tests extended in `desktop-kit.test.sh` in the style of the existing key cases.
- `make smoke` passes generated `MARGINCE_KEYVAULT_ROOT_KEY`, `MARGINCE_CONNECTOR_STATE_KEY`, `MARGINCE_WEBHOOK_KEY` to api and worker (as `-e NAME`, never on argv), so `/readyz` includes the vault probe. Test with the stubs that the three names are passed and their values never appear in argv or output.

- [ ] Step 1: Write the failing tests. Run. Expected: fail.
- [ ] Step 2: Implement. Run the tests and `make test-scripts </dev/null`. If Docker is available, run `make smoke VERSION=<an existing local tag>` and report.
- [ ] Step 3: Commit `feat: desktop kit and smoke test provide the webhook and vault keys`.

### Task 5: Lifecycle, guides, and status

**Files:**
- Modify: `scripts/lifecycle.test.sh` (use `make deploy-init ENV=prod ADAPTER=host DOMAIN=demo.example.test SSH=test@server` instead of hand-written files in the host step; assert `instance.env` exists on the stub server after the deploy)
- Modify: `docs/deploy.md` (generated keys table, precedence, file storage, license check, `make deploy-init`, `make host-admin-password`), `docs/create-an-instance.md` (first deployment starts with `make deploy-init`), `docs/README.md`, `README.md` (quick start: `make package`, `make local-up`), `docs/troubleshooting.md` ("The key was not sealed" → the vault key; now generated), `docs/trial.md` if the webhook key is mentioned
- Modify: spec Section 13 status (a row for this plan), `docs/superpowers/plans/2026-09-24-issue-breakdown.md` (a row for this work)

- [ ] Step 1: Update the lifecycle test; run `make test-lifecycle </dev/null`. Expected: `lifecycle: all steps passed`.
- [ ] Step 2: Update the documents. Run `make check-docs`, `make check-public`, `make test-scripts </dev/null`. Expected: pass.
- [ ] Step 3: Commit `docs: default setup — generated keys, deploy-init, local-up`.
