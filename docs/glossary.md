# Glossary

Words this repository uses in a specific way. Each entry says where the word is
defined in code, so you can check it.

## composition / to compose

The composed tree upstream's generator writes from the units it finds. `make
compose` stages, then calls core's `composition` target, which runs
`core/backend/tools/gen-composition` over `core/extensions/`. The output is
`core/build/composition/` (a Go workspace and a generated `Extensions()`
function) and `core/build/composition-frontend/` (the pnpm workspace for unit
frontends). See `core/docs/explanation/extensibility.md` and the `compose`
target in the `Makefile`.

## craft

Upstream's code-craftsmanship linter, `core/cli/craft`. `scripts/lint.sh` runs
`craft static --strict` over `extensions/`. The tool's own description is at the
top of `core/cli/craft/main.go`: it reviews code against a rubric. It is one of
the four legs of `make lint`, next to gofmt, golangci-lint and Biome.

## drift

Two related uses. The `drift` make target (delegating to core's
`backend/Makefile:472`) fails when a generated file no longer matches its
source: `*_gen.go`, the contracts, and every
`extensions/*/manifest.generated.json`. `make update-core` also uses the word
loosely for config drift — the settings your `config/` files are missing after
an upstream bump, reported by `make config-check`.

## extension surface

The set of packages under `core/backend/pkg/` a unit is allowed to import. A
package is in the set only if a source file carries the comment marker
`//margince:extension-surface`. Today the marked packages are `pkg/extension`,
`pkg/extension/jurisdiction` and `pkg/extension/crm`. The marker string is read
by `core/backend/extensions_arch_test.go` (`extensionSurfaceMarker`);
`TestSurfaceMarkerLivesOnlyUnderPkg` restricts where it may appear, and
`TestExtensionsImportOnlyTheAllowlistedSurface` admits a unit's import. Both run
in `make arch`.

## gate

A make target whose only job is to fail the build on a rule. Examples in this
repo: `ext-imports` (import allowlist), `arch` (upstream's fitness tests),
`check-manifests`, `drift`, `check-composition`, `secret-scan`. `make check`
runs them all; `make u` runs the cheap ones for one unit.

## installation

This repository: upstream core plus the instance's unit set plus a submodule
pointer. The word marks the difference between this repo and upstream core,
which is a dependency here. Inconsistency: an instance repository is typically
named `margince-<client>-instance`, and a few `Makefile` comments say
"instance". Use **installation** in prose.

## jurisdiction gate

`core/scripts/check-no-jurisdiction.sh`, reached here as `make -C core
fitness-jurisdiction` (an alias for `no-jurisdiction`, `core/Makefile:173`) and
run by `make u`. It greps `backend/internal` — **not** `extensions/` — for
country-specific regulatory identifiers (`XRechnung`, `ZUGFeRD`, `DATEV`,
`GoBD`, `eIDAS`, `Impressum`) and for a quoted upper-case ISO-3166 alpha-2 code
on a line that also mentions country or jurisdiction. Hits under
`/ports/jurisdiction/`, generated files, tests and comments are excluded. An
extension is jurisdiction-specific by design, so a unit is never scanned.

## lane

A make target you run, as listed by `make help` (which greps targets carrying a
`## ` comment out of the `Makefile`). Used for both this repo's targets and
upstream's — hence the `core-root-<lane>` and `core-backend-<lane>` pattern
rules that run an upstream target after staging.

## module-path trap

A unit's module path and the host's module path use unrelated namespaces. A
unit is `margince.instance/extensions/<name>` (see any `extensions/*/go.mod`);
the host it imports is `github.com/margince/margince/backend/...` (see
`core/backend/go.mod` and the header of `scripts/gowork.sh`). `margince.instance`
is ours, `github.com/margince/margince` is upstream. A unit's own path is never
fetched: it is resolved through the composed workspace.

## overlay

`core/config/margince.dev.yaml`, upstream's tracked dev overlay. It is read only
when `MARGINCE_ENV=dev`, on top of `config/margince.yaml`, later layer winning
per key. It arms the "Reset data" action. It is tracked upstream and yours is
not, deliberately — see the file's own header comment.

## pass 1 and pass 2

The two halves of `make check`, defined in the comment above the `check` target
in the `Makefile`. Pass 1 runs upstream's own gate on a **pristine, unstaged**
checkout, because core's `check` includes
`TestEveryEnabledExtensionIsTracked`, which asserts every unit under
`extensions/` is tracked by core — false by construction for a staged unit, so
that lane can never pass with ours present. Pass 2 stages our units and runs the
gates that can see them (lint, build, unit tests, arch, the screen suites,
manifests, drift).

## posture

A configured stance, in `config/margince.yaml` and the overlay. The file uses it
for several settings: retention posture at first boot, license posture, AI
runtime posture (`ai.capture_payloads`, which turns on AI payload capture), and
capture-pipeline posture. It is not one field — read the comment next to the
setting you mean.

## risk tier

An entry in a unit's `manifest.generated.json`, under `risk_tiers`. The composer
derives it statically from the `extension.Extension` literal's AST: one entry
per governed operation the unit adds (an agent tool, a job), carrying its id,
operation, scopes, `tier` (for example `auto_execute`) and digests. A unit that
declares no governed operation has an empty list. See
`core/docs/explanation/extensibility.md` and
`core/extensions/openchannel/manifest.generated.json`, upstream's own worked
example.

## scratch / staged copy

`core/extensions/<unit>/`. It is a copy of `extensions/<unit>/`, written by
`scripts/stage.sh` and deleted by `make unstage`. Never edit it: staging deletes
and recopies each unit unconditionally, so the next `make compose` overwrites it
without warning. `scripts/lib.sh` records which directories this repo copied in
a marker file inside the submodule's git dir, so unstaging removes ours and
never an upstream-owned one.

## seam

A place in core that a unit is written against — a package on the extension
surface, or an interface it exposes. "A unit needs a seam core does not expose"
means a package must be added under `core/backend/pkg/extension/` with the
`//margince:extension-surface` marker, which is a change to core, not to this
repo. The procedure is `docs/contributing-to-core.md`.

## slug

Two unrelated meanings.

1. `DEV_SLUG=<name>` names an isolated dev stack: its own database
   (`margince_dev_<slug>`) and slug-derived ports, and it sweeps nothing else on
   the machine. See `README.md` "The stack" and `core/Makefile:125`.
2. The second half of a core contribution branch name, `<type>/<slug>` — the
   lower-case hyphenated words after `feat`, `fix`, `chore`, `docs`, `refactor`,
   `test` or `perf`. `make core-branch` refuses any other shape. See
   `docs/contributing-to-core.md` and `scripts/core-contrib.sh`.

The two have nothing to do with each other.

## staging / to stage

Copying what this repository owns into `core/`, so upstream's tooling sees it at
the paths it reads: `extensions/*` into `core/extensions/` for the composer, and
this installation's `.env.local` and `config/margince.yaml` to the paths core's
own Makefile and dev stack read them from. `make stage` runs
`scripts/stage.sh` and `scripts/config-init.sh stage`, then regenerates
`go.work` and `tsconfig.json` for editors.

A copy, never a symlink, and each half has its own reason: `gen-composition`
refuses a symlinked unit entry, and upstream's gates walk the whole submodule
tree and refuse the first symlink they meet anywhere in it. Presence under
`<core-root>/extensions/` is the enablement.

Every lane in the `Makefile` depends on it, which is what keeps a staged copy
from drifting from ours. `make unstage` removes our unit copies again.

## unit

An instance extension module: one directory under `extensions/`, its own Go
module, exporting `func New() extension.Extension`. Inconsistency: the same
thing is also called "extension" (upstream's word, and the word in file and
target names such as `test-extensions`) and "our-unit" (in path placeholders
like `core/extensions/<our-unit>/`). Use **unit** in prose, and **extension**
only when quoting upstream's contract.
