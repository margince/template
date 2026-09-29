# margince-template

The standard template for Margince client instances.

A Margince client runs an *instance*: the upstream core product
([`margince/margince`](https://github.com/margince/margince)) plus the client's
extensions, configuration, data, and deployment definition. This repository
defines the directory structure and tooling that every instance uses.

Without extensions, the template is itself a working instance, referred to as
**Margince Default**.

## Status

**Complete.** The template works as Margince Default: an instance can be
created, developed, trialled, released, and deployed (to a `hook` target or
to a single Linux server through the built-in `host` adapter) using only this
public template. See the [design specification](docs/superpowers/specs/2026-09-24-client-instance-template-design.md)
(Section 13) and the [issue breakdown](docs/superpowers/plans/2026-09-24-issue-breakdown.md)
for implementation status.

## Quick start

Try Margince Default on this machine, with generated instance keys and a
generated admin password, no deployment target needed:

```sh
make install
make package VERSION=v0.1.0-rc.1
make local-up VERSION=v0.1.0-rc.1
# open https://localhost (your browser warns about the local certificate)
make local-admin-password
```

`make local-down` stops it; `make local-down WIPE=1` also removes its data.
Delete `.local/` only with `make local-down WIPE=1`; deleting it by hand
leaves the data volumes, and the next `local-up` generates new database
passwords that the old database rejects.

Deploy a new instance to one Linux virtual machine (for example AWS EC2):
every instance created with `make new-instance` already has a default
`production` environment (`deploy/production/`, the built-in `host` adapter).
Fill in three values, then bootstrap and deploy:

```sh
make new-instance NAME=acme DISPLAY_NAME="Acme"
cd ../margince-acme
# fill in deploy/production/host.env (HOST_SSH, HOST_DOMAIN) and the admin
# email in deploy/production/config/margince.yaml
make host-bootstrap ENV=production
MARGINCE_LICENSE=<license> make deploy ENV=production VERSION=<v>
```

See [docs/deploy.md](docs/deploy.md) for the full `host` adapter walkthrough
and [docs/create-an-instance.md](docs/create-an-instance.md) for creating the
instance.

## How instances use this template

- Each client instance is a **fork** of this repository.
- The instance adds its own extensions, configuration, data, and deployment
  definition in instance-owned paths.
- Template changes reach an instance through `git merge template/main`.
- Core upgrades use `make update-core REF=<tag>`. Instances pin core by tag.

## Structure

```
core/            git submodule, pinned to a core tag
instance.yaml    instance metadata: name, core version, units, deployment
instance.mk      optional client-specific make targets
extensions/      client extension units (empty in the template)
config/          margince.yaml and per-environment overlays
data/            seed and demo dataset references
deploy/          one directory per environment
docs/client/     client-specific documentation
Makefile         lifecycle targets (template-owned)
scripts/         lifecycle scripts and tests (template-owned)
```

Each path is owned by either the template or the instance, never both. See
Section 6 of the design.

## Commands

Run `make help` for the full list.

| Command | Function |
|---|---|
| `make install` | Check prerequisites, check out core, install dependencies, hooks, and configuration. |
| `make dev` | Run the development stack with the instance units. |
| `make new-unit NAME=<n>` | Create an extension unit from `scripts/unit-skeleton/`. |
| `make u NAME=<n>` | Run one unit's tests and the policy gates. |
| `make check` | Run the full quality gate. |
| `make ci` | Run `make check` plus the database and submodule lanes. |
| `make new-instance NAME=<n> DISPLAY_NAME=<d>` | Create a client instance repository from this template. |
| `make template-sync` | Merge this template's changes into an instance and record them. |
| `make check-template` | Verify an instance has not drifted from the template. |
| `make check-public` | Confirm no tracked or staged file names a private repository, host, organization, or service (template only; `make check` runs it there). |
| `make update-core REF=<tag>` | Move the core pin to a core release tag. |
| `make package VERSION=<v>` | Build the `api`, `web`, and `worker` images. |
| `make smoke VERSION=<v>` | Run the built images with a temporary database and check them. |
| `make release VERSION=<v>` | Tag and push a release; `release.yml` builds and publishes it. |
| `make license OUT=<file>` | Obtain a production license into a file. |
| `make trial VERSION=<v>` | Build a trial desktop bundle with a trial license. |
| `make deploy-init ENV=<env> [ADAPTER=host\|hook] [DOMAIN=<host>] [SSH=<user@host>]` | Scaffold `deploy/<env>/` and register it under `deploy:` in `instance.yaml`. |
| `make deploy ENV=<env> VERSION=<v>` | Deploy the instance's images to an environment defined in `instance.yaml` (`deploy:`), with the `hook` or built-in `host` adapter. |
| `make host-bootstrap ENV=<env>` | Install Docker and Compose on a new server for a `host` environment. |
| `make host-admin-password ENV=<env>` | Print a `host` environment's generated first admin password. |
| `make local-up VERSION=<v>` | Run a built release on `https://localhost` (Caddy, PostgreSQL, Redis, the generated keys and admin password); state is kept in `.local/`. |
| `make local-down [WIPE=1]` | Stop the local stack; `WIPE=1` also removes its data and `.local/`. |
| `make local-admin-password` | Print the local stack's generated first admin password. |
| `make test-lifecycle` | Run the whole instance lifecycle end to end in a scratch instance (slow; installs into the Go module cache, pnpm store, and `$(go env GOPATH)/bin`). |

See [docs/release.md](docs/release.md), [docs/deploy.md](docs/deploy.md),
[docs/license.md](docs/license.md), and [docs/trial.md](docs/trial.md) for
each of these in detail.

## Related repositories

| Repository | Role |
|---|---|
| `margince/margince` | Core product, release tags, image and desktop build definitions. |
| The licensing service | Issues trial and production licenses through the API [docs/license.md](docs/license.md) documents. Not part of this template. |
| A demo dataset repository (optional, per instance) | Demo datasets, referenced by `data.dataset` in `instance.yaml` and, for the desktop build workflows, by `vars.DATASET_REPOSITORY` / `secrets.DATASET_DEPLOY_KEY`. The template refers to no specific one. |
| The client's own image registry (optional) | Where `make release` pushes images, set with `REGISTRY`. Nothing is pushed when it is not set. |

## Documentation

Start at [`docs/README.md`](docs/README.md).
