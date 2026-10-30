# Documentation

The guides for creating, developing, releasing, and deploying a Margince
instance. Start with the [README](../README.md) for the requirements, the quick
start, and the command overview. Each topic has one guide; the other guides
link to it.

## Getting started

| Guide | Purpose |
|---|---|
| [Create your instance](create-an-instance.md) | Create your instance, receive template changes, upgrade core, and add instance-only `make` targets. |
| [Adding an extension](adding-an-extension.md) | Create, compose, and test a unit in `extensions/`. |

## Day to day

| Guide | Purpose |
|---|---|
| [Contributing to core](contributing-to-core.md) | Change `core/` on a contribution branch and open a pull request to `margince/margince`. |
| [Troubleshooting](troubleshooting.md) | Known error messages, their causes, and their fixes. |

## Release and deploy

| Guide | Purpose |
|---|---|
| [Release](release.md) | Cut a release with `make release`, and what `release.yml` builds, tests, and publishes. Image names, `make package`, and `make smoke`. |
| [Deploy](deploy.md) | The deployment contract, `make deploy-init`, the `host` adapter, the `hook` adapter, and `deploy.yml`. |
| [License](license.md) | Obtain a trial or production license with `make license`, and the license service API. |

## Reference

| Guide | Purpose |
|---|---|
| [Glossary](glossary.md) | The terms this repository uses. |

`docs/client/` is instance-owned and holds a client's own documentation; the
template has none.
