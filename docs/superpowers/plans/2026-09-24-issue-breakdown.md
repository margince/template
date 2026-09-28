# Issue Breakdown

Source: [design specification](../specs/2026-09-24-client-instance-template-design.md), revised 2026-09-28.

**Target:** a new Margince instance can be created, developed, trialled,
released, and deployed using only the public template.

Each issue lists the scope, the completion criterion, and the dependencies.
All template issues are in `margince-template`.

## Template

| ID | Issue | Title | Scope | Done when | Depends on | Status |
|---|---|---|---|---|---|---|
| T1 | #1 | Import tooling | Copy and generalize the tooling; pin core `v0.0.2`. | `make install`, `make check`, `make dev` work on a fresh clone. | — | Done |
| T2 | #2 | `instance.yaml` and CLI | `instance.yaml`, Go CLI, `make check-instance`. | Invalid files fail `make check`. | T1 | Done |
| T3 | #3 | Neutral release and desktop scripts | `package.sh`, `desktop.sh`, `build-info.sh` without client values. | `make test-scripts` passes. | T2 | Done |
| T4 | #4 | `instance.mk` | `-include instance.mk` and its check. | A redefined target fails `make check`. | T1 | Done |
| T5 | #5 | Core pin by tag | `make update-core` accepts tags only. | A branch or commit is refused. | T2 | Done |
| T6 | #6 | Drift check | `.template-version`, `make check-template`. | An edited template-owned file fails `make check`. | T1 | Done |
| T9 | #9 | Deployment contract | `make deploy`, `deploy.yml`, four steps, `hook` adapter. | A failing verify rolls back. | T2 | Done |
| T11 | #11 | New instance | `make new-instance`, `make template-sync`. | A new instance passes `make check`. | T2, T6 | Done |
| T10 | #10 | Template CI and lifecycle test | Part 1: `make test-lifecycle`, `lifecycle.yml`. Part 2: release and `host` steps. | `lifecycle.yml` passes. | T7, T15 | Done |
| T13 | #19 | Public-ready template | Remove `flavor` and private references; `make check-public`; optional dataset source; `-rc.N` in `make deploy`. | `make check-public` passes and catches a planted reference. | — | Done |
| T7 | #7 | Release | `make release`, `make smoke`, `release.yml` images, smoke test, push to `REGISTRY`, GitHub Release. | Tests pass; the wiring test covers `release.yml`. | T13 | Done |
| T15 | #20 | `host` adapter | Single-server deployment with Docker Compose and Caddy; `DEPLOY_STATE_DIR`; `make host-bootstrap`. | `host.test.sh` covers every step. | T13 | Done |
| T16 | #21 | License client | `scripts/license.sh`, `make license`. | `license.test.sh` covers the behavior table. | — | Done |
| T8 | #8 | Laptop trial | `make trial`, `data.dataset`. | `trial.test.sh` passes; the bundle starts in production mode. | T16 | Done |
| T12 | #12 | Guides | Release, deploy, license, trial. | `make check-docs` passes. | T7, T8, T15, T16 | Done |
| T17 | — | Default setup | Generated instance keys and admin password (`host` adapter), persistent file storage, the license check, `make deploy-init`, `make local-up`/`local-down`/`local-admin-password`, the desktop kit's and `make smoke`'s webhook key. Design: [2026-09-24-client-instance-template-design.md](../specs/2026-09-24-client-instance-template-design.md#97-default-setup). Plan: [2026-09-29-default-setup.md](2026-09-29-default-setup.md). | `test-lifecycle` asserts `instance.env` after a host deploy; `test-scripts`, `test-cli`, `check-docs`, `check-public` pass. | T15 | Done |

## Outside the template

| ID | Repository | Issue | Title | Status |
|---|---|---|---|---|
| K1 | margince-constellation | #448 | Public license API for the template contract | Open. The template does not wait for it: licenses can be supplied by hand. |

Closed by the 2026-09-28 revision as not part of the public template: C1,
K2, K3, K4, D1, I1, R1, R2, R3.

## Order

```
T13 → T7, T15, T16   (independent)
T16 → T8
T7 + T15 → T10 part 2
all → T12
T15 → T17
```

Tracking issue: #14.
