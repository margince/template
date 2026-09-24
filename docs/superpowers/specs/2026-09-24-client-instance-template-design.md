# Client Instance Template — Design Specification

- **Date:** 2026-09-24
- **Status:** Draft. The foundation (T1, T2) has an implementation plan; later sections may change.
- **Repository:** `gradionhq/margince-template`

## 1. Background

A Margince client runs an *instance*. An instance consists of the upstream core
product, the client's extensions, configuration, data, and a deployment
definition.

Three instance repositories currently exist: `incap`, `afs`, and
`margince-automation-world`. (`gradionhq/margince-gradion` is the former name of
`margince-automation-world`.) Section 14 defines which of them adopt the
template. They are inconsistent:

- `incap` and `afs` provide approximately 12 make targets.
- `margince-automation-world` provides approximately 70 documented make
  targets, including a development stack, desktop builds, secret scanning, role
  image builds, and release workflows. It contains five extensions.
- Its `main` pins a core commit from before core moved the `craft` tool out of
  `cli/craft`. `scripts/lint.sh` needs a small change to run against core
  `v0.0.2` (see Section 7).

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
| Version scheme | Release versions are git tags: core `v0.0.x`, instances `v<major>.<minor>.<patch>`. Hourly mainline builds carry a build version in the Constellation `YYYY.edition` format with year `1970` (`1970.1`, `1970.2`, …). See Section 11. |
| Mainline core builds | Constellation builds core `main` on a schedule and records each build as a test build (`1970.N`) in the dist service. The build definition stays in core. |
| Flavors | Each instance is registered in Constellation as a **flavor**, namespaced by vendor (for example `acme/margince`). Core is `margince/margince`. Licenses are issued per flavor. Instance images are published under the flavor namespace. |
| Release verification | Every release, core or flavor, is verified by the Constellation release harness: a valid license, pullable containers, downloadable binaries, downloadable SBOMs. |
| Source of the template tooling | The files of `margince-automation-world` (`scripts/`, `Makefile`, `.github/workflows/`, `.githooks/`, `.gitignore`, `.gitleaks.toml`, tooling docs) are copied into the template from `origin/main` commit `644ee45`. `config/` is not copied: it is not tracked there, and `make config` generates it from core's examples. |
| Template git history | The template starts with new git history. The history of `margince-automation-world` is not imported, because it contains the code of five client extensions, and every future client fork would inherit that code. The initial import commit records the source repository and commit of each copied file. |
| `margince-release` | Archived. |
| Constellation PR #421 | Closed. Its Go commands (`verdict`, `promote`, `notes`, `tag-sources`, `cleanup`) are reused in the Constellation mainline builds and in the template tooling where applicable. |
| Deployment | Each client uses one deployment process. The template defines standard deployment steps. The instance provides configuration values and, where required, hook scripts. |

## 5. Repository Responsibilities

| Repository | Responsible for | Not responsible for |
|---|---|---|
| `margince/margince` (core) | Product source code; release tags; role image definitions (`Dockerfile`, `docker-bake.hcl`); desktop all-in-one build; `gen-composition`; extension SDK. | Any client-specific content. |
| `margince-template` (new) | Standard directory layout; lifecycle commands; development environment; CI workflows; deployment interface; core version pin. The template is itself a functional instance without extensions, referred to as **Margince Default**. | Client-specific code. |
| Client instance (fork of the template) | `instance.yaml`, `instance.mk`, `extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`. | Modifications to template-owned files. Tooling changes are made in the template and merged into the instance. |
| `margince-constellation` | Customer records; flavors; license issuance per flavor (trial and production); scheduled mainline builds of core; the release harness; license-gated container registry and artifact downloads; `upgrade-cli`. | Instance composition or instance builds. |
| `margince-demo-database` | Demo datasets. An instance references a dataset by name and version in `data/`. | — |
| `margince-qc` | Acceptance tests against a specified build. Can target any instance. | — |
| `margince-d13-deploy` | Deploys vanilla core (Margince Default) to District 13. Replaced by the `d13` adapter and the `deploy/` directory of an owning instance repository, then archived. The owning repository is an open decision. | — |
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
├── instance.yaml          ● instance metadata: name, core version,
│                            deployment targets, flavor
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

`.template-owned` lists the template-owned paths, one git pathspec per line.
`make check-template` reads this list from the commit named in
`.template-version`, not from the instance's working tree, so an instance
cannot remove a path from the list by editing it locally.

`.template-version` holds one commit id: the template commit that was last
merged into the instance. `make check-template` fails if any
`.template-owned` path differs from that commit — an edit, a removal, or an
untracked or newly added file inside an owned directory all count as drift.
`make check` includes `make check-template`.

The template itself carries no `.template-version`: it is the source of
template-owned paths, so there is nothing to compare it with, and
`make check-template` reports this and exits 0.

`make template-sync` merges the template's `main` into the instance and
updates `.template-version` to the merged commit, which is how an instance
picks up a template-owned change before `make check-template` next runs.

### 6.2 `instance.yaml`

Example (all values are illustrative):

```yaml
name: acme                       # used in image names and the trial bundle name
display_name: Acme               # used in user-facing text of the desktop bundle
core: v0.0.2                     # must match the tag of the core/ submodule
data:
  dataset: margince-demo-database/acme@v1    # optional
flavor: acme/margince            # Constellation flavor: license product and image namespace
deploy:
  staging:    { adapter: d13 }
  production: { adapter: d13 }
```

There is no `units` key. A directory under `extensions/` is an enabled unit,
as in the existing tooling (`scripts/stage.sh`). A second list would duplicate
that and could disagree with it.

Scripts read `instance.yaml` through the Go CLI (`scripts/cli`), run with
`GOWORK=off` because the editor `go.work` at the repository root does not list
it. Go is already a required tool, so this adds no dependency.

`make check-instance` (part of `make check`) validates the following:

- `name` matches `^[a-z0-9]+(-[a-z0-9]+)*$` and has at most 32 characters.
- `display_name` is present and is one line.
- `core` is one of the tags that point at `core/` HEAD.
- `flavor` has the form `<vendor>/margince`.
- No unknown key is present.
- Each environment under `deploy` has a matching `deploy/<env>/` directory
  (added with the `deploy` key in T9).

Sections are added to the schema by the issue that uses them: `data` (T8),
`deploy` (T9). The template's own file is:

```yaml
name: margince-default
display_name: Margince Default
core: v0.0.2
flavor: margince/margince
```

The image namespace is derived from `flavor`: `<registry>/<flavor>` when a
registry is supplied, `<flavor>` otherwise. Core's `docker-bake.hcl` appends
`/api`, `/web`, and `/worker` to that namespace, so an instance's images are
`<registry>/<flavor>/api`, `/web`, and `/worker` — for example
`myregistry.example.com/acme/margince/api`. The registry host is supplied at
build time (`REGISTRY=<host> make package`), not stored in `instance.yaml`.

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
| `lib.test.sh` | Tests for `lib.sh` | Change: the path-rewrite cases create synthetic units instead of assuming `zalo-oa` and `dispact-connector` exist |
| `stage.sh`, `unstage.sh` | Copy units into `core/extensions/` and remove them | Keep |
| `sync-manifests.sh`, `check-manifests.sh` | Keep unit manifests committed and current | Keep |
| `check-core-clean.sh` | Verify `core/` is unmodified after a build | Keep |
| `check-docs.sh` | Verify every `make` target named in the docs exists | Keep |
| `preflight.sh`, `toolcheck.sh` | Verify required tools and versions | Keep |
| `config-init.sh`, `config-check.sh`, `config-sync.sh` | Create and synchronize `.env.local` and `config/` with core examples | Keep |
| `core-contrib.sh` | Create branches and pull requests for core contributions | Keep |
| `fe-ds-gates.sh`, `fmt.sh` | Design-system gates and formatting for unit code | Keep |
| `gitleaks-pin.sh`, `secret-scan.sh` | Pinned secret scanner | Keep |
| `secret-scan.test.sh`, `.gitleaks.toml` | Prove the secret policy still catches | Change: remove the `zalo-personal` allowlist; the test plants tokens into synthetic files |
| `gowork.sh`, `tsconfig-editor.sh` | Generate editor workspace files | Keep |
| `test-integration-ext.sh` | Integration tests for units | Keep |
| `desktop-kit/` | Desktop bundle launcher files | Keep |
| `lint.sh` | Lint unit code | Change: run craft through `core/scripts/craft-pin.sh`; core `v0.0.2` has no `cli/craft` |
| `package.sh` | Build `api`, `web`, `worker` images with units | Generalize: read the image name and registry from `instance.yaml`; rename labels `com.gradion.*` to `com.margince.instance.*` |
| `new-unit.sh` | Create a new unit | Change (T1): render `scripts/unit-skeleton/*.tmpl` instead of copying `extensions/gradion`; add `new-unit.test.sh` |
| `desktop.sh`, `build-info.sh` | Build, install, and inspect the desktop bundle | Generalize: take the client name in user-facing text from `display_name` in `instance.yaml` |

The `Makefile` is copied with the following changes:

- The header comment describes the template, not Gradion.
- The `zalo-lab` target is removed. It moves to `instance.mk` in
  `margince-automation-world`.
- The `new-unit` description refers to `scripts/unit-skeleton/`.
- The new targets in Section 9 are added.

`.gitignore` loses the `.zalolab/` rule. The tooling docs (`adding-an-extension`,
`contributing-to-core`, `desktop-build`, `glossary`, `release`,
`troubleshooting`) are copied and their client references replaced. Every
`make <target>` named in `README.md`, `CLAUDE.md`, or `docs/*.md` must exist,
because `scripts/check-docs.sh` enforces it.

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
| `make new-instance NAME=<n> DISPLAY_NAME=<d>` | Creates a client instance repository from the template (`VENDOR=`, `DIR=`, `PUSH=1 OWNER=`). | Existing |
| `make dev` | Starts infrastructure services and runs `api`, `worker`, and `web` with the instance units composed. | Existing |
| `make new-unit NAME=<n>` | Creates an extension in `extensions/<n>` from `scripts/unit-skeleton/`. | Existing, changed |
| `make check-instance` | Validates `instance.yaml` (Section 6.2). | New |
| `make test-cli` | Runs the Go CLI tests. Part of `make test-scripts`. | New |
| `make check` | Full gate: core checks, composition, unit tests, linters, secret scanning. Adds `instance.yaml` validation and `check-template`. | Existing, changed |
| `make ci` | `make check` plus integration tests against a real database and submodule checks. | Existing |
| `make package VERSION=<v>` | Builds the `api`, `web`, and `worker` images with the instance units. | Existing, changed |
| `make desktop VERSION=<v>` | Builds the desktop bundle with the instance units. | Existing, changed |
| `make trial` | Runs `make desktop` and adds configuration, dataset, and a trial license. See Section 10.2. | New |
| `make update-core REF=<tag>` | Moves the core submodule to a release tag and records the tag in `instance.yaml`. | Existing, changed |
| `make release VERSION=<v>` | Verifies the working tree and `make check`, then pushes the tag `v<v>`. | New |
| `make deploy ENV=<env> VERSION=<v>` | Deploys the specified images to the environment defined in `deploy/<env>/`. | New |
| `make template-sync` | Merges the template's `main` into the instance and records the merged commit in `.template-version`. | Existing |
| `make check-template` | Drift check: template-owned paths match `.template-version`, and `instance.mk` only adds targets. | Existing |

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
flavor in `flavor`. It has a limited validity period and is marked as
a trial license. The template requests it from the licenser API using an
operator credential provided in the environment variable
`MARGINCE_LICENSER_TOKEN`. The license is written to the bundle only. It is
never committed to the repository.

The bundle runs in production mode. The client therefore evaluates the same
configuration that is later deployed.

Required Constellation changes: a trial license type (validity period and trial
marker) and an issuance endpoint that accepts an operator credential. Trial
licenses are issued per flavor, so flavors must exist first. The details are
defined in sub-project 4.

### 10.3 Build and Release (Goal 5)

`make release VERSION=<v>` verifies that the working tree is clean and that
`make check` passes, then pushes the tag `v<v>`.

The existing `release.yml` runs on `v*` tags. It runs `full-check.yml` and
builds the macOS and Windows desktop bundles. The template adds the following
jobs:

1. **Images:** runs `make package` with the flavor namespace and `VERSION=<v>`.
   This produces `<registry>/<flavor>/api`, `/web`, and `/worker` with
   the candidate tag `cand-<commit>`, for multiple architectures. Each image has an OCI label with the core version.
2. **Smoke test:** starts the three images with a temporary PostgreSQL and
   Redis instance and verifies that they start and respond.
3. **Publish:** adds the tag `<v>` to the images in the Constellation registry
   using the publisher identity, records the release for the flavor in the dist
   service, and generates release notes with the `notes` command. The release
   notes list the core version, the instance commit, and the image digests.
4. **Verify:** runs the Constellation release harness against the published
   flavor release: a license for the flavor is valid, the containers can be
   pulled with it, and the binaries and SBOMs can be downloaded.

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
| Trial | Production | Trial license for the flavor, issued by the Constellation licenser and included in the bundle. |
| Staging and production | Production | Production license for the flavor, issued at sign-off. Stored in the environment secret store and provided as `MARGINCE_LICENSE`. |

Licenses are never committed to a repository. `MARGINCE_LICENSE` overrides any
`license.token` value in the instance configuration. The instance
configuration therefore does not define `license.token`.

## 11. Versioning (Goals 1 and 2)

| Version | Format | Used for |
|---|---|---|
| Core release | git tag `v0.0.x` (for example `v0.0.2`) | What instances pin. `make update-core` accepts release tags only. The version stamped into the release images by `docker-bake.hcl` equals the tag. |
| Core build | `1970.N` (Constellation `YYYY.edition` format) | Hourly mainline builds of core `main` in Constellation, published to testing only. Not pinned by instances. |
| Instance release | git tag `v<major>.<minor>.<patch>` in the instance repository | Image tags of the instance. The core release it is built on is recorded as an OCI label and in the dist service. |
| Template | template commit in `.template-version`; template release tags | The template version an instance last merged. |

Current state: core has release tags `v0.0.1` and `v0.0.2`, and `docker-bake.hcl`
stamps `1970.<build>`. Sub-project 1 makes the release images carry the release
tag and keeps `1970.N` for hourly builds.

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

## 14. Scope of Adoption

The template applies to **new instances only**.

- `incap` and `afs` are not migrated. They keep their current structure.
- `margince-automation-world` is the source of the template tooling. Whether it
  is migrated is an open decision (issue I1).
- A new instance is created from the template with `scripts/new-instance.sh`
  (issue T11). The instance is a new repository with a `template` remote.
  Template changes are applied with `git merge template/main`.

The `margince-d13-deploy` deployment moves to the `d13` adapter and the
`deploy/` directory of its owning instance repository (open decision).

## 15. Sub-Projects

The work is delivered as separate implementation plans in the following order:

1. **Core versioning and mainline builds:** core release tags stay `v0.0.x`
   and equal the release image version; Constellation builds core `main` hourly
   with build version `1970.N`; the release harness verifies each build.
2. **Template foundation:** copy the tooling from `margince-automation-world`,
   generalize the scripts in Section 7, add `instance.yaml`, `instance.mk`,
   the unit skeleton, the drift check, and the template CI.
3. **Flavors, build, and release:** Constellation flavors (management API,
   vendor namespace, dynamic catalog through the event outbox, licenses per
   flavor); image, smoke test, publish, and verify jobs in `release.yml`; the
   Go CLI with the reused PR #421 commands.
4. **Trial and licensing:** Constellation trial license type and issuance
   endpoint per flavor; `make trial`. Starts after flavors exist.
5. **Deployment:** the four-step deployment interface, the `hook` adapter, the
   `d13` adapter.
6. **Retirement:** archive
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
