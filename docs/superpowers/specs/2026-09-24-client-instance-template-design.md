# Client Instance Template — Design Specification

- **Date:** 2026-09-24
- **Status:** Draft, pending review
- **Repository:** `gradionhq/margince-template`

## 1. Background

A Margince client runs an *instance*. An instance consists of the upstream core
product, the client's extensions, configuration, data, and a deployment
definition.

Four instance repositories currently exist: `incap`, `afs`, `margince-gradion`,
and `margince-automation-world`. They are inconsistent:

- `incap` and `afs` provide approximately 12 make targets.
- `margince-gradion` and `margince-automation-world` provide approximately 70
  documented make targets, including a development stack, desktop builds,
  secret scanning, role image builds, and release workflows.
- `margince-automation-world` is a copy of `margince-gradion`. The two
  repositories share git history, have identical Makefiles, and contain the
  same five extensions. Their `scripts/` directories differ in one file
  (`lint.sh`), where the `margince-gradion` version is newer.

Related responsibilities are spread across other repositories:

- Release image builds are in `margince-release`. Constellation PR #421 is
  porting them into `margince-constellation`.
- The Gradion deployment is in `margince-d13-deploy`.

No document defines which repository is responsible for which function.

This specification introduces an **instance template** that defines the
standard structure and tooling for all instances. The template is derived from
the existing tooling in `margince-automation-world`, which is in active use. The
specification also defines the responsibility of each repository.

## 2. Goals

1. Each Margince core release is identified by a git tag.
2. Each instance pins a specific core version by tag. An instance does not
   track a branch.
3. A single command builds a trial version of an instance that runs on a
   laptop. Clients use the trial version for evaluation before sign-off.
4. A single command sets up a development environment for extension
   development.
5. An instance can build, test, and deploy itself to a target environment. The
   deployment uses separate `api`, `web`, and `worker` images so that each
   component scales independently.
6. The responsibility of each repository is documented. Each responsibility is
   assigned to exactly one repository.

## 3. Non-Goals

- Changes to how core composes extensions (`gen-composition`), builds images,
  or builds the desktop bundle. The template invokes these mechanisms. It does
  not replace them.
- Changes to Constellation licensing or distribution services, except those
  required by the trial and release workflows.
- A separately versioned tooling repository or CLI. See Section 16.
- Rewriting existing scripts. Existing scripts are reused and changed only
  where they contain client-specific values. See Section 7.

## 4. Decisions

| Topic | Decision |
|---|---|
| Propagation of template changes | Each instance is a fork of the template. Template changes are applied with `git merge template/main`. |
| Propagation of core upgrades | The existing `make update-core REF=<tag>` command, restricted to tags. |
| Image builds | Each instance builds its own images in its own CI. Constellation handles licensing and distribution only. |
| Source of the template tooling | The files of `margince-automation-world` (`scripts/`, `Makefile`, `.github/workflows/`, `.githooks/`, `config/`, supporting files) are copied into the template. `lint.sh` is taken from `margince-gradion`. |
| Template git history | The template starts with new git history. The history of `margince-automation-world` is not imported, because it contains the code of five client extensions, and every future client fork would inherit that code. The initial import commit records the source repository and commit of each copied file. |
| `margince-release` | Archived. |
| Constellation PR #421 | Closed. Its Go commands (`verdict`, `promote`, `notes`, `tag-sources`, `cleanup`) are reused in the template tooling where applicable. |
| Deployment | Each client uses one deployment process. The template defines standard deployment steps. The instance provides configuration values and, where required, hook scripts. |

## 5. Repository Responsibilities

| Repository | Responsible for | Not responsible for |
|---|---|---|
| `margince/margince` (core) | Product source code; release tags; role image definitions (`Dockerfile`, `docker-bake.hcl`); desktop all-in-one build; `gen-composition`; extension SDK. | Any client-specific content. |
| `margince-template` (new) | Standard directory layout; lifecycle commands; development environment; CI workflows; deployment interface; core version pin. The template is itself a functional instance without extensions, referred to as **Margince Default**. | Client-specific code. |
| Client instance (fork of the template) | `instance.yaml`, `instance.mk`, `extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`. | Modifications to template-owned files. Tooling changes are made in the template and merged into the instance. |
| `margince-constellation` | Customer records; license issuance (trial and production); license-gated container registry and artifact downloads; `upgrade-cli`. | Instance composition or instance builds. |
| `margince-demo-database` | Demo datasets. An instance references a dataset by name and version in `data/`. | — |
| `margince-qc` | Acceptance tests against a specified build. Can target any instance. | — |
| `margince-d13-deploy` | Moved into `margince-gradion/deploy/`, then archived. | — |
| `margince-release` | — | Archived. |

## 6. Template Structure and Path Ownership

Each path is owned by either the template or the instance. No path is owned by
both. This rule minimizes merge conflicts when an instance merges template
changes.

The structure keeps the existing layout of `margince-automation-world`. The
tooling directory remains `scripts/`.

```
margince-template/                   (client forks use the same structure)
├── core/                  ◆ git submodule, pinned to a core tag
├── instance.yaml          ● instance metadata: name, core version, units,
│                            deployment targets, license product
├── instance.mk            ● optional client-specific make targets
├── extensions/            ● client extension units (empty in the template)
├── config/                ● margince.yaml and per-environment overlays
├── data/                  ● seed and demo dataset references
├── deploy/                ● one directory per environment: values and optional hooks
├── docs/client/           ● client-specific documentation
├── Makefile               ○ lifecycle targets; includes instance.mk if present
├── scripts/               ○ lifecycle scripts and their tests
│   ├── cli/               ○ Go CLI (instance.yaml access, release commands)
│   ├── desktop-kit/       ○ launcher files for the desktop bundle
│   ├── unit-skeleton/     ○ template for new extension units
│   └── deploy/            ○ deployment adapters
├── .github/workflows/     ○ ci.yml, full-check.yml, release.yml, deploy.yml,
│                            desktop-macos.yml, desktop-windows.yml
├── .githooks/, .gitleaks.toml, linter configuration   ○
└── docs/                  ○ template usage documentation

○ Template-owned. Instances must not modify these paths.
● Instance-owned. The template provides an empty or example version.
◆ Modified only by `make update-core REF=<tag>`.
```

### 6.1 Drift Check

The file `.template-version` records the template commit that was last merged
into the instance. The command `make check-template` fails if any
template-owned path differs from that commit. `make check` includes
`make check-template`.

### 6.2 `instance.yaml`

Example (all values are illustrative):

```yaml
name: incap                      # used in image names and the trial bundle name
display_name: Incap              # used in user-facing text of the desktop bundle
core: v0.0.2                     # must match the tag of the core/ submodule
units: [incap]                   # extensions/ entries to compose; empty means none
data:
  dataset: margince-demo-database/incap@v3   # optional
license:
  product: margince-incap        # Constellation product for license issuance
registry: registry.example.com/clients/incap
deploy:
  staging:    { adapter: d13 }
  production: { adapter: d13 }
```

Scripts read `instance.yaml` through the Go CLI (`scripts/cli`). Go is already
a required tool, so this adds no dependency.

`make check` validates the following:

- `core` matches the tag of the `core/` submodule.
- Each entry in `units` exists under `extensions/`.
- Each environment under `deploy` has a matching `deploy/<env>/` directory.

### 6.3 `instance.mk`

`instance.mk` contains make targets that only one client needs. An example is
the `zalo-lab` target in `margince-automation-world`. The template `Makefile`
ends with `-include instance.mk`. Targets in `instance.mk` must not redefine
template targets. `make check-template` fails if they do.

## 7. Reuse of Existing Scripts

The following table lists each script in `margince-automation-world/scripts/`
and the action taken when it is copied into the template. Each script keeps its
`*.test.sh` test file.

| Script | Function | Action |
|---|---|---|
| `lib.sh` | Shared shell functions | Keep |
| `stage.sh`, `unstage.sh` | Copy units into `core/extensions/` and remove them | Keep |
| `sync-manifests.sh`, `check-manifests.sh` | Keep unit manifests committed and current | Keep |
| `check-core-clean.sh` | Verify `core/` is unmodified after a build | Keep |
| `check-docs.sh` | Verify every `make` target named in the docs exists | Keep |
| `preflight.sh`, `toolcheck.sh` | Verify required tools and versions | Keep |
| `config-init.sh`, `config-check.sh`, `config-sync.sh` | Create and synchronize `.env.local` and `config/` with core examples | Keep |
| `core-contrib.sh` | Create branches and pull requests for core contributions | Keep |
| `fe-ds-gates.sh`, `fmt.sh` | Design-system gates and formatting for unit code | Keep |
| `gitleaks-pin.sh`, `secret-scan.sh` | Pinned secret scanner | Keep |
| `gowork.sh`, `tsconfig-editor.sh` | Generate editor workspace files | Keep |
| `test-integration-ext.sh` | Integration tests for units | Keep |
| `desktop-kit/` | Desktop bundle launcher files | Keep |
| `lint.sh` | Lint unit code | Replace with the `margince-gradion` version (uses the pinned `craft` binary) |
| `package.sh` | Build `api`, `web`, `worker` images with units | Generalize: read the image name and registry from `instance.yaml`; rename labels `com.gradion.*` to `com.margince.instance.*` |
| `new-unit.sh` | Create a new unit | Generalize: copy from `scripts/unit-skeleton/` instead of `extensions/gradion` |
| `desktop.sh`, `build-info.sh` | Build, install, and inspect the desktop bundle | Generalize: take the client name in user-facing text from `display_name` in `instance.yaml` |

The `Makefile` is copied with the following changes:

- The header comment describes the template, not Gradion.
- The `zalo-lab` target is removed. It moves to `instance.mk` in
  `margince-automation-world`.
- The `new-unit` description refers to `scripts/unit-skeleton/`.
- The new targets in Section 8 are added.

New components that do not exist in `margince-automation-world`:

| Component | Function |
|---|---|
| `scripts/cli/` | Go CLI: reads and validates `instance.yaml`; contains the reused PR #421 commands. Run with `go run`. |
| `scripts/check-template.sh` | Drift check (Section 6.1). |
| `scripts/trial-license.sh` | Requests a trial license from the Constellation licenser (Section 9.2). |
| `scripts/deploy/` | Deployment adapters `d13` and `hook` (Section 9.4). |
| `scripts/unit-skeleton/` | Neutral unit template for `new-unit.sh`. |
| `.github/workflows/deploy.yml` | Manually triggered deployment workflow. |

## 8. Build Tooling Layers

| Layer | Location | Scope | Versioned with |
|---|---|---|---|
| 1. Product build | core | Builds Margince: role images (`docker buildx bake`), desktop bundle (`make desktop-dist`, `make desktop-win`), composition (`gen-composition`). | Core tag |
| 2. Instance orchestration | template `scripts/` | Assembles and ships the instance: stages units into core, invokes layer 1 with the instance name and version, obtains licenses, pushes images, invokes deployment. | Template (via merge) |
| 3. Deployment target | instance `deploy/<env>/` | Defines where the instance runs: configuration values and optional hooks. Contains no build logic. | Instance |

Changes are placed as follows:

- A change to how Margince is compiled is made in core.
- A change to how an instance is assembled or shipped is made in the template.
- A client repository contains neither type of change.

## 9. Lifecycle Commands

All instances provide the same commands. Existing target names from
`margince-automation-world` are kept. The template CI runs these commands
against the template itself to verify the template.

| Command | Function | Status |
|---|---|---|
| `make install` | Verifies required tools, checks out core, installs dependencies, git hooks, and configuration. | Existing |
| `make dev` | Starts infrastructure services and runs `api`, `worker`, and `web` with the instance units composed. | Existing |
| `make new-unit NAME=<n>` | Creates an extension in `extensions/<n>` from `scripts/unit-skeleton/` and adds it to `instance.yaml`. | Existing, changed |
| `make check` | Full gate: core checks, composition, unit tests, linters, secret scanning. Adds `instance.yaml` validation and `check-template`. | Existing, changed |
| `make ci` | `make check` plus integration tests against a real database and submodule checks. | Existing |
| `make package VERSION=<v>` | Builds the `api`, `web`, and `worker` images with the instance units. | Existing, changed |
| `make desktop VERSION=<v>` | Builds the desktop bundle with the instance units. | Existing, changed |
| `make trial` | Runs `make desktop` and adds configuration, dataset, and a trial license. See Section 10.2. | New |
| `make update-core REF=<tag>` | Updates the core submodule. Changed to accept tags only and to update `instance.yaml`. | Existing, changed |
| `make release VERSION=<v>` | Verifies the working tree and `make check`, then pushes the tag `v<v>`. | New |
| `make deploy ENV=<env> VERSION=<v>` | Deploys the specified images to the environment defined in `deploy/<env>/`. | New |
| `make check-template` | Drift check. | New |

## 10. Workflows

### 10.1 Development (Goal 4)

Run `make install`, then `make dev`. `make dev` performs the following steps:

1. Stages the instance units into `core/`.
2. Starts PostgreSQL, Redis, and MinIO.
3. Runs `api`, `worker`, and `web` from source using `config/margince.yaml` with
   the development overlay.

The development environment sets `MARGINCE_ENV=dev`. No license is required.
These targets exist in `margince-automation-world` and are copied unchanged.

### 10.2 Laptop Trial (Goal 3)

`make trial` performs the following steps:

1. Runs `make desktop`, which stages the units and runs the core desktop build
   for the host platform.
2. Adds the production configuration overlay from `config/`.
3. Adds the dataset referenced in `data/`, using the existing `desktop-seed`
   mechanism.
4. Runs `scripts/trial-license.sh` to obtain a trial license and writes it to
   the bundle environment file.
5. Writes the bundle to `dist/trial/<name>-<version>-<platform>/`.

The trial license is a license JWT issued by the Constellation licenser for the
product in `license.product`. It has a limited validity period and is marked as
a trial license. The template requests it from the licenser API using an
operator credential provided in the environment variable
`MARGINCE_LICENSER_TOKEN`. The license is written to the bundle only. It is
never committed to the repository.

The bundle runs in production mode. The client therefore evaluates the same
configuration that is later deployed.

Required Constellation changes: a trial license type (validity period and trial
marker) and an issuance endpoint that accepts an operator credential. The
details are defined in sub-project 4.

### 10.3 Build and Release (Goal 5)

`make release VERSION=<v>` verifies that the working tree is clean and that
`make check` passes, then pushes the tag `v<v>`.

The existing `release.yml` runs on `v*` tags. It runs `full-check.yml` and
builds the macOS and Windows desktop bundles. The template adds the following
jobs:

1. **Images:** runs `make package` with `REPO=<registry>` and `VERSION=<v>`. This
   produces `<registry>/<name>-api`, `<registry>/<name>-web`, and
   `<registry>/<name>-worker` with the candidate tag `cand-<commit>`, for
   multiple architectures. Each image has an OCI label with the core version.
2. **Smoke test:** starts the three images with a temporary PostgreSQL and
   Redis instance and verifies that they start and respond.
3. **Publish:** adds the tag `<v>` to the images in the Constellation registry
   using the publisher identity, and generates release notes with the `notes`
   command. The release notes list the core tag, the instance commit, and the
   image digests.

Images are tagged with the instance version only. The core version is recorded
as a label, because multiple instance releases can use the same core version.

### 10.4 Deployment (Goal 5)

`make deploy ENV=<env> VERSION=<v>` (or a manual run of `deploy.yml`) executes
the following steps in order:

```
preflight → apply → verify → rollback (on failure only)
```

`deploy/<env>/` contains the environment configuration: hostnames, replica
count per component, and the names of required secrets, such as the production
license (`MARGINCE_LICENSE`) and the database URL. It does not contain secret
values.

`instance.yaml` specifies an **adapter** for each environment. An adapter
implements the four steps. The template provides two adapters in
`scripts/deploy/`:

- `d13`: deploys to District 13 (Gradion's Kubernetes platform). Based on
  `margince-d13-deploy`. Uses `.d13.<env>.yaml` and ingress definitions, with
  one service per component.
- `hook`: runs the instance scripts
  `deploy/<env>/hooks/{preflight,apply,verify,rollback}.sh`.

A new adapter is added to the template only when at least two clients require
the same deployment target. Until then, clients use the `hook` adapter.

All adapters deploy `api`, `web`, and `worker` as separate services so that each
can be scaled independently.

### 10.5 Licensing by Stage

| Stage | Runtime mode | License |
|---|---|---|
| Development | `MARGINCE_ENV=dev` | Not required. |
| Trial | Production | Trial license issued by the Constellation licenser and included in the bundle. |
| Staging and production | Production | Production license issued at sign-off. Stored in the environment secret store and provided as `MARGINCE_LICENSE`. |

Licenses are never committed to a repository. `MARGINCE_LICENSE` overrides any
`license.token` value in the instance configuration. The instance
configuration therefore does not define `license.token`.

## 11. Versioning (Goals 1 and 2)

- **Core:** each release is a git tag. `make update-core` accepts tags only.
- **Instance:** has an independent version. Releases are tagged
  `v<major>.<minor>.<patch>` in the instance repository.
- **Template:** each instance records the last merged template commit in
  `.template-version`. The template tags its releases so that each merge
  references a tagged version.

**Open decision: core version scheme.** Core currently uses two version
schemes:

- Git tags in the format `v0.0.x`.
- `docker-bake.hcl` sets image versions in the Constellation `YYYY.edition`
  format (for example `1970.<build>`) and pushes to
  `registry.test.margince.com/margince`.

The template treats the core version as a single string that must be a core git
tag. Core must adopt one scheme, in which the git tag equals the version set in
the images. This decision is required before sub-project 1 is planned.

## 12. Error Handling

| Command | Failure condition | Behavior |
|---|---|---|
| `make check` | `core/` is not at the tag in `instance.yaml`, or has uncommitted changes. | Fails. |
| `make check` | A template-owned path differs from `.template-version`, or `instance.mk` redefines a template target. | Fails. |
| `make release` | Working tree is not clean, the tag already exists, or `make check` fails. | Fails without creating a tag. |
| `release.yml` | Smoke test fails. | The version tag is not added. Images keep the candidate tag. The `cleanup` command removes old candidate images. |
| `make deploy` | `verify` fails. | Runs `rollback` and exits with a non-zero status. |
| `make trial` | No license is available. | Fails. Does not fall back to development mode. |

## 13. Testing

- Existing script tests (`*.test.sh`) are copied with their scripts and run by
  `make test-scripts`. Generalized scripts get updated tests.
- The template CI runs the complete lifecycle against the template: `install`,
  `check`, `trial` (build only), `release` (dry run), and `deploy` with a test
  `hook` adapter. Template changes that break a command fail in the template CI
  before any instance merges them.
- A test instance with one example unit runs the same lifecycle to verify
  composition with a unit present.
- The Go CLI has unit tests.

## 14. Migration

Each existing instance is converted into a fork of the template:

1. Add the template as a git remote and merge it with
   `git merge --allow-unrelated-histories template/main`. This option is
   required once, because the template has new history. For template-owned
   paths, keep the template version. Move client-specific content into
   instance-owned paths.
2. Create `instance.yaml`. Update the core pin to the nearest core tag.
3. Verify with `make check`, `make trial`, and one staging deployment.

Later merges are regular merges.

Migration order:

1. `margince-automation-world`. Its tooling is the source of the template, so
   the first merge has the fewest conflicts. Its `zalo-lab` target moves to
   `instance.mk`.
2. `margince-gradion`, including the move of `margince-d13-deploy` into
   `deploy/` as the first use of the `d13` adapter.
3. `incap` and `afs`. These receive the full tooling set for the first time.

## 15. Sub-Projects

The work is delivered as separate implementation plans in the following order:

1. **Core versioning:** define the version scheme; release tags determine the
   image version.
2. **Template foundation:** copy the tooling from `margince-automation-world`,
   generalize the scripts in Section 7, add `instance.yaml`, `instance.mk`,
   the unit skeleton, the drift check, and the template CI.
3. **Build and release:** image, smoke test, and publish jobs in `release.yml`;
   the Go CLI with the reused PR #421 commands; push to the Constellation
   registry.
4. **Trial and licensing:** Constellation trial license type and issuance
   endpoint; `make trial`.
5. **Deployment:** the four-step deployment interface, the `hook` adapter, the
   `d13` adapter.
6. **Migration and retirement:** migrate the four instances; archive
   `margince-release` and `margince-d13-deploy`; close PR #421.

## 16. Rejected Alternatives

| Alternative | Reason for rejection |
|---|---|
| One-time copy (GitHub template repository without synchronization) | Instances diverge over time. This caused the current inconsistency. |
| Separately versioned tooling repository or CLI | Adds a third version to align with core and the template. Duplicates the function of fork-and-merge. |
| Central build workflow in Constellation (PR #421) | Instance developers cannot build and deploy their own repository, which Goal 5 requires. |
| Configuration-only deployment (no hooks) | Each client-specific requirement would require a template change. |
| Import the `margince-automation-world` git history into the template | The history contains the code of five client extensions. Every client fork would inherit it. |
| New tooling written from scratch | The existing scripts are in active use and have tests. Rewriting them adds work and risk without benefit. |
