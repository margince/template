# Cutting a release

Two lanes, and which one runs is decided by what you did, not by a flag.

| You did | What runs | How long |
|---|---|---|
| Opened a pull request, or merged to `main` | `ci.yml` — the light gate, and only that | minutes |
| Pushed a **`v*` tag** | `release.yml` — the full gate, the images and their smoke test, both desktop bundles, then it publishes the release | ~20 minutes |

## The light gate

`ci.yml` proves the composition: it regenerates the composed tree and requires
the regeneration be byte-identical, builds it, runs every unit's own suite, the
arch fitness tests, the import allowlist, the design-system gates over our units'
screens, lint, drift, the staging script tests, and the two assertions about
`core/` being pinned and pristine.

What it does NOT run: the screen suites, the composed typecheck, and the two
lanes that need a real Postgres. Those cost infrastructure, and both release
lanes run them. **A green pull request means the composition is sound, not that
the tree is releasable.** `make ci` locally is still the full thing.

The full gate lives in `full-check.yml` and is called by both release lanes, so
there is one definition rather than two that drift.

## Version pattern and ordering

A release version is a git tag, an image tag, and the desktop bundle name, all
at once:

```
^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$
```

Matches `v1.2.0`, `v0.1.0`, `v10.0.12`, `v1.3.0-rc.1`. Does not match `1.2.0`,
`v1.2`, `v1.2.0-rc.0`, `v1.2.0-rc1`, or `v1.2.0-beta.1`.

Ordering follows semantic versioning: `vX.Y.Z-rc.N` is older than `vX.Y.Z`, and
`-rc.N` numbers compare numerically (`-rc.2` is newer than `-rc.1`, and newer
than `-rc.10` is wrong — they compare as numbers, not as text). `make release`
refuses a version that is not newer than every existing release tag.

A plain `v0.3.0` publishes as a normal release. A suffixed `v0.3.0-rc.1`
publishes as a **pre-release**, so a build meant for testing does not become
the download the release page offers by default. One tag grammar, two
shelves.

## `make release`

```sh
make release VERSION=v0.3.0
```

This runs `scripts/release.sh`, which checks every precondition below, in
order, **before any tag exists**. The first one that fails exits 1 and leaves
no tag, locally or on the remote:

1. `VERSION` matches the pattern above.
2. The working tree is clean, untracked files included.
3. `HEAD` is an ancestor of `origin/main` (after `git fetch --tags`).
4. The tag does not already exist, locally or on `origin`.
5. `VERSION` is newer than every existing release tag (core's own `v0.0.x`
   tags are ignored).
6. `make check` passes.

It then creates an annotated tag and pushes it. If the push fails, the local
tag is deleted, so a failed `make release` never leaves a dangling tag.

| Variable | Default | Meaning |
|---|---|---|
| `RELEASE_REMOTE` | `origin` | The remote to fetch from and push the tag to. |
| `RELEASE_BRANCH` | `main` | The branch `HEAD` must be an ancestor of. |
| `RELEASE_CHECK_TARGET` | `check` | The make target run as the last precondition. |

That is the whole gesture. `release.yml` builds the tag once it is pushed.

## Setting this up on GitHub

Nothing above needs any repository setting: with none set, `release.yml`
still builds and smoke-tests the images (just does not push them) and builds
both desktop bundles without demo data. Someone with repository admin rights
can additionally set, all optional:

| To get | Set |
|---|---|
| Pushed images | Repository variable `REGISTRY`, secrets `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` (see the table below). |
| More than `linux/amd64` pushed | Repository variable `PLATFORMS`. |
| A seeded demo dataset in the desktop bundles | Repository variable `DATASET_REPOSITORY` and secret `DATASET_DEPLOY_KEY` (see "What a bundle says about itself" below). |

## What `release.yml` does

`release.yml` runs on a pushed tag that matches the release pattern:

1. **Version check.** The tag matches the pattern above and is on `main`
   (`git merge-base --is-ancestor HEAD origin/main`). A `-rc.N` tag is marked
   as a pre-release from here on.
2. **Full gate.** `full-check.yml`, the same gate `make ci` runs locally.
3. **Images.** `make package VERSION=<v>` builds `api`, `web`, and `worker`
   for `linux/amd64` (the runner's own platform), loaded into the local
   Docker image store.
4. **Smoke test.** `make smoke VERSION=<v>` (see below). Only the
   `linux/amd64` build is smoke-tested — it is the one loaded locally. If
   `PLATFORMS` names other platforms, they are pushed in the next step without
   a smoke test of their own; they share the `linux/amd64` layers through the
   build cache, but a foreign-platform runtime bug is not caught here.
5. **Push**, only when the repository variable `REGISTRY` is set. Logs in to
   the registry host with the secrets `REGISTRY_USERNAME` and
   `REGISTRY_PASSWORD` (password on standard input, never on a command line or
   in a log), removes the login on every exit, and pushes the images with tag
   `<v>` for every platform in `PLATFORMS`. The pushed image digests are
   written to an artifact (`margince-images-<v>`), not a job output — a job
   output is dropped by GitHub when it contains a secret's value, and an image
   name can contain the registry user name.
6. **Desktop bundles.** macOS (Apple silicon and Intel) and Windows, as today.
7. **GitHub Release.** Created after every job above passes, with both zips
   already attached. A `-rc.N` version is published as a pre-release. The
   notes list the core version, the instance commit, and the pushed image
   digests (or `images were not pushed: REGISTRY is not set`), read from the
   image-list artifact.

| Setting | Kind | Default | Effect |
|---|---|---|---|
| `REGISTRY` | repository variable | unset | The image name prefix, for example `docker.io/acme` or `myregistry.example.com/acme`. **Must start with the registry host** — `release.yml` logs in to `${REGISTRY%%/*}` (everything before the first `/`), so a value such as `acme/margince-default` with no host is not a usable registry prefix for this login. Unset: the images are built and smoke-tested, not pushed. |
| `PLATFORMS` | repository variable | `linux/amd64` | Comma-separated platforms of the *pushed* images, for example `linux/amd64,linux/arm64`. Only `linux/amd64` is smoke-tested (step 4 above), regardless of this list. |
| `REGISTRY_USERNAME` | secret | — | User name for `docker login` to the `REGISTRY` host. |
| `REGISTRY_PASSWORD` | secret | — | Password or token for `docker login`, piped to standard input. Never printed or logged. |

**An unverified release cannot exist on this lane**, because CI is the only
thing that creates one, and it creates it after the gate and the smoke test.
If the run fails, no release appears. Delete the tag and tag again once the
tree is fixed:

```sh
git push --delete origin v0.3.0 && git tag -d v0.3.0
```

Re-running a failed run after the release was already created is safe: the
publish step replaces the assets on the existing release rather than failing.

### Why CI can create this one

A release created by CI's own token does not fire the `release` event, so
publishing from inside the lane cannot retrigger anything — this lane
included. The trigger is the tag push and nothing else: there is exactly one
way a release comes into existence here, and it runs after the gate.

## `make smoke` locally

```sh
make package VERSION=v0.3.0
make smoke VERSION=v0.3.0
```

`make smoke` runs the same check `release.yml` runs, against images already
built by `make package` and present in the local Docker image store. It:

1. Starts a private Docker network, PostgreSQL (`pgvector/pgvector:pg16`), and
   Redis (`redis:7`) on it, with random, per-run passwords that never appear
   on a command line.
2. Runs core's database bootstrap (`core/scripts/deploy/db-bootstrap.sql`)
   once, as the superuser.
3. Starts `api` and waits until it answers `/readyz`.
4. Starts `worker` and `web`. `web` must answer `/`; `worker` must still be
   running after `SMOKE_SETTLE` seconds.
5. Removes every container and the network, on success and on failure. On
   failure it prints the last 100 log lines of each Margince container first.

| Variable | Default | Meaning |
|---|---|---|
| `SMOKE_TIMEOUT` | `180` | Seconds to wait for PostgreSQL, `api /readyz`, and `web /`, each. |
| `SMOKE_SETTLE` | `10` | Seconds the worker must stay running after start before the test passes it. |
| `REGISTRY` | unset | Registry prefix of the image names to smoke-test (Section 8 of [create-an-instance.md](create-an-instance.md)). |

No test here needs a license: the smoke test runs `api` with
`MARGINCE_ENV=test`, which does not require one.

## What a bundle says about itself

A zip name does not survive being unzipped, so every folder carries its own
record. `make desktop` writes both files through `scripts/build-info.sh`:

```
margince/
├── BUILD-INFO.txt          a person, asked to paste it into a bug report
└── runtime/
    └── build-info.json     a program
```

```
Margince v0.3.0

  built     2026-08-25T14:02Z
  platform  darwin/arm64
  repo      b287031
  core      45fc738
  dataset   0861f93

  units
    (one line per unit, name and version)
```

`repo` is this installation's commit, `core` the upstream it carries, `dataset`
the demo database it was seeded from, and the unit list is read from each
`extensions/*/manifest.generated.json` — so a bundle answers "which build, which
upstream, which units, which demo data" without a rebuild.

`dataset` earns its place for a reason the other two do not need: **the demo
database is deliberately not pinned.** Both desktop lanes check out the demo
dataset repository (`vars.DATASET_REPOSITORY`) with no `ref`, so every build
takes whatever its default branch was at that moment — a bundle ships the
freshest demo rather than a historical one. When `vars.DATASET_REPOSITORY` and
`secrets.DATASET_DEPLOY_KEY` are not set, the lane seeds nothing and the
bundle ships empty, keeping its demo loader. That is the intended behaviour,
and it is also why recording the commit is the only thing that can ever say
which data a given bundle holds. It has one consequence worth knowing:
re-running a release lane on an existing tag replaces the assets, so **the
same tag can ship different demo data**. The `dataset` line is what makes that
visible instead of silent.

It has three possible values, and the last two are not the same fact:

| value | meaning |
|---|---|
| a sha | seeded from that commit of the demo database |
| `none` | the folder ships no demo data, and keeps its demo loader |
| `unknown` | it ships demo data whose commit nobody recorded |

`unknown` should prompt a question. It means a seeded bundle was built by
something that did not pass `MARGINCE_BUILD_DATASET_SHA` — a lane that has
drifted from this contract — and reporting that as `none` would hide it.

The version comes from `VERSION=`, which a release lane sets to its tag. Left
unset — a developer's own `make desktop` — it falls back to `git describe`
against `v*` tags, then to `dev-<sha>`, and a build from an uncommitted tree is
marked `-dirty`. A tag that is not a `v*` version is deliberately not matched: it
names no version, and a build must not quote one as if it did.

The **commits** are measured by each lane and passed in, not read off the tree
when the folder is stamped. For `dataset` there is no alternative: by the time
the kit re-stamps a seeded folder the rows are inside a Postgres cluster, where
no commit is recoverable, so the lane reads it at checkout or the bundle can
never say. For the other two it is a correctness fix. A build can dirty its own tree:
`build-windows.ps1` regenerates the manifests of core's own units as a side
effect, which marks `core/` dirty and — because git reads a modified submodule
as a change to the parent's gitlink — this repository with it. Read at stamping
time, every Windows bundle said `-dirty` on both commits about sources nobody
had touched. A marker that fires on every build is one nobody reads.

`build-info.json` lives in `runtime/` and `BUILD-INFO.txt` beside `README.md`,
both of which an update replaces. A build-info file that survived an update
would name the version the user no longer runs.

Nothing inside the *binaries* carries the version: core's `desktop/build/` sets
no ldflags and the launcher has no version variable, so `margince --version`
does not exist. Changing that is a core contribution — see
[contributing-to-core.md](contributing-to-core.md).

## The desktop lanes on their own

`desktop-macos.yml` and `desktop-windows.yml` are reusable workflows, copied
from `core/.github/workflows/` because GitHub cannot `uses:` a file inside a
submodule. When core's versions change, re-derive ours from them rather than
patching blind. Both release lanes call them, so a shipped bundle is built by the
lane that has been exercised all along.

They do NOT run on pull requests. A pull request runs exactly what a merge to
main runs — the light gate — and nothing else. These lanes bill at ten times
(macOS) and twice (Windows) a Linux minute, roughly 109 Linux-equivalent minutes
per run against ~4 for the light gate, and the bundles are a release concern
rather than a merge concern.

To prove a lane without cutting a release, dispatch it:

```
gh workflow run desktop-windows.yml --ref main
```

A dispatched build names itself after the commit, because no lane gave it a
version.

The trade is deliberate: a broken bundle surfaces when a release is cut, not on
the pull request that broke it. Cutting one is a deliberate act somebody is
already watching, which is the right place to absorb that.

Locally, `make desktop` builds the macOS folder. There is no local Windows lane:
pgvector needs nmake against MSVC and the event bus needs MSYS2, so
`make desktop-win-kit DIR=` only stamps the demo-data loader into a folder built
on a Windows host. CI is that host.

See [desktop-build.md](desktop-build.md) for what to do with a built folder,
[license.md](license.md) for the license a production deployment needs, and
[deploy.md](deploy.md) for deploying a released image to a server.
