# Client Instance Template — Design Specification

- **Date:** 2026-09-24
- **Status:** Complete. Open decisions are listed in Section 17 and implementation status in Section 18.
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
| Image builds | Builds run only in the template and in instances, in their own CI. Nothing is built in the Constellation repository. The template uses Constellation's tools and services (release-management CLI, licenser, registry, dist service); it does not run builds there. |
| Version scheme | Core release tags stay `v0.0.x`. Template and instance releases use the Constellation version scheme `YYYY.edition` (for example `2026.3`), so the dist service, licensing, and upgrades accept them. There are no scheduled or hourly builds. See Section 11. |
| Flavors | Each instance is registered in Constellation as a **flavor**, namespaced by vendor (for example `acme/margince`). Core is `margince/margince`. Licenses are issued per flavor. Instance images are published under the flavor namespace. |
| Release verification | Every release, core or flavor, is verified by the Constellation release harness: a valid license, pullable containers, downloadable binaries, downloadable SBOMs. |
| Source of the template tooling | The files of `margince-automation-world` (`scripts/`, `Makefile`, `.github/workflows/`, `.githooks/`, `.gitignore`, `.gitleaks.toml`, tooling docs) are copied into the template from `origin/main` commit `644ee45`. `config/` is not copied: it is not tracked there, and `make config` generates it from core's examples. |
| Template git history | The template starts with new git history. The history of `margince-automation-world` is not imported, because it contains the code of five client extensions, and every future client fork would inherit that code. The initial import commit records the source repository and commit of each copied file. |
| `margince-release` | Archived. |
| Constellation PR #421 | Closed. Dist releases are drafted and published with Constellation's release-management CLI. The PR #421 commands (`verdict`, `promote`, `notes`, `tag-sources`, `cleanup`) are reused in the template CLI only for functions that the release-management CLI does not provide: image promotion, release notes, and removal of candidate images. |
| District 13 deployment of Margince Default | Owned by a new instance repository created from the template with `make new-instance` (issue D1). It is not placed in the template: `deploy/` is instance-owned, and a real environment in the template would be copied into every new instance. |
| `margince-automation-world` | Adopts the template after M1 (issue I1): it merges the template with `--allow-unrelated-histories`, moves `zalo-lab` to `instance.mk`, and adds `instance.yaml` and `.template-version`. It is the most active instance; without migration its tooling diverges from the template. |
| Deployment | Each client uses one deployment process. The template defines standard deployment steps. The instance provides configuration values and, where required, hook scripts. |

## 5. Repository Responsibilities

| Repository | Responsible for | Not responsible for |
|---|---|---|
| `margince/margince` (core) | Product source code; release tags; role image definitions (`Dockerfile`, `docker-bake.hcl`); desktop all-in-one build; `gen-composition`; extension SDK. | Any client-specific content. |
| `margince-template` (new) | Standard directory layout; lifecycle commands; development environment; CI workflows; deployment interface; core version pin. The template is itself a functional instance without extensions, referred to as **Margince Default**. | Client-specific code. |
| Client instance (fork of the template) | `instance.yaml`, `instance.mk`, `extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`. | Modifications to template-owned files. Tooling changes are made in the template and merged into the instance. |
| `margince-constellation` | Customer records; flavors; license issuance per flavor (trial and production); the release-management CLI and the release harness that instance CI runs; license-gated container registry and artifact downloads; `upgrade-cli`. | Instance composition or instance builds. |
| `margince-demo-database` | Demo datasets. An instance references a dataset by name and version in `data/`. | — |
| `margince-qc` | Acceptance tests against a specified build. Can target any instance. | — |
| `margince-d13-deploy` | Deploys vanilla core (Margince Default) to District 13. Replaced by the `d13` adapter and the `deploy/` directory of a new instance repository created from the template (Section 4), then archived. | — |
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
├── .template-owned        ○ list of template-owned paths (Section 6.1)
├── .template-version      ● template commit last merged (instances only)
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
├── .github/workflows/     ○ ci.yml, full-check.yml, lifecycle.yml, release.yml,
│                            deploy.yml, desktop-macos.yml, desktop-windows.yml
├── .githooks/, .gitleaks.toml, .gitignore   ○
├── AGENTS.md, CLAUDE.md   ○ contributor and agent instructions
└── docs/*.md              ○ template usage documentation

○ Template-owned. Instances must not modify these paths.
● Instance-owned. The template provides `instance.yaml` and an empty
  `extensions/`. The instance creates the other paths when it needs them.
◆ Modified only by `make update-core REF=<tag>`.
```

`.template-owned` is the authoritative list of template-owned paths. A path
that is not listed there is instance-owned.

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
The instance keeps its own `core` gitlink; the sync prints the template's
core pin, and `make update-core` follows it. A conflict on an instance-owned
path keeps the instance's side; a conflict on a template-owned path takes the
template's side; a conflict on any other path stops the sync.

### 6.2 `instance.yaml`

Example (all values are illustrative):

```yaml
name: acme                       # used in image names and the trial bundle name
display_name: Acme               # used by make new-instance only (README.md); not shown in the desktop bundle
core: v0.0.2                     # must match the tag of the core/ submodule
data:
  dataset: margince-demo-database/acme@v1    # optional
flavor: acme/margince            # Constellation flavor: license product and image namespace
deploy:
  staging:    { adapter: hook }
  production: { adapter: hook }
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
- Each environment under `deploy` matches `^[a-z0-9]+(-[a-z0-9]+)*$`, has an
  `adapter` of `hook` (`d13` is refused, naming issue D1, until that adapter
  exists), and has a matching `deploy/<env>/` directory (added with the
  `deploy` key in T9).

`make deploy` runs the same validation, without the `core` check
(`cli validate`), before it reads the adapter (Section 10.4).

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
ends with `-include instance.mk`. `make check-template` runs
`scripts/check-instance-mk.sh`, which fails in the following cases:

- `instance.mk` redefines a template target.
- `instance.mk` assigns a variable whose name does not start with `INSTANCE_`.
- `make` cannot read the `Makefile` with `instance.mk` included.

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
| `desktop.sh`, `build-info.sh` | Build, install, and inspect the desktop bundle | Change: neutral text (no client names). `display_name` is used by `new-instance` only. |

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
| `scripts/cli/` | Go CLI: reads and validates `instance.yaml`; the reused PR #421 commands are added in T7. Run with `go run`. |
| `scripts/check-template.sh`, `scripts/check-instance-mk.sh` | Drift check and `instance.mk` check (Sections 6.1 and 6.3). |
| `scripts/new-instance.sh`, `scripts/template-sync.sh` | Create an instance; merge template changes into it (Sections 6.1 and 14). |
| `scripts/deploy.sh`, `scripts/deploy/` | Deployment steps and adapters; `hook` exists, `d13` is issue D1 (Section 10.4). |
| `scripts/lifecycle.test.sh` | End-to-end lifecycle test (Section 13). |
| `scripts/trial-license.sh` | Requests a trial license from the Constellation licenser (Section 10.2). Issue T8. |
| `scripts/unit-skeleton/` | Neutral unit template for `new-unit.sh`. |
| `.github/workflows/deploy.yml`, `lifecycle.yml` | Manually triggered deployment; lifecycle test. |

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

Status values: **Copied** (from `margince-automation-world`, unchanged or
generalized), **Implemented** (new in the template), **Planned** (issue named).

| Command | Function | Status |
|---|---|---|
| `make install` | Verifies required tools, checks out core, installs dependencies, git hooks, and configuration. | Copied |
| `make dev` | Starts infrastructure services and runs `api`, `worker`, and `web` with the instance units composed. | Copied |
| `make new-unit NAME=<n>` | Creates an extension in `extensions/<n>` from `scripts/unit-skeleton/`. | Copied, changed |
| `make check` | Full gate: core checks, composition, unit tests, linters, secret scanning, `check-instance`, and `check-template`. | Copied, changed |
| `make ci` | `make check` plus integration tests against a real database and submodule checks. | Copied |
| `make package VERSION=<v>` | Builds the `api`, `web`, and `worker` images with the instance units. | Copied, changed |
| `make desktop VERSION=<v>` | Builds the desktop bundle with the instance units. | Copied, changed |
| `make update-core REF=<tag>` | Moves the core submodule to a release tag and records the tag in `instance.yaml`. | Copied, changed |
| `make new-instance NAME=<n> DISPLAY_NAME=<d>` | Creates a client instance repository from the template (`VENDOR=`, `DIR=`, `PUSH=1 OWNER=`). Runs in the template only. | Implemented |
| `make check-instance` | Validates `instance.yaml` (Section 6.2). | Implemented |
| `make check-template` | Drift check: template-owned paths match `.template-version`, and `instance.mk` passes Section 6.3. | Implemented |
| `make template-sync` | Merges the template's `main` into the instance and records the merged commit in `.template-version`. | Implemented |
| `make deploy ENV=<env> VERSION=<v>` | Deploys the specified images to the environment defined in `deploy/<env>/`. | Implemented |
| `make test-cli` | Runs the Go CLI tests. Part of `make test-scripts`. | Implemented |
| `make test-lifecycle` | Runs the end-to-end lifecycle test (Section 13). Runs in the template only. | Implemented |
| `make release VERSION=<v>` | Verifies the working tree and `make check`, then pushes the tag `<v>` (a Constellation version, for example `2026.3`). | Planned (T7) |
| `make trial` | Runs `make desktop` and adds configuration, dataset, and a trial license. See Section 10.2. | Planned (T8) |

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

`VERSION` is a Constellation version (`YYYY.edition`, for example `2026.3`;
Section 11) and is the git tag, the image tag, and the dist release version at
once (`make release`, `make package`, `make deploy`). For example,
`make release VERSION=2026.3` verifies that the working tree is clean and that
`make check` passes, then creates and pushes the tag `2026.3`; the images of
that release are tagged `2026.3`, and the release is drafted into the dist
service as `2026.3` with Constellation's release-management CLI.

The existing `release.yml` runs on release tags (currently `v*`; changed to the `YYYY.edition` shape in T7). It runs `full-check.yml` and
builds the macOS and Windows desktop bundles. The template adds the following
jobs:

1. **Images:** runs `make package` with the flavor namespace and `VERSION=<v>`.
   This produces `<registry>/<flavor>/api`, `/web`, and `/worker` with
   the candidate tag `cand-<commit>`, for multiple architectures. Each image has an OCI label with the core version.
2. **Smoke test:** starts the three images with a temporary PostgreSQL and
   Redis instance and verifies that they start and respond.
3. **Publish:** adds the tag `<v>` (for example `2026.3`) to the images in the Constellation registry
   using the publisher identity, records the release for the flavor in the dist
   service, and generates release notes with the `notes` command. The release
   notes list the core version, the instance commit, and the image digests.
4. **Verify:** runs the Constellation release harness against the published
   flavor release: a license for the flavor is valid, the containers can be
   pulled with it, and the binaries and SBOMs can be downloaded.

Images are tagged with the instance version only. The core version is recorded
as a label, because multiple instance releases can use the same core version.

### 10.4 Deployment (Goal 5)

`make deploy ENV=<env> VERSION=<v>` (`bash scripts/deploy.sh <env> <version>`,
or a manual run of `deploy.yml`) runs:

```
preflight → apply → verify
```

A failed `preflight` stops the deployment immediately: nothing has changed, so
there is no rollback. A failed `apply` or `verify` runs `rollback`, and the
deployment still fails (non-zero exit) whether or not the rollback succeeds.
If the environment provides no `rollback` step, `make deploy` prints
"no rollback hook" and exits non-zero without attempting one; the environment
may be half-deployed.

Before any step, `deploy.sh` requires `VERSION` to be a full release tag
(Constellation's version pattern, `^\d{4}\.(0|[1-9]\d*)(\.(0|[1-9]\d*)(-p[1-9]\d*)?)?$`), validates `instance.yaml` (`cli validate`),
and refuses a working tree with uncommitted changes or untracked files unless
`ALLOW_DIRTY=1`. The hooks and `deploy/<env>/` always come from the checkout;
when `HEAD` is not the commit of the tag `VERSION`, `deploy.sh` prints
`deploy: hooks and configuration come from <short sha>, not from release
<VERSION>` and continues. `deploy.yml` deploys from the tag itself.

`deploy.sh` resolves the adapter for `<env>` from `instance.yaml`
(`deploy.<env>.adapter`), exports the variables below, then asks the adapter
`has <step>` before running that step — a step the adapter does not provide is
skipped, never mistaken for a failure, because a provided step's exit code is
never overridden. `apply` is the only required step; its absence is caught by
the adapter's `check`, before any step runs.

| Variable | Set for | Value |
|---|---|---|
| `DEPLOY_ENV` | every step | The environment name. |
| `DEPLOY_VERSION` | every step | The release being deployed. |
| `DEPLOY_STEP` | every step | The step's own name (`preflight`, `apply`, `verify`, `rollback`). |
| `DEPLOY_DIR` | every step | Absolute path of `deploy/<env>/`. |
| `INSTANCE_NAME` | every step | `name` from `instance.yaml`. |
| `IMAGE_REPO` | every step | The image namespace (Section 6.2). |
| `IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER` | every step | `$IMAGE_REPO/<role>:$DEPLOY_VERSION`. |
| `DEPLOY_FAILED_STEP` | `rollback` only | The step that failed (`apply` or `verify`). |

`deploy/<env>/` contains the environment configuration: hostnames, replica
count per component, and the names of required secrets, such as the production
license (`MARGINCE_LICENSE`) and the database URL. It does not contain secret
values; hooks receive secrets from the environment.

`instance.yaml` specifies an **adapter** for each environment. This plan
implements one adapter, in `scripts/deploy/`:

- `hook`: runs the instance's own scripts,
  `deploy/<env>/hooks/{preflight,apply,verify,rollback}.sh`, called with
  `bash` so a missing executable bit does not matter. `apply.sh` is required;
  the other three steps are optional.

`d13` (deploy to District 13, Gradion's Kubernetes platform, based on
`margince-d13-deploy`) is issue D1 and is not implemented yet;
`instance.yaml` refuses `adapter: d13` with a message naming D1. A new
adapter is added to the template only when at least two clients require the
same deployment target. Until then, clients use the `hook` adapter.

All adapters deploy `api`, `web`, and `worker` as separate services so that each
can be scaled independently.

`.github/workflows/deploy.yml` runs `make deploy` by hand
(`workflow_dispatch`, with one `environment` input), in the GitHub
Environment named by `environment`, so protection rules, secrets, and
variables are configured per environment. The workflow is dispatched from the
release tag: `VERSION` is `github.ref_name`, and the checkout is that tag.
Each environment must be created ahead of time in repository settings, with
"Deployment branches and tags" limited to the release-tag rule (for example `[0-9][0-9][0-9][0-9].*`) and, for
production, required reviewers; the workflow does not create one.

The job steps run in this order:

1. Fail unless `github.ref_type` is `tag` and `github.ref_name` matches
   Constellation's version pattern.
2. Fail unless `environment` matches `^[a-z0-9]+(-[a-z0-9]+)*$` (bash
   `[[ =~ ]]` on the whole value).
3. Check out the tag; set up Go.
4. Fail unless `environment` is under `deploy:` in `instance.yaml`.
5. Export the variables, then the secrets, as environment variables.
6. Run `make deploy ENV=<environment> VERSION=<tag>`.

A malformed name stops the job before checkout. A well-formed name that is
not under `deploy:` stops it before any secret or variable is exported.
GitHub resolves the job's `environment:` — and, for a name it does not
recognize, may auto-create one — before any step runs, so in both cases
GitHub may still have resolved or auto-created that environment for the run.
Every environment a deployment might target must therefore be created ahead
of time with its own protection rules; an environment reached only through
auto-creation has none.

The `secrets` and `vars` contexts contain the environment's secrets and
variables and also the repository's and the organization's. Deploy secrets
are kept at environment level only. Each name is exported (one `printf`
heredoc per value, so a multi-line value stays intact; a secret wins over a
variable of the same name) except a name that does not match
`^[A-Z_][A-Z0-9_]*$`, or that does match but is one of the excluded exact
names `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `BASH_ENV`, `NODE_OPTIONS`,
`CDPATH`, `PROMPT_COMMAND`, `TMPDIR`, `MFLAGS`, `MAKE_TERMOUT`,
`MAKE_TERMERR`, or carries one of the excluded prefixes `LD_`, `DYLD_`,
`GITHUB_`, `RUNNER_`, `ACTIONS_`, `GIT_`, or matches `^GO[A-Z0-9]*$` or
`^MAKE[A-Z0-9]*$` (Go's and make's own variables contain no underscore, so
`GOOGLE_APPLICATION_CREDENTIALS` and `MAKER_TOKEN` are exported).
`github_token` is never exported. A skipped name is printed to the log; no
value is printed. `REGISTRY` can be an environment variable. Checkout runs
with `persist-credentials: false`, so no push credential for the repository
is left on disk for a hook to find.
The checkout is shallow and detached at the tag, so a hook must not rely on
git history or on pushing. `make deploy` removes `ENV`, `VERSION`,
`MAKEFLAGS`, `MAKELEVEL`, and `MFLAGS` from the environment of `deploy.sh`,
so a hook that runs `make` does not inherit them as overrides.

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
| Core release | git tag `v0.0.x` (for example `v0.0.2`) | What instances pin. `make update-core` accepts release tags only. Core's own images are not consumed by instances; each instance builds its images from core's bake file at the pinned tag. |
| Template or instance release | Constellation version `YYYY.edition`, optionally `.bugfix` and `-pN` for LTS (`^\d{4}\.(0|[1-9]\d*)(\.(0|[1-9]\d*)(-p[1-9]\d*)?)?$`, from `margince-constellation/pkg/version`), for example `2026.3` | The git tag, the image tag, the `VERSION=` value, and the dist release version are the same string. The core release it is built on is recorded as an OCI label and in the dist service. |
| Template | template commit in `.template-version`; template release tags | The template version an instance last merged. |

There are no scheduled, hourly, or mainline builds in any repository.

Current state: `make deploy` and `deploy.yml` still require `vX.Y.Z`
(`^v[0-9]+\.[0-9]+\.[0-9]+$`); T7 changes them to the Constellation pattern
together with the release lane.

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
- `make test-lifecycle` (`scripts/lifecycle.test.sh`) creates an instance from
  the template in a scratch directory and runs it through the lifecycle a
  client developer uses: `new-instance`, `check-instance` and `check-template`,
  adding and testing a unit (`new-unit`, `compose`, `u`), `deploy` through the
  hook adapter (a success and a verify failure that rolls back), and
  `template-sync` from a scratch template clone. Every step asserts its
  outcome. It is slow, so it is not part of `make test-scripts` and runs in
  its own CI workflow, `lifecycle.yml`, on every pull request, on push to
  `main`, and on demand. Template changes that break the lifecycle fail there
  before any instance merges them. It needs a clean template working tree
  (`make new-instance` refuses otherwise).
- `.github/workflows/` is template-owned (Section 6), so every instance
  inherits `lifecycle.yml` unchanged. Its job guards on
  `github.repository == 'gradionhq/margince-template'` so it never runs
  there, and `scripts/lifecycle.test.sh` itself skips (exit 0) when
  `.template-version` exists, since an instance has no `make new-instance` to
  drive the lifecycle it tests.
- Trial (T8) and release (T7) steps join `scripts/lifecycle.test.sh` when
  those lanes exist; `lifecycle.yml` needs no change when they do.
- The Go CLI has unit tests.

## 14. Scope of Adoption

The template applies to **new instances only**.

- `incap` and `afs` are not migrated. They keep their current structure.
- `margince-automation-world` is the source of the template tooling. It adopts
  the template after M1 (Section 4, issue I1).
- A new instance is created from the template with `scripts/new-instance.sh`
  (issue T11). The instance is a new repository with a `template` remote.
  Template changes are applied with `git merge template/main`.

The `margince-d13-deploy` deployment moves to the `d13` adapter and the
`deploy/` directory of a new instance repository created from the template
(Section 4, issue D1).

## 15. Sub-Projects

The work is delivered as separate implementation plans in the following order.

| # | Sub-project | Scope | Repository | Status |
|---|---|---|---|---|
| 1 | Core versioning | No work. Core release tags stay `v0.0.x`. Instances build their own images, so core's release images need no change (C1 closed). | core | Closed |
| 2 | Template foundation | Copy the tooling from `margince-automation-world`; generalize the scripts in Section 7; add `instance.yaml`, `instance.mk`, the unit skeleton, the drift check, instance creation and synchronization, and the template CI. | template | Complete (T1–T6, T11, T10 part 1) |
| 3 | Flavors, build, and release | Constellation flavors (management API, vendor namespace, dynamic catalog through the event outbox, licenses per flavor) and the release harness; the image, smoke test, publish, and verify jobs in `release.yml`; `make release`. | Constellation (K2, K4), template (T7) | Waiting for K2 and K4 |
| 4 | Trial and licensing | Constellation trial license type and issuance endpoint per flavor; `make trial`. Starts after flavors exist. | Constellation (K1), template (T8) | Waiting for K1 |
| 5 | Deployment | The four-step deployment interface and the `hook` adapter (T9); the `d13` adapter (D1). | template | T9 complete; D1 open |
| 6 | Retirement | Archive `margince-release` (R1) and `margince-d13-deploy` (R2); close PR #421; update references (R3). | several | Waiting for T7 and D1 |

## 16. Rejected Alternatives

| Alternative | Reason for rejection |
|---|---|
| One-time copy (GitHub template repository without synchronization) | Instances diverge over time. This caused the current inconsistency. |
| Separately versioned tooling repository or CLI | Adds a third version to align with core and the template. Duplicates the function of fork-and-merge. |
| Central build workflow in Constellation (PR #421) | Instance developers cannot build and deploy their own repository, which Goal 5 requires. |
| Configuration-only deployment (no hooks) | Each client-specific requirement would require a template change. |
| Import the `margince-automation-world` git history into the template | The history contains the code of five client extensions. Every client fork would inherit it. |
| Scheduled or hourly mainline builds (in Constellation or elsewhere) | Not needed: releases are a deliberate step in each instance, and core already reduced its own release builds to on demand to protect the shared runner pool. |
| `vX.Y.Z` tags for template and instance releases | The Constellation dist service accepts only `YYYY.edition` versions, so `v` versions could not be recorded as releases, licensed, or upgraded. |
| New tooling written from scratch | The existing scripts are in active use and have tests. Rewriting them adds work and risk without benefit. |

## 17. Open Decisions

None. A new decision is added here with its options and the issues it blocks,
and is moved to Section 4 when it is made.

## 18. Implementation Status

The GitHub issues and their dependencies are listed in
`docs/superpowers/plans/2026-09-24-issue-breakdown.md`.

| Area | Status |
|---|---|
| Template foundation, `instance.yaml` and CLI, `instance.mk`, core pin by tag, drift check (T1–T6) | Complete |
| Instance creation and synchronization (T11) | Complete |
| Deployment contract and `hook` adapter (T9) | Complete |
| Template CI and lifecycle test (T10 part 1) | Complete. Part 2 adds the trial and release steps after T7 and T8. |
| Release (T7) | Waiting for Constellation K2 (flavors, image namespace, push identity) and K4 (release harness). T7 also changes `make deploy`, `deploy.yml`, and the lifecycle test from `vX.Y.Z` to the Constellation version pattern. |
| Trial (T8) | Waiting for Constellation K1 (trial license per flavor). |
| Guides (T12) | After T7 and T8. |
| `d13` adapter and its instance repository (D1) | Open. Can start now. |
| Retirement (R1–R3) | After T7 and D1. |
| `margince-automation-world` migration (I1) | After M1. |
