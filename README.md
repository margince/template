# margince-template

The standard template for Margince client instances.

A Margince client runs an *instance*: the upstream core product
([`margince/margince`](https://github.com/margince/margince)) plus the client's
extensions, configuration, data, and deployment definition. This repository
defines the directory structure and tooling that every instance uses.

Without extensions, the template is itself a working instance, referred to as
**Margince Default**.

## Status

**Design phase.** The design is in
[`docs/superpowers/specs/2026-09-24-client-instance-template-design.md`](docs/superpowers/specs/2026-09-24-client-instance-template-design.md)
and is pending review. The tooling described below is not implemented yet.

## How instances use this template

- Each client instance is a **fork** of this repository.
- The instance adds its own extensions, configuration, data, and deployment
  definition in instance-owned paths.
- Template changes reach an instance through `git merge template/main`.
- Core upgrades use `make update-core REF=<tag>`. Instances pin core by tag.

## Planned structure

```
core/            git submodule, pinned to a core tag
instance.yaml    instance metadata: name, core version, units, flavor, deployment
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

## Planned commands

| Command | Function |
|---|---|
| `make install` | Set up tools, core, dependencies, hooks, and configuration. |
| `make dev` | Run the development stack with the instance units. |
| `make new-unit NAME=<n>` | Create an extension unit. |
| `make check` | Run the full quality gate. |
| `make trial` | Build a laptop trial bundle with a trial license. |
| `make update-core REF=<tag>` | Move the core pin to a core tag. |
| `make release VERSION=<v>` | Tag a release. CI builds the `api`, `web`, and `worker` images. |
| `make deploy ENV=<env> VERSION=<v>` | Deploy a release to an environment. |

## Related repositories

| Repository | Role |
|---|---|
| `margince/margince` | Core product, release tags, image and desktop build definitions. |
| `gradionhq/margince-constellation` | Licensing, license-gated registry and downloads, upgrades. |
| `gradionhq/margince-demo-database` | Demo datasets. |
| `gradionhq/margince-qc` | Acceptance tests. |
| `gradionhq/margince-automation-world` | Source of the template tooling. |

## Documentation

Start at [`docs/README.md`](docs/README.md).
