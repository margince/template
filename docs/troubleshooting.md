# Troubleshooting

Symptoms you will actually see, and what to do. Each entry quotes the real
message and names the file that produces it, so you can check it yourself.

Two terms used below. A **unit** is one of our extensions, living in
`extensions/<name>/`. **Staging** is the copy step: every make target here first
copies our units into `core/extensions/`, then calls upstream's own make
targets. That copy is scratch. Never edit it.

## First, where am I?

These four commands change nothing. They answer most questions.

```sh
make help          # every make target in this repo, one line each
make core-status   # what core/ is: branch or detached, pinned sha, drift, dirty
make preflight     # which prerequisites this machine is missing
make config-check  # which settings your config files lack against core's examples
```

## Setting up

### `preflight: REQUIRED tools are missing:`

One of git, go, node, pnpm or docker is not on `PATH`. The message names every
missing tool at once, with a `brew install` line for the ones brew can install
(`scripts/preflight.sh:95`). Fix: `make install INSTALL_TOOLS=1` lets brew
install what it can, then runs `make init`.

### `preflight: docker is installed but its daemon is not responding.`

The `docker` command exists, but Docker Desktop is not running. `make dev`,
`make check` and `make ci` all need a database. The probe is `docker info`
(`scripts/preflight.sh:41`, message at `scripts/preflight.sh:86`). Start Docker
Desktop, then `docker info && make preflight`.

### `toolcheck: pnpm 10.x locally, but CI runs pnpm 11.x.`

pnpm 10 and pnpm 11 read different files for the same setting, so a target can
pass here and fail in CI on a config nobody changed. The pinned major is read
out of core's own workflow (`scripts/toolcheck.sh:40`). The script prints the
fix: `npm install -g pnpm@11`. If pnpm is missing entirely, the message is
`toolcheck: pnpm is not installed, and CI runs pnpm <version>.` with the same
fix (`scripts/toolcheck.sh:36`).

### `watch: needs fswatch (brew install fswatch)`

`make watch` re-stages on every file change and is built on `fswatch`, which is
optional and not installed by default (`Makefile:134`). `make init` warns about
it at setup time (`Makefile:71`). Fix: `brew install fswatch`.

### `error: core/ is not checked out — run 'make init' (git submodule update --init)`

The submodule is empty (`scripts/lib.sh:20`). Run `make init`.

## Running the stack

### Port 8080 is already in use, or another checkout's stack is running

`:8080` is the frontend port of an unslugged stack, so two unslugged stacks
cannot coexist. Give yours a slug and it gets its own database and its own ports:

```sh
make dev DEV_SLUG=mine
make dev-stop DEV_SLUG=mine DROP=1    # DROP=1 also drops its database
```

The frontend port of a slugged stack is `8080 + (cksum(slug) % 1000)`; the api
sits on `18080 +` the same offset (`core/scripts/dev.sh:94`,
`core/scripts/dev.sh:101-102`). Do not compute it by hand. The stack prints the
real port when it comes up (`core/scripts/dev.sh:683`):

```
  OPEN     http://localhost:8341
```

A slug must match `^[a-z0-9_-]+$`, or the stack refuses with
`FAIL: DEV_SLUG must match ^[a-z0-9_-]+$` (`core/scripts/dev.sh:89`).

### `make dev` with no slug took over the machine

This is by design, and worth knowing before you type it. A bare `make dev` kills
every Margince api, worker and Vite process on the machine, frees `:8080`, and
drops leftover `margince_dev_*` databases (`Makefile:330-339`). A bare
`make dev-stop` is the mirror: it stops every stack (`Makefile:343-346`).

If anyone else on the machine — another worktree, another checkout — has a stack
up, always pass `DEV_SLUG=<name>`. A slugged stack sweeps nothing.

### `FAIL: check-ext-migrations — N unit(s) declare migrations/ but the test cluster ... is unreachable.`

This gate applies each unit's migrations as that unit's restricted `ext_<name>`
role against a throwaway database. It exits early only while no unit ships a
`migrations/` directory; once one does, it needs a running Postgres and refuses
rather than skipping (`core/scripts/check-ext-migrations.sh:45-48`). Our target
starts the cluster itself when a unit declares migrations (`Makefile:269-274`),
so this usually means Docker is not up. Fix: `make db-up`.

## Working on a unit

### gopls or tsserver says a host import cannot be resolved

On the first import line of a new unit:

```
could not import github.com/margince/margince/backend/pkg/extension
Cannot find module '@margince/frontend/api' or its corresponding type declarations. ts(2307)
```

The build is fine. A unit resolves the host surface through generated files under
`core/build/`, which an editor cannot see (`scripts/gowork.sh:1-25`,
`scripts/tsconfig-editor.sh:1-22`). Two generated files at this repository's root
fix it: `go.work` for gopls and `tsconfig.json` for tsserver. Both are
gitignored. `make config` and every `make stage` rewrite them
(`Makefile:76-77`, `Makefile:105-106`).

Run `make stage`, then restart the language server. Both files list the source
directories, so "go to definition" opens `extensions/`, never the staged copy.

### `ERR_PNPM_OUTDATED_LOCKFILE`

The composer rewrites the composed frontend workspace's member set, which leaves
that workspace's lockfile describing the old set. Core's target installs without
`--no-frozen-lockfile`, and pnpm defaults to frozen under CI, so a stale lockfile
is an error instead of a re-resolve. `make check` installs twice — once with
core's members, once with ours — so the second install always disagrees
(`Makefile:116-127`).

`make compose` already deletes that lockfile, so this error means a target ran
without going through `make compose`. The file is generated and sits under
ignored build output, so deleting it is safe:

```sh
rm -f core/build/composition-frontend/workspace/pnpm-lock.yaml
make compose
```

### `error: core has modified tracked files, and staging would overwrite work in it:`

Staging deletes and recopies each unit, so an edit inside `core/` could be lost
without warning. It refuses instead (`scripts/lib.sh:118-149`). Untracked staged
copies from a previous run are normal and never cause this.

If you did not mean to change `core/`, inspect with `git -C core status`, then
discard with `git -C core checkout -- .` once you are sure.

If you are editing a core seam on a contribution branch, `core/` is dirty by
design. The escape hatch is a variable. **Prefix it on the single command. Do
not `export` it**, or the guard stays off for the rest of your session,
including for targets that really would destroy work:

```sh
MARGINCE_ALLOW_DIRTY_CORE=1 make u NAME=acme-sync
```

The full procedure is in [contributing-to-core.md](contributing-to-core.md).

### `FAIL: a unit's manifest.generated.json is not committed as generated.`

`manifest.generated.json` is generated by the composer and committed next to the
source, because operators read it to see a unit's risk tiers. The gate makes two
separate complaints (`scripts/check-manifests.sh:58-71`):

- `changed by the composer (commit the new content):` — the file is tracked but
  out of date.
- `not tracked by git (run 'make compose', then git add these):` — the file was
  never added. This is the normal state of a brand-new unit, because
  `scripts/new-unit.sh` deletes the template's manifest.

Both fixes:

```sh
make compose
git add extensions/<unit>/manifest.generated.json
```

Only manifests are checked here. Your own uncommitted source edits do not
trigger it.

### `new-unit: '<name>' must match ^[a-z0-9]+(-[a-z0-9]+)*$`

The unit name keys SQL identifiers and the `#/ext/<name>` route, so the grammar
is upstream's, checked here before the composer can produce a worse message
(`scripts/new-unit.sh:20`). The same script also refuses a name over 32
characters (`:21`), a directory that already exists (`:23`), and a name upstream
already uses (`:30`). Rename ours.

## Gates and CI

### The pre-push hook blocked a push

The hook runs two checks (`.githooks/pre-push`):

```
pre-push: the staging lane's tests fail — push blocked.
Run 'make test-scripts' to reproduce.
```

```
pre-push: core/ is pinned to a commit upstream has not merged.
Pushing this would put that pointer on the branch. See the fix above.
```

Reproduce with `make test-scripts` or `make core-check-pin`. Both messages offer
`--no-verify`, and both mean it narrowly: use it **only** when the failure is
unrelated to what you are pushing (`.githooks/pre-push:23`,
`.githooks/pre-push:32`).

### `release: v0.3 is not a release version.`

`release.yml` reads the tag as the version — it names the build, both zips and
the release itself — so it checks the grammar before spending twenty minutes of
runner time. It wants `vMAJOR.MINOR.PATCH`, optionally with an `-rc.N`
suffix (`N` is 1 or greater). Delete the tag and push one that names a version:

```sh
git push --delete origin v0.3 && git tag -d v0.3
git tag -a v0.3.0 -m "..." && git push origin v0.3.0
```

A SUFFIXED version — `v0.3.0-rc.1` — is accepted and publishes as a pre-release,
so a build meant for testing is tagged the same way as one meant to ship. See
[release.md](release.md).

### `release: v0.3.0 does not point at a commit on main.`

The tag is on a branch that has not merged. Nothing has gated that commit — the
light gate runs on `main`, and `core-check-pin` with it — so the lane refuses
rather than shipping a build nobody reviewed. Merge first, then tag the merge
commit.

If the message is `origin/main is not in this checkout` instead, the tag is fine
and the checkout is not: the ancestry check found no `origin/main` to compare
against, which means the lane's `fetch-depth: 0` stopped fetching branches. That
is a CI bug, not yours.

### `package: refusing to build — this repository has uncommitted changes.`

The image tag is this repository's commit, so an image built from a dirty tree
would be tagged with a commit it does not contain (`scripts/package.sh:41-47`).
Commit first, or run `ALLOW_DIRTY=1 make package` for a throwaway build.

### `secret-scan: FAIL — the finding above is in the commit, not just your worktree.`

The scan runs over `git archive HEAD`, not your working tree, so the finding is
committed (`scripts/secret-scan.sh:45-47`). Values are redacted; open the named
line to see it.

- A real credential: remove it from the source, then **rotate it** — it is in
  git history.
- A false positive: add a scoped allowlist entry to `.gitleaks.toml` saying why.

### `gitleaks-pin: checksum mismatch`

The pinned scanner binary did not match its digest
(`scripts/gitleaks-pin.sh:93-95`). Do not bypass it: it means the downloaded
artifact changed, not that the pin is stale.

## The core submodule

### `git status` shows `core` as modified

The submodule pointer moved, normally because a contribution branch is checked
out inside `core/`. Do not commit it.

**`git checkout core` does not fix this.** It is a no-op: the modified state
comes from the submodule's `HEAD` differing from the index, and
`git checkout <path>` does not enter the submodule. With `submodule.recurse=true`
set it does something worse — it silently detaches `core/` off your contribution
branch.

The correct command puts `core/` back on the pinned commit and keeps your branch
(`scripts/core-contrib.sh:274-293`):

```sh
make core-restore
```

If the bad pointer is already committed:

```sh
git checkout HEAD~1 -- core      # if it was the last commit
# or: make core-restore, then
git commit core -m "core: restore the pinned commit"
```

`make core-restore` refuses while `core/` has modified tracked files, rather than
discarding them (`scripts/core-contrib.sh:280-285`). Commit them on the branch
first.

### `error: core/ is pinned to <sha>, which is NOT on origin/main.`

This repository may only pin a commit upstream has merged. A pointer to a
contribution branch builds on your machine and breaks for everyone else — and if
the branch was pushed, CI passes too, until the pull request is squashed or
closed (`scripts/core-contrib.sh:258-270`). The remedy the message prints:

```sh
make core-restore
git checkout HEAD -- core        # if the bad pointer is already committed
git commit core -m "core: restore the pinned commit"
```

If your seam is merged upstream, bump to it properly instead: `make update-core REF=<tag>`.

### `core-check-pin: SKIPPED — cannot resolve origin/main or the pinned object.`

Not a failure. The check could not reach upstream — no network, or a shallow
clone missing the object — so it says so rather than passing silently
(`scripts/core-contrib.sh:254-256`). Fix:
`git -C core fetch origin main && make core-check-pin`.

### `make update-core` refuses to run

It protects three states — `core/` on a contribution branch, uncommitted work,
or commits upstream does not have — and it also refuses a `REF` that is not a
core release tag: instances pin releases only. `make core-status` says which
of the first three applies; `git -C core tag --list 'v*'` lists the release
tags. See [contributing-to-core.md](contributing-to-core.md).

## The desktop build

### `Cannot find module 'react'` in a unit screen, during `desktop-app`

Fixed upstream in core `50f57116`, and gone from this repo with it: core's
`build-app.sh` installs the composed pnpm workspace itself now and refuses the
build if the composer did not produce one. If you see this on an older pin, the
cause is that missing install — `make update-core REF=<tag>`, or use `make desktop`, which
carried the install itself until the pin moved.

### `the installation folder is too deeply nested: the database socket path would be N bytes`

Not a build failure — the launcher refusing to start, correctly. macOS caps a
unix socket path at 103 bytes and the database socket lives inside the
installation folder, so the folder's path must be at most 76. This checkout is
79 bytes on its own, so no location inside the repository can ever run it, the
`build/desktop/` mirror included. Install it out of the tree:

```sh
make desktop-install   # ~/Margince, or DEST=<somewhere short>
make desktop-run
```

`make desktop-install` measures the path the same way the launcher does, so it
refuses before copying 163 MB somewhere that cannot start.

### `margince.env line 1: expected KEY=value, got "\ufeff# Margince settings."`

A Windows installation refusing to start on a file it wrote itself. The comment
is not the problem — the launcher's parser skips comments, and that line is one.
`\ufeff` in front of it is a UTF-8 **byte-order mark**, and the mark is what
defeats the leading-`#` test, so the line is taken for a setting and refused.

`Setup.cmd` put it there. Up to and including **v0.0.1-rc.1** the setup script
wrote `margince.env` back through `Set-Content -Encoding UTF8`, which on Windows
PowerShell 5.1 — the engine `Setup.cmd` invokes, deliberately, because every
Windows box has it — prepends a mark. PowerShell 7 does not, which is why no
lane caught it. Every Windows install was affected: the setup script generates
the keyvault key on every run, and generating it is what rewrote the file.

Fixed in `scripts/desktop-kit/setup.ps1`: all writes go through
`Write-Utf8NoBom`, and setup now repairs a file an earlier release corrupted.
**For a folder you already have, run `Setup.cmd` again** — it strips the mark and
keeps your settings. To do it by hand instead, in PowerShell:

```powershell
$p = 'C:\Users\you\Downloads\margince-windows\margince.env'
[System.IO.File]::WriteAllLines($p, (Get-Content -LiteralPath $p),
  (New-Object System.Text.UTF8Encoding($false)))
```

Nothing else in the folder needs repairing. `margince.yaml` was written the same
way and is unaffected: `yaml.v3` strips a leading mark per the YAML spec, and the
launcher's own reader for that file meets it on a comment line.

Worth knowing for a hand-edited `margince.env`: a mark in front of a line that
*is* an assignment does **not** fail. It parses, and the child process is handed
a variable whose name begins with an invisible character — so the setting is
silently ignored rather than refused. If a setting you added is having no
effect, check the file's encoding before anything else. Save it as UTF-8
*without* a BOM.

### `BUILD-INFO.txt` says `dev-b287031-dirty` and I wanted a version

Both halves are the file working. `VERSION=` is what names a build, and a local
`make desktop` sets none, so the version is derived: `git describe` against `v*`
tags, then `dev-<sha>`. The `-dirty` says the tree had uncommitted changes — a
build whose commit does not identify it, which is worth knowing before that
folder travels anywhere.

To name one:

```sh
make desktop VERSION=v0.3.0
```

A release lane passes its own tag, so a downloaded folder always names the
release it came from.

### Which build is an installed folder?

```sh
cat ~/Margince/BUILD-INFO.txt
```

Version, build time, platform, this repo's commit, the pinned `core/` commit and
every unit with its version. `runtime/build-info.json` is the same facts for a
program. Ask for it first when someone reports a problem with an installation
you did not build — the zip's name is the only other record, and it does not
survive being unzipped.

### The sign-in screen wants an account and I have none

```sh
make desktop-logins
```

It lists every account in the installation's own database with its password, and
probes the admin password against the live api — which matters because seeding
replaces it: a seeded installation is on `demo-password-123` and
`data/admin-password` is then stale. `make desktop-status` reports the same one
line at a time.

### `make seed-demo` cannot reach the desktop app

It is not meant to. That lane is bound to the dev stack: it reads
`core/config/margince-admin-password`, defaults the api to `:8080` and hands the
seeder the compose MinIO. Use `make desktop-seed`, which feeds the same upstream
seeder the desktop installation's own port, credentials and Postgres socket.

### `422 fx_rate_base_self` part-way through `make desktop-seed`

```
seed-demo: setting the USD rate: POST /v1/fx-rates: HTTP 422 ...
  from_currency equals the base currency (the rate is always 1)
```

The installation's base currency is USD and the demo dataset is euro-based. The
seeder loads a rate for every non-EUR currency it meets, and the api correctly
refuses one for the base currency itself — after most of the dataset is already
written, which is why `make desktop-seed` warns about this before it starts.

`margince.yaml` is written once and the workspace is bootstrapped from it, so
a euro installation means a fresh one:

```sh
rm -rf ~/Margince/data ~/Margince/margince.yaml && make desktop-install
```

A fresh `make desktop-install` writes `base_currency: EUR` for exactly this
reason. `CURRENCY=USD make desktop-install` opts out.

### `501 not_implemented` on attachments, or `make desktop-seed` stops at documents

```
seed-demo: document for "metoda — Rahmenvertrag 2": POST /v1/attachments: HTTP 501
  operation attachments is specified but not yet implemented
```

The api wired no object store, and a role without one answers 501 —
`handlers_attachment.go` maps `ErrBlobstoreUnconfigured` to it. Not cosmetic for
seeding: the documents phase sits mid-run, so products, offers, surfaces,
consent, lifecycle, relationship types and the owner assignment that runs last
never happen.

A desktop installation should never see this: the launcher points the blobstore's
filesystem provider at `data/blobs`, which needs no service and no
configuration. Seeing it means the bundle was built from a core that does not
carry that provider — it is committed on `core/`'s
`feat/blobstore-filesystem-provider` branch and not yet merged, so a build from
the pinned commit still answers 501. `make core-status` says which core you have.

If `margince.env` names `MARGINCE_BLOBSTORE_ENDPOINT`, that wins over the
directory — remove those lines and attachments go back to `data/blobs`.

### `500` on any `/v1/ext/*` endpoint, and the body says nothing

The body is a bare `{"code":"internal","status":500}`, so the cause is only in the
log:

```sh
tail -50 ~/Margince/data/logs/api.log
```

The common one on a hand-made installation is a missing keyvault:

```
err="extsecrets: no keyvault is configured for this installation, so no
     extension secret can be stored or read"
```

Every unit that stores a credential needs `MARGINCE_KEYVAULT_ROOT_KEY` in
`margince.env` (`openssl rand -base64 32`; a wrong length refuses the boot).
`make desktop-install` generates one on a fresh install for exactly this reason.

It does not present the same way twice, which is what makes it look like several
unrelated bugs: a unit whose `status` reads a secret has its screen fail on load
("Couldn't load this view"); a unit whose `status` does not renders normally,
reports "Not connected", and only its `connect` 500s — with copy that points at
the provider rather than at the vault. Same single cause.

Set the key **before** connecting an account. Changing it later makes already
sealed credentials unreadable.

### `422 read_only` on a project's `key`, part-way through a seed

```
seed-demo: projects: project for communicode.de: POST /v1/projects: HTTP 422
  a project's key is assigned by the server from its name and cannot be set
```

Not ours and not desktop-specific: core commit `1da94847` (2026-08-23) made the
server mint project keys and refuse a caller-supplied one, and
`backend/tools/seed-demo/surfaces.go` still sends `key`. `make seed-demo` fails
the same way on the dev stack at this pin. It stops the run, so the phases after
`projects` do not happen. The fix belongs upstream — `make core-branch`,
`make core-pr` — or in a later `make update-core REF=<tag>`, once a release
carries it.

### A database client cannot connect to the desktop app

There is no TCP listener: the launcher starts Postgres with
`listen_addresses=''`, so it is reachable only through a socket in a `0700`
directory — and for the same reason there is no password. `make desktop-dsn`
prints the socket path, the roles and a `socat` bridge for a client that speaks
TCP only; `make desktop-psql` opens the `psql` the installation ships.
