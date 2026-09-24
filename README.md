# margince-template

The standard template for Margince client instances.

A Margince client runs an *instance*: the upstream core product
([`margince/margince`](https://github.com/margince/margince)) plus the client's
extensions, configuration, data, and deployment definition. This repository
defines the directory structure and tooling that every instance uses.

Without extensions, the template is itself a working instance, referred to as
**Margince Default**.

## Status

**Foundation in place.** The template works as Margince Default. Trial,
release, and deployment are planned (see the issue breakdown).

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
| `make update-core REF=<ref>` | Move the core pin. |

Planned, not implemented yet: the trial bundle (issue T8), release (issue T7),
and deployment (issue T9).

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
