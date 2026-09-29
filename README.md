# margince-template

The template you create your Margince instance from. An instance is the
Margince core product ([`margince/margince`](https://github.com/margince/margince))
plus your extension units, configuration, demo data reference, and
deployment definition. This repository defines the directory structure, the
`make` targets, the CI workflows, and the deployment adapters that every
instance uses. Without extensions, the template is itself a working instance,
named **Margince Default**.

This README is for developers who create, develop, release, or deploy an
instance. Contributors to the template itself also read [AGENTS.md](AGENTS.md).

## Requirements

| Tool | Version | Needed for | Checked by |
|---|---|---|---|
| git | any | everything | `make preflight` |
| Go | the `go` line of `core/backend/go.mod` (1.26.6 at core `v0.0.2`) | the backend, the gates, `scripts/cli` | `make preflight` (installed only) |
| Node.js | 24, the version CI uses | the frontend lanes | `make preflight` (installed only) |
| pnpm | the major version of `packageManager` in `core/package.json` (11) | the frontend lanes | `make toolcheck` (major version) |
| Docker, with a running daemon and `docker buildx` | current | the database, `make package`, `make smoke`, `make local-up` | `make preflight`; `make package` checks buildx |
| GitHub CLI (`gh`) | any | `make new-instance PUSH=1`, `make core-pr` | optional |
| fswatch | any | `make watch` | optional |
| python3, curl | any | `make config-check`, `make license`, `make trial`, `make smoke`, `make local-up` | not checked |
| ssh, scp, ssh-keyscan | any | the `host` adapter | not checked |

`make install` runs `make preflight` first and names every missing tool.
`make install INSTALL_TOOLS=1` installs the missing tools that Homebrew can
install.

## Quick start

### Run Margince Default on your computer

```sh
make install
make package VERSION=v0.1.0-rc.1
make local-up VERSION=v0.1.0-rc.1
make local-admin-password
```

Ports 80 and 443 must be free.

1. Open `https://localhost` and accept the browser warning about the local
   certificate.
2. Sign in as `admin@localhost` with the password that
   `make local-admin-password` prints.

`VERSION` can be any release version string; it does not need a git tag.
`make package` refuses a working tree with uncommitted changes (`ALLOW_DIRTY=1`
overrides this). Without `MARGINCE_LICENSE` in the environment the stack runs
with `MARGINCE_ENV=test`. `make local-down` stops the stack;
`make local-down WIPE=1` also removes its data and `.local/`. Do not delete
`.local/` by hand: the data volumes stay, and the next `make local-up`
generates database passwords that the old database rejects.

### Create your instance

Run this in a template checkout on which `make install` has run:
`make new-instance` checks out `core/` from the template's `core/` and
validates `instance.yaml` with Go.

```sh
make new-instance NAME=acme DISPLAY_NAME="Acme"
cd ../margince-acme
make install
make dev
```

`PUSH=1 OWNER=<github-owner>` also creates a private GitHub repository and
pushes the instance. See [docs/create-an-instance.md](docs/create-an-instance.md).

### Deploy an instance to a Linux server

Every new instance has a `production` environment in `deploy/production/` that
uses the built-in `host` adapter. Before you start, you need:

- the instance on GitHub, with the repository variable `REGISTRY` and, for a
  private registry, the secrets `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`
  ([docs/release.md](docs/release.md#5-repository-settings));
- a server with Ubuntu 22.04, Ubuntu 24.04, or Amazon Linux 2023, ports 22, 80,
  and 443 open, a DNS record for its domain, and an SSH user with
  passwordless `sudo`;
- a production license ([docs/license.md](docs/license.md));
- an SSH key for the server's user, in your SSH agent or in `HOST_SSH_KEY`.

Run these commands in the instance:

```sh
# 1. Fill in HOST_SSH and HOST_DOMAIN in deploy/production/host.env and
#    bootstrap_admin.email in deploy/production/config/margince.yaml.
git commit -am "deploy: configure production" && git push
# 2. Compare the printed key fingerprint with the server's before you use it.
export HOST_KNOWN_HOSTS="$(ssh-keyscan -H <host>)"
make host-bootstrap ENV=production
# 3. make release runs make check, then tags the release. release.yml
#    builds, tests, and pushes the images.
make release VERSION=v0.1.0
# 4. When release.yml has finished:
REGISTRY=<registry> MARGINCE_LICENSE="$(cat <license-file>)" \
  make deploy ENV=production VERSION=v0.1.0
make host-admin-password ENV=production
```

For a private registry, also set `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`.

See [docs/deploy.md](docs/deploy.md) for every step, the `hook` adapter, and
deployment from GitHub Actions.

## Commands

`make help` lists every target, including the individual gates, the frontend
and infrastructure lanes, and the desktop lanes.

| Stage | Command | Function |
|---|---|---|
| Setup | `make install` | Check prerequisites, then check out core and install dependencies, hooks, and configuration. |
| Setup | `make preflight` | Report missing prerequisites without changing anything. |
| Setup | `make toolcheck` | Verify that the local pnpm major version matches core's CI. |
| Setup | `make config` | Create `.env.local` and `config/`, stage them into `core/`, and refresh `go.work`. |
| Setup | `make config-check` | Compare the keys of `.env.local` and `config/margince.yaml` with core's examples. |
| Development | `make dev` | Run the development stack with the instance's units (`DEV_SLUG=<name>` for an isolated stack). |
| Development | `make dev-stop` | Stop the development stack (`DROP=1` also drops its database). |
| Development | `make seed-dev` | Add a demo workspace and records to the running stack. |
| Development | `make new-unit NAME=<name>` | Create a unit in `extensions/<name>` from `scripts/unit-skeleton/`. |
| Development | `make u NAME=<unit>` | Run one unit's tests and the policy gates. |
| Development | `make u-check NAME=<unit>` | Run `make u`, the screen suites, and the composed typecheck. |
| Development | `make watch` | Stage the units again when a source file changes. |
| Development | `make fmt` | Format `extensions/` in place. |
| Gates | `make check` | Run the full gate: core's own gate, then the composed gates. |
| Gates | `make ci` | Run `make check` plus the database and submodule lanes. |
| Gates | `make test-scripts` | Run the tests of the template's scripts and CLI. |
| Gates | `make test-lifecycle` | Run the whole instance lifecycle in a scratch instance (slow; `KEEP=1` keeps it). |
| Instance | `make new-instance NAME=<name> DISPLAY_NAME=<text>` | Create your instance repository from this template. |
| Instance | `make template-sync` | Merge the template's `main` into an instance and record it in `.template-version`. |
| Instance | `make check-template` | Verify that template-owned paths match the merged template commit. |
| Instance | `make check-instance` | Verify that `instance.yaml` is valid and names the tag `core/` is at. |
| Instance | `make update-core REF=<tag>` | Move `core/` to a core release tag and record it in `instance.yaml`. |
| Release | `make package VERSION=<v>` | Build the `api`, `web`, and `worker` images with the instance's units. |
| Release | `make smoke VERSION=<v>` | Start the built images with a temporary database and check them. |
| Release | `make release VERSION=<v>` | Check the preconditions, then tag and push a release; `release.yml` builds it. |
| Release | `make license OUT=<file>` | Obtain a production license into a file. |
| Release | `make desktop VERSION=<v>` | Build the macOS desktop folder with the instance's units. |
| Release | `make trial VERSION=<v>` | Build a trial bundle with a trial license. |
| Deploy | `make deploy-init ENV=<env>` | Create `deploy/<env>/` and register the environment in `instance.yaml`. |
| Deploy | `make host-bootstrap ENV=<env>` | Install Docker and Docker Compose on a new server of a `host` environment. |
| Deploy | `make deploy ENV=<env> VERSION=<v>` | Deploy a release to an environment in `instance.yaml`. |
| Deploy | `make host-admin-password ENV=<env>` | Print the generated first admin password of a `host` environment. |
| Local | `make local-up VERSION=<v>` | Run a built release on `https://localhost`. |
| Local | `make local-down` | Stop the local stack (`WIPE=1` also removes its data and `.local/`). |
| Local | `make local-admin-password` | Print the generated first admin password of the local stack. |
| Core | `make core-status` | Show where `core/` is: branch, pinned commit, ahead and behind, changes. |
| Core | `make core-branch NAME=<type>/<slug>` | Start a core contribution branch in `core/`. |
| Core | `make core-pr` | Verify the sign-off, push the core branch, and open the pull request. |
| Core | `make core-restore` | Return `core/` to the commit this repository pins. |

## Repository layout

| Path | Owner | Content |
|---|---|---|
| `core/` | pinned | Git submodule of `margince/margince`, pinned to a core release tag. Changed only by `make update-core`. |
| `Makefile` | template | The lifecycle targets. Includes `instance.mk`. |
| `scripts/` | template | Lifecycle scripts, deployment adapters, the Go CLI in `scripts/cli`, and their tests. |
| `.github/workflows/` | template | `ci`, `full-check`, `lifecycle`, `release`, `deploy`, `desktop-macos`, `desktop-windows`. |
| `.githooks/`, `.gitleaks.toml`, `.gitignore` | template | The pre-push hook, the secret scanner configuration, the ignore rules. |
| `AGENTS.md`, `CLAUDE.md`, `docs/*.md` | template | Contributor rules and the guides. |
| `.template-owned` | template | The list of template-owned paths, one git pathspec per line. |
| `.template-version` | instance | The template commit the instance last merged. Instances only. |
| `README.md` | instance | This file in the template; `make new-instance` writes a new one. |
| `instance.yaml` | instance | Name, display name, core tag, optional demo dataset, and deployment environments. |
| `instance.mk` | instance | Optional instance-only `make` targets. Not in the template. |
| `extensions/` | instance | Extension units. Empty in the template. |
| `config/` | instance | Local configuration, created by `make config`. Not tracked in the template. |
| `data/` | instance | Demo dataset references. Not in the template. |
| `deploy/` | instance | One directory per environment. The template ships `deploy/production/`. |
| `docs/client/` | instance | Client documentation. Not in the template. |

`.template-owned` is the authoritative list; a path that it does not list is
instance-owned. `make check-template` fails in an instance when a
template-owned path differs from the merged template commit. See
[docs/create-an-instance.md](docs/create-an-instance.md#4-what-the-instance-contains).

## Related repositories and services

| Repository or service | Role |
|---|---|
| `margince/margince` | Core product, release tags, image and desktop build definitions. |
| Margince license service | Issues trial and production licenses through the API in [docs/license.md](docs/license.md). Not part of this template. |
| A demo dataset repository | Optional, per instance: `data.dataset` in `instance.yaml` and, for the desktop workflows, `vars.DATASET_REPOSITORY` and `secrets.DATASET_DEPLOY_KEY`. |
| The client's image registry | Optional: `make release` pushes images there when `REGISTRY` is set. |

## Documentation

| Guide | Purpose |
|---|---|
| [Documentation index](docs/README.md) | Every guide, the design, and the plans. |
| [Create an instance](docs/create-an-instance.md) | Create an instance and keep it current with the template and with core. |
| [Adding an extension](docs/adding-an-extension.md) | Create and test a unit. |
| [Release](docs/release.md) | Cut a release, build and test the images. |
| [Deploy](docs/deploy.md) | Deploy a release with the `host` or `hook` adapter. |
| [License](docs/license.md) | Obtain a trial or production license. |
| [Trial](docs/trial.md) | Build a trial bundle. |
| [Troubleshooting](docs/troubleshooting.md) | Known errors and their fixes. |
