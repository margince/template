# Trial

This guide covers `make trial VERSION=<v>`, which builds a desktop bundle that
runs in production mode with a trial license, for a client to evaluate
Margince on a laptop. It is for the developer who prepares a trial. It is the
one guide for trial bundles. Without a trial license, `make trial` builds
nothing; it never falls back to development mode.

## 1. Prerequisites

- A Mac (Apple silicon or Intel). `make trial` runs `make desktop`, which
  builds the macOS folder; see [desktop-build.md](desktop-build.md).
- A checkout on which `make install` has run, and `python3`.
- A trial license value, or access to the license service
  ([license.md](license.md)).
- Optional: a local checkout of the demo dataset named in `data.dataset` of
  `instance.yaml`, to ship a bundle that can seed itself (Section 5).

## 2. Build a trial bundle

With a trial license value:

```sh
MARGINCE_TRIAL_LICENSE=<jwt> make trial VERSION=v0.3.0
```

With a request to the license service:

```sh
MARGINCE_LICENSE_API=https://license.margince.example \
MARGINCE_ACCOUNT_TOKEN=<token> \
  make trial VERSION=v0.3.0
```

`make trial` does the following, in order:

1. Checks that `VERSION` is a release version and that the platform is
   supported.
2. Checks that `dist/trial/<name>-<v>-<platform>/` does not exist, unless
   `FORCE=1`.
3. Obtains the trial license with `scripts/license.sh trial`. Without one, it
   stops before the build.
4. Runs `make desktop VERSION=<v>`.
5. Copies `build/desktop/margince` to a staging directory.
6. Writes `MARGINCE_LICENSE` (the trial license) and `MARGINCE_ENV=production`
   into the bundle's `margince.env`. The launcher reads that file from its
   folder, and the value overrides its default `MARGINCE_ENV=dev`.
7. When `instance.yaml` sets `data.dataset`, writes its URL and ref to
   `data/demo/DATASET.txt`. The dataset itself is not fetched.
8. Writes `TRIAL.txt`: name, version, core version, platform, mode, the
   license expiry from the JWT's `exp` claim (`unknown` when it has none), and
   the dataset when set.
9. Moves the staged bundle to `dist/trial/<name>-<v>-<platform>/`.

The license is never printed and never passed on a command line.
`<platform>` is `macos-arm64` or `macos-x64`.

| Variable | Meaning |
|---|---|
| `VERSION` | Required. A release version (`vX.Y.Z` or `vX.Y.Z-rc.N`). |
| `FORCE` | `FORCE=1` replaces an existing output directory. Without it, an existing directory stops `make trial` before the license request. |
| `DATASET` | The path to a local checkout of the demo dataset, used by the desktop build to seed the bundle (Section 5). |
| `MARGINCE_TRIAL_LICENSE`, `MARGINCE_LICENSE_API`, `MARGINCE_ACCOUNT_TOKEN` | See [license.md](license.md#5-variables). |

## 3. Output

```
dist/trial/<name>-<v>-<platform>/
├── margince.env           MARGINCE_LICENSE, MARGINCE_ENV=production, and the launcher's settings
├── TRIAL.txt
└── data/demo/DATASET.txt  only when data.dataset is set
```

The rest of the folder is the desktop folder that `make desktop` builds.
`dist/` is ignored by git; a bundle holds a license and is never committed.

## 4. First start

macOS limits a Unix socket path to 103 bytes. The launcher's database socket
is `<root>/data/sockets/.s.PGSQL.5432`, so the bundle's path can be at most 76
bytes. A path inside the checkout is often longer. When it is, `make trial`
prints a note and a command to move the bundle:

```sh
mv dist/trial/<name>-<v>-<platform> ~/Trial
```

1. Move the bundle to a short path when `make trial` says so.
2. Start the launcher from that path, as
   [desktop-build.md](desktop-build.md) describes.

The bundle starts in production mode with the trial license in place.

## 5. Seed demo data

`make trial` does not clone `data.dataset`. The bundle has a demo loader only
when the desktop build could read the dataset. To ship a bundle with a demo
loader, pass a checkout:

```sh
git clone <dataset-url> <dataset-checkout>
git -C <dataset-checkout> checkout <ref>
make trial VERSION=v0.3.0 DATASET=<dataset-checkout>
```

When `data.dataset` is set but no `DATASET` was passed, `make trial` prints
the commands to seed the bundle by hand after its first start, and notes that
the bundle has no demo loader:

```sh
git clone <url> "<bundle>/data/demo/dataset"
git -C "<bundle>/data/demo/dataset" checkout <ref>
make desktop-seed DESKTOP_DEST="<bundle>" DATASET="<bundle>/data/demo/dataset"
```

`DESKTOP_DEST` must be the path the bundle runs from: `<bundle>`, or the new
path if you moved it. The default of `make desktop-seed`, `~/Margince`, is a
`make desktop-install` copy, not the trial bundle.

## Related guides

- [license.md](license.md): the trial license and the license service.
- [desktop-build.md](desktop-build.md): building, running, and seeding the
  desktop folder.
- [release.md](release.md): the desktop bundles of a release.
