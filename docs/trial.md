# Laptop trial

`make trial VERSION=<v>` builds a **production-mode** desktop bundle with a
trial license, for a client to evaluate on a laptop. It never falls back to
development mode: without a trial license, nothing is built.

```sh
MARGINCE_TRIAL_LICENSE=<jwt> make trial VERSION=v0.3.0
```

or, to request one from the license service instead of supplying it by hand:

```sh
MARGINCE_LICENSE_API=https://license.margince.example \
MARGINCE_ACCOUNT_TOKEN=<token> \
  make trial VERSION=v0.3.0
```

## Steps

1. **License.** `scripts/license.sh trial` (see [license.md](license.md) for
   the variables). Fails before any build when no trial license is available.
2. **Build.** `make desktop VERSION=<v>` — the same desktop build
   [desktop-build.md](desktop-build.md) describes.
3. **Copy.** The built folder goes to
   `dist/trial/<name>-<v>-<platform>/`, where `<platform>` is `macos-arm64`,
   `macos-x64`, or `windows-x64`. `make trial` fails if the directory already
   exists, unless `FORCE=1` is given.
4. **License and mode.** `MARGINCE_LICENSE` (the trial license) and
   `MARGINCE_ENV=production` are written into the bundle's `margince.env`,
   which the launcher reads from the folder it runs in and overrides its own
   `MARGINCE_ENV=dev` default with. The license value is never printed and
   never passed on a command line.
5. **Dataset reference.** When `instance.yaml` sets `data.dataset`, its
   `<git-url>@<ref>` is written to `data/demo/DATASET.txt` inside the bundle
   — a reference, not a clone. The dataset itself is not fetched by `make
   trial`.
6. **`TRIAL.txt`.** Name, version, core version, platform, mode, and the
   license expiry (read from the JWT's `exp` claim; `unknown` if the license
   has no readable one).

| Variable | Meaning |
|---|---|
| `VERSION` | Required. A release version (`vX.Y.Z` or `vX.Y.Z-rc.N`). |
| `FORCE` | `FORCE=1` replaces an existing output directory. Without it, an existing directory stops the build before anything runs. |
| `DATASET` | Path to a local checkout of the dataset named in `data.dataset`, so the desktop build can seed it and ship a demo loader (see below). |

## Output

```
dist/trial/<name>-<v>-<platform>/
├── margince                  the launcher
├── margince.env               MARGINCE_LICENSE, MARGINCE_ENV=production, ...
├── TRIAL.txt
└── data/demo/DATASET.txt      only when data.dataset is set
```

## First start

Unzip and run the launcher (`docs/desktop-build.md` covers running it in
detail). It starts in production mode with the trial license already in
place — no separate license step for the person trying the bundle.

`make trial` builds straight into `dist/trial/<name>-<v>-<platform>/` inside
the checkout, and that path is routinely too long: the launcher's database
socket lives at `<root>/data/sockets/.s.PGSQL.5432`, and macOS caps a unix
socket path at 103 bytes, so the bundle's own root must be at most 76.
`make trial` checks this and, when the path is too long, prints a note and a
command to move the bundle somewhere short before the first start, the same
way `make desktop-install` does for an installed copy:

```sh
mv dist/trial/<name>-<v>-<platform> ~/Trial
```

Run the launcher from the new location, not the original.

## Seeding

A plain `make trial` has **no demo loader** unless a dataset checkout was
available to the desktop build at the time it ran — `make trial` itself does
not clone `data.dataset`; it only writes the reference. To ship a bundle that
can seed itself, pass a checkout of the dataset:

```sh
git clone <dataset-url> /path/to/dataset-checkout
git -C /path/to/dataset-checkout checkout <ref>
make trial VERSION=v0.3.0 DATASET=/path/to/dataset-checkout
```

When `data.dataset` is set but no such checkout was passed, `make trial`
prints the commands to seed the bundle by hand after the first start:

```sh
git clone <url> "<bundle>/data/demo/dataset"
git -C "<bundle>/data/demo/dataset" checkout <ref>
make desktop-seed DESKTOP_DEST="<bundle>" DATASET="<bundle>/data/demo/dataset"
```

`DESKTOP_DEST` must point at the trial bundle itself — where the launcher is
actually running from, which is `<bundle>` unless you moved it (see "First
start" above) — not `make desktop-seed`'s own default (`~/Margince`), which is
a separate `make desktop-install` copy that a trial bundle never uses.

and a note that the bundle ships without a demo loader in that case.
