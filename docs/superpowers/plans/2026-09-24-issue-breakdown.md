# Issue Breakdown

Source: [design specification](../specs/2026-09-24-client-instance-template-design.md).

The Constellation issues (C1, K1–K4) include the proposal for mainline builds, a release harness, flavors, and trials. Trials start after flavors exist.

Versions: core releases are `v0.0.x` tags; template and instance releases use Constellation's `YYYY.edition` (for example `2026.3`). There are no scheduled or hourly builds; builds run only in the template and instances.

Implementation plan for T1 and T2: [template foundation](2026-09-24-template-foundation.md).

**Target:** a new Margince instance can be created, developed, trialled,
released, and deployed using only the template. This is milestone **M1**.
Milestone **M2** retires old repositories. Existing instances (`incap`, `afs`) are not migrated; the template applies to new instances only.

`gradionhq/margince-gradion` is the former name of `margince-automation-world`, so there are three instances.

Each issue lists the repository, the scope, the completion criterion, and the
dependencies.

## M1 — Ready for a new instance

### margince/margince (core)

| ID | Title | Scope | Done when | Depends on |
|---|---|---|---|---|
| C1 | ~~Release images carry the v0.0.x release tag~~ | Closed: not needed. Instances build their own images from core's bake file at the pinned `v0.0.x` tag; core's release images are not consumed. | — | — |

### gradionhq/margince-constellation

| ID | Title | Scope | Done when | Depends on |
|---|---|---|---|---|
| K2 | Flavors: vendor-namespaced products with dynamic catalog and licenses | Add flavors to the dist service. A flavor is namespaced by vendor: `margince/margince` is core, `<vendor>/margince` is a client instance. Add management APIs to create flavors. Make the static `MARGINCE_AUTH_CATALOG` dynamic through the event outbox, so that a new flavor can be licensed immediately. Grant push to the publisher identity for the flavor image namespace. | Creating a flavor through the API allows issuing a license for it, pushing `<registry>/<vendor>/margince/api`, `/web`, and `/worker` with the publisher identity, and pulling them with the license. | — |
| K3 | ~~Hourly mainline builds of core~~ | Closed: no scheduled or hourly builds in any repository; builds run only in the template and instances. | — | — |
| K4 | Release harness | A command that instance CI runs after publishing a flavor release: a license for the flavor is valid, the containers can be pulled with it, the binaries and SBOMs can be downloaded. Constellation provides the tool; it runs in the instance's CI, not in Constellation. | The command passes against a published flavor release and fails when any check fails. | K2 |
| K1 | Trial license per flavor | Add a trial license type (validity period, trial marker) and an issuance endpoint that accepts an operator credential. Trial licenses are issued per flavor. Used by `make trial` in instance repositories. | An operator credential can obtain a trial JWT for a flavor. Core accepts it in production mode. | K2 |

### gradionhq/margince-template

| ID | Title | Scope | Done when | Depends on |
|---|---|---|---|---|
| T1 | Import tooling from margince-automation-world | Copy the tooling from `margince-automation-world` `644ee45` and pin core at `v0.0.2`. Fix what depends on that instance's extensions: `lint.sh` (pinned craft binary), `lib.test.sh` (synthetic units), `secret-scan.test.sh` and `.gitleaks.toml` (no client allowlist), `new-unit.sh` (neutral `scripts/unit-skeleton/`, with `new-unit.test.sh`), `Makefile` and `.gitignore` (no `zalo-lab`), tooling docs without client references, README commands that exist. Plan: `docs/superpowers/plans/2026-09-24-template-foundation.md`, Tasks 1–5. | `make install`, `make check`, `make ci`, `make dev`, and `make new-unit` + `make u` work on a fresh clone. CI is green. | — |
| T2 | instance.yaml and CLI | Add `instance.yaml` (`name`, `display_name`, `core`, `flavor`; unknown keys refused) and a Go CLI in `scripts/cli` (run with `GOWORK=off`). `make check-instance` validates the file and that `core` is a tag at `core/` HEAD. Part of `make check` and CI. Plan Task 6. | `make check` fails on an invalid `instance.yaml` or a core mismatch, naming each problem. | T1 |
| T3 | Remove client-specific values from release and desktop scripts | `package.sh` derives the image namespace from `flavor` in `instance.yaml` and uses neutral labels. `desktop.sh` and `build-info.sh` use `display_name`. Update the tests. | No script contains "gradion" or "automation-world" except the demo dataset repository name. `make test-scripts` passes. | T2 |
| T4 | `instance.mk` | Add `-include instance.mk` and a check that it does not redefine template targets. | A redefined target fails `make check`. | T1 |
| T5 | Core pin by tag | `make update-core` accepts release tags only and updates `core` in `instance.yaml`. | A branch ref or commit is rejected. After `make update-core REF=<tag>`, `make check-instance` passes. | T2 |
| T6 | Drift check | Add `.template-version` and `make check-template`. | Editing a template-owned file fails `make check`. | T1 |
| T7 | Release workflow | `make release VERSION=YYYY.edition` tags the release; `release.yml` on that tag builds the role images (candidate tag), smoke-tests them, publishes them under the flavor namespace, drafts and publishes the release in the dist service with Constellation's release-management CLI, and runs the release harness. `make deploy`, `deploy.yml` and the lifecycle test switch from `vX.Y.Z` to Constellation's version pattern. | Tag `2026.1` publishes three role images and a dist release for the flavor, and the harness passes. | T3, K2, K4 |
| T8 | Laptop trial build | Add `make trial`: desktop build, production configuration, dataset, and a trial license for the flavor from `scripts/trial-license.sh`. | `make trial` produces a bundle that starts in production mode on macOS. | T3, K1 |
| T9 | Deploy contract and `hook` adapter | Add `make deploy`, `deploy.yml`, and the four steps (`preflight`, `apply`, `verify`, `rollback`) with the `hook` adapter. | A test hook deployment runs. A failing `verify` triggers `rollback`. | T2 |
| T10 | Template CI | Run the lifecycle in CI on the empty template and on a test instance with one unit: `install`, `check`, `trial` (build only), `release` (dry run), `deploy` (test hook). | CI passes on both. | T1–T9 |
| T11 | New instance bootstrap | Add `scripts/new-instance.sh`: create the instance repository, add the `template` remote, write `instance.yaml`, push. (GitHub does not allow a fork into the same organization, so the instance is a new repository with a `template` remote.) | One command creates a new instance repository that passes `make check`. | T2, T6 |
| T12 | Guides | Write the guides listed in `docs/README.md`. | Each guide exists and `check-docs` passes. | T1–T11 |

**M1 is complete** when a new instance created with T11 runs `make dev`,
`make trial`, `make release`, and `make deploy` successfully.

## M2 — Retire

| ID | Repository | Title | Scope | Done when | Depends on |
|---|---|---|---|---|---|
| D1 | margince-template | `d13` adapter | Port `margince-d13-deploy` into `scripts/deploy/d13`. It currently deploys vanilla core; the owning instance repository is open decision OD1 (spec Section 17). | The adapter deploys `api`, `web`, `worker` as separate services to D13 staging. | T9 |
| I1 | margince-automation-world | Migrate (open decision OD2, spec Section 17) | Merge the template (`--allow-unrelated-histories`). Move `zalo-lab` to `instance.mk`. Add `instance.yaml`. | `make check` and `make check-template` pass. | M1 |
| R1 | margince-release | Archive | Archive the repository. | Archived. | T7 |
| R2 | margince-d13-deploy | Archive | Archive the repository. | Archived. | D1 |
| R3 | margince-principles | Update references | Replace references to `margince-release` with `margince-template` and `margince-constellation`. | No reference to `margince-release` remains. | R1 |

## Order

```
K2, T1                      (parallel start)
K2 → K1, K4
T2 → T3, T4, T5, T6, T9
T3 + K2 + K4 → T7
T3 + K1      → T8
T2 + T6      → T11
all T        → T10 → T12  → M1
M1 → I1 (if decided) ; D1 → R2 ; T7 → R1 → R3
```

## GitHub issues

Tracking issue: https://github.com/gradionhq/margince-template/issues/14

| ID | Issue |
|---|---|
| C1 | https://github.com/margince/margince/issues/6120 |
| K1 | https://github.com/gradionhq/margince-constellation/issues/448 |
| K2 | https://github.com/gradionhq/margince-constellation/issues/449 |
| K3 | https://github.com/gradionhq/margince-constellation/issues/450 |
| T1 | https://github.com/gradionhq/margince-template/issues/1 |
| T2 | https://github.com/gradionhq/margince-template/issues/2 |
| T3 | https://github.com/gradionhq/margince-template/issues/3 |
| T4 | https://github.com/gradionhq/margince-template/issues/4 |
| T5 | https://github.com/gradionhq/margince-template/issues/5 |
| T6 | https://github.com/gradionhq/margince-template/issues/6 |
| T7 | https://github.com/gradionhq/margince-template/issues/7 |
| T8 | https://github.com/gradionhq/margince-template/issues/8 |
| T9 | https://github.com/gradionhq/margince-template/issues/9 |
| T10 | https://github.com/gradionhq/margince-template/issues/10 |
| T11 | https://github.com/gradionhq/margince-template/issues/11 |
| T12 | https://github.com/gradionhq/margince-template/issues/12 |
| D1 | https://github.com/gradionhq/margince-template/issues/13 |
| I1 | https://github.com/gradionhq/margince-automation-world/issues/60 |
| R1 | https://github.com/gradionhq/margince-release/issues/2 |
| R2 | https://github.com/gradionhq/margince-d13-deploy/issues/37 |
| R3 | https://github.com/gradionhq/margince-principles/issues/2 |
| K4 | https://github.com/gradionhq/margince-constellation/issues/451 |
