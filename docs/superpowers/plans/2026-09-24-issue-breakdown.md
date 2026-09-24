# Issue Breakdown

Source: [design specification](../specs/2026-09-24-client-instance-template-design.md).

The Constellation issues (C1, K1–K4) include the proposal for mainline builds, a release harness, flavors, and trials. Trials start after flavors exist.

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
| C1 | Release tags use the YYYY.edition version scheme | Release git tags currently use `v0.0.x`, while `docker-bake.hcl` stamps images with the `YYYY.edition` scheme. Use `YYYY.edition` (for example `2026.3`) for release tags, and make `release-tag.yml` and `docker-bake.hcl` use the same value. Test builds use year `1970`. | Pushing release tag `<v>` produces images stamped with version `<v>`. | — |

### gradionhq/margince-constellation

| ID | Title | Scope | Done when | Depends on |
|---|---|---|---|---|
| K2 | Flavors: vendor-namespaced products with dynamic catalog and licenses | Add flavors to the dist service. A flavor is namespaced by vendor: `margince/margince` is core, `<vendor>/margince` is a client instance. Add management APIs to create flavors. Make the static `MARGINCE_AUTH_CATALOG` dynamic through the event outbox, so that a new flavor can be licensed immediately. Grant push to the publisher identity for the flavor image namespace. | Creating a flavor through the API allows issuing a license for it, pushing `<vendor>/margince-api`, `-web`, `-worker` with the publisher identity, and pulling them with the license. | — |
| K3 | Mainline builds of core | Build core `main` on a schedule (for example hourly) and record each build as a test release `1970.N` in the dist service, published to testing. The build definition stays in core (`docker-bake.hcl`, desktop build). Reuse the Go commands from PR #421 (`verdict`, `promote`, `notes`, `cleanup`) and close PR #421. | A new `1970.N` release appears in testing after each scheduled run. PR #421 is closed. | C1 |
| K4 | Release harness | After each release (mainline core build or flavor release), verify: a license for the product is valid, the containers can be pulled with it, the binaries can be downloaded, the SBOMs can be downloaded. Provide it as a command that instance CI can also run. | The harness runs after every mainline build and fails the run on any failed check. | K3 |
| K1 | Trial license per flavor | Add a trial license type (validity period, trial marker) and an issuance endpoint that accepts an operator credential. Trial licenses are issued per flavor. Used by `make trial` in instance repositories. | An operator credential can obtain a trial JWT for a flavor. Core accepts it in production mode. | K2 |

### gradionhq/margince-template

| ID | Title | Scope | Done when | Depends on |
|---|---|---|---|---|
| T1 | Import tooling | Copy `scripts/`, `Makefile`, `.github/`, `.githooks/`, `config/`, and supporting files from `margince-automation-world`. Take `lint.sh` from branch `chore/update-core` of `margince-automation-world`. Remove all extensions and `zalo-lab`. Record source commits in the commit message. | `make install && make check` pass with no extensions. | — |
| T2 | instance.yaml and CLI | Add `instance.yaml` (including `flavor: <vendor>/margince`) and a Go CLI in `scripts/cli` that reads and validates it. Add the validation to `make check`. | `make check` fails on an invalid `instance.yaml`. | T1 |
| T3 | Remove client-specific values from scripts | `package.sh` derives the image namespace from `flavor` in `instance.yaml`. `new-unit.sh` uses `scripts/unit-skeleton/`. `desktop.sh` and `build-info.sh` use `display_name`. Update the tests. | No script contains "gradion" or "automation-world". `make test-scripts` passes. | T2 |
| T4 | `instance.mk` | Add `-include instance.mk` and a check that it does not redefine template targets. | A redefined target fails `make check`. | T1 |
| T5 | Core pin by tag | `make update-core` accepts tags only and updates `instance.yaml`. `make check` verifies the submodule matches `instance.yaml`. | A branch ref is rejected. A mismatch fails `make check`. | T2, C1 |
| T6 | Drift check | Add `.template-version` and `make check-template`. | Editing a template-owned file fails `make check`. | T1 |
| T7 | Release workflow | Add `make release`. Extend `release.yml` with image build (candidate tag), smoke test, publish to the flavor namespace, record the flavor release in the dist service, and run the release harness. Port `notes` and `cleanup` from PR #421 into `scripts/cli`. | Tag `v<v>` publishes three role images and release notes for the flavor, and the release harness passes. | T3, C1, K2, K4 |
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
| D1 | margince-template | `d13` adapter | Port `margince-d13-deploy` into `scripts/deploy/d13`. It currently deploys vanilla core; the owning instance repository is an open decision. | The adapter deploys `api`, `web`, `worker` as separate services to D13 staging. | T9 |
| I1 | margince-automation-world | Migrate (open decision) | Merge the template (`--allow-unrelated-histories`). Move `zalo-lab` to `instance.mk`. Add `instance.yaml`. | `make check` and `make check-template` pass. | M1 |
| R1 | margince-release | Archive | Archive the repository. | Archived. | T7 |
| R2 | margince-d13-deploy | Archive | Archive the repository. | Archived. | D1 |
| R3 | margince-principles | Update references | Replace references to `margince-release` with `margince-template` and `margince-constellation`. | No reference to `margince-release` remains. | R1 |

## Order

```
C1, K2, T1                  (parallel start)
C1 → K3 → K4
K2 → K1
T2 → T3, T4, T5, T6, T9
T3 + C1 + K2 + K4 → T7
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
