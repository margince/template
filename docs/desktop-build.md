# Building the desktop app

The self-contained macOS folder — Postgres, the event bus, api, worker, the web
UI and a launcher that supervises them — with the instance's units composed in.
No Docker, no prerequisites for whoever runs it.

```sh
make desktop
```

First run takes about five minutes, because it compiles a relocatable Postgres
from source. Later runs reuse it and take minutes.

Upstream owns the build itself. Read
[core/docs/how-to/build-the-desktop-app.md](../core/docs/how-to/build-the-desktop-app.md)
for what the folder contains, how to configure it, the update gesture and the
failure table; [the explanation](../core/docs/explanation/desktop-distribution.md)
for why it carries its own Postgres. This page covers only what is different
here, which is the parts that bite.

## Why this repo has its own `desktop` lane

`make desktop` here is `compose`, then core's own three stages, then a mirror out
of the submodule. Two reasons, both ours rather than upstream's: the folder has to
be built from a tree with our units staged into it, and core's `make clean` drops
`core/build/` wholesale, so the artifact is copied somewhere that survives.

It calls those stages directly instead of going through `make core-root-desktop`,
because that pattern rule re-**stages** and `compose` has just done it.

**This used to be a hard failure rather than a preference.** Until core commit
`50f57116`, `desktop/build/build-app.sh` installed only core's root pnpm
workspace, and a unit's frontend layer stopped being a member of it when
membership moved to the generated workspace under
`core/build/composition-frontend/workspace/`. So nothing resolved `react` or
`@tanstack/react-query` for a unit screen, and every frontend-bearing unit failed
the composed typecheck with `TS2307`. This lane carried the missing install
itself, between staging and `desktop-app`, which is a seam `core-root-desktop`
does not have.

Upstream installs that workspace now, and fails loudly if the composer did not
produce it, so the workaround is gone and the reason it existed is recorded here
rather than in the recipe.

## Where the output goes

| Path | What it is |
|---|---|
| `core/build/desktop/margince` | core's own output, ignored by `core/.gitignore` |
| `build/desktop/margince` | our mirror of it, ignored by `.gitignore` |

The mirror exists because core's `make clean` drops `core/build/` wholesale.
`make desktop-mirror` re-copies without rebuilding; `make desktop-clean`
removes both.

## It will not run from this checkout

macOS caps a unix-domain socket path at 103 bytes. The launcher puts the
database socket inside the installation folder and appends
`/data/sockets/.s.PGSQL.5432` — 27 bytes — so the folder's own path must be at
most 76. This checkout is 79 bytes before any of `build/desktop/margince` is
added, so **no location inside the repository can run**, and the mirror does not
help: it saves five bytes against a twenty-six byte deficit.

The launcher measures it and refuses, which is the good outcome — it says so
instead of failing as a database error:

```
the installation folder is too deeply nested: the database socket path would be
129 bytes and the system limit is 103.
```

So the build has to be installed somewhere short before it runs:

```sh
make desktop-install   # copy it to ~/Margince (DEST= to choose)
make desktop-run       # start it there, in the foreground
```

`desktop-install` measures the path the same way the launcher does and refuses
*before* copying 163 MB somewhere that cannot start. `DEST=~/M` and the like are
accepted; a path with whitespace in it is not, because the database socket
cannot carry one.

## Installing over an existing installation

`make desktop-install` on a folder that has already run is an **update**, and
implements upstream's update contract exactly: it replaces the launcher, the
starter script, the README, `BUILD-INFO.txt` and `runtime/`, and leaves `data/`,
`margince.yaml` and `margince.env` alone. Your database, your port, your API keys survive; a new
build of the code lands on top. It refuses while the installation is running —
quit it first, because its binaries are the ones being replaced.

That is also why rebuilding does not mean re-seeding: `make desktop` then
`make desktop-install` keeps the data you seeded.

## What a fresh install decides for you

`make desktop-install` does not write those files itself. It runs the
**`Setup.command` inside the folder**, the same script a downloader
double-clicks — `--no-prompt`, so an automated lane never blocks asking for a vendor
credential. There is one configuration path and developers and recipients both
run it, for the reason `make desktop-seed` already delegates to the loader beside
it: two spellings of the same config drift, and only one of them is the one
anybody tests.

Everything below is therefore what **`Setup.command`** decides, wherever it is
run from. All of it is write-once on the launcher's side too, and the api reads
it at boot, so anything left to the first run cannot be changed without a reset.

| Setting | Why |
|---|---|
| `workspace.base_currency: EUR` | the demo dataset is euro-based; USD cannot finish a seed |
| `bootstrap_admin.email: admin@demo.test` | the dataset names that admin, and the seeder replaces a password but never renames an account |
| `MARGINCE_KEYVAULT_ROOT_KEY` (`openssl rand -base64 32`) | without it every extension that stores a credential answers 500 — `extsecrets: no keyvault is configured` |
| `MARGINCE_CONNECTOR_STATE_KEY` (`openssl rand -hex 32`) | the Gmail and Calendar consent flows sign their state with it; below 32 characters the api refuses to mount them |
| `MARGINCE_WEBHOOK_KEY` (`openssl rand -base64 32`) | seals outbound webhook signing secrets at rest; without it the mutating `/webhook-subscriptions` paths (create/rotate, replay) answer 503 and the delivery worker's webhook consumer stays off |
| `MARGINCE_PUBLIC_BASE_URL` | the origin Google redirects back to |
| `seeds.ai_routing` | the tier→model binding, when a provider was chosen — see below |

**A provider key alone binds nothing, which is why `Setup.command` writes both.**
Nothing routes to a vendor until a *tier* is bound to it, and until then every AI
surface answers from the offline fake — plausibly, in canned text. So an
installation handed a perfectly good key was indistinguishable from one whose key
had been rejected, and the only place that said so was a comment in
`margince.env`. Picking a provider now also writes `seeds.ai_routing` into
`margince.yaml`, with the models the app's own onboarding would have offered
(`core/frontend/src/screens/setup-providers.ts` — they are the ids that carry a
price row, and one outside the sheet reports UNPRICED on every call).

That seed is consumed **once**, at workspace creation — which is a narrower
window than it sounds, and the cases that miss it are the common ones:

| Folder | Comes up bound? | Why |
|---|---|---|
| `make desktop` then `make desktop-install` | no | the lane runs `--no-prompt`, so no provider is chosen and no seed is written |
| a **release download** | **no** | it ships a seeded database, so its workspace was created on the build runner before the recipient ever ran `Setup` |
| a folder whose `data/` has been deleted, or one built with no dataset | yes | nothing has been bootstrapped, so the seed is read on the first start |

**So the folders people download do not come up bound**, and that is worth
stating plainly because the fix above reads as though they would. Their
workspace already exists, so the binding `Setup.command` writes into
`margince.yaml` is never read. Measured on `v0.1.1-rc.1`: Setup wrote the seed,
the app booted, `ai.routing` was absent and all 1842 `ai_call` rows were `fake`.

What a downloader gets instead is the other half, from core `d79f3b5ab`: the key
is **sealed** even with no binding present, so Settings → AI reports the vendor
as configured rather than unkeyed. Before that commit the same screen said the
key was not set, which is where the report that a "Gemini API key does not work"
came from.

**That was as far as it went until core `a0866edc5`, and the history is worth
keeping.** "Bind the tiers under Settings → AI" used to be impossible for a
recipient of these bundles: the screen rendered a form only for an installation
that already had tiers, and with none it named `seeds.ai_routing` — the file
that had already been ignored. The routes out were `PUT /v1/ai/routing` by hand
or deleting the demo database the folder exists to show.

Two upstream changes closed it, and the pinned core carries both:

| | |
|---|---|
| [#4856](https://github.com/margince/margince/pull/4856) | a declared binding is planted at boot wherever `ai.routing` is unset, insert-only — so a folder whose `margince.yaml` Setup wrote **comes up bound**, with no screen involved |
| [#4853](https://github.com/margince/margince/pull/4853) | Settings → AI can create a first binding from a keyed provider's presets — the answer for a folder that could not take a seed |

The second still matters, because one shape cannot take a seed: a folder whose
`margince.yaml` already exists when Setup runs. The Windows bundle is exactly
that — its lane runs `Setup.cmd` to seed and zips the result, so the file ships
with it. Setup says so and sends the reader to the screen, which now works.

`Setup.command` detects this case — `data/pg` exists before the first start only
if the cluster arrived in the download — and says so instead of claiming the
surfaces now answer on the key. It still writes the seed, because `data/` is what
the documented reset deletes and a rebuilt installation should come up bound.

Getting a seeded bundle to arrive already bound would mean binding it at build
time, and there is no provider key at build time to bind to. That is a design
question rather than a bug.

The timezone comes from the machine `Setup.command` runs on, which is why
`margince.yaml` is **not** stamped into the artifact the way `margince.env` is —
baking it at build time would give every recipient the build machine's zone.

`margince.env` IS stamped into the folder at build time, as the launcher's own
annotated template lifted from `desktop/launcher/envfile.go` rather than
restated, with every key line left commented for `Setup.command` to fill.
Windows gets neither the template nor the script: a stamped `margince.env` stops
the launcher writing its own, so a platform given the file without the script
that fills it would lose the keyvault key it has today rather than gain one.

`CURRENCY=` and `ADMIN_EMAIL=` override the first two. Nothing here happens on an
update: an existing value is yours, and rotating the keyvault key would strand
credentials already sealed with it.

## Seed it

`make seed-demo` does **not** seed a desktop installation. That lane is bound to
the dev stack: it reads `core/config/margince-admin-password`, defaults the API
to `:8080` and hands the seeder the compose MinIO. A desktop installation has
its own port, its own credentials and its own Postgres.

Its own lane, against a **running** installation:

```sh
make desktop-run                 # in one terminal, left running
make desktop-seed                # in another
make desktop-seed LIMIT=195      # skip a few companies; see the floor below
make desktop-verify              # the seeder's verify pass, writes nothing
make desktop-status              # where it is, whether it is up, how to sign in
```

The seeder itself is upstream's `tools/seed-demo` — the same tool `make
seed-demo` runs, and idempotent in the same way. What feeds it the four facts
that come from the installation rather than from this repo — the port from
`margince.env`, the sign-in address from `margince.yaml`, the password from
`data/admin-password`, and an owner DSN over `data/sockets` — is the loader
that now **ships inside the folder**. `make desktop-seed` runs that loader
rather than keeping a seeding path of its own, so the lane exercises exactly
what a downloader gets.

**`LIMIT=` buys almost nothing, and a small value fails.** `-limit N` truncates
the COMPANY list — the sorted `datasets/v1/siteresults/` directories — and
nothing else. Deals and contracts are seeded whole and resolve their company by
domain, so a limit that drops one they name stops the run outright:

```
seed-demo: deal d-akeneo names company "akeneo.com", which is not seeded
```

Measured against the current dataset: 198 companies, and the deepest one a deal
or contract references sits at position **193**. So `LIMIT` must be at least 193
— five companies of 198 — and `LIMIT=20` cannot work at all. Use it to shave a
little off, or not at all; it is not a way to get a small demo.

The fix belongs upstream, in the seeder: a limit that truncates one collection
and not the records pointing into it is a flag that cannot be used correctly
from the outside.

`DATASET=` keeps its meaning and still wins. Without it the loader prefers the
installation's own `data/demo`, and falls back to a checkout beside this repo —
which is where `make desktop-seed` has always looked.

## The loader that ships in the folder

`make seed-demo` needs this repository, a Go toolchain and a composed workspace.
Nobody who downloads a zip has any of the three. So `make desktop` also stamps a
**kit** into the folder:

| In the folder | What it is |
|---|---|
| `runtime/seed-demo` | the seeder, compiled — built through `build/composition/go.work`, so our units are linked in |
| `Load Demo Data.command` | the loader. Double-clickable; reads every fact from the folder it sits in |
| `README.md` | what a non-technical recipient reads: start it, copy the dataset in, load it, sign in |
| `data/demo` | where the dataset goes. Ships **empty** — see below |

Source is [`scripts/desktop-kit/`](../scripts/desktop-kit/); `make desktop-kit`
re-stamps without a full rebuild.

**The dataset never ships.** It is a private repository, and a folder anyone can
download is not where it belongs. `data/demo` arrives holding one note file
telling the recipient to copy the dataset in — the loader accepts either the
checkout's contents or the checkout itself dropped inside. `make
desktop-install` creates it when absent and never touches it when present: it
holds 63 MB the user copied by hand from a source an update cannot fetch again.

The folder therefore ships a `data/` where it previously shipped none, and that
had one consequence worth naming: the launcher creates `data/` at `0700`, but
`MkdirAll` leaves an existing directory's mode alone, so a shipped one arrives
at whatever the builder's umask and the recipient's unzip produced. On macOS
the filesystem IS the database's access control, so the kit sets `0700`
explicitly and `make desktop-install` re-asserts it on every install —
including on an installation that came from a download. (`data/sockets` keeps
its own `0700` from `resolveSocketDir` and never ships.)

It lives **inside `data/`** rather than beside it, because `data/` is the one
directory an update never replaces. Nesting makes that guarantee structural
instead of a rule `cmd_install` has to keep remembering — the dataset is
protected by the same line that protects the database.

The one thing that gets worse is the reset gesture: "delete `data/` and start
again", which the folder README gives for a currency mismatch, now sits on top
of the dataset. The README says to move it aside first, because nothing in the
download can fetch that copy back.

### Windows

Both shipped scripts are written for both platforms. `make desktop-win-kit
DIR=<folder>` stamps `Setup.cmd`, `runtime/setup.ps1`, `Load Demo Data.cmd`,
`runtime/load-demo-data.ps1`, `runtime/seed-demo.exe` and the launcher's
`margince.env` template into a Windows folder.

`Setup.cmd` omits `workspace.timezone`, where the macOS script writes one.
Windows does not name zones the way `margince.yaml` wants and the mapping lives
in CLDR data the stdlib does not carry — the launcher has the same limit, in
`desktop/launcher/platform_windows.go`. `deployconfig` validates the field only
when it is present, so leaving it out is a legal file rather than a wrong one.
Add an IANA name by hand before the first start if you want one.

It takes `DIR=` because this repository cannot produce that folder: upstream
builds it with PowerShell **on a Windows host** — pgvector has no build system
but nmake against MSVC, and Redis needs MSYS2 — so `make -C core desktop-win` is
not a lane that runs here. The seeder is the one half that does cross-build
(pure Go, `CGO_ENABLED=0`), which is why the kit can be stamped from macOS onto
a folder mounted here, or run on the Windows host after its own build.

Two things differ on Windows, both forced by the platform
(`core/desktop/launcher/postgres_windows.go`): there is no unix socket, so the
DSN is loopback TCP with a real password from `data\db-margince_owner-password`;
and that port is **ephemeral**, chosen on every launch and written to no
settings file. The one place it is recorded is the running cluster's own
`data\pg\postmaster.pid`, whose fourth line is the port — which is what the
Windows loader reads.

> **What is and is not verified on Windows.** The folder builds on a Windows
> runner, the kit stamps correctly, and `desktop-windows.yml` now holds every
> shipped `.ps1` to a real Windows PowerShell parser before zipping — so a
> syntax error cannot reach a downloader. Neither script has been *run* there:
> `ParseFile` proves only that the file reads, not that seeding or setup
> behave. That half needs a Windows host and a database.

Three things worth knowing before they surprise you.

**The seeder replaces the sign-in password.** A configured bootstrap account is
on `must_change_password` and refuses every write until the operator's
credential is really replaced, so seeding lands the account on the documented
`demo-password-123` — and `data/admin-password` is then **stale**. Nothing
rewrites that file; it is the launcher's record of what it generated.
`make desktop-status` and `make desktop-logins` probe which password actually
signs in and say so, and `make desktop-seed` finds the live one either way.

**The base currency has to be EUR, and it is decided before the first run.** The
demo dataset is euro-based: the seeder loads an fx rate for every non-EUR
currency it meets, and the api refuses a rate whose currency *is* the base one
("the rate is always 1"). The launcher's own default is USD, which fails the FX
phase — with `422 fx_rate_base_self`, after most of the dataset is already
written. `margince.yaml` is created once and never overwritten, and the
workspace is bootstrapped from it, so `make desktop-install` writes that file
itself on a **fresh** install, with `base_currency: EUR` and the launcher's
template otherwise. `CURRENCY=USD make desktop-install` if you want the
launcher's default; edit `margince.yaml` before the first run to change it by
hand. Never on an update — an existing file is yours.

An installation that has already booted on USD needs a fresh one, because the
workspace is already created:

```sh
rm -rf ~/Margince/data ~/Margince/margince.yaml ~/Margince/margince.env
make desktop-install
```

**Attachments and logos are the installation's own.** Object bytes go to
`data/blobs` through the blobstore's filesystem provider, so the demo needs no
service, no container and no credentials — which is the whole point of a review
build. The lane passes that directory to the seeder too, because the seeder
writes company logos itself through the same seam: same machine, same directory
the api reads. An installation whose `margince.env` names a real endpoint has
that used instead, so the seeder always writes where the api reads.

This assumes a core that carries the filesystem provider. Built against one
without it, `POST /v1/attachments` answers `501 not_implemented` and the seeder
stops at the documents phase, taking products, offers, surfaces, consent,
lifecycle, relationship types and the owner assignment with it. See
[Upstream](#upstream).

The owner DSN is not optional, which is why nothing exposes it as a flag:
without it the seeder silently skips teams, seats, finance links and facts, then
fails in the ownership pass with "no seats to own anything".

## Sign in

The sign-in screen says accounts come from your administrator and there is no
self-signup, which is correct and unhelpful when the accounts were made by a
seeder. So ask the installation:

```sh
make desktop-logins
```

```
  Sign in at http://127.0.0.1:8800

  admin
    admin@demo.test                  demo-password-123

  demo colleagues (password 1234)
    katharina.brandt@demo.test       Dr. Katharina Brandt
    markus.steiner@demo.test         Markus Steiner
    mailinh.nguyen@demo.test         Nguyễn Thị Mai Linh
    …
```

It reads the accounts out of the installation's own database and probes the
admin password against the live api, so it describes the installation in front
of you rather than a documented ideal — including an unseeded one, where it says
only that `make desktop-seed` creates the colleagues.

Where the values come from: `admin@demo.test` is `bootstrap_admin.email` in
`margince.yaml`; its password is `data/admin-password` before a seed and
`demo-password-123` after one. The colleagues' `1234` cannot be set through the
API at all — the contract floors a password at twelve characters and only sets
one through a single-use link — so the seeder writes the Argon2 hash directly,
which is the one place it writes SQL instead of calling the product.

## Look in its database

`make desktop-dsn` prints everything a client needs; `make desktop-psql` opens
the `psql` the installation ships, which is the one guaranteed to match its
server.

The part that catches people out: **there is no TCP listener.** The launcher
starts Postgres with `listen_addresses=''`, so the database is reachable only
through a socket in a `0700` directory — which is also why there is no password
to find, local socket auth being trust.

| | |
|---|---|
| host | `~/Margince/data/sockets` — a directory, not a hostname |
| database | `margince` |
| user | `margince_owner` (owns the tables), or `margince_app` (the runtime role, holding only the DML its grants name) |
| password | none |
| port | `5432`, on the socket only |

```sh
make desktop-psql
~/Margince/runtime/pgsql/bin/psql "postgres://margince_owner@/margince?host=$HOME/Margince/data/sockets"
```

TablePlus, Postico and DBeaver's socket option take that directory verbatim with
an empty password. A client that speaks TCP only needs a bridge, which exposes
the database on a local port for as long as it runs:

```sh
socat TCP-LISTEN:15433,reuseaddr,fork UNIX-CONNECT:$HOME/Margince/data/sockets/.s.PGSQL.5432
# then 127.0.0.1:15433, user margince_owner, no password
```

It is the live database of a running app. Read freely; a write is a write.

## The whole loop, from nothing

```sh
make desktop            # build (~5 min the first time)
make desktop-install    # copy it to ~/Margince
make desktop-run        # leave this running
make desktop-seed       # in another terminal
make desktop-logins     # who to sign in as
```

Swap `make desktop-run` for `make desktop-connect` to start it reachable by an
agent — see [Connect it to Claude](#connect-it-to-claude-or-chatgpt).

## Connect it to Claude (or ChatGPT)

```sh
make desktop-connect    # instead of make desktop-run
```

An installation can be a **remote MCP connector**: an agent signs in to it over
OAuth and then reads and writes records through the same tool surface the
product serves. Getting there needs three things, and none of them is optional.

**1. The deployment has to declare the connector.** `mcp.connector_enabled:
true` in `margince.yaml`. Without it the api mounts no `/mcp`, no authorization
server and neither discovery document — the whole route group is behind that one
flag (`core/backend/cmd/api/boot.go`, "Gate 1"). It is **off** in what the
launcher writes on a first run and in what `Setup.command` writes, so a desktop
installation serves 404 there until something turns it on.

**2. The api has to know its own public address.** `MARGINCE_PUBLIC_BASE_URL` in
`margince.env`. This is not advice: with the gate on and the value unset the api
**refuses to boot**. The OAuth audience and the advertised MCP resource are
derived from it and must never be read off a `Host` header, so there is nothing
sensible to default to.

**3. That address has to be genuinely reachable.** An agent runs on somebody else's
machine and cannot reach `127.0.0.1`. `make desktop-connect` opens a tunnel to
the app's port and uses *its* address for (2).

The order follows from (2): the api reads the address once, at boot, so the
tunnel is opened **before** the launcher starts. That is the whole reason this
is a wrapper around the start rather than something you turn on afterwards.

The launcher already proxies the connector's routes — `/mcp`, `/oauth` and
`/.well-known` are in its `apiPrefixes` list (`core/desktop/launcher/web.go`) —
so nothing in core needs changing for any of this. The three writes are the
work, and `scripts/desktop-kit/connect-claude.command` is where they live; the
lane delegates to the copy inside the installation, the way `make desktop-seed`
delegates to the loader.

### Why the address is rewritten on every start

The two discovery documents do not get their URLs from the same place, and the
split is the reason a stale `MARGINCE_PUBLIC_BASE_URL` breaks the connector
rather than merely aging.

`/.well-known/oauth-authorization-server` is **request-derived**: reached through
the tunnel it names the tunnel, because the launcher's reverse proxy passes the
`Host` header through untouched and ngrok sends `X-Forwarded-Proto: https`.
Nothing has to be configured for that half.

`/.well-known/oauth-protected-resource` is not. Its `resource` field is the
**configured** base with `/mcp` appended, on purpose — an MCP client checks that
the resource it was sent to is the resource the document names, and deriving it
from a header would let whoever controls the header decide. So the configured
value and the live tunnel have to be the same string, and the only way to
guarantee that is to write the address down at the moment the tunnel opens.

Verified against a throwaway install: with the connector on and the base URL set
to a tunnel-shaped address, `/mcp` answers

```
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer resource_metadata="https://<host>/.well-known/oauth-protected-resource", scope="read draft"
```

which is the challenge Claude follows to discover the authorization server,
register itself at `/oauth/register`, and start the consent flow.

### Which tunnel, and why cloudflared is the default

`MARGINCE_TUNNEL` in `margince.env` picks one; it is inferred as `ngrok` when
`NGROK_AUTHTOKEN` or `NGROK_DOMAIN` is set, and is `cloudflared` otherwise.

**cloudflared (default) — no account.** `cloudflared tunnel --url` opens a quick
tunnel with no signup, no token and no prompt. Verified from a clean machine with
`HOME` pointed at an empty directory: a real `https://….trycloudflare.com` that
served traffic. It is Apache-2.0, so unlike ngrok it *could* ship inside the
folder; it is still fetched on first use, because most installations never turn
this on and 38 MB in every download is a poor trade for the ones that do.

**ngrok — one free account, and a permanent address.** Worth knowing, because it
used to be otherwise: **ngrok v3 opens no anonymous tunnel.** v2 did; v3
authenticates the *session*, so it exits before any tunnel exists:

```
ERROR: authentication failed: This ngrok session is not authenticated.
ERROR: ERR_NGROK_4018
```

What the account buys is a **reserved domain** (`NGROK_DOMAIN`), which is the
only way to an address that survives a restart — and therefore the only way to
add the connector in Claude once instead of on every start. ngrok also shows its
own interstitial on a first browser visit; click through it, server-to-server
calls to `/mcp` never see it.

### What it costs

- **The address changes on every run** unless you have a reserved ngrok domain,
  so the connector has to be re-added in Claude each time.
- **The tunnel publishes the whole installation, not just `/mcp`.** It forwards a
  *port*, and that port is the launcher's single origin — the SPA at `/` plus the
  proxied api. It also has to: approving the agent is a browser sign-in on the
  public address, so the login page must be reachable there. Anyone with the URL
  reaches it. This is why the lane is separate from `make desktop-run` rather
  than folded into it.

### Windows

The same pair, stamped by the same kit: `Connect to Claude.cmd` at the folder
root and `runtime\connect-claude.ps1` beside the other scripts. It cannot be run
or parse-checked from a macOS checkout — see
[the Windows section above](#windows) — so CI is the only proof, and
`scripts/desktop-kit.test.sh` holds the source-level invariants the two halves
share.

## What this build is not

- **Not signed for distribution.** The binaries carry an ad-hoc signature, which
  is why they run on the machine that built them and nowhere else without
  Gatekeeper complaining.
- **Not universal.** Each folder is built for one architecture, and neither runs
  on the other's Mac — an Intel Mac given the Apple-silicon folder dies on
  `./margince` with `Bad CPU type in executable`, and Rosetta does not help
  because it translates x86_64 to arm64 and never the reverse. The release page
  therefore carries two, `apple-silicon` and `intel`. A local `make desktop`
  builds for whatever this machine is.
- **A proof of concept**, in upstream's own words. It boots, migrates, serves the
  UI and survives a restart; several surfaces are off by default.
- **Not the Windows folder.** That lane exists but must run on Windows; neither
  platform cross-builds the other.

## Upstream

Two changes this installation is waiting on, both found by running the lanes
above and both contributed from here (`make core-branch`, `make core-pr`):

- **A filesystem blobstore provider** (`MARGINCE_BLOBSTORE_PATH`), so the bundle
  holds attachments and logos in `data/blobs` with no object storage service.
  MinIO is AGPLv3 and awkward to redistribute inside a BUSL-1.1 product, so
  upstream bundles no S3 server — and a local S3 server would only be a hop on
  the way to the same local disk. **The desktop lanes here assume it**: it is
  committed and pushed on `core/`'s `feat/blobstore-filesystem-provider` branch
  and not yet merged, so a bundle built from the pinned core answers 501 on every
  attachment until a core release tag includes it and `make update-core
  REF=<tag>` picks it up.
- **The demo seeder sends a read-only `key` to `POST /v1/projects`**, so every
  seed stops at the projects phase — `make seed-demo` on the dev stack too, not
  only the desktop lane. Core made the server mint project keys (`1da94847`) and
  the seeder was not updated with it.

## Which build is this?

The folder says, in two files the kit stamps into it:

```
margince/
├── BUILD-INFO.txt          for a person
└── runtime/build-info.json for a program
```

```sh
cat ~/Margince/BUILD-INFO.txt
```

```
Margince v0.3.0

  built     2026-08-25T14:02Z
  platform  darwin/arm64
  repo      b287031
  core      45fc738

  units
    (one line per unit, name and version)
```

They exist because the zip's name is the only other record, and a name does not
survive being unzipped. Ask for this file first when someone reports a problem
with an installation you did not build.

`VERSION=` names the build:

```sh
make desktop VERSION=v0.3.0
```

Left unset it derives one — `git describe` against `v*` tags, then `dev-<sha>` —
and marks a build from an uncommitted tree `-dirty`. A release lane passes its
tag, so a downloaded folder names the release it came from. The rule lives in
`scripts/build-info.sh` and nowhere else.

Both files are replaced by an update, along with the programs they describe.
Nothing in the binaries themselves carries the version: that would need a change
to core's `desktop/build/`, which is a contribution rather than an edit here.

## Built in CI

All three folders are built by CI on every release, and downloadable from the
release page as `margince-macos-apple-silicon-<version>.zip`,
`margince-macos-intel-<version>.zip` and `margince-windows-<version>.zip`.

The two macOS folders come from ONE lane called twice, with an `arch` input that
selects the runner: `macos-latest` for Apple silicon, `macos-15-intel` for
Intel. Nothing cross-builds — every step compiles native to whatever runner it
lands on, which is why a second architecture costs a second runner and no code.
The Intel call is gated on the Apple-silicon one, because macOS bills at ten
times a Linux minute. That Intel runner has an end date: GitHub retires x86_64
on Actions in August 2027.

The Windows folder has no local lane at all — CI is the only place it is built.
Pushing a `v*` tag is what cuts a release; see [release.md](release.md).
