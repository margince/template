# Adding an extension

This guide covers the extension units of an instance: creating a unit with
`make new-unit`, its files, composing it into core, testing it, and the gates
that check it. It is for the developer who writes a unit in an instance. The
extension contract itself (what a unit may declare and what each capability
means) is core's, in
[core/docs/how-to/add-an-extension.md](../core/docs/how-to/add-an-extension.md)
and [core/docs/explanation/extensibility.md](../core/docs/explanation/extensibility.md).
This guide covers only what differs because the instance builds on top of the
`core/` submodule.

## 1. Prerequisites

- An instance checkout on which `make install` has run
  ([create-an-instance.md](create-an-instance.md)).
- Docker running, for the gates that need a database
  (`make check-ext-migrations`, `make test-integration-ext`).
- `fswatch`, only for `make watch`.

## 2. How units reach core

A unit is one directory under `extensions/`. Presence of the directory is the
enablement; there is no list of units.

Core's composer only reads `core/extensions/`. `make stage` therefore copies
each unit from `extensions/<name>/` to `core/extensions/<name>/` (without
`node_modules`). Every lane that builds or tests the composition runs
`make stage` first. `make compose` runs `make stage`, then core's composer,
then copies each unit's generated `manifest.generated.json` back to
`extensions/<name>/`.

- `extensions/<name>/` is the source. Edit only this directory.
- `core/extensions/<name>/` is a staged copy. The next `make stage` deletes and
  replaces it, and `make unstage` removes it.
- Most lanes that call core rewrite an absolute path inside a staged copy in
  their output to the path in `extensions/<name>/`.

## 3. Create a unit

1. Choose a name. It must match `^[a-z0-9]+(-[a-z0-9]+)*$`, have at most 32
   characters, and not be the name of a unit that core ships (list them with
   `git -C core ls-files extensions/ | cut -d/ -f2 | sort -u`).
2. Run `make new-unit`:

   ```sh
   make new-unit NAME=<name>
   ```

   The script validates the name before it creates anything. It refuses an
   existing `extensions/<name>/` and a name that core already uses.
3. Declare what the unit does in `extensions/<name>/<pkg>.go`.
4. Generate the manifest:

   ```sh
   make compose
   ```

5. Add the unit to git, including `manifest.generated.json`:

   ```sh
   git add extensions/<name>
   ```

6. Run the unit's tests and the policy gates:

   ```sh
   make u NAME=<name>
   ```

`make u` fails until step 5 is done, because `make check-manifests` refuses an
untracked manifest.

The instance's `.gitignore` does not ignore `extensions/`. Core's guide asks for
a `.gitignore` exception per unit; that rule applies to units inside core, not
to an instance.

## 4. Unit layout

`<pkg>` is the name without hyphens: the unit `acme-sync` has the Go package
`acmesync` and the files `acmesync.go` and `acmesync_test.go`. The directory,
the module path, and `Extension.Name` keep the hyphen.

| Path | Created by | Content |
|---|---|---|
| `go.mod` | `make new-unit` | `module margince.instance/extensions/<name>` and `go 1.26.6`. |
| `<pkg>.go` | `make new-unit` | `func New() extension.Extension`: the declaration, with `Name`, `Version` (`0.1.0`), and `Description`. |
| `<pkg>_test.go` | `make new-unit` | A test that `Name` is the directory name and that `Name` and `Version` are valid. |
| `manifest.generated.json` | `make compose` | The derived record of the unit's risk tiers, secrets, subscriptions, and ingress. Committed. |
| `api/crm.yaml`, `api/jobs.yaml` | you | Contract fragments: governed operations and scheduled jobs. |
| `migrations/NNNN_<name>.up.sql`, `.down.sql` | you | The unit's tables, embedded with `//go:embed migrations` and the `Migrations:` field. |
| `frontend/package.json`, `frontend/screen.tsx` | you | The unit's screen at `#/ext/<name>`. |
| `frontend/i18n/en.json`, `de.json`, `vi.json` | you | The screen's copy, all three locales. |
| `frontend/*.test.tsx` | you | The screen's tests. |

The module path `margince.instance/extensions/<name>` is never downloaded:
the composed workspace (`core/build/composition/go.work`) resolves it locally.
The unit imports core as `github.com/margince/margince/backend/...`, and only
the packages under `core/backend/pkg/` that carry the
`//margince:extension-surface` marker. List them with:

```sh
grep -rl 'margince:extension-surface' core/backend/pkg | xargs -n1 dirname | sort -u
```

A unit that needs a core package outside that set needs a change to core
([contributing-to-core.md](contributing-to-core.md)).

## 5. Capabilities

Core's guide defines each capability and its rules. This table names the files
and the gate that checks each one here.

| Capability | Files | Checked by |
|---|---|---|
| A governed operation (a tool) | An operation in `api/crm.yaml`, with its `x-mcp-tool` block, and a `Tools` entry in `New()`. | `make compose`, `make u` |
| Tables | `migrations/`, the `//go:embed migrations` variable, and the `Migrations:` field. | `make check-ext-migrations`, `make test-integration-ext` |
| A scheduled job | `api/jobs.yaml` and a `Jobs` entry in `New()`. | `make compose`, `make u` |
| A secret | A `Secrets` entry in `New()`. | `make u` |
| A screen | `frontend/package.json` and the module it names. | `make u-fe`, `make fe-ds-gates`, `make fe-typecheck-composed` |
| Screen copy | `frontend/i18n/en.json`, `de.json`, and `vi.json`, keyed `ext<CamelName>.`. | `make compose` |
| An event subscription or ingress | `Subscriptions` or `Ingress` in `New()`. | `make u` |

`core/extensions/openchannel/` is core's reference unit: it has tables, jobs,
secrets, ingress, and a screen with tests.

### 5.1 A unit screen

A unit's `frontend/` is a member of the composed pnpm workspace that the
composer writes to `core/build/composition-frontend/workspace/`, not of core's
root workspace. That workspace's lockfile is build output: `make compose`
deletes it, and core's `pnpm-lock.yaml` is not changed.

- Declare `@margince/frontend`, `react`, `react-dom`, and
  `@tanstack/react-query` as `peerDependencies`. The host provides them.
- Declare test tools such as `vitest` and `@testing-library/react` as
  `devDependencies`.
- `make u` does not run screen tests. `make u-fe` runs every unit's screen
  suite; it installs the composed workspace and builds the SPA, and takes
  minutes.

### 5.2 Database tests

Tag a test that needs a database with `//go:build integration`.
`make test-integration-ext` runs these tests; a unit without such a test is
listed as skipped. The lane:

1. Creates the database `margince_ext_it` on the test cluster
   (`EXT_IT_DB` may name `margince_ext_it_<suffix>` instead).
2. Runs `migrate up` and checks that each unit with `migrations/` appears in
   the output.
3. Runs `migrate up` again, which must apply nothing.
4. Runs `go test -tags integration` in each unit that has an integration test,
   with `MARGINCE_TEST_DSN` and `MARGINCE_TEST_APP_DSN` set to that database.
5. Drops the database.

## 6. Test a unit

| Command | Runs | Time |
|---|---|---|
| `make u NAME=<name>` | `make compose`; the unit's Go tests in the staged copy with the composed workspace; core's `ext-imports` and `fitness-jurisdiction` gates; `make compose` again; `make check-manifests`. | Seconds |
| `make u-fe` | `make compose`, then core's `fe-test-ext`: every unit's screen suite. No `NAME` filter. | Minutes |
| `make u-check NAME=<name>` | `make u`, `make u-fe`, and core's `fe-typecheck-composed`. | Minutes |
| `make test-extensions` | Every unit's Go tests. | Minutes |
| `make check` | The full gate (Section 8). | Long |
| `make ci` | `make check`, `make test-integration-ext`, `make core-check-pin`, and the check that `core/` is unchanged. | Long |

Run `make u` while you work, `make u-check` for a unit with a screen, and
`make ci` before you open a pull request.

`make dev` runs the development stack with the instance's units. A unit's
routes and its screen at `#/ext/<name>` are served on the port that
`make dev` prints. `make watch` stages the units again when a file under
`extensions/` changes (it needs `fswatch`).

## 7. Lint and format

| Command | Effect |
|---|---|
| `make lint` | Checks `extensions/` with gofmt, golangci-lint (per unit module, with `core/backend/.golangci.yml`), craft (`craft static --strict`), and Biome (unit frontends, with core's configuration). Changes nothing. |
| `make fmt` | Rewrites `extensions/` in place: `gofmt -w`, then Biome's safe fixes and formatting. |

`make lint` needs golangci-lint from core's tools (`make init` installs it).
When Biome is not installed, `make lint` skips the Biome check and names
`make fe-install`.

## 8. What `make check` runs

`make check` first runs `toolcheck`, `check-instance`, `check-template`,
`check-public` (only in the template, where `.template-version` does not
exist), `test-scripts`, `test-secret-scan`, and `secret-scan`. It then runs two
passes:

1. **Pass 1**: `make unstage`, then core's own `check` on a `core/` without
   the instance's units.
2. **Pass 2**: with the units staged, `lint`, `check-composition`, `build`,
   `test-extensions`, `arch`, `fe-test-ext`, `fe-typecheck-composed`,
   `fe-ds-gates`, `ext-imports`, `check-ext-migrations`, `check-manifests`,
   `check-docs`, and `drift`.

| Gate | Checks |
|---|---|
| `check-composition` | Generating the composition again gives the same files. |
| `arch` | Core's tests `TestExtensionsImportOnlyTheAllowlistedSurface`, `TestSurfaceMarkerLivesOnlyUnderPkg`, and `TestCompositionWiredOnlyFromCmd` on the composed tree. |
| `ext-imports` | The import allowlist of unit code. |
| `check-ext-migrations` | Applies each unit's migrations as its restricted `ext_<name>` role on a temporary database, checks the catalog, and reverts them. Starts the database when a staged unit has `migrations/`. |
| `check-manifests` | Every `extensions/*/manifest.generated.json` is tracked by git and has no uncommitted change. |
| `drift` | Generated files match their generators. |
| `fe-ds-gates` | Core's design-system gates over the unit screens. |

CI runs a subset of these on every pull request; see
[release.md](release.md#9-ci-workflows).

## 9. The manifest

`make compose` writes `manifest.generated.json` into the staged copy, and
`scripts/sync-manifests.sh` copies it to `extensions/<name>/` when it changed.
Commit it with the unit, and again whenever `make compose` changes it. The
manifest lists what an operator approves before enabling the unit, so a stale
manifest is refused by `make check-manifests`.

`make new-unit` does not create a manifest. The first `make compose` writes it.

## 10. Remove a unit

1. Remove the staged copies while the unit still exists:

   ```sh
   make unstage
   ```

2. Remove the directory with git, so the manifest removal is staged:

   ```sh
   git rm -r extensions/<name>
   ```

3. Run `make check`.

Run `make unstage` first. `make stage` does not delete the staged copy of a
unit that is no longer in `extensions/`.

## Related guides

- [core/docs/how-to/add-an-extension.md](../core/docs/how-to/add-an-extension.md):
  the extension contract.
- [contributing-to-core.md](contributing-to-core.md): change an extension seam
  in core.
- [release.md](release.md): the images that contain the units.
- [troubleshooting.md](troubleshooting.md#3-units-and-staging): unit and
  staging errors.
- [glossary.md](glossary.md): unit, staging, composition, and manifest.
