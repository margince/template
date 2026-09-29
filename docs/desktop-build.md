# Desktop build

This guide covers the desktop folder of an instance: a self-contained Margince
(PostgreSQL, the event bus, `api`, `worker`, the web UI, and a launcher) with
the instance's units, which runs without Docker. It covers building the macOS
folder with `make desktop`, installing, configuring, running, and seeding it,
the build information inside it, and the folders that CI builds for a release.
It is for the developer who builds or tests a desktop folder. Core owns the
build itself; see
[core/docs/how-to/build-the-desktop-app.md](../core/docs/how-to/build-the-desktop-app.md)
and [core/docs/explanation/desktop-distribution.md](../core/docs/explanation/desktop-distribution.md).
A trial bundle, a desktop folder with a trial license, is in
[trial.md](trial.md).

## 1. Prerequisites

- A Mac, Apple silicon or Intel. The folder is built for the architecture of
  the Mac that builds it. There is no local Windows build (Section 10).
- The Xcode Command Line Tools (`xcode-select --install`), because the first
  build compiles PostgreSQL and the event bus.
- An instance checkout on which `make install` has run.
- `curl`, used by the desktop targets to probe the running app.
- Optional: a local checkout of the demo dataset, to include the demo loader
  (Section 3.2).

## 2. Quick start

```sh
make desktop
make desktop-install
make desktop-run          # leave it running
make desktop-seed DATASET=<dataset-checkout>   # in a second terminal
make desktop-logins
```

Open the address that `make desktop-logins` prints and sign in with an account
it lists.

## 3. Build

```sh
make desktop VERSION=<v>
```

`make desktop` runs, in order:

1. `make compose`, so the build contains the instance's units.
2. Core's `desktop-deps`, `desktop-app`, and `desktop-dist` targets, which write
   the folder to `core/build/desktop/margince/`.
3. `make desktop-mirror`, which copies it to `build/desktop/margince/`.
4. `make desktop-kit`, which adds the files in Section 3.1 and the build
   information (Section 8).

The first build compiles PostgreSQL and takes about five minutes. Later builds
reuse it.

| Path | Content |
|---|---|
| `core/build/desktop/margince/` | Core's output, ignored by `core/.gitignore`. Core's `make clean` removes it. |
| `build/desktop/margince/` | The copy that the other desktop targets use, ignored by `.gitignore`. |

`make desktop-mirror` copies the folder again without a build.
`make desktop-clean` removes both folders.

### 3.1 Files the kit adds

`make desktop-kit` stamps the files from `scripts/desktop-kit/` into
`build/desktop/margince/`. `make desktop` runs it; run it alone after a change
to `scripts/desktop-kit/`.

| File in the folder | Content |
|---|---|
| `Setup.command` | Configures the folder before its first start (Section 4.1). |
| `Connect to Claude.command` | Starts the app behind a public tunnel address with the MCP connector on (Section 7). |
| `Load Demo Data.command`, `runtime/seed-demo` | The demo loader and the seeder it runs. Only when the demo dataset was available (Section 3.2). |
| `README.md` | Instructions for the person who receives the folder. |
| `margince.env` | The launcher's annotated settings template, from `core/desktop/launcher/envfile.go`, with every setting commented out. |
| `data/demo/` | An empty directory for the demo dataset, with a note file. Only when the folder is not seeded. |
| `BUILD-INFO.txt`, `runtime/build-info.json` | The build information (Section 8). |

`make desktop-kit SEEDED=1` stamps a folder whose database already holds the
demo data: it removes the loader, the seeder, and `data/demo/`, and the README
describes a seeded folder.

### 3.2 The demo loader

The seeder is built from the demo dataset checkout (`<dataset>/tools/seed-demo`),
not from core. Pass the checkout to include the loader:

```sh
make desktop VERSION=<v> DATASET=<dataset-checkout>
```

Without `DATASET`, the kit prints `kit: no demo dataset reachable, so this
folder ships no loader.` and the folder has no `Load Demo Data.command`. The
dataset itself never ships in the folder.

## 4. Install

```sh
make desktop-install
```

The folder cannot run inside the checkout. macOS limits a Unix socket path to
103 bytes, and the launcher's database socket is
`<folder>/data/sockets/.s.PGSQL.5432` (27 bytes), so the folder path can be at
most 76 bytes. `make desktop-install` copies the folder to `DESKTOP_DEST`
(default `~/Margince`), after it checks that path. It refuses a path that
contains whitespace or is too long.

```sh
make desktop-install DESKTOP_DEST=~/M
```

| Case | Result |
|---|---|
| `DESKTOP_DEST` has no `data/` (fresh install) | Copies the folder, including `data/demo/` when the build has one, and runs `Setup.command --no-prompt`. |
| `DESKTOP_DEST` has `data/` (update) | Refuses while the app is running. Replaces `margince`, the `.command` files, `README.md`, `BUILD-INFO.txt`, and `runtime/`. Keeps `data/` (including `data/demo/`), `margince.yaml`, and `margince.env`. Runs `Setup.command --no-prompt`, which keeps existing values. |

Both cases set the mode of `data/` to `0700` when it exists. An update keeps the database, so
a rebuild followed by `make desktop-install` keeps the seeded data.

### 4.1 What `Setup.command` writes

`make desktop-install` runs the folder's own `Setup.command` with
`--no-prompt`, the same script that a person who downloads the folder runs.
It writes `margince.env` and `margince.yaml`. Both files are read at the first
start, and `margince.yaml` is used once to create the workspace, so change them
before the first start.

| Setting | File | Value |
|---|---|---|
| `MARGINCE_KEYVAULT_ROOT_KEY` | `margince.env` | `openssl rand -base64 32`. Seals extension credentials and provider keys. |
| `MARGINCE_CONNECTOR_STATE_KEY` | `margince.env` | `openssl rand -hex 32`. Signs the Gmail and Calendar consent flows. |
| `MARGINCE_WEBHOOK_KEY` | `margince.env` | `openssl rand -base64 32`. Seals webhook signing secrets. |
| `MARGINCE_PUBLIC_BASE_URL` | `margince.env` | `http://127.0.0.1:<port>`, the port from `MARGINCE_PORT` (default 8800). |
| `workspace.base_currency` | `margince.yaml` | `CURRENCY`, default `EUR`. |
| `workspace.timezone` | `margince.yaml` | The Mac's time zone, else `UTC`. |
| `bootstrap_admin.email` | `margince.yaml` | `ADMIN_EMAIL`, default `admin@demo.test`. |
| `seeds.ai_routing` | `margince.yaml` | Only when a Gemini or OpenRouter key is set in `margince.env`: binds every tier to that provider. |

`Setup.command` never replaces a value that is already set, and never
overwrites an existing `margince.yaml`. Without `openssl`, it leaves the keys
unset and prints the commands to generate them. Run interactively (without
`--no-prompt`), it also asks for a model provider key and the Google OAuth
client ID and secret.

Keep the three keys. Without `MARGINCE_KEYVAULT_ROOT_KEY` every extension that
stores a credential answers 500. A changed `MARGINCE_KEYVAULT_ROOT_KEY` cannot
open the credentials sealed with the old key.

The demo dataset needs `base_currency: EUR`. A folder with another base
currency fails the seed with `422 fx_rate_base_self`. To use another currency:

```sh
CURRENCY=USD make desktop-install
```

To change `margince.yaml` after the first start, start over: stop the app, then
remove `data/`, `margince.yaml`, and `margince.env`, and install again. This
deletes the database and `data/demo/`; move the dataset out first.

```sh
rm -rf ~/Margince/data ~/Margince/margince.yaml ~/Margince/margince.env
make desktop-install
```

## 5. Run

```sh
make desktop-run
```

`make desktop-run` starts the app at `DESKTOP_DEST` in the foreground. Stop it
with Ctrl-C. It refuses when something already answers on the app's address,
and when `margince.env` names an object store (`MARGINCE_BLOBSTORE_ENDPOINT`)
that does not answer. By default, attachments and logos are stored in
`data/blobs/`.

| Command | Output |
|---|---|
| `make desktop-status` | The folder, the build, the address and whether the app runs, the sign-in email, the password that signs in, the database URL, and the log directory. |
| `make desktop-logins` | The address, the admin account and its password, and the demo accounts (password `1234`) from the database. |

The admin password is in `data/admin-password` until the first seed. The
seeder changes it to `demo-password-123`, and `data/admin-password` is not
updated. `make desktop-status` and `make desktop-logins` try both passwords
against the running app and show the one that signs in.

Logs are in `data/logs/` (`api.log`, `worker.log`, `postgres.log`, `bus.log`).

## 6. Seed demo data

`make seed-demo` seeds the development stack of `make dev`, not a desktop
folder. Use `make desktop-seed` with the app running:

```sh
make desktop-seed DATASET=<dataset-checkout>
make desktop-verify DATASET=<dataset-checkout>
```

`make desktop-seed` runs the folder's own `Load Demo Data.command`. The dataset
is `DATASET` when it is set, else a dataset copied into `<folder>/data/demo/`.
Without either, it refuses and names both options. It refuses when the folder
has no loader (Section 3.2).

| Variable | Meaning |
|---|---|
| `DATASET` | The demo dataset checkout. |
| `LIMIT` | Seeds only the first `LIMIT` companies. Deals and contracts are always seeded in full, so a `LIMIT` that leaves out a company they name stops the seed. |
| `SEED_ARGS` | Other seeder arguments, for example `-dry-run`. |
| `MARGINCE_SEED_PASSWORD` | The admin password, when neither `data/admin-password` nor `demo-password-123` signs in. |

`make desktop-verify` runs the seeder's verify pass and writes nothing.

## 7. Connect an AI agent

```sh
make desktop-connect
```

`make desktop-connect` starts the app like `make desktop-run`, through the
folder's `Connect to Claude.command`, so that an agent such as Claude can use
the app's MCP connector. Before it starts the app, the script:

1. Sets `mcp.connector_enabled: true` in `margince.yaml`.
2. Opens a tunnel to the app's port.
3. Writes the tunnel's address to `margince.env` as `MARGINCE_PUBLIC_BASE_URL`.

The `api` reads the address once at start, and refuses to start with the
connector on and no address, so the tunnel opens first.

| Setting in `margince.env` or the environment | Meaning |
|---|---|
| `MARGINCE_TUNNEL` | `cloudflared` (the default; no account) or `ngrok`. It is `ngrok` when `NGROK_AUTHTOKEN` or `NGROK_DOMAIN` is set. |
| `NGROK_AUTHTOKEN` | The ngrok token. ngrok opens no tunnel without an account. |
| `NGROK_DOMAIN` | A reserved ngrok domain. It is the only way to keep the same address across restarts. |

The tunnel address changes on every start unless `NGROK_DOMAIN` is set, so the
connector must then be added in the agent again. The tunnel exposes the whole
app, including its sign-in page, to anyone who has the address. Stop
`make desktop-connect` when you do not use it.

## 8. Build information

Each folder contains `BUILD-INFO.txt` (for a person) and
`runtime/build-info.json` (for a program), written by `scripts/build-info.sh`.
Ask for `BUILD-INFO.txt` first when someone reports a problem with a folder.

```
Margince <version>

  built     <UTC time>
  platform  darwin/arm64
  repo      <instance commit>
  core      <core commit>
  dataset   <dataset commit, none, or unknown>

  units
    <unit>  <version>
```

| Field | Source |
|---|---|
| version | `VERSION` when set. Else `git describe --tags --match 'v*' --dirty`, else `dev-<commit>`. |
| built | The build time in UTC. |
| platform | `darwin/arm64` or `darwin/amd64` from the building Mac; always `windows/amd64` for Windows. |
| repo | `MARGINCE_BUILD_REPO_SHA` when set, else the instance's short commit, with `-dirty` when tracked files outside `core/` differ from `HEAD`. |
| core | `MARGINCE_BUILD_CORE_SHA` when set, else the short commit of `core/`, with `-dirty` when tracked files differ. |
| dataset | `MARGINCE_BUILD_DATASET_SHA` when set. Else `unknown` for a seeded folder and `none` for a folder without demo data. |
| units | Each unit in `extensions/` with the version from its `manifest.generated.json`. |

A local `make desktop` without `VERSION` is named `dev-<commit>` or after the
nearest `v*` tag. Pass `VERSION=<v>` to name it. An update replaces both files.

## 9. CI builds

`release.yml` calls `desktop-macos.yml` twice (`arch: apple-silicon` on
`macos-latest`, `arch: intel` on `macos-15-intel`) and `desktop-windows.yml`
once, and attaches the zips to the GitHub Release
([release.md](release.md#8-desktop-bundles)):

| Zip | Built by |
|---|---|
| `margince-macos-apple-silicon-<v>.zip` | `desktop-macos.yml` |
| `margince-macos-intel-<v>.zip` | `desktop-macos.yml` |
| `margince-windows-<v>.zip` | `desktop-windows.yml` |

When the repository has the variable `DATASET_REPOSITORY` and the secret
`DATASET_DEPLOY_KEY`, each workflow checks out the dataset's default branch and
ships a seeded folder:

1. Builds the folder with `DATASET` set, so it has a loader.
2. Starts it, seeds it, and stops it.
3. Clears the sealed demo mailbox credentials (`credential_ref`), so that the
   recipient's own `MARGINCE_KEYVAULT_ROOT_KEY` seals them again at the first
   start.
4. Writes `demo-password-123` to `data/admin-password`.
5. Runs `make desktop-kit SEEDED=1` (or `make desktop-win-kit SEEDED=1`) with
   `MARGINCE_BUILD_DATASET_SHA`.

Without the variable and the secret, the folders ship without demo data and
keep their demo loader. The macOS workflow also checks with `lipo` that the
launcher is built for the requested architecture.

A seeded folder's workspace already exists, so the `seeds.ai_routing` that
`Setup.command` writes is not used. Bind the AI tiers in the app under
Settings, AI.

To build a folder without a release, start a workflow by hand:

```sh
gh workflow run desktop-macos.yml --ref main -f arch=intel
gh workflow run desktop-windows.yml --ref main
```

## 10. Windows

The Windows folder is built only by `desktop-windows.yml`, on a Windows
runner: core's `desktop/build/build-windows.ps1` needs MSVC and MSYS2. The
workflow runs `make compose` and the kit inside MSYS2.

`make desktop-win-kit DIR=<folder>` stamps a Windows folder built elsewhere. It
needs `DIR` and accepts `VERSION`, `DATASET`, and `SEEDED=1`. It adds
`Setup.cmd` and `runtime/setup.ps1`, `Connect to Claude.cmd` and
`runtime/connect-claude.ps1`, the `margince.env` template, the build
information, and, with a dataset, `Load Demo Data.cmd`,
`runtime/load-demo-data.ps1`, and `runtime/seed-demo.exe` (cross-built with
`CGO_ENABLED=0`).

| Difference on Windows | Effect |
|---|---|
| No Unix socket | The database listens on loopback TCP, on a port chosen at each start. The loader reads it from `data\pg\postmaster.pid` and the password from `data\db-margince_owner-password`. |
| No `workspace.timezone` | `Setup.cmd` omits it. Add an IANA time zone name to `margince.yaml` before the first start, or the app uses `UTC`. |
| Seeded in place | The workflow seeds the built folder, then removes `margince.yaml`, so the recipient's `Setup.cmd` writes a new one. |
| Files written without a byte-order mark | `setup.ps1` writes UTF-8 without a BOM, and removes a BOM that an earlier release wrote. |

`desktop-windows.yml` parses every shipped `.ps1` file with the Windows
PowerShell parser, and runs `setup.ps1` against a copy of the template to
check the files it writes. The loader and the connect script are not run in
CI.

## 11. Limits

- The binaries have an ad-hoc signature, not a Developer ID signature.
  `Setup.command` removes the macOS quarantine mark from a downloaded folder,
  and says so.
- Each folder runs only on the architecture it was built for. An Intel Mac
  cannot run the Apple silicon folder, and the reverse.
- Core describes the desktop build as a proof of concept; see
  [core/docs/explanation/desktop-distribution.md](../core/docs/explanation/desktop-distribution.md).

## 12. Commands

| Command | Effect |
|---|---|
| `make desktop` | Build the macOS folder with the units (`VERSION=`, `DATASET=`). |
| `make desktop-mirror` | Copy `core/build/desktop/margince/` to `build/desktop/margince/`. |
| `make desktop-kit` | Stamp the kit and the build information into `build/desktop/margince/` (`VERSION=`, `DATASET=`, `SEEDED=1`). |
| `make desktop-win-kit DIR=<folder>` | Stamp a Windows folder (`VERSION=`, `DATASET=`, `SEEDED=1`). |
| `make desktop-install` | Copy or update the folder at `DESKTOP_DEST` and run `Setup.command --no-prompt`. |
| `make desktop-run` | Start the app in the foreground. |
| `make desktop-connect` | Start the app behind a tunnel with the MCP connector on. |
| `make desktop-seed` | Seed the running app (`DATASET=`, `LIMIT=`, `SEED_ARGS=`). |
| `make desktop-verify` | Run the seeder's verify pass. |
| `make desktop-status` | Show the folder, the address, and how to sign in. |
| `make desktop-logins` | List the accounts and their passwords. |
| `make desktop-psql` | Open the folder's own `psql` on its database. |
| `make desktop-dsn` | Print how to connect a database client. |
| `make desktop-clean` | Remove both build folders. |
| `make trial` | Build a trial bundle ([trial.md](trial.md)). |

Every command that uses an installed folder takes `DESKTOP_DEST` (default
`~/Margince`).

### 12.1 The database

The macOS database has no TCP listener: PostgreSQL runs with
`listen_addresses=''` and accepts connections only on its socket in
`<folder>/data/sockets/`, a `0700` directory, without a password.

| Setting | Value |
|---|---|
| Host | `<folder>/data/sockets` (a directory) |
| Database | `margince` |
| User | `margince_owner` (owns the tables) or `margince_app` (the runtime role) |
| Password | none |
| Port | `5432`, on the socket |

`make desktop-psql` opens the `psql` in `runtime/pgsql/bin/`, which matches the
server. `make desktop-dsn` prints the URL, the keyword form, and a `socat`
command that bridges the socket to a local TCP port for a client that supports
only TCP. The database is the running app's live data.

## Related guides

- [trial.md](trial.md): a desktop bundle with a trial license.
- [release.md](release.md#8-desktop-bundles): the desktop bundles of a release.
- [troubleshooting.md](troubleshooting.md#7-desktop): desktop errors.
- [core/docs/how-to/build-the-desktop-app.md](../core/docs/how-to/build-the-desktop-app.md):
  core's desktop build, configuration, and failure table.
