# Deploy

`make deploy ENV=<env> VERSION=<v>` deploys one release to one environment
declared under `deploy:` in `instance.yaml`:

```yaml
deploy:
  staging: { adapter: hook }
  production: { adapter: host }
```

The environment name must match `^[a-z0-9]+(-[a-z0-9]+)*$`. Each environment
needs a `deploy/<env>/` directory. The adapter is `hook` (your own scripts) or
`host` (the built-in single-server adapter, over SSH and Docker Compose).

## Default `deploy/production/`

The template deploys to one Linux virtual machine (for example AWS EC2) by
default: it ships `deploy/production/` for the `host` adapter, and
`instance.yaml` already lists `production: { adapter: host }`. `make
new-instance` gives every new instance its own `deploy/production/`, scaffolded
for that instance's `display_name` (and, when `make new-instance` is given
`DOMAIN`, `SSH` or `ADMIN_EMAIL`, filled in with those values — see
[create-an-instance.md](create-an-instance.md#2-create)).

Without `DOMAIN`/`SSH`/`ADMIN_EMAIL`, `deploy/production/host.env` has
`HOST_SSH=` and `HOST_DOMAIN=` empty (each with a comment above it saying what
to enter) and `deploy/production/config/margince.yaml`'s admin email is the
placeholder `admin@example.com` (with a comment to change it). A client's
first deployment is: fill in `deploy/production/host.env` and the admin email
in `deploy/production/config/margince.yaml`, then `make host-bootstrap
ENV=production` and `make deploy ENV=production VERSION=<v>` with
`MARGINCE_LICENSE` set. `check` refuses to run — naming the file to edit —
while any of the three is still a placeholder.

## The four-step contract

```
preflight → apply → verify
```

A failed `preflight` stops the deployment immediately: nothing has changed,
so there is no rollback. A failed `apply` or `verify` runs `rollback`, and the
deployment still fails — non-zero exit — whether or not the rollback
succeeds. An environment with no `rollback` step fails with `no rollback
hook`: the environment may be half-deployed.

Before any step, `scripts/deploy.sh`:

1. Requires `VERSION` to match `^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$`.
2. Validates `instance.yaml`.
3. Refuses a working tree with uncommitted changes (untracked files
   included), unless `ALLOW_DIRTY=1`.
4. Prints a notice, but continues, if `HEAD` is not the commit of the tag
   `VERSION`: hooks and configuration always come from this checkout, not
   from the release. `deploy.yml` (below) deploys from the tag itself, so
   this notice never fires there.

Every step of every adapter receives:

| Variable | Set for | Value |
|---|---|---|
| `DEPLOY_ENV` | every step | The environment name (`ENV=`). |
| `DEPLOY_VERSION` | every step | The release being deployed (`VERSION=`). |
| `DEPLOY_STEP` | every step | The step's own name. |
| `DEPLOY_DIR` | every step | Absolute path of `deploy/<env>/`. |
| `DEPLOY_STATE_DIR` | every step | A temporary directory shared by the steps of one run, removed when the run ends. |
| `INSTANCE_NAME` | every step | `name` from `instance.yaml`. |
| `IMAGE_REPO` | every step | The image namespace (see [create-an-instance.md](create-an-instance.md#8-image-names)). |
| `IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER` | every step | `$IMAGE_REPO/<role>:$DEPLOY_VERSION`. |
| `DEPLOY_FAILED_STEP` | `rollback` only | The step that failed (`apply` or `verify`). |

`make deploy` runs with `ENV`, `VERSION`, `MAKEFLAGS`, `MAKELEVEL`, and
`MFLAGS` removed from the environment, so a hook that runs `make` itself does
not inherit them as overrides. Read `DEPLOY_ENV` and `DEPLOY_VERSION` instead.

## The `hook` adapter

`deploy/<env>/hooks/<step>.sh`, run with `bash` (no executable bit needed).
`apply.sh` is required; `preflight.sh`, `verify.sh`, and `rollback.sh` are
optional — a missing one is reported as skipped, not failed.

```
deploy/staging/
└── hooks/
    ├── apply.sh       required
    ├── preflight.sh   optional
    ├── verify.sh      optional
    └── rollback.sh    optional
```

Example `apply.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail
echo "deploying $IMAGE_API"
echo "deploying $IMAGE_WEB"
echo "deploying $IMAGE_WORKER"
# ... pull and run the images on the target host
```

`deploy/<env>/` holds configuration values only — hostnames, replica counts,
the names of required secrets — never secret values. Hooks read secret
values from the environment (from your shell locally, or from
[`deploy.yml`](#deployyml) in CI).

Run it locally:

```sh
make deploy ENV=staging VERSION=v1.2.3
```

## The `host` adapter

The built-in adapter for one Linux server, deployed over SSH with Docker
Compose — for example an AWS EC2 instance. It is the template's default: every
new instance already has `deploy/production/`, ready to fill in (Section
"Default `deploy/production/`" below).

### End to end on AWS EC2

1. **Launch the instance.** Ubuntu 24.04 or Amazon Linux 2023, any size that
   fits your workload. Open its security group to:

   | Port | Purpose |
   |---|---|
   | 22 | SSH (the adapter and `make host-bootstrap`) |
   | 80 | HTTP (Caddy's ACME challenge and redirect to HTTPS) |
   | 443 | HTTPS (the application) |

2. **DNS.** Point `HOST_DOMAIN` (an A or AAAA record) at the instance's
   public address. Caddy requests a certificate for it automatically on
   first start, which needs port 80 reachable from the internet.

3. **Instance files**, committed in `deploy/<env>/`. `make deploy-init
   ENV=<env> ADAPTER=host DOMAIN=<domain> SSH=user@host` scaffolds all three
   below and registers `<env>` under `deploy:` in `instance.yaml` in one step
   (`ADMIN_EMAIL=` overrides the default `admin@<domain>`); write them by hand
   only if you need something `deploy-init` does not produce.

   `DOMAIN`, `SSH` and `ADMIN_EMAIL` are all optional. A missing `DOMAIN` or
   `SSH` is written as an empty `host.env` value with a comment above it
   saying what to enter; a missing `ADMIN_EMAIL` defaults to `admin@<domain>`
   when `DOMAIN` is given, or to the placeholder `admin@example.com`
   otherwise, with a comment to change it. `check` (and so `make deploy`)
   refuses to run while any of the three stays a placeholder, naming the file
   to edit.

   | File | Content |
   |---|---|
   | `host.env` | `HOST_SSH=user@host` (required), `HOST_DOMAIN=<domain>` (required), `HOST_DIR` (default `/opt/margince/<name>`), `API_REPLICAS`, `WORKER_REPLICAS` (default 1). Read as plain `KEY=VALUE` lines, never executed. |
   | `config/margince.yaml` | The instance configuration for this environment. |
   | `secrets` | Names of environment variables written to the server's `.env`, one per line (for example `MARGINCE_LICENSE`). Values come from the environment of `make deploy`, never from this file. A listed name with no value fails `preflight`. |

   `HOST_SSH` must be exactly `user@host` — letters, digits, `.`, `_`, `-`
   only. No IPv6 literal and no port; use a hostname or an A/AAAA-resolvable
   name if you need one.

   `deploy-init` refuses to run over an existing `deploy/<env>/` directory or
   an existing `deploy.<env>` entry in `instance.yaml`, so it is safe to run
   once per new environment and never overwrites one that already exists.

4. **Credentials**, from the environment only (never committed):

   | Variable | Meaning |
   |---|---|
   | `HOST_SSH_KEY` | The private key, optional when the SSH agent already holds one. |
   | `HOST_KNOWN_HOSTS` | Required. Host key checking is never disabled. Get it with `ssh-keyscan -H <host>`, and verify the printed fingerprint against the instance's console output (or the key AWS shows you) before trusting it — `ssh-keyscan` does not verify anything by itself. |
   | `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | Only when the registry needs a login. |

5. **`make host-bootstrap ENV=<env>`.** Installs Docker Engine and the
   Compose plugin over SSH on a fresh Ubuntu 22.04/24.04 or Amazon Linux 2023
   server, and adds the SSH user to the `docker` group. Safe to run again on
   an already-prepared server — it reports "nothing to change" and does
   nothing. On Ubuntu, a conflicting distribution package (`docker.io`,
   `docker-compose-v2`, `podman-docker`, ...) stops the run with the package
   names and the removal command; `host-bootstrap` never removes software
   itself.

   ```sh
   HOST_KNOWN_HOSTS="$(ssh-keyscan -H <host> 2>/dev/null)" \
     make host-bootstrap ENV=production
   ```

6. **External database and cache (optional).** By default the `host` adapter
   runs PostgreSQL and Redis as containers on the same server, with named
   volumes. To use an external RDS PostgreSQL instance and ElastiCache Redis
   instead, set `MARGINCE_DSN`, `MARGINCE_REDIS`, and `MARGINCE_OWNER_DSN` in
   the environment of `make deploy` (list their names in `secrets`, or pass
   them directly — the adapter treats them like any other secret). When both
   `MARGINCE_DSN` and `MARGINCE_REDIS` are set, the local `postgres` and
   `redis` containers are not started.

7. **Deploy.**

   ```sh
   HOST_KNOWN_HOSTS="$(cat known_hosts_line)" \
   MARGINCE_LICENSE="$(cat production.license)" \
     make deploy ENV=production VERSION=v1.2.3
   ```

### Generated instance keys and the first admin password

The first `apply` of an environment generates `$HOST_DIR/shared/instance.env`
(mode 600), once, and never replaces it on a later deploy:

| Variable | Format |
|---|---|
| `MARGINCE_KEYVAULT_ROOT_KEY` | base64 (standard) of 32 random bytes |
| `MARGINCE_CONNECTOR_STATE_KEY` | hex of 32 random bytes (64 hex characters) |
| `MARGINCE_WEBHOOK_KEY` | base64 (standard) of 32 random bytes |
| `MARGINCE_ADMIN_PASSWORD` | 24 random characters from `[A-Za-z0-9]` |

**Precedence.** The `api` and `worker` containers read, in order,
`shared/data.env`, then `shared/instance.env`, then the release `.env` — a
value the client lists in `secrets` wins over the generated one. Listing one
of the four names above in `secrets` (with a value of your own from the
environment of `make deploy`) brings your own value for that one variable;
`apply` still generates the other names normally, and, for
`MARGINCE_ADMIN_PASSWORD` specifically, generates none at all when `secrets`
lists it. For the three keys, `apply` warns (without failing) whenever
`secrets` lists one of them: the generated value still lands in
`instance.env`, unused while your value overrides it. **If you later remove
the name from `secrets`, the environment switches back to that generated
value** — a different key from the one you just removed — and any data
sealed under the value you removed will not open with it. Plan a key
rotation deliberately (reseal the data under the new key) rather than by
simply dropping the name from `secrets`.

`MARGINCE_ADMIN_PASSWORD` is a **first-boot** credential only. Core's `api`
entrypoint reads it once, to bootstrap the admin account while the
installation has no company yet, then never again — including once you
change that account's password in the app (see
[troubleshooting.md](troubleshooting.md) for the log line that confirms
this). There is no way back to "in effect" other than the application's own
password-reset flow.

`make host-admin-password ENV=<env>` prints it: the generated value from
`instance.env`, or a note that it comes from `secrets` when
`MARGINCE_ADMIN_PASSWORD` is listed there. It never prints a value that is
not the one actually in effect, and it fails, naming the file, before the
environment's first deployment (`instance.env` does not exist yet). An
environment whose first `apply` ran while a release was already running on
the target from before `instance.env` existed has **no** generated admin
password at all — see "Upgrading an environment that predates the generated
instance keys" below — and `host-admin-password` says so instead of
printing a password that was never in effect.

### File storage

By default, the `api` and `worker` containers store uploaded files on the
local filesystem: `MARGINCE_BLOBSTORE_PATH=/app/data/blobs` on the named
volume `blobs`, kept across releases like the database volumes. A one-shot
`blobs-init` service gives the volume to the image's `app` user before `api`
and `worker` start.

To use S3 or a compatible object store instead, list
`MARGINCE_BLOBSTORE_ENDPOINT` (and the other object-storage variables
`core/docs/reference/configuration.md` documents) in `secrets`: `apply`
leaves out the `blobs` volume, its mounts, and `blobs-init` entirely. The
volume itself, if one already exists from an earlier deploy, is not deleted.

A custom `MARGINCE_BLOBSTORE_PATH` (listed in `secrets`) replaces the default
path used inside the containers, but it must stay under `/app/data/blobs`:
that is the mount point the `blobs` volume is attached to (or, without the
default file store, simply a path inside the container's own filesystem),
and a path outside it is not backed by the persistent volume at all — it
would be lost on the next `apply` that recreates the container.

### The license check

In production mode (`MARGINCE_ENV` unset, or listed in `secrets` with a
value other than `dev` or `test`), `preflight` fails unless `secrets` lists
`MARGINCE_LICENSE` with a value — before any connection is made or anything
is uploaded. For a non-production environment, list `MARGINCE_ENV` in
`secrets` and set it to `test` (or `dev`) in the environment of `make
deploy`.

This check looks only at `secrets` and the environment of `make deploy`; it
does not read a `license:` block in `deploy/<env>/config/margince.yaml`
(core's own `token_file` or `${file:…}` license configuration). An
environment that configures its license that way still needs `MARGINCE_ENV`
listed in `secrets` and set to `test`/`dev` to pass `preflight`, or
`MARGINCE_LICENSE` listed and set, even though the license itself is not read
from that variable at runtime.

### What each step does

| Step | Action |
|---|---|
| `check` | `host.env` has non-empty `HOST_SSH` and `HOST_DOMAIN`; `config/margince.yaml` and `secrets` exist; `bootstrap_admin.email` in `config/margince.yaml` is not the placeholder `admin@example.com`. Each refusal names the file to edit. No connection made. |
| `preflight` | The release files can be built (every name in `secrets` has a value); `HOST_KNOWN_HOSTS` is set; SSH connects; the server has Docker, `timeout`, and Docker Compose 2.30.0 or later; the server can log in to the registry and read the three image manifests. Nothing is uploaded. |
| `apply` | Records the release `current` points to (for rollback); builds the release files; uploads them; logs in to the registry; runs `compose pull` and `compose up -d --remove-orphans`; installs a changed Caddyfile once `up` succeeds and reloads Caddy; points `current` at the new release; prunes old release directories. |
| `verify` | Within `HOST_VERIFY_TIMEOUT` (default 300s): the api answers `/readyz` and the worker is running, on the server; then, unless `HOST_VERIFY_PUBLIC=0`, `https://$HOST_DOMAIN/` answers a status below 500. |
| `rollback` | Starts the previous release directory and points `current` back at it. Without a previous release, it stops the new release and fails — see "Rollback limits" below. |

Server layout: `$HOST_DIR/releases/<v>/` holds the release's `compose.yaml`,
`compose.env`, `config/margince.yaml`, and `.env` (mode 600). The Caddyfile
itself is not per-release; it lives in `$HOST_DIR/shared/caddy/`, below.
`$HOST_DIR/current` is a symbolic link to the running release.
`$HOST_DIR/shared/` holds `db-init.sh`, `db-bootstrap.sql`, `caddy/Caddyfile`,
`data.env` (the generated database passwords, created once, mode 600), and
`instance.env` (the generated vault, connector state and webhook keys, and
first admin password, created once, mode 600) — files every release mounts
unchanged, so postgres and caddy are not recreated
on each deploy. Every `docker compose` call on the server uses
`--env-file compose.env` from the release directory.

Caddy routes `/v1`, `/oauth`, `/mcp`, the two `/.well-known/oauth-*` metadata
paths, `/webhooks/gmail`, and `/webhooks/graph` to `api` (exact paths and
slash-terminated prefixes, not bare prefixes), and every other path to `web`.
`/healthz`, `/readyz`, and `/metrics` are not routed publicly.
`MARGINCE_PUBLIC_BASE_URL` defaults to `https://$HOST_DOMAIN` unless `secrets`
lists it.

Redeploying the version that is already running keeps the old copy of that
release directory as `releases/.replaced-<v>`, so a rollback of a bad
redeploy still has something to restore; it is removed by the next `apply`.
Pruning keeps the five highest-numbered release directories, plus whichever
directories `current` and the previous release point at, even if that pushes
the count above five.

Registry logins on the server use a `DOCKER_CONFIG` directory scoped to that
one step, removed again when the step ends — no registry credential is left
on the server afterwards. `docker compose up -d` is bounded by
`HOST_APPLY_TIMEOUT` (default 600 seconds) with the server's own `timeout`
command, so a stuck start does not hold the deployment open; readiness itself
is `verify`'s job, not `apply`'s.

Docker Compose **2.30.0 or later** is required (the rendered `compose.yaml`
uses `env_file` entries with `format: raw`, which older Compose does not
support). `make host-bootstrap` installs a version that satisfies this;
`preflight` checks it either way.

| Variable | Default | Meaning |
|---|---|---|
| `HOST_DIR` | `/opt/margince/<name>` | Where releases and shared files live on the server. |
| `API_REPLICAS`, `WORKER_REPLICAS` | 1 | Container replica counts. |
| `HOST_APPLY_TIMEOUT` | 600 | Seconds `docker compose up -d` may take. |
| `HOST_VERIFY_TIMEOUT` | 300 | Seconds `verify` waits for readiness. |
| `HOST_VERIFY_INTERVAL` | 5 | Seconds between `verify`'s polls. |
| `HOST_VERIFY_PUBLIC` | 1 | `0` skips the public `https://$HOST_DOMAIN/` check. |

These may be set in `host.env` or in the environment of `make deploy`; the
environment wins.

### Rollback limits

`rollback` restores the previous release directory and points `current` at
it — it does **not** roll back the database: `api` applies migrations when it
starts, and a migration is not automatically reversible.

A failed `preflight` never runs `rollback` at all: `deploy.sh` stops
immediately, before `apply` or any other step runs, so nothing was changed to
roll back from.

A failed `apply` does run `rollback`, but `rollback` needs `apply` to have
recorded which release was running before it started (`host.sh`,
`$DEPLOY_STATE_DIR/previous`). Two cases where that record says there is
nothing to restore:

- `apply` failed before it ever read the running release: `rollback` exits 1
  immediately, saying so, and changes nothing on the server — it was never
  touched.
- `apply` read the running release and found none (the first deployment to an
  environment): `rollback` stops the release `apply` had uploaded, clears
  `current` if it points there, and exits 1 — there is nothing to fall back
  to, and the environment is left with nothing running rather than a guess.

**Upgrading an environment that predates the generated instance keys.** A
release built before this template gained `shared/instance.env` has no
`env_file` entry for it and does not read `MARGINCE_KEYVAULT_ROOT_KEY` at
all. The environment's very first `apply` after the upgrade is what creates
`instance.env`, and it is created once, permanently — no later `apply` ever
regenerates it, including a retried one. If you already manage your own
vault key outside this template and want to keep using it, list
`MARGINCE_KEYVAULT_ROOT_KEY` (and the other names you manage) in `secrets`
**before** that first upgrade `apply`, not after. If that first apply's
`verify` fails and `rollback` restores the pre-upgrade release, the restored
release keeps running exactly as it did before the upgrade (it ignores the
now-existing `instance.env`); the generated `instance.env` itself is not
rolled back and is still what the next `apply` — of the same or a later
version — uses, unedited.

That same first `apply` after the upgrade generates no
`MARGINCE_ADMIN_PASSWORD` at all, even without `secrets` listing it: the
installation already has a company by then, so core ignores the credential
outright (see "Generated instance keys and the first admin password"
above), and generating one would only mislead `make host-admin-password`
into printing a password that was never in effect. `host-admin-password`
says so instead.

### Backups

Database backups on the deployment target are **the client's own
responsibility** — this template does not take them. For the `host`
adapter's local PostgreSQL volume, the client typically takes periodic EBS
snapshots of the underlying volume (or the whole instance) outside of
anything `make deploy` runs. Using external RDS instead (see step 6 above)
moves backups to RDS's own automated snapshot feature.

## `deploy.yml`

`.github/workflows/deploy.yml` is a manually triggered workflow
(`workflow_dispatch`, one `environment` input) that runs `make deploy` in the
GitHub Environment named by `environment`. Dispatch it **from the release
tag**: Actions → deploy → Run workflow → "Use workflow from" → Tags →
`v1.2.3`. The checkout is that tag, so the hooks and `deploy/<env>/` that run
are the ones in the release.

Create each environment ahead of time (repository Settings → Environments);
the workflow does not create one.

| Setting | Value |
|---|---|
| Deployment branches and tags | Selected branches and tags, with the tag rule `v*`. |
| Required reviewers | Required for `production`. |
| Secrets and variables | The values this environment's steps read — for the `host` adapter, at least `HOST_KNOWN_HOSTS`, `HOST_SSH_KEY` (unless the runner otherwise has a usable key), and every name listed in `deploy/<env>/secrets`. |

The job:

1. Confirms it was dispatched from a release tag.
2. Confirms the environment name is well-formed.
3. Checks out the tag (no submodule push credential persisted).
4. Confirms the environment is under `deploy:` in `instance.yaml` at that tag.
5. Exports the environment's variables and secrets as environment variables
   of the same name, except a short reserved list (below).
6. Runs `make deploy ENV=<environment> VERSION=<tag>`.

A name is exported only if it matches `^[A-Z_][A-Z0-9_]*$` and is none of the
exact names `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `BASH_ENV`,
`NODE_OPTIONS`, `CDPATH`, `PROMPT_COMMAND`, `TMPDIR`, `MFLAGS`,
`MAKE_TERMOUT`, `MAKE_TERMERR`; none with the prefix `LD_`, `DYLD_`,
`GITHUB_`, `RUNNER_`, `ACTIONS_`, or `GIT_`; and none matching
`^GO[A-Z0-9]*$` or `^MAKE[A-Z0-9]*$` (Go's and make's own variables). This
keeps a hook from being handed a name that would silently change how `make`,
git, or the shell itself behaves. A skipped name is printed to the log; its
value never is.

## Setting this up on GitHub

Before the first deployment, someone with repository admin rights needs to:

- Create a GitHub Environment per entry under `deploy:` in `instance.yaml`
  (for example `staging`, `production`), with the branch/tag and reviewer
  rules above.
- Add that environment's secrets and variables — at minimum
  `HOST_KNOWN_HOSTS` and, for the `host` adapter, `HOST_SSH_KEY` unless the
  runner already has a usable key, plus every secret name listed in
  `deploy/<env>/secrets`.
- Optionally, set the repository variables `vars.REGISTRY` and secrets
  `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` (see [release.md](release.md)) so
  released images are pushed somewhere `deploy.yml` can pull them from.
