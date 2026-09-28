# License

A license is a JWT that core accepts in `MARGINCE_LICENSE`. It authorizes
running Margince core; there is no per-instance product ("flavor"). It is
never committed and never printed. `scripts/license.sh` is the only script
that calls the license service.

| Stage | Runtime mode | License |
|---|---|---|
| Development (`make dev`) | `MARGINCE_ENV=dev` | Not required. |
| Trial (`make trial`) | Production | Trial license, written into the bundle. |
| Staging, production (`make deploy`) | Production | Production license, in the environment secret `MARGINCE_LICENSE`. |

## Variables

| Variable | Used for | Meaning |
|---|---|---|
| `MARGINCE_TRIAL_LICENSE` | `trial` | A trial license value, supplied by hand. When set, it is written to the output file directly; no request is made. |
| `MARGINCE_LICENSE` | `production` | A production license value, supplied by hand. When set, it is written to the output file directly; no request is made. Also the name of the environment secret a deployment reads it from (`deploy/<env>/secrets`). |
| `MARGINCE_LICENSE_API` | both | The base URL of the public Margince license service, for example `https://license.margince.example`. Required to request either kind of license. |
| `MARGINCE_ACCOUNT_TOKEN` | both | The bearer token for `MARGINCE_LICENSE_API`. Required to request either kind of license. Never printed; refused outright if it contains a control character. |

## `make license OUT=<file>`

```sh
MARGINCE_LICENSE_API=https://license.margince.example \
MARGINCE_ACCOUNT_TOKEN=<token> \
  make license OUT=production.license
```

Obtains a **production** license into `<file>` (`scripts/license.sh
production <file>`). Store it as the `MARGINCE_LICENSE` secret of the
environment that will run it — for the `host` adapter, as a line named in
`deploy/<env>/secrets`, with the value set on `make deploy` or in the
environment's GitHub Environment secrets (see
[deploy.md](deploy.md#deployyml)). Do not commit it.

`scripts/license.sh trial <file>` obtains a **trial** license the same way;
`make trial` calls it automatically (see [trial.md](trial.md)).

### Behavior

| Condition | Result |
|---|---|
| `MARGINCE_TRIAL_LICENSE` (for `trial`) or `MARGINCE_LICENSE` (for `production`) is set | That value is written to `<file>`. No request is made. |
| `MARGINCE_LICENSE_API` or `MARGINCE_ACCOUNT_TOKEN` is not set | Fails, naming the missing variable(s). |
| The service answers `201` | The license is written to `<file>` with mode 600; the expiry is printed. |
| Any other answer | Fails with the service's `error` message and the HTTP status; nothing is written. |

The license and the account token are never printed, including on an HTTP
error, and the output file is always created with mode 600 (a temporary file
under `umask 077`, forced to 600, then renamed over the target).

## API contract

Implemented by the Margince license service, not by this template. The
template defines this contract; it does not implement the service.

```
POST {MARGINCE_LICENSE_API}/v1/licenses
Authorization: Bearer {MARGINCE_ACCOUNT_TOKEN}
Content-Type: application/json

{"kind": "trial" | "production", "instance": "<name>", "core": "<core tag>"}

201 {"license": "<JWT>", "expires_at": "<RFC 3339 time>"}
4xx {"error": "<message>"}
```

`instance` is `name` from `instance.yaml`; `core` is `core` from
`instance.yaml` (the pinned core release tag).
