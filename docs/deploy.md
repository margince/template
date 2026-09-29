# Deploy

This guide covers deploying a release of your instance to an environment with
`make deploy ENV=<env> VERSION=<v>`: declaring environments, the first
deployment of the default `production` environment, the deployment contract,
the `hook` adapter, the built-in `host` adapter for one Linux server, and the
`deploy.yml` workflow. It is for the developer or operator who deploys an
instance. It is the one guide for deployment and adapters; other guides link
here.

## 1. Environments

An environment is an entry under `deploy:` in `instance.yaml` plus a
directory `deploy/<env>/`:

```yaml
deploy:
  production: { adapter: host }
  staging: { adapter: hook }
```

| Rule | Detail |
|---|---|
| Name | Must match `^[a-z0-9]+(-[a-z0-9]+)*$`. |
| Adapter | `host` (the built-in adapter, Section 5) or `hook` (your own scripts, Section 4). Any other value fails with `deploy.<env>.adapter: "<value>" is not an adapter (want hook or host)`. |
| Directory | `deploy/<env>/` must exist. `make check-instance` and `make deploy` fail without it. |
| Content | `deploy/<env>/` holds configuration and the names of secrets, never secret values. |

Your instance, created with `make new-instance`, has the environment
`production` with the `host` adapter (Section 2).

### 1.1 Create an environment with `make deploy-init`

```sh
make deploy-init ENV=staging ADAPTER=host DOMAIN=staging.example.com SSH=ubuntu@203.0.113.20
```

| Variable | Default | Meaning |
|---|---|---|
| `ENV` | required | The environment name. |
| `ADAPTER` | `host` | `host` or `hook`. |
| `DOMAIN` | empty | `HOST_DOMAIN` in `host.env` (`host` only). |
| `SSH` | empty | `HOST_SSH` in `host.env`, `user@host` (`host` only). |
| `ADMIN_EMAIL` | `admin@<DOMAIN>`, or `admin@example.com` without `DOMAIN` | `bootstrap_admin.email` in `config/margince.yaml` (`host` only). |

`make deploy-init` writes `deploy/<env>/`, adds `<env>: { adapter: <adapter> }`
under `deploy:` in `instance.yaml`, validates the result with `cli check`, and
prints the next steps. It refuses to run when `deploy/<env>/` or the
`deploy.<env>` entry already exists. When validation fails, it restores
`instance.yaml` and removes the directory.

| Adapter | Files written |
|---|---|
| `host` | `host.env`, `secrets` (lists `MARGINCE_LICENSE`), and `config/margince.yaml` (workspace, first admin, email off, MCP connector off). An empty `HOST_SSH` or `HOST_DOMAIN` gets a comment that says what to enter. |
| `hook` | `hooks/apply.sh`, a scaffold that lists the variables each step receives and exits 1 until you replace its body. |

To add an environment by hand, add its line under `deploy:` and create
`deploy/<env>/` with the files of its adapter.

## 2. First deployment of the default production environment

Prerequisites:

- The instance repository on GitHub, with `make install` done in your checkout.
- The repository variable `REGISTRY` (and, for a private registry, the
  secrets) set, so that `release.yml` pushes the images
  ([release.md](release.md#5-repository-settings)).
- A server as Section 5.1 describes, and its DNS record.
- A production license. See [license.md](license.md).
- An SSH key for the server's user, in your SSH agent or in `HOST_SSH_KEY`.

Steps, in the instance checkout:

1. Set `HOST_SSH` (`user@host`) and `HOST_DOMAIN` in
   `deploy/production/host.env`.
2. Set `bootstrap_admin.email` in `deploy/production/config/margince.yaml`.
   The `check` step refuses the placeholder `admin@example.com`.
3. Commit and push the changes. `make deploy` refuses a working tree with
   uncommitted changes.
4. Get the server's host key:

   ```sh
   export HOST_KNOWN_HOSTS="$(ssh-keyscan -H <host> 2>/dev/null)"
   ```

5. Compare the key fingerprint with the one the server's console shows.
   `ssh-keyscan` does not verify the key.
6. Install Docker on the server:

   ```sh
   make host-bootstrap ENV=production
   ```

7. Cut a release and wait until `release.yml` has pushed the images:

   ```sh
   make release VERSION=v0.1.0
   ```

8. Deploy it. `REGISTRY` must be the value the release used, so that the
   image names match:

   ```sh
   REGISTRY=<registry> MARGINCE_LICENSE="$(cat <license-file>)" \
     make deploy ENV=production VERSION=v0.1.0
   ```

9. Print the first admin password and sign in at `https://<HOST_DOMAIN>`:

   ```sh
   make host-admin-password ENV=production
   ```

For a private registry, also set `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`
in step 8. To deploy from GitHub Actions instead of your computer, see
Section 6.

## 3. The deployment contract

### 3.1 Checks before the steps

`scripts/deploy.sh` does the following before any step runs:

1. Requires `VERSION` to match `^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$`.
2. Validates `instance.yaml`, including the `deploy/<env>/` directories.
3. Refuses a working tree with uncommitted changes, untracked files included,
   unless `ALLOW_DIRTY=1`.
4. Prints a notice, and continues, when `HEAD` is not the commit of the tag
   `VERSION`. The adapter files and `deploy/<env>/` always come from the
   checkout, not from the release.
5. Runs the adapter's `check` step, which makes no connection.

### 3.2 Steps

```
preflight -> apply -> verify
```

| Step | Failure |
|---|---|
| `preflight` | The deployment stops. Nothing has changed, so `rollback` does not run. |
| `apply` | `rollback` runs, and the deployment fails. |
| `verify` | `rollback` runs, and the deployment fails. |

The deployment fails with a non-zero exit whether or not `rollback`
succeeds. When the adapter has no `rollback` step, the deployment fails with
`no rollback hook — the environment may be half-deployed`.

### 3.3 Variables every step receives

| Variable | Set for | Value |
|---|---|---|
| `DEPLOY_ENV` | every step | The environment name (`ENV`). |
| `DEPLOY_VERSION` | every step | The release (`VERSION`). |
| `DEPLOY_STEP` | every step | The step's own name. |
| `DEPLOY_DIR` | every step | The absolute path of `deploy/<env>/`. |
| `DEPLOY_STATE_DIR` | every step | A temporary directory that the steps of one run share, removed when the run ends. |
| `INSTANCE_NAME` | every step | `name` from `instance.yaml`. |
| `IMAGE_REPO` | every step | `<REGISTRY>/<name>`, or `<name>` without `REGISTRY`. See [release.md](release.md#6-image-names-and-labels). |
| `IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER` | every step | `$IMAGE_REPO/<role>:$DEPLOY_VERSION`. |
| `DEPLOY_FAILED_STEP` | `rollback` only | The step that failed: `apply` or `verify`. |

`make deploy` removes `ENV`, `VERSION`, `MAKEFLAGS`, `MAKELEVEL`, and `MFLAGS`
from the environment, so a step that runs `make` does not inherit them. Read
`DEPLOY_ENV` and `DEPLOY_VERSION` instead. Every other variable of the calling
environment reaches the steps.

## 4. The hook adapter

The `hook` adapter runs your own scripts, `deploy/<env>/hooks/<step>.sh`, with
`bash`; the executable bit is not needed.

```
deploy/staging/
└── hooks/
    ├── apply.sh       required
    ├── preflight.sh   optional
    ├── verify.sh      optional
    └── rollback.sh    optional
```

A missing optional script is reported as skipped. Without `rollback.sh`, a
failed `apply` or `verify` leaves the environment as the failed step left it.

Example `apply.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail
echo "deploying $IMAGE_API $IMAGE_WEB $IMAGE_WORKER to $DEPLOY_ENV"
# pull and run the images on the target
```

Hooks read secret values from the environment: from your shell locally, or
from the GitHub Environment in `deploy.yml`.

```sh
make deploy ENV=staging VERSION=v1.2.3
```

## 5. The host adapter

The `host` adapter deploys the three images to one Linux server over SSH with
Docker Compose, behind Caddy with an automatic HTTPS certificate. By default
PostgreSQL and Redis run as containers on the same server.

### 5.1 Server requirements

| Requirement | Detail |
|---|---|
| Operating system | Ubuntu 22.04, Ubuntu 24.04, or Amazon Linux 2023 for `make host-bootstrap`. `make deploy` also works on another Linux server with Docker, Docker Compose 2.30.0 or later, and GNU coreutils. |
| Port 22 | SSH, for the adapter and `make host-bootstrap`. |
| Port 80 | HTTP, for the certificate challenge and the redirect to HTTPS. Must be reachable from the internet. |
| Port 443 | HTTPS, the application. |
| DNS | An A or AAAA record for `HOST_DOMAIN` that points at the server. |
| SSH user | Passwordless `sudo` for `make host-bootstrap` (the default for `ubuntu` and `ec2-user` on AWS EC2). |

### 5.2 Files in `deploy/<env>/`

| File | Content |
|---|---|
| `host.env` | `KEY=VALUE` lines, read as text and never executed. Blank lines and `#` comments are skipped, one pair of surrounding quotes is removed, and the last line of a key wins. |
| `secrets` | The names of the environment variables written into the release `.env`, one per line. `make deploy` reads each value from its own environment. Never write a value in this file. |
| `config/margince.yaml` | The installation configuration, mounted read-only into `api` and `worker`. It is read once, at the first start against an empty database; the application's Settings change it afterwards. See `core/config/margince.example.yaml`. |

| `host.env` key | Required | Rule |
|---|---|---|
| `HOST_SSH` | yes | `user@host`: letters, digits, `.`, `_`, and `-` only. No IPv6 literal and no port. |
| `HOST_DOMAIN` | yes | A host name. |
| `HOST_DIR` | no | See Section 5.11. |
| `API_REPLICAS`, `WORKER_REPLICAS` | no | Positive numbers, default 1. |

A name in `secrets` must match `^[A-Z_][A-Z0-9_]*$` and have a value without a
line break. It must not be one the adapter sets itself: `INSTANCE_NAME`,
`IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER`, `HOST_DOMAIN`, `API_REPLICAS`,
`WORKER_REPLICAS`, `COMPOSE_PROFILES`.

### 5.3 Credentials

Credentials come from the environment of `make deploy` only.

| Variable | Required | Meaning |
|---|---|---|
| `HOST_KNOWN_HOSTS` | yes | The server's `known_hosts` line or lines. Host key checking is never turned off. |
| `HOST_SSH_KEY` | no | The private key. Without it, the SSH agent's keys are used. |
| `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | no | The registry login on the server, for a private registry. |
| `REGISTRY` | no | The registry prefix of the image names. Must match the release. |

The registry login goes to the registry host in the first part of
`IMAGE_REPO` when that part contains `.` or `:` or is `localhost`, and to
Docker Hub otherwise. The password is sent on standard input, and the login is
kept in a directory that the step removes when it ends. No secret is printed
or passed on a command line.

`make host-bootstrap` and `make host-admin-password` use the same SSH
variables.

### 5.4 Prepare the server

```sh
make host-bootstrap ENV=production
```

`make host-bootstrap` connects over SSH and:

1. Reads `/etc/os-release` and refuses a system other than Ubuntu 22.04,
   Ubuntu 24.04, or Amazon Linux 2023.
2. When `docker compose version` fails, installs Docker Engine and the Compose
   plugin: from Docker's apt repository on Ubuntu, and with `dnf install
   docker` plus a pinned, checksum-verified Compose plugin on Amazon Linux 2023.
3. Adds the SSH user to the `docker` group.

It reports `<host> is ready (nothing to change)` on a prepared server. It
does not replace an existing Docker Compose older than 2.30.0; it fails and
names the version. On Ubuntu, installed distribution packages that conflict
with Docker's (`docker.io`, `docker-compose-v2`, `podman-docker`, and others)
stop the run with their names and the removal command. `make host-bootstrap`
never removes software.

### 5.5 External database and Redis

To use an external PostgreSQL and Redis, set `MARGINCE_DSN`,
`MARGINCE_REDIS`, and `MARGINCE_OWNER_DSN` in the environment of `make
deploy`. When `MARGINCE_DSN` and `MARGINCE_REDIS` are both set, the adapter
writes the three values into the release `.env` and does not start the
`postgres` and `redis` containers. `MARGINCE_OWNER_DSN` is then required,
because the `api` migrates the database as the owner role.

### 5.6 Generated instance keys and the first admin password

The first `apply` of an environment creates `$HOST_DIR/shared/instance.env`
(mode 600). No later `apply` replaces it.

| Variable | Format |
|---|---|
| `MARGINCE_KEYVAULT_ROOT_KEY` | Standard base64 of 32 random bytes. |
| `MARGINCE_CONNECTOR_STATE_KEY` | Hex of 32 random bytes (64 characters). |
| `MARGINCE_WEBHOOK_KEY` | Standard base64 of 32 random bytes. |
| `MARGINCE_ADMIN_PASSWORD` | 24 random characters from `[A-Za-z0-9]`. |

The `api` and `worker` containers read `shared/data.env`, then
`shared/instance.env`, then the release `.env`; a later file wins. To use your
own value for one of these variables, list its name in `secrets` and set it
in the environment of `make deploy`.

| Listed in `secrets` | Result |
|---|---|
| `MARGINCE_ADMIN_PASSWORD` | `apply` generates no admin password. |
| One of the three keys | `apply` still generates the key into `instance.env` and prints a warning. Your value overrides it. |

`MARGINCE_KEYVAULT_ROOT_KEY` must not change once data is sealed with it. If
you remove a key's name from `secrets` later, the environment uses the
generated value again, and data sealed under your value does not open.
Rotate a key on purpose, by resealing the data, not by removing its name.

`MARGINCE_ADMIN_PASSWORD` is used once: core's `api` entrypoint reads it to
create the first admin account while the installation has no company, and
ignores it after that, also after you change the password in the
application. `make host-admin-password ENV=<env>` prints the generated
password from `instance.env` over SSH. When `secrets` lists
`MARGINCE_ADMIN_PASSWORD`, it says so and prints nothing else. It fails,
naming the file, before the first deployment.

### 5.7 File storage

By default `api` and `worker` store uploaded files in
`MARGINCE_BLOBSTORE_PATH=/app/data/blobs`, on the named volume `blobs`, which
is kept across releases. A one-time `blobs-init` service gives the volume to
the image's `app` user before `api` and `worker` start.

To use S3 or a compatible object store, list `MARGINCE_BLOBSTORE_ENDPOINT` and
the other object storage variables that `core/docs/reference/configuration.md`
describes in `secrets`. The adapter then leaves out the `blobs` volume, its
mounts, and `blobs-init`. An existing `blobs` volume is not deleted.

A `MARGINCE_BLOBSTORE_PATH` listed in `secrets` replaces the default path. Keep
it under `/app/data/blobs`, where the `blobs` volume is mounted; files outside
that path are lost when the container is recreated.

### 5.8 The license check

The environment runs in production mode unless `secrets` lists `MARGINCE_ENV`
and its value is `dev` or `test`. In production mode, `preflight` fails before
it connects to the server unless `secrets` lists `MARGINCE_LICENSE` and
`MARGINCE_LICENSE` has a value.

For a test environment, add `MARGINCE_ENV` to `secrets` and deploy with it set:

```sh
make deploy ENV=staging VERSION=v1.2.3 MARGINCE_ENV=test
```

The check reads only `secrets` and the environment. A license configured
another way in `config/margince.yaml` (for example core's `token_file`) does
not satisfy it.

### 5.9 What each step does

| Step | Action |
|---|---|
| `check` | `host.env` has non-empty `HOST_SSH` and `HOST_DOMAIN`; `config/margince.yaml` and `secrets` exist; `bootstrap_admin.email` is not `admin@example.com`. Each failure names the file to edit. No connection. |
| `preflight` | Builds the release files locally (every name in `secrets` has a value); runs the license check; connects over SSH with `HOST_KNOWN_HOSTS`; checks Docker for the SSH user, `timeout`, and Docker Compose 2.30.0 or later; logs in to the registry when `REGISTRY_USERNAME` is set; reads the three image manifests. Uploads nothing. |
| `apply` | Records the running release for `rollback`; builds and uploads the release files; creates `shared/data.env` (database passwords) and `shared/instance.env` when absent; logs in to the registry when `REGISTRY_USERNAME` is set; runs `docker compose pull` and `docker compose up -d --remove-orphans` within `HOST_APPLY_TIMEOUT`; installs a changed Caddyfile after `up` succeeds and reloads Caddy; points `current` at the new release; removes old release directories. |
| `verify` | Within `HOST_VERIFY_TIMEOUT`: the `api` answers `/readyz` on the server and the `worker` is running. Then, unless `HOST_VERIFY_PUBLIC=0`, `https://<HOST_DOMAIN>/` answers with a status below 500. |
| `rollback` | Removes a staged Caddyfile, starts the previous release, and points `current` back at it. See Section 5.12. |

### 5.10 Server layout and routing

| Path on the server | Content |
|---|---|
| `$HOST_DIR/releases/<v>/` | `compose.yaml`, `compose.env`, `config/margince.yaml`, and `.env` (mode 600) of one release. |
| `$HOST_DIR/current` | A symbolic link to the running release. |
| `$HOST_DIR/shared/` | `db-init.sh`, `db-bootstrap.sql`, `caddy/Caddyfile`, `data.env`, and `instance.env`. Every release uses the same files, so `postgres` and `caddy` are not recreated on each deployment. |

Every `docker compose` call on the server uses the project name
`margince-<name>` and `--env-file compose.env` from the release directory.
The `apply` step keeps the five newest release directories, plus the current
and the previous release. Redeploying the running version keeps its old
directory as `releases/.replaced-<v>` for `rollback`; the next `apply` removes
it.

Caddy sends `/v1`, `/v1/*`, `/oauth/*`, `/mcp`, `/mcp/*`, the
`/.well-known/oauth-authorization-server*` and
`/.well-known/oauth-protected-resource*` paths, `/webhooks/gmail`, and
`/webhooks/graph` to `api`, and every other path to `web`. It answers 404 for
`/healthz`, `/readyz`, and `/metrics`. `MARGINCE_PUBLIC_BASE_URL` is
`https://<HOST_DOMAIN>` unless `secrets` lists it.

### 5.11 Settings

| Setting | Default | Source | Meaning |
|---|---|---|---|
| `HOST_DIR` | `/opt/margince/<name>` | environment, else `host.env` | The directory on the server. An absolute path of letters, digits, `.`, `_`, `-`, and `/`, without `.` or `..` components. |
| `HOST_APPLY_TIMEOUT` | 600 | environment, else `host.env` | Seconds that `docker compose up -d` may take. |
| `HOST_VERIFY_TIMEOUT` | 300 | environment, else `host.env` | Seconds that `verify` waits. |
| `HOST_VERIFY_INTERVAL` | 5 | environment, else `host.env` | Seconds between the `verify` checks. |
| `HOST_VERIFY_PUBLIC` | 1 | environment, else `host.env` | `0` skips the public HTTPS check. |
| `API_REPLICAS`, `WORKER_REPLICAS` | 1 | `host.env` only | The number of containers per role. |

### 5.12 Rollback limits

`rollback` restores the previous release directory. It does not roll back the
database: the `api` applies migrations when it starts, and a migration is not
reversed automatically.

| Situation | Result of `rollback` |
|---|---|
| A previous release was running | Starts it and points `current` at it. For a redeployment of the same version, restores `releases/.replaced-<v>` first. |
| `apply` failed before it read the running release | Exits 1 and changes nothing on the server. |
| No release was running (the first deployment) | Stops the new release, removes `current` when it points there, and exits 1. Nothing runs afterwards. |

An environment first deployed by an older version of this template has no
`shared/instance.env`. The first `apply` with the current template creates
it, once. To keep a vault key that you already manage, list
`MARGINCE_KEYVAULT_ROOT_KEY` (and the other names you manage) in `secrets`
before that `apply`. That `apply` generates no `MARGINCE_ADMIN_PASSWORD`,
because the installation already has a company; `make host-admin-password`
reports this. If its `verify` fails, `rollback` restores the older release,
and the new `instance.env` stays in place for the next `apply`.

### 5.13 Backups

The template does not back up the database. Backups are the client's
responsibility: for example, snapshots of the server's disk, or the automated
backups of an external database (Section 5.5).

## 6. Deploy from GitHub Actions

`.github/workflows/deploy.yml` runs `make deploy` in a GitHub Environment. It
is started by hand (`workflow_dispatch`) with one input, `environment`.

### 6.1 Set up the GitHub Environments

Someone with admin rights on the repository does this once per environment,
before its first deployment. When no GitHub Environment of that name exists,
GitHub creates one without protection rules or secrets when the workflow runs.

1. Create a GitHub Environment with the name of each entry under `deploy:`
   (Settings, Environments).
2. Set "Deployment branches and tags" to "Selected branches and tags" with the
   tag rule `v*`.
3. Add required reviewers for `production`.
4. Add the environment's secrets: for the `host` adapter, `HOST_KNOWN_HOSTS`,
   `HOST_SSH_KEY`, and every name in `deploy/<env>/secrets` (at least
   `MARGINCE_LICENSE`).
5. Set `REGISTRY` as a variable, and `REGISTRY_USERNAME` and
   `REGISTRY_PASSWORD` as secrets, with the same values the release used (see
   [release.md](release.md#5-repository-settings)).

The job also receives the repository's and the organization's secrets and
variables. Keep deployment secrets at the environment level.

### 6.2 Run the workflow

1. Open Actions, deploy, Run workflow.
2. Under "Use workflow from", select Tags and the release tag, for example
   `v1.2.3`.
3. Enter the environment name and run it.

The checkout is the tag, so the adapter files and `deploy/<env>/` that run are
the ones in the release. Runs for the same environment wait for each other.

### 6.3 What the job does

1. Fails unless it was started from a tag that matches the release version
   pattern.
2. Fails unless the environment name matches `^[a-z0-9]+(-[a-z0-9]+)*$`.
3. Checks out the tag with submodules, without keeping a push credential.
4. Fails unless the environment is under `deploy:` in `instance.yaml` at that
   tag.
5. Exports the environment's variables and secrets as environment variables
   of the same name. A secret wins over a variable of the same name.
6. Runs `make deploy ENV=<environment> VERSION=<tag>`.

A name is exported only if it matches `^[A-Z_][A-Z0-9_]*$` and is not
reserved. The reserved names are `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`,
`BASH_ENV`, `NODE_OPTIONS`, `CDPATH`, `PROMPT_COMMAND`, `TMPDIR`, `MFLAGS`,
`MAKE_TERMOUT`, `MAKE_TERMERR`; names that start with `LD_`, `DYLD_`,
`GITHUB_`, `RUNNER_`, `ACTIONS_`, or `GIT_`; and names that match
`^GO[A-Z0-9]*$` or `^MAKE[A-Z0-9]*$`. The log names each skipped name, never a
value.

## Related guides

- [release.md](release.md): cut the release that `make deploy` deploys, and
  the image names.
- [license.md](license.md): obtain the production license.
- [create-an-instance.md](create-an-instance.md): the default `production`
  environment of a new instance.
- [troubleshooting.md](troubleshooting.md): known errors, including the key
  vault and first admin password messages.
