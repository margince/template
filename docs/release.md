# Cutting a release

Two lanes, and which one runs is decided by what you did, not by a flag.

| You did | What runs | How long |
|---|---|---|
| Opened a pull request, or merged to `main` | `ci.yml` — the light gate, and only that | minutes |
| Pushed a **`v*` tag** | `release.yml` — the full gate, the images and their smoke test, both bundles, then it publishes the release | ~20 minutes |

One gesture cuts a downloadable build, and the tag says which shelf it lands on.
A plain `v0.3.0` ships. A suffixed `v0.3.0-rc.1` publishes as a pre-release, so a
build meant for testing does not become the download the release page offers by
default. One tag grammar, two shelves, one lane.

To exercise a bundle without publishing anything, dispatch `desktop-macos.yml`
or `desktop-windows.yml` directly — each takes a `ref` and uploads its folder as
a run artifact. That builds one platform and runs no gate, which is the trade
for needing no tag.

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

## Cutting a release

Tag a commit that is on `main`:

```sh
git tag -a v0.3.0 -m "Desktop build info"
git push origin v0.3.0
```

That is the whole gesture. `release.yml` then:

1. **checks the tag** — `vMAJOR.MINOR.PATCH`, optionally `-rc.N`, and refuses
   anything else in seconds rather than after twenty minutes of runner time;
2. **checks the commit is on `main`** — a release built from an unmerged commit
   is a release nobody reviewed;
3. runs the full gate;
4. **builds the role images** (`make package`, `linux/amd64`, loaded locally)
   and **smoke-tests them** (`make smoke`);
5. **pushes the images** when the repository variable `REGISTRY` is set, for
   every platform in `PLATFORMS`;
6. builds the macOS bundle on `macos-latest` and the Windows bundle on
   `windows-latest`, both stamped with the tag;
7. **creates the release**, with both zips already attached. The notes list
   the core version, the instance commit, and the image digests, or
   `images were not pushed: REGISTRY is not set`.

The image steps read these repository settings:

| Setting | Kind | Default | Effect |
|---|---|---|---|
| `REGISTRY` | variable | unset | Registry prefix of the image names. Unset: the images are built and smoke-tested, not pushed. |
| `PLATFORMS` | variable | `linux/amd64` | Comma-separated platforms of the pushed images, for example `linux/amd64,linux/arm64`. |
| `REGISTRY_USERNAME` | secret | — | User name for `docker login` to the `REGISTRY` host. |
| `REGISTRY_PASSWORD` | secret | — | Password or token for `docker login`, passed on standard input. |

`make smoke VERSION=<v>` runs the same smoke test locally, against images
built by `make package VERSION=<v>`. It starts PostgreSQL, Redis, `api`,
`worker`, and `web` on a private Docker network, waits until `api` answers
`/readyz` and `web` answers `/`, checks that `worker` is running, and removes
everything it started. `SMOKE_TIMEOUT` (seconds, default 180) bounds each wait.

**An unverified release cannot exist on this lane**, because CI is the only
thing that creates one and it creates it after the gate. Nothing to promote and
nothing to guard.

If the run fails, no release appears. Fix the tree, delete the tag, and tag
again:

```sh
git push --delete origin v0.3.0 && git tag -d v0.3.0
```

Re-running a failed run after the release was created is safe: the publish step
replaces the assets on the existing release rather than failing.

### Why CI can create this one

A release created by CI's own token does not fire the `release` event, so
publishing from inside the lane cannot retrigger anything — this lane included.
The trigger is the tag push and nothing else, which is what makes the guarantee
above hold by construction rather than by habit: there is exactly one way a
release comes into existence here, and it runs after the gate.

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
dataset repository (`vars.DATASET_REPOSITORY`) with no `ref`, so every build takes whatever
its default branch was at that moment — a bundle ships the freshest demo rather
than a historical one. That is the intended behaviour, and it is also why
recording the commit is the only thing that can ever say which data a given
bundle holds. It has one consequence worth knowing: re-running a release lane on
an existing tag replaces the assets, so **the same tag can ship different demo
data**. The `dataset` line is what makes that visible instead of silent.

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

See [desktop-build.md](desktop-build.md) for what to do with a built folder.
