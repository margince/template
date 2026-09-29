# Troubleshooting

This guide lists known error messages of the instance lifecycle, with their
cause and fix, by area. It is for every developer who works in your instance.
Each entry starts with the message as the code prints it; `<...>` marks a part
that changes. The guide that owns each topic has the full procedure; this
guide links to it.

## 1. Start here

These commands change nothing:

| Command | Output |
|---|---|
| `make help` | Every target. |
| `make preflight` | Missing required and optional tools. |
| `make toolcheck` | Whether the local pnpm major version matches core's. |
| `make config-check` | Keys that `.env.local` and `config/margince.yaml` lack compared with core's examples. |
| `make core-status` | Where `core/` is: branch, pinned commit, distance from `origin/main`, modified files. |
| `make check-instance` | Whether `instance.yaml` is valid and names the tag that `core/` is at. |

## 2. Install and setup

### `preflight: REQUIRED tools are missing:`

**Cause:** git, go, node, pnpm, or docker is not on `PATH`. The message lists
each missing tool and a `brew install` line for the tools that Homebrew
installs.

**Fix:** Install the tools, or run `make install INSTALL_TOOLS=1`, which runs
the `brew install` line first.

### `preflight: docker is installed but its daemon is not responding.`

**Cause:** The Docker CLI exists, but `docker info` fails. The database needs a
running Docker daemon.

**Fix:** Start Docker Desktop, check that `docker info` succeeds, and run the
command again.

### `toolcheck: pnpm <local> locally, but CI runs pnpm <pinned>.`

**Cause:** The local pnpm major version differs from the version in
`packageManager` of `core/package.json`. Two pnpm major versions can resolve
the same configuration differently.

**Fix:** Run the command that the message prints:

```sh
corepack enable && corepack prepare pnpm@<pinned> --activate
```

`toolcheck: pnpm is not installed, and CI runs pnpm <pinned>.` has the same fix.

### `error: core/ is not checked out — run 'make init' (git submodule update --init)`

**Cause:** The `core/` submodule is empty.

**Fix:** Run `make init`.

### `instance.yaml: core: instance.yaml says "<tag>", but core/ is at <tags>`

**Cause:** `core/` is not at the commit of the tag that `instance.yaml` names,
for example after a pull that changed the core pointer.

**Fix:** Run `git submodule update --init core`. To move to another core
release, use `make update-core REF=<tag>`
([create-an-instance.md](create-an-instance.md#7-upgrade-core)).

### `instance.yaml: yaml: unmarshal errors:` ... `field <key> not found in type main.Instance`

**Cause:** `instance.yaml` has a key that the template does not accept. The
accepted keys are `name`, `display_name`, `core`, `data`, and `deploy`. An
instance created by an older template can still have a `flavor:` line.

**Fix:** Remove the key from `instance.yaml` and commit.

### `watch: needs fswatch (brew install fswatch)`

**Cause:** `make watch` needs `fswatch`, which is optional.

**Fix:** Run `brew install fswatch`.

### The editor reports `could not import github.com/margince/margince/backend/pkg/extension` or `Cannot find module '@margince/frontend/api'`

**Cause:** A unit resolves core through the composed workspace, which an editor
does not read. The generated files `go.work` (for gopls) and `tsconfig.json`
(for tsserver) at the repository root give the editor the same paths. Both are
ignored by git.

**Fix:** Run `make stage`, which writes both files, then restart the language
server. `make config` also writes them.

## 3. Units and staging

### `error: new-unit: '<name>' must match ^[a-z0-9]+(-[a-z0-9]+)*$ ...`

**Cause:** The unit name does not follow core's name rule. `make new-unit` also
refuses a name over 32 characters (`exceeds 32 characters`), an existing
directory (`extensions/<name> already exists`), and a name of a core unit
(`'<name>' is an upstream unit`).

**Fix:** Choose another name ([adding-an-extension.md](adding-an-extension.md#3-create-a-unit)).

### `error: extensions/<unit> collides with an upstream unit of the same name — rename ours`

**Cause:** A unit in `extensions/` has the name of a unit that core ships, for
example after `make update-core` to a release that added a unit with that
name. `make stage` does not replace a core unit.

**Fix:** Rename the unit directory, its module path, and `Extension.Name`.

### `error: <checkout>/core has modified tracked files, and staging would overwrite work in it:`

**Cause:** Tracked files in `core/` are modified, or `core/extensions/` has an
untracked directory that the last `make stage` did not create. `make stage`
refuses, because it replaces staged copies in `core/extensions/`.

**Fix:**

- For changes you did not intend, inspect them with `git -C core status`, and
  discard them with `git -C core checkout -- .` once you are sure.
- For a staged copy of a unit you removed from `extensions/`, delete
  `core/extensions/<unit>/`.
- For a change to core on a contribution branch, set
  `MARGINCE_ALLOW_DIRTY_CORE=1` on each command
  ([contributing-to-core.md](contributing-to-core.md#32-margince_allow_dirty_core1)).

### `FAIL: a unit's manifest.generated.json is not committed as generated.`

**Cause:** One of two cases, named in the message:

- `changed by the composer (commit the new content):` the manifest differs from
  the version in git.
- `not tracked by git (run 'make compose', then git add these):` the manifest
  was never added. This is the state of a new unit after its first
  `make compose`.

**Fix:**

```sh
make compose
git add extensions/<unit>/manifest.generated.json
```

### `u: no such unit: extensions/<name>`

**Cause:** `NAME` does not name a directory in `extensions/`.

**Fix:** Pass the directory name: `make u NAME=<name>`.

### `ERR_PNPM_OUTDATED_LOCKFILE`

**Cause:** The lockfile of the composed frontend workspace describes an older
set of units. `make compose` deletes it; the error means that a core target
ran without `make compose` before it.

**Fix:**

```sh
rm -f core/build/composition-frontend/workspace/pnpm-lock.yaml
make compose
```

### `FAIL: check-ext-migrations — <n> unit(s) declare migrations/ but the test cluster at <dsn>/ is unreachable.`

**Cause:** A staged unit has `migrations/` (core's own units do too), and the
test database does not answer. `make check-ext-migrations` runs `make db-up`
first, so Docker is usually not running.

**Fix:** Start Docker, then run `make db-up`.

### `error: a second 'migrate up' applied work — a unit migration is not idempotent`

**Cause:** In `make test-integration-ext`, the second `migrate up` applied a
migration again.

**Fix:** Correct the unit's migration files. Core's rules for unit migrations
are in [core/docs/how-to/add-an-extension.md](../core/docs/how-to/add-an-extension.md).

### `FAIL: gofmt would rewrite the files above — run 'make fmt'`

**Cause:** `make lint` found Go files that are not gofmt-formatted.

**Fix:** Run `make fmt`, then `make lint`.

### `FAIL: golangci-lint not found at <path> — run 'make init' ...`

**Cause:** golangci-lint is not installed in `$(go env GOPATH)/bin`.

**Fix:** Run `make init`.

## 4. Development stack

### `FAIL: port :<port> already in use — is <stack> already running?`

**Cause:** Another process listens on the port of the development stack, for
example a stack that is still running.

**Fix:** Stop the stack with `make dev-stop` (with `DEV_SLUG=<name>` for a named
stack), or start a separate stack with its own database and ports:

```sh
make dev DEV_SLUG=<name>
make dev-stop DEV_SLUG=<name> DROP=1
```

The message also suggests core's `dev-sweep` target, which stops every stack
on the machine. The instance has no such target; run it as
`make core-root-dev-sweep`.

### `seed-demo: DATASET=<path> required — clone the demo dataset repository, then:`

**Cause:** `make seed-demo` has no default dataset.

**Fix:** Pass the checkout: `make seed-demo DATASET=<dataset-checkout>`.
`make seed-demo` seeds the `make dev` stack only; for a desktop folder use
`make desktop-seed` ([desktop-build.md](desktop-build.md#6-seed-demo-data)).

## 5. Checks and CI

### `pre-push: the staging lane's tests fail — push blocked.`

**Cause:** The pre-push hook runs `make test-scripts`, and a test failed.

**Fix:** Run `make test-scripts`, and correct the failure. Use
`git push --no-verify` only when the failure is not related to the push.

### `pre-push: core/ is pinned to a commit upstream has not merged.`

**Cause:** `make core-check-pin` failed: the recorded `core` commit is not on
core's `origin/main`. See Section 9.

**Fix:** See `error: core/ is pinned to <commit>, which is NOT on origin/main.`
in Section 9.

### `check-template: template-owned paths differ from template commit <commit>:`

**Cause:** In your instance, a template-owned path was changed. The message lists
the paths.

**Fix:** Revert the paths in the instance. Make the change in the template and
run `make template-sync` in the instance
([create-an-instance.md](create-an-instance.md#6-receive-template-changes)).

### `check-instance-mk: instance.mk redefines a template target:`

**Cause:** `instance.mk` defines a target that the `Makefile` also defines.
`check-instance-mk: instance.mk may only set variables named INSTANCE_*` is the
same check for variables.

**Fix:** Rename the target, or the variable to `INSTANCE_<name>`
([create-an-instance.md](create-an-instance.md#8-instance-only-make-targets)).

### `FAIL: <file> names `make <target>`, which the Makefile does not declare.`

**Cause:** `make check-docs` found a `make <target>` in `README.md`,
`CLAUDE.md`, or `docs/*.md` that the `Makefile` does not define with a `##`
description.

**Fix:** Correct the target name in the document.

### `secret-scan: FAIL — the finding above is in the commit, not just your worktree.`

**Cause:** gitleaks found a credential in `git archive HEAD`, the committed
tree. Values are redacted in the output.

**Fix:**

- A real credential: remove it from the source, and rotate it, because it is in
  git history.
- A false positive: add a scoped allowlist entry with a reason to
  `.gitleaks.toml`.

### `gitleaks-pin: checksum mismatch for gitleaks v<version> (<platform>).`

**Cause:** The downloaded gitleaks archive does not match the digest in
`scripts/gitleaks-pin.sh`.

**Fix:** Do not bypass the check. Remove `.tmp/` and run the scan again. If the
mismatch stays, the download changed; report it.

## 6. Release and images

### `error: release: VERSION '<v>' does not match ...`

**Cause:** `make release` needs a version in the format of
[release.md](release.md#2-version-format).

**Fix:** Pass a valid version, for example `make release VERSION=v1.2.0`.

### `error: release: the working tree has uncommitted changes; commit or discard them first`

**Cause:** `make release` needs a clean working tree, untracked files included.

**Fix:** Commit or remove the changes.

### `error: release: HEAD is not an ancestor of origin/main; push or merge it first`

**Cause:** The commit to release is not on `origin/main`.

**Fix:** Merge it to `main`, update the checkout, and run `make release` again.

### `error: release: <v> is not newer than <tag>`

**Cause:** An existing release tag is the same version or newer.

**Fix:** Choose a higher version.

### `error: release: make check failed; nothing was tagged`

**Cause:** The last precondition of `make release` failed.

**Fix:** Run `make check`, correct the failure, and run `make release` again.

### `release: <tag> is not a release version.` (in `release.yml`)

**Cause:** A tag that starts with `v` but does not match the version format was
pushed, for example `v1.2`.

**Fix:** Delete the tag and push a valid one:

```sh
git push --delete origin <tag> && git tag -d <tag>
make release VERSION=<v>
```

### `release: <tag> does not point at a commit on main.` (in `release.yml`)

**Cause:** The tag names a commit that is not on `main`.

**Fix:** Delete the tag, merge the work to `main`, and tag the merge commit
with `make release`. `release: origin/main is not in this checkout.` means that
the workflow's checkout did not fetch `main`; check its `fetch-depth`.

### `package: refusing to build — this repository has uncommitted changes.`

**Cause:** The images are labelled with the instance commit, and the working
tree differs from it.

**Fix:** Commit the changes, or run `make package ALLOW_DIRTY=1 VERSION=<v>`
for a build that you do not release.

### `error: package: docker buildx is required (it drives core's bake file)`

**Cause:** `docker buildx` is not installed.

**Fix:** Install Docker Desktop or the buildx plugin.

## 7. Desktop

### `the installation folder is too deeply nested: the database socket path would be <n> bytes and the system limit is 103.`

**Cause:** The launcher refuses to start: macOS limits a socket path to 103
bytes, and the folder path is longer than 76 bytes. A path inside the checkout,
such as `build/desktop/margince/`, is usually too long.

**Fix:** Install the folder at a short path, then start it there:

```sh
make desktop-install DESKTOP_DEST=~/Margince
make desktop-run
```

### `error: the installation path is too long: the database socket would be <n> bytes and the system limit is 103.`

**Cause:** `make desktop-install` checks the path before it copies the folder.

**Fix:** Pass a shorter `DESKTOP_DEST`, for example
`make desktop-install DESKTOP_DEST=~/M`. The message suggests `DEST=`, which
the `make` target does not read.

### `error: the installation at <folder> is running — quit it first (Ctrl-C in its window), then install again`

**Cause:** `make desktop-install` updates a folder whose app is running.

**Fix:** Stop the app, then run `make desktop-install` again.

### `error: the installation at <folder> has no demo loader.`

**Cause:** The folder was built without a demo dataset, so it has no
`Load Demo Data.command`.

**Fix:** Build again with the dataset, and install:

```sh
make desktop DATASET=<dataset-checkout>
make desktop-install
```

### `error: no demo dataset.`

**Cause:** `make desktop-seed` has no `DATASET`, and `<folder>/data/demo/` has
no dataset.

**Fix:** Pass `DATASET=<dataset-checkout>`, or copy the dataset into
`<folder>/data/demo/`.

### `422 fx_rate_base_self` during `make desktop-seed`

**Cause:** The folder's base currency is not EUR. The demo dataset is based on
EUR, and the `api` refuses an exchange rate for the base currency. The base
currency is fixed when the workspace is created.

**Fix:** Start over with a new database; this deletes the folder's data:

```sh
rm -rf ~/Margince/data ~/Margince/margince.yaml ~/Margince/margince.env
make desktop-install
```

`make desktop-install` writes `base_currency: EUR` unless `CURRENCY` is set
([desktop-build.md](desktop-build.md#41-what-setupcommand-writes)).

### A `/v1/ext/...` request answers `500`, and `api.log` says `extsecrets: no keyvault is configured for this installation`

**Cause:** `margince.env` has no `MARGINCE_KEYVAULT_ROOT_KEY`. Every unit that
stores a credential needs it. The folder was configured without
`Setup.command`, or without `openssl`.

**Fix:** Stop the app, run `Setup.command` in the folder (or
`make desktop-install` again), and start the app. Set the key before you
connect an account: credentials sealed under one key do not open with another.

### `margince.env line 1: expected KEY=value, got "﻿# ..."` (Windows)

**Cause:** `margince.env` starts with a UTF-8 byte-order mark. `setup.ps1` of an
older release wrote it.

**Fix:** Run `Setup.cmd` in the folder again. It removes the mark and keeps the
settings. A hand-edited `margince.env` must be saved as UTF-8 without a BOM.

### `error: margince.env names an object store at <host:port> and nothing is listening there.`

**Cause:** `margince.env` sets `MARGINCE_BLOBSTORE_ENDPOINT`, and the `api`
does not start without that object store.

**Fix:** Start the object store, or remove the `MARGINCE_BLOBSTORE_*` lines from
`margince.env` to store files in `data/blobs/`.

### `error: neither data/admin-password nor the seeded password signs in as <email>.`

**Cause:** The admin password was changed in the app.

**Fix:** Pass the password: `MARGINCE_SEED_PASSWORD=<password> make desktop-seed`.

### A database client cannot connect to the desktop folder

**Cause:** The macOS database has no TCP listener. It accepts connections only
on the socket in `<folder>/data/sockets/`.

**Fix:** Run `make desktop-dsn` for the socket path and a `socat` bridge, or
`make desktop-psql` ([desktop-build.md](desktop-build.md#121-the-database)).

### `Bad CPU type in executable`

**Cause:** The folder was built for the other Mac architecture.

**Fix:** Use the zip for the Mac: `margince-macos-apple-silicon-<v>.zip` or
`margince-macos-intel-<v>.zip`. A local `make desktop` builds for the Mac
that runs it.

Core's failure table for the desktop app is in
[core/docs/how-to/build-the-desktop-app.md](../core/docs/how-to/build-the-desktop-app.md#when-something-goes-wrong).

## 8. Deploy and host

### `error: deploy: the working tree has uncommitted changes, so the hooks and configuration match no commit; commit them, or re-run with ALLOW_DIRTY=1`

**Cause:** `make deploy` reads `deploy/<env>/` from the working tree, which
differs from the commit.

**Fix:** Commit the changes. `ALLOW_DIRTY=1` deploys anyway.

### `deploy: <env> runs in production mode and needs MARGINCE_LICENSE: ...`

**Cause:** The environment runs in production mode, and `secrets` does not list
`MARGINCE_LICENSE` or it has no value.

**Fix:** List `MARGINCE_LICENSE` in `deploy/<env>/secrets` and set it in the
environment of `make deploy` ([license.md](license.md)). For a test environment,
list `MARGINCE_ENV` and set it to `test`
([deploy.md](deploy.md#58-the-license-check)).

### `deploy: <dir>/config/margince.yaml still has the placeholder admin email admin@example.com; ...`

**Cause:** `bootstrap_admin.email` in `deploy/<env>/config/margince.yaml` is the
placeholder.

**Fix:** Set the real admin email and commit.

### `HOST_KNOWN_HOSTS is not set: pass the server's known_hosts line(s) ...`

**Cause:** The `host` adapter never disables host key checking, and needs the
server's `known_hosts` lines.

**Fix:** Compare the key fingerprint with the server's, then:

```sh
export HOST_KNOWN_HOSTS="$(ssh-keyscan -H <host>)"
```

### `deploy: Docker on <target> does not answer for this user; run make host-bootstrap ENV=<env>`

**Cause:** Docker is not installed on the server, or the SSH user is not in the
`docker` group. `<target> has no Docker Compose plugin` has the same fix.

**Fix:** Run `make host-bootstrap ENV=<env>`
([deploy.md](deploy.md#54-prepare-the-server)).

### `deploy: <target> cannot read the manifest of <image> (is the release pushed, and the registry login right?)`

**Cause:** The server cannot read an image: the release was not pushed, the
image name has no or another `REGISTRY` prefix, or the registry login is
missing or wrong.

**Fix:** Check that `release.yml` pushed the images, deploy with the same
`REGISTRY` as the repository variable, and, for a private registry, set
`REGISTRY_USERNAME` and `REGISTRY_PASSWORD`
([deploy.md](deploy.md#53-credentials)).

### `error: render: no value in the environment for: <names> (listed in <dir>/secrets)`

**Cause:** A name in `deploy/<env>/secrets` has no value in the environment of
`make deploy`.

**Fix:** Set each named variable, or remove the name from `secrets`.

### `keyvault: this installation holds sealed secrets but MARGINCE_KEYVAULT_ROOT_KEY is not set`

**Cause:** The `api` does not start: the database holds data sealed with a
vault key, and no `MARGINCE_KEYVAULT_ROOT_KEY` reaches the container. This
happens on an environment deployed before `shared/instance.env` existed, when
the key that sealed the data was set by hand and is no longer listed in
`secrets`.

**Fix:** List `MARGINCE_KEYVAULT_ROOT_KEY` in `secrets` again and deploy with
the original value. No other copy of the key exists. See
[deploy.md](deploy.md#56-generated-instance-keys-and-the-first-admin-password)
and [deploy.md](deploy.md#512-rollback-limits).

### `entrypoint: MARGINCE_ADMIN_PASSWORD is set, but this installation already has a company, ...`

**Cause:** Expected after the first start. The `api` used
`MARGINCE_ADMIN_PASSWORD` once to create the first admin account, and ignores
it afterwards.

**Fix:** None. See
[deploy.md](deploy.md#56-generated-instance-keys-and-the-first-admin-password).

### `error: host-admin-password: no generated admin password: ...`

**Cause:** The environment was set up before `instance.env` existed, or
`secrets` lists `MARGINCE_ADMIN_PASSWORD`.

**Fix:** Use the admin password that you set. `host-admin-password: <target> has
no <file>; run make deploy ...` means that the environment was never deployed.

## 9. The core submodule

### `git status` shows `core` as modified

**Cause:** `core/` is not at the recorded commit, usually because a
contribution branch is checked out.

**Fix:** Run `make core-restore`. Do not commit the change, and do not use
`git checkout core`, which does not enter the submodule
([contributing-to-core.md](contributing-to-core.md#7-the-core-pointer)).

### `error: core/ is pinned to <commit>, which is NOT on origin/main.`

**Cause:** The instance records a `core` commit that is not on core's `main`,
for example a commit of a contribution branch.

**Fix:** If the pointer change is not committed, run `make core-restore`. If
it is committed, restore the pointer from the last correct commit:

```sh
git checkout <good-commit> -- core
git commit -m "core: restore the pinned commit"
make core-restore
```

The fix that the message prints (`git checkout HEAD -- core`) does not change a
pointer that is already committed.

### `core-check-pin: SKIPPED — could not establish whether <commit> is on origin/main.`

**Cause:** Not a failure. The check could not fetch `origin/main`, the object
is missing, or `core/` is a shallow clone.

**Fix:** Run `git -C core fetch origin main` (or
`git -C core fetch --unshallow origin main` for a shallow clone), then
`make core-check-pin`.

### `error: update-core: '<ref>' must be a release tag like v0.0.2`

**Cause:** `REF` is not a core release tag (`vX.Y.Z`). Your instance pins core
releases only. `update-core: '<ref>' is not a core release tag.` means that no
such tag exists in `core/`.

**Fix:** List the tags with `git -C core tag --list 'v*'`, and pass one.

### `error: core/ is on branch <branch>, and moving it would abandon that branch.`

**Cause:** `make update-core` or `make core-branch` found a contribution branch
in `core/`. The same guard refuses modified tracked files
(`moving it would discard them`) and commits on a detached `HEAD` that
`origin/main` does not have.

**Fix:** Finish or park the contribution with `make core-pr` and
`make core-restore`, or give the commits a branch name with
`git -C core branch <name>`.

## 10. Local stack

### `error: local: make local-up needs ports 80 and 443:` ...

**Cause:** Another process listens on port 80 or 443. The message names it when
`lsof` is installed.

**Fix:** Stop that process, or a local stack of another checkout with
`make local-down` there.

### `error: local: image(s) not found locally: <images> — run 'make package VERSION=<v>' first`

**Cause:** The images of `VERSION` are not in the local Docker image store.

**Fix:** Run `make package VERSION=<v>`, with the same `REGISTRY` as for
`make local-up`.

### The database rejects its password after `.local/` was deleted

**Cause:** `make local-up` generated new database passwords in a new `.local/`,
and the data volumes still hold the old database.

**Fix:** Run `make local-down WIPE=1`, which removes the volumes and `.local/`,
then `make local-up VERSION=<v>`. This deletes the local data.

## 11. Trial and license

### `error: trial: <dir> exists; pass FORCE=1 to replace it`

**Cause:** A trial bundle for this name, version, and platform exists.

**Fix:** Run `make trial VERSION=<v> FORCE=1`, or move the existing bundle.

### `license: set MARGINCE_LICENSE_API and MARGINCE_ACCOUNT_TOKEN (or set $MARGINCE_TRIAL_LICENSE directly to skip the request)`

**Cause:** No license value and no license service settings are set. For
`make license`, the variable named last is `MARGINCE_LICENSE`.

**Fix:** Set the license value, or the two service variables
([license.md](license.md#5-variables)). `make trial` then stops with
`error: trial: no trial license; nothing was built`.

### `license: cannot reach <url>`

**Cause:** The license service does not answer.

**Fix:** Check `MARGINCE_LICENSE_API` and the network. Other answers of the
service are printed as `license: the license service answered <code>: <message>`
([license.md](license.md#6-behavior)).

## Related guides

- [create-an-instance.md](create-an-instance.md): setup, template sync, core
  upgrades.
- [adding-an-extension.md](adding-an-extension.md): units and gates.
- [release.md](release.md): releases and images.
- [deploy.md](deploy.md): deployment.
- [desktop-build.md](desktop-build.md): the desktop folder.
- [trial.md](trial.md) and [license.md](license.md): trials and licenses.
