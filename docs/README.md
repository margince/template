# Documentation

## Design

| Document | Content |
|---|---|
| [Client instance template — design](superpowers/specs/2026-09-24-client-instance-template-design.md) | Goals, repository responsibilities, structure, script reuse, workflows, versioning, and implementation status (Section 13). Status: approved design; implemented. |

## Directory layout

| Directory | Content |
|---|---|
| `docs/superpowers/specs/` | Design specifications. One file per design, named `YYYY-MM-DD-<topic>-design.md`. |
| `docs/superpowers/plans/` | The [issue breakdown](superpowers/plans/2026-09-24-issue-breakdown.md) and the implementation plans below. |
| `docs/client/` | Instance-owned. Client-specific documentation in a client fork. Empty in the template. |

## Plans

| Plan | Content |
|---|---|
| [Issue breakdown](superpowers/plans/2026-09-24-issue-breakdown.md) | Every issue (T1–T16), its scope, its completion criterion, its dependencies, and its status. |
| [Template foundation (T1, T2)](superpowers/plans/2026-09-24-template-foundation.md) | Tooling import, `instance.yaml`, and the Go CLI. |
| [Instance basics (T3–T6, T11)](superpowers/plans/2026-09-25-instance-basics.md) | Neutral scripts, `instance.mk`, core pin by tag, drift check, `make new-instance`. |
| [Deploy (T9)](superpowers/plans/2026-09-25-deploy.md) | The four-step deployment contract and the `hook` adapter. |
| [Lifecycle CI (T10 part 1)](superpowers/plans/2026-09-25-lifecycle-ci.md) | `make test-lifecycle` and `lifecycle.yml`. |
| [Public template (T13, T16, T7, T15, T8, T10 part 2, T12)](superpowers/plans/2026-09-28-public-template.md) | Making the template public-ready and completing release, licensing, trial, the `host` adapter, the lifecycle test, and these guides. |

## Guides

| Guide | Content |
|---|---|
| [Create an instance](create-an-instance.md) | Create a client instance from this template, keep it current with the template and with core, and deploy it. |
| [Adding an extension](adding-an-extension.md) | Create and test a unit. |
| [Contributing to core](contributing-to-core.md) | Send a change to `margince/margince`. |
| [Desktop build](desktop-build.md) | Build and run the desktop bundle. |
| [Release](release.md) | Cutting a release: `make release`, `release.yml`, `make smoke`. |
| [Deploy](deploy.md) | The deployment contract, the `hook` adapter, and the `host` adapter end to end on a Linux server. |
| [License](license.md) | Obtaining a license: `make license`, the license service API contract. |
| [Trial](trial.md) | Building a laptop trial bundle: `make trial`. |
| [Troubleshooting](troubleshooting.md) | Known problems and fixes. |
| [Glossary](glossary.md) | Terms. |
