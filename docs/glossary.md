# Glossary

The terms that the guides of this repository use, with one definition each.
The guides use these names and no others for the same concepts. Where a term
is defined in code, the entry names the file.

## adapter

The script that performs the steps of a deployment for an environment:
`host` (`scripts/deploy/host.sh`, the built-in adapter for one Linux server
with Docker Compose) or `hook` (`scripts/deploy/hook.sh`, which runs the
environment's own hook scripts). `instance.yaml` names the adapter of each
environment. See [deploy.md](deploy.md).

## composition

The generated tree that combines core with the staged units. `make compose`
stages the units, runs core's composer (`core/backend/tools/gen-composition`)
over `core/extensions/`, and writes `core/build/composition/` (the Go workspace
and the generated `Extensions()` function) and
`core/build/composition-frontend/` (the pnpm workspace of the unit screens).
To compose is to run `make compose`.

## core

Margince, the product: the `margince/margince` repository, included in every
instance as the git submodule `core/`. Never edited in an instance; changes go
to core through [contributing-to-core.md](contributing-to-core.md).

## core pin

The core release tag that an instance uses: the `core` field of
`instance.yaml` and the commit that the `core/` submodule records. Only
`make update-core REF=<tag>` changes it. `make check-instance` checks that
`core/` is at the tag, and `make core-check-pin` checks that the commit is on
core's `main`.

## craft

Core's code-quality linter. `make lint` runs `craft static --strict` over
`extensions/`, using the binary that `core/scripts/craft-pin.sh` downloads.

## desktop bundle

Another name for a desktop folder, used for a folder built for distribution:
the zips of a release ([release.md](release.md#8-desktop-bundles)) and the
trial bundle. Same concept as desktop folder.

## desktop folder

The self-contained Margince folder for macOS or Windows that `make desktop`
(macOS) or `desktop-windows.yml` (Windows) builds: PostgreSQL, the event bus,
`api`, `worker`, the web UI, and a launcher, with the instance's units. An
installed copy, for example at `~/Margince`, is a desktop installation. See
[desktop-build.md](desktop-build.md).

## drift

A generated file that no longer matches its generator. `make drift` runs
core's `drift` target, which includes each unit's `manifest.generated.json`.

## environment

A deployment target of an instance, for example `production`: a key under
`deploy:` in `instance.yaml` and the directory `deploy/<env>/`. Each
environment has one adapter. `make deploy-init` creates one. See
[deploy.md](deploy.md#1-environments).

## extension

Core's name for a unit. Core's documents, and target names such as
`test-extensions`, use it; the guides of this repository use unit.

## extension surface

The packages under `core/backend/pkg/` that a unit may import: the packages
with a source file that carries the comment `//margince:extension-surface`.
Core's tests `TestSurfaceMarkerLivesOnlyUnderPkg` and
`TestExtensionsImportOnlyTheAllowlistedSurface` enforce the rule; `make arch`
runs them.

## full gate

`make check`, and in CI `full-check.yml`: the light gate plus the screen
suites, the composed typecheck, and the database lanes. `make ci` adds the
submodule checks. See [release.md](release.md#9-ci-workflows).

## gate

A `make` target that fails when a rule is broken, for example `ext-imports`,
`arch`, `check-manifests`, `drift`, `check-composition`, or `secret-scan`.
`make check` runs all gates; `make u` runs the fast gates for one unit.

## instance

A client's Margince repository, created from the template with
`make new-instance`: core as a submodule, the client's units, configuration,
demo dataset reference, and environments. The template is itself an instance,
Margince Default. `instance.yaml` describes the instance. See
[create-an-instance.md](create-an-instance.md).

## instance-owned

A path that the instance owns and changes freely: every path that
`.template-owned` does not list, for example `instance.yaml`, `extensions/`,
`deploy/`, and `README.md`. `make template-sync` keeps the instance's version.

## lane

A `make` target that a developer runs, as `make help` lists them. The pattern
rules `core-root-<lane>` and `core-backend-<lane>` stage the units and then run
a target of core's `Makefile` or `backend/Makefile`.

## light gate

The gates that `ci.yml` runs on every pull request and push to `main`. See
[release.md](release.md#9-ci-workflows).

## manifest

`extensions/<unit>/manifest.generated.json`: the record, derived by core's
composer from the unit's declaration, of what the unit requests (risk tiers,
secrets, subscriptions, ingress). `make compose` writes it; it is committed;
`make check-manifests` checks it.

## Margince Default

The template used as an instance without units: `name: margince-default` in
the template's `instance.yaml`.

## pass 1, pass 2

The two parts of `make check`. Pass 1 runs core's own `check` with the units
unstaged, because core's `check` asserts that every unit under
`core/extensions/` is tracked by core. Pass 2 stages the units and runs the
gates that check them. See [adding-an-extension.md](adding-an-extension.md#8-what-make-check-runs).

## release

A version of an instance: a git tag in the release version format
(`vX.Y.Z` or `vX.Y.Z-rc.N`), the images built from it, and the GitHub Release
with the desktop bundles. `make release` creates the tag; `release.yml`
builds the release. See [release.md](release.md).

## risk tier

An entry under `risk_tiers` in a unit's manifest: one governed operation that
the unit adds, with its scopes and tier (for example `auto_execute`). A unit
without governed operations has an empty list.

## seam

A place in core that a unit is written against, usually a package on the
extension surface. A unit that needs a seam that core does not have needs a
change to core ([contributing-to-core.md](contributing-to-core.md)).

## slug

1. `DEV_SLUG=<name>`: the name of a separate development stack with its own
   database and ports (`make dev DEV_SLUG=<name>`).
2. The part after `/` in a core contribution branch name, `<type>/<slug>`
   (`make core-branch`).

## staged copy

`core/extensions/<unit>/`: the copy of `extensions/<unit>/` that staging
writes. Never edit it; the next `make stage` replaces it. `make unstage`
removes the staged copies. `scripts/lib.sh` records the staged units in a
marker file in the submodule's git directory, so unstaging removes only the
instance's units.

## staging

Copying the instance's units and configuration into `core/`, where core's
tools read them. `make stage` copies `extensions/*` to `core/extensions/`
(without `node_modules`), copies `.env.local` and `config/margince.yaml` into
`core/`, and writes the editor files `go.work` and `tsconfig.json`. Every lane
that builds or tests the composition stages first. It is a copy, not a
symbolic link, because core's composer refuses a linked unit.

## template

This repository, `margince/template`: the source of every instance. It owns
the `Makefile`, `scripts/`, the workflows, and the guides.

## template-owned

A path that the template owns, listed in `.template-owned`. An instance
receives changes to it only through `make template-sync`, and
`make check-template` fails when an instance changes it.

## template sync

`make template-sync`: merging the template's `main` into an instance and
recording the template commit in `.template-version`. See
[create-an-instance.md](create-an-instance.md#6-receive-template-changes).

## trial bundle

A desktop folder that runs in production mode with a trial license, built with
`make trial`. See [trial.md](trial.md).

## unit

An extension of an instance: one directory under `extensions/`, its own Go
module (`margince.instance/extensions/<name>`), which exports
`func New() extension.Extension`. The directory's presence enables it. See
[adding-an-extension.md](adding-an-extension.md).
