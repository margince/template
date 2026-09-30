# Try Margince

This guide covers the all-in-one image: one Docker image that runs all of
your instance's Margince, and the install command that starts it. It is for
the instance owner, who builds the image and gives testers the command. The
testers are not developers: they paste one command, and it installs Docker
when it is missing, starts Margince, and opens it in the browser.

## 1. Limits

| Topic | Limit |
|---|---|
| Mode | Test mode (`MARGINCE_ENV=test`). The image never reads a license. It is not for production; use [deploy.md](deploy.md) for that. |
| Access | The tester's computer only: the port is published on `127.0.0.1`. |
| Protocol | Plain HTTP on `http://localhost:<port>`. |
| Systems | macOS, Windows (x64), Ubuntu 22.04 and 24.04. |
| Configuration | None. The container takes no environment variable, file, or flag. |

## 2. Prerequisites

- A checkout of your instance on which `make install` has run.
- Docker with Buildx.
- To push the image: `REGISTRY`, and an image repository that allows
  anonymous pulls, because testers do not log in.
- To include demo data: a checkout of the demo dataset that `data.dataset` in
  `instance.yaml` names.

## 3. Build the image

```sh
make aio VERSION=<v>
```

`make aio` builds `<repo>/all-in-one:<v>` from the `api`, `worker`, and `web`
images of `<v>`. `<repo>` is the one in [release.md](release.md). When one of
the three images is missing from the local image store, it runs
`make package VERSION=<v>` first.

| Variable | Default | Meaning |
|---|---|---|
| `VERSION` | none | The release version of the role images and the tag of the image. Required. |
| `DATASET` | unset | A checkout of the demo dataset. The image then loads it on its first start. |
| `PUSH` | unset | `PUSH=1` pushes the image instead of loading it, built from the pushed role images of `<v>`. Requires `REGISTRY`. |
| `REGISTRY` | unset | The registry prefix. |
| `REPO` | `<REGISTRY>/<name>` | Overrides the whole image repository. |
| `PLATFORMS` | unset | The platforms of the pushed role images (`make package` reads it too). A pushed image has the same platforms. |
| `AIO_PLATFORMS` | `PLATFORMS`, else `linux/amd64,linux/arm64` | The platforms of a pushed image. Each one must exist in the pushed role images. |
| `METADATA_FILE` | unset | Writes Buildx's metadata file, which records the pushed digest. |

The image contains:

- the binaries and the web app of the three role images;
- PostgreSQL 16 with pgvector, Redis, and nginx;
- the first-boot configuration from `deploy/production/config/margince.yaml`,
  with the admin `admin@localhost`, the MCP connector off, and email off. Other
  settings, such as the workspace name and currency, are kept. Without that
  file, the workspace is named after `display_name`, with `EUR` and `UTC`.

The demo dataset is included only when all of these are true:

1. `DATASET` is given, and the checkout has `datasets/v1/demo.json` and the
   seeder source `tools/seed-demo`.
2. The workspace's `base_currency` is `EUR`, because the dataset is
   euro-based.

Otherwise `make aio` prints a notice and builds the image without demo data.
An image with demo data contains the dataset's files. Push it only to a
registry whose readers may see the dataset.

## 4. Test the image on your computer

| Command | Function |
|---|---|
| `make aio-smoke VERSION=<v>` | Starts the image on a temporary volume, checks that it becomes healthy, serves the web app, hides `/readyz`, signs in as `admin@localhost`, and keeps its data over a restart. Removes everything at the end. |
| `make aio-up VERSION=<v>` | Runs the tester's install command with the local image: installs Docker when it is missing, starts Margince, prints the address and the sign-in, and opens the browser. |
| `make aio-logins` | Prints the address and the sign-in again. |
| `make aio-logs` | Prints the last 200 log lines. |
| `make aio-down` | Stops Margince. The data is kept. |
| `make aio-reset` | Deletes the container and its data, after you type `yes`. |

`make aio-smoke` waits at most `AIO_SMOKE_TIMEOUT` seconds (default 600) for
each start.

## 5. Give testers the command

1. Push the role images and then the image, for the same platforms. Testers
   on Apple silicon Macs need `linux/arm64`:

   ```sh
   export REGISTRY=<registry> PLATFORMS=linux/amd64,linux/arm64
   make package VERSION=<v> PUSH=1
   make aio VERSION=<v> PUSH=1
   ```

   `release.yml` does both for a release, with the platforms of the
   repository variable `PLATFORMS` (default `linux/amd64`).

2. Write the install scripts:

   ```sh
   make aio-scripts VERSION=<v>
   ```

   This writes `dist/aio/<v>/install.sh` (macOS, Ubuntu) and
   `dist/aio/<v>/install.ps1` (Windows), with the image name, the container
   name `margince-<name>`, and the volume name `margince-<name>-data` filled
   in.

3. Put the two files where testers can download them without logging in. A
   release of a public repository already has them when `REGISTRY` is set:
   `release.yml` then pushes the image, attaches both files to the GitHub
   release, and writes the commands into the release notes
   ([release.md](release.md)). Without `REGISTRY`, nothing is pushed and the
   release offers no install command. For a private repository, use any web
   server.
4. Send the tester the command for their system:

   | System | Command |
   |---|---|
   | macOS, Ubuntu | `curl -fsSL <url>/install.sh \| sh` |
   | Windows (PowerShell) | `irm <url>/install.ps1 \| iex` |

The same command starts Margince again after a restart of the computer, and
updates it when `<url>` serves the scripts of a newer version. The data is
kept.

Other actions:

| Action | macOS, Ubuntu | Windows (PowerShell) |
|---|---|---|
| Stop, keep the data | `curl -fsSL <url>/install.sh \| sh -s -- down` | `& ([scriptblock]::Create((irm <url>/install.ps1))) down` |
| Show the sign-in | `curl -fsSL <url>/install.sh \| sh -s -- logins` | `& ([scriptblock]::Create((irm <url>/install.ps1))) logins` |
| Print the log | `curl -fsSL <url>/install.sh \| sh -s -- logs` | `& ([scriptblock]::Create((irm <url>/install.ps1))) logs` |
| Delete Margince and its data | `curl -fsSL <url>/install.sh \| sh -s -- reset` | `& ([scriptblock]::Create((irm <url>/install.ps1))) reset` |

On Windows, `irm | iex` cannot pass an action, and the default execution
policy refuses to run a downloaded `install.ps1`, so the other actions use the
scriptblock form above. Add `--yes` on macOS and Ubuntu, or `-Yes` in the
scriptblock form on Windows, to answer the install question in advance, for
example where there is no terminal.

## 6. What the tester sees

1. When Docker is missing, the command asks before it installs it:

   | System | Installs |
   |---|---|
   | macOS | Docker Desktop for the Mac's architecture. Asks for the Mac password. |
   | Windows | Docker Desktop with `winget`. When WSL 2 is missing, it installs WSL 2 first and asks the tester to restart and run the command again. |
   | Ubuntu 22.04, 24.04 | Docker Engine from Docker's apt repository. Asks for the password. |
   | other systems | Nothing. The message names the system and Docker's install page. |

   Docker Desktop's subscription terms apply to the tester's organization.
2. Docker Desktop may ask the tester to accept its terms on its first start.
3. The first start of Margince takes a few minutes. The command waits at most
   10 minutes.
4. The command prints the address (`http://localhost:8080`, or the first free
   port up to 8099) and the sign-in, and opens the browser.
5. The tester signs in as `admin@localhost` with the printed password. The
   first sign-in asks for a new password.

With demo data, the first start also loads the dataset in the background.
After that, the admin signs in with `demo-password-123`, and the demo
colleagues with `1234`. The command's `logins` action lists them.

## 7. Data

The container keeps all data in one Docker volume, `margince-<name>-data`,
mounted at `/data`:

| Path | Content |
|---|---|
| `/data/postgres` | The database. |
| `/data/redis` | The event bus. |
| `/data/blobs` | Uploaded files. |
| `/data/secrets.env` | The installation's generated keys and admin password (mode 600). |
| `/data/.seeded` | Present after the demo data is loaded. |

Removing or updating the container keeps the volume. The `reset` action
deletes it.

## 8. Browsers

The image serves plain HTTP, so its nginx removes the `Secure` flag from the
session cookies. The session then works over `http://localhost` in every
browser, including browsers that do not treat `localhost` as a secure origin.

## Related guides

- [release.md](release.md): the role images and `release.yml`.
- [desktop-build.md](desktop-build.md): the desktop folder, which runs without Docker.
- [troubleshooting.md](troubleshooting.md#12-all-in-one-image): the messages of the image and the install command.
