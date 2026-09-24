# Adding a unit

The upstream contract is `core/docs/how-to/add-an-extension.md`, and it is the
authority on what each capability means. This page covers only what is
different because we build *downstream* of the core rather than inside it.

## The workflow

0. **Scaffold it.** `make new-unit NAME=<name>` renders `scripts/unit-skeleton/`
   and rewrites the names. It validates everything before creating anything, so
   a bad name costs nothing. The steps below are what the scaffold leaves you
   to fill in.

1. **The directory name is the unit's canonical name.** It is the prefix for the
   unit's SQL identifiers and the `#/ext/<name>` route segment, so it must be
   identical to the `Name` field you declare. Grammar is
   `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters. `scripts/stage.sh` checks
   this before the composer does, so a bad name fails with a clear message.

2. **Add its `go.mod`.** Its own module, as every unit is. Give it this path:

   ```text
   module margince.instance/extensions/<name>

   go 1.26.6
   ```

   Nothing ever downloads this path. The composed workspace written by
   `gen-composition` resolves the unit locally; no module proxy is contacted.
   The path only has to be unique among this instance's units — it is never
   fetched, so it does not need to describe where the source lives.

   Note the two module namespaces, which are unrelated: our units live under
   `margince.instance/...`, and the host they import is
   `github.com/margince/margince/...`.

3. **Write `<name>.go`** exporting `func New() extension.Extension`. Start from
   `scripts/unit-skeleton/` and grow it. A hyphenated unit drops the hyphen in
   the Go **package identifier** only (`acme-sync` → `package acmesync`); the
   directory, module path and `Extension.Name` all keep it.

4. **Import only `backend/pkg/**` packages carrying the
   `//margince:extension-surface` marker** — `pkg/extension`,
   `pkg/extension/jurisdiction`, `pkg/extension/crm` today. Anything else fails
   upstream's arch test.

5. **Generate and commit the manifest.** `make compose` writes
   `extensions/<name>/manifest.generated.json`; `git add extensions/<name>`
   stages it alongside the unit. `make u` below fails on an untracked
   manifest, so a first run needs this step first.

6. **Prove it.** `make u NAME=<name>` is the inner loop: that unit's Go tests
   plus the cheap policy gates, in seconds. `make u-check NAME=<name>` adds the
   screen suites and the composed typecheck. `make ci` is the full answer, and
   the one to run before opening a pull request.

## What is different downstream

**Name collisions with upstream are fatal, by design.** Upstream ships its own
units under `extensions/` in the vanilla tree. If we create a unit with a name
upstream already uses, staging would overwrite theirs with ours inside the
submodule and leave no trace of the substitution. `scripts/stage.sh` refuses
instead, and names the unit that collided. Rename ours.

To see the current list, ask git rather than a doc — the set changes with every
`make update-core`:

```sh
git -C core ls-files extensions/ | cut -d/ -f2 | sort -u
```

**`manifest.generated.json` is generated, and it is committed.** The composer
writes it beside the unit it scanned, which is the staged copy. `make compose`
then copies it back beside the source in `extensions/<name>/`. That copy is what
you commit.

**Commit the manifest whenever `make compose` changes it.** An operator reads it
to see a unit's risk tiers, secrets and subscriptions before enabling the unit,
so a stale one understates what the unit can do. `make check-manifests` enforces
this, and it also fails when a manifest is not tracked by git at all — the state
a newly scaffolded unit starts in, because `make new-unit` does not create one;
the first `make compose` writes it.

**A unit with a `frontend/` resolves in the composed workspace, not core's.**
`gen-composition` generates the workspace at
`core/build/composition-frontend/workspace/`, using the same `extensions/` scan
the Go side uses. That workspace's lockfile is build output and is gitignored.
Core's tracked `pnpm-lock.yaml` is never modified.

A unit frontend may therefore have dependencies of its own.
`core/extensions/openchannel/frontend/` is upstream's own worked example: its
`package.json` declares `vitest` and `@testing-library/react` as dev
dependencies, and core's lockfile is untouched.

Two rules follow:

- **Declare what the host owns as `peerDependencies`, not direct dependencies**
  — `@margince/frontend`, `react`, `@tanstack/react-query`. The composed
  workspace links those from `core/frontend/node_modules`, so a unit cannot end
  up with a second copy of something the host owns.
- **The screen suites run in `make u-fe`, not `make u`.** They need the composed
  workspace installed and the SPA built. That takes minutes, not seconds.
  `make u-check NAME=<unit>` and `make check` both include them.

`core/pnpm-workspace.yaml` records why membership lives in the generated
workspace rather than core's root one.

## What each capability needs

`make new-unit` gives you `<name>.go`, `<name>_test.go` and `go.mod`. Everything
else you add yourself. This table says which file, and which gate proves it.
`core/extensions/openchannel/` is upstream's own worked example for all of it —
a unit that owns tables, a scheduled job, a screen, and an anonymous edge an
outside provider posts to — and the package comment at the top of its `doc.go`
explains the design.

| To add | Write | Proven by |
|---|---|---|
| A tool (an operation) | An entry in `api/crm.yaml` — tier, scope, RBAC object, prose, schemas. Governance is declared here, not in Go. | `make u` |
| A database table | `migrations/000N_<thing>.up.sql` and a matching `.down.sql`, plus the `//go:embed` and the `Migrations:` field in `New()` | `make check-ext-migrations` — applies it as your unit's restricted `ext_<name>` role, then reverts it |
| A scheduled job or poller | `api/jobs.yaml` — cadence and wall clocks — and the job function | `make u`; `make dev` runs it in the worker |
| A secret | Declare it in `New()`. Members deposit it through your unit's own tools; no operation returns it, masked or otherwise. | `make u` |
| A screen | `frontend/screen.tsx`, `frontend/package.json` (host packages as `peerDependencies`) | `make u-fe` — **not** `make u` |
| Screen copy | `frontend/i18n/en.json`, `de.json` **and** `vi.json`. All three or none: the composer refuses a locale supplied for one language and not another. Prefix keys with your unit's camel-case name, e.g. `extCrmSync.`. | `make compose` |
| Reaching core capture | An `Ingress` declaration in `New()` | `make u`; it is what an operator reads to see the unit reaches capture at all |

Two things are generated and must be committed: `manifest.generated.json`, and
the OpenAPI fragments the composer derives from your `api/` files. `make compose`
writes them; `make check-manifests` fails if you did not commit them.

For a database test, tag the file `//go:build integration`. Without that tag
`make test-integration-ext` does not run it, and reports zero integration tests
as a pass. The harness supplies `MARGINCE_TEST_DSN` and `MARGINCE_TEST_APP_DSN`,
and it applies your migrations twice — they must be idempotent on a second
`migrate up`, which is the thing a poller's cursor table usually gets wrong.

## Where the source of truth is

`extensions/` in this repo. `core/extensions/<our-name>/` is a copy that
`make unstage` deletes. Never edit the staged copy — the next `make compose`
overwrites it without warning.
