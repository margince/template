# License

This guide covers Margince licenses: when a license is needed, how to obtain a
production or trial license with `scripts/license.sh`, and the license service
API that the script calls. It is for the developer or operator who deploys an
instance or builds a trial bundle. It is the one guide for licenses.

A license is a JWT that core reads from `MARGINCE_LICENSE`. It authorizes
running Margince core; there is no per-instance product. A license is never
committed and never printed. `scripts/license.sh` is the only script that
calls the license service.

## 1. When a license is needed

| Stage | Runtime mode | License |
|---|---|---|
| Development (`make dev`) | `MARGINCE_ENV=dev` | Not needed. |
| Smoke test (`make smoke`) | `MARGINCE_ENV=test` | Not needed. |
| Local stack (`make local-up`) | `MARGINCE_ENV=test`, or production when `MARGINCE_LICENSE` is set | Optional. |
| Trial bundle (`make trial`) | production | A trial license, written into the bundle. See [trial.md](trial.md). |
| Deployment (`make deploy`) | production, unless the environment sets `MARGINCE_ENV` to `dev` or `test` | A production license in `MARGINCE_LICENSE`. See [deploy.md](deploy.md#58-the-license-check). |

## 2. Prerequisites

- `python3` and `curl`.
- Either the license value itself, or access to the license service: its base
  URL (`MARGINCE_LICENSE_API`) and an account token
  (`MARGINCE_ACCOUNT_TOKEN`).

## 3. Obtain a production license

1. Request the license into a file:

   ```sh
   MARGINCE_LICENSE_API=https://license.margince.example \
   MARGINCE_ACCOUNT_TOKEN=<token> \
     make license OUT=production.license
   ```

2. Store the file's content as the `MARGINCE_LICENSE` secret of the
   environment that runs it: in the GitHub Environment for `deploy.yml`, or in
   the environment of `make deploy`. `deploy/<env>/secrets` lists the name
   `MARGINCE_LICENSE`.
3. Delete the local file, or keep it outside the repository. Do not commit
   it.

`make license OUT=<file>` runs `scripts/license.sh production <file>`.

## 4. Obtain a trial license

`make trial` calls `scripts/license.sh trial <file>` itself. To obtain a trial
license on its own:

```sh
MARGINCE_LICENSE_API=https://license.margince.example \
MARGINCE_ACCOUNT_TOKEN=<token> \
  bash scripts/license.sh trial trial.license
```

## 5. Variables

| Variable | Used for | Meaning |
|---|---|---|
| `MARGINCE_TRIAL_LICENSE` | `trial` | A trial license value. When set, it is written to the output file and no request is made. |
| `MARGINCE_LICENSE` | `production` | A production license value. When set, it is written to the output file and no request is made. It is also the name of the secret a deployment reads. |
| `MARGINCE_LICENSE_API` | both | The base URL of the license service, for example `https://license.margince.example`. Required for a request. |
| `MARGINCE_ACCOUNT_TOKEN` | both | The bearer token for the license service. Required for a request. Refused when it contains a control character. |

## 6. Behavior

| Condition | Result |
|---|---|
| `MARGINCE_TRIAL_LICENSE` (for `trial`) or `MARGINCE_LICENSE` (for `production`) is set | The value is written to the file. No request is made. |
| `MARGINCE_LICENSE_API` or `MARGINCE_ACCOUNT_TOKEN` is not set | Fails and names the missing variables. |
| The service cannot be reached | Fails with `license: cannot reach <url>`. |
| The service answers `201` with a license | The license is written to the file, and the expiry is printed when the answer has one. |
| The service answers `201` without a license | Fails. Nothing is written. |
| Any other answer | Fails with the HTTP status and the service's `error` message. Nothing is written. |

The file is always mode 600: the script writes a temporary file in the same
directory under `umask 077`, sets mode 600, and renames it over the target.
The license and the token are never printed, also not on an error. The token
reaches `curl` on standard input, not on the command line.

## 7. License service API

The Margince license service implements this API. The template defines the
contract and calls it; it does not implement the service.

```
POST {MARGINCE_LICENSE_API}/v1/licenses
Authorization: Bearer {MARGINCE_ACCOUNT_TOKEN}
Content-Type: application/json

{"kind": "trial" | "production", "instance": "<name>", "core": "<core tag>"}

201 {"license": "<JWT>", "expires_at": "<RFC 3339 time>"}
4xx {"error": "<message>"}
```

`instance` is `name` from `instance.yaml`. `core` is `core` from
`instance.yaml`, the pinned core release tag.

## Related guides

- [deploy.md](deploy.md): where a deployment reads `MARGINCE_LICENSE`.
- [trial.md](trial.md): the trial bundle that embeds a trial license.
- [release.md](release.md): the release a license runs with.
