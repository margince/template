# Create an instance

A client instance is a repository created from `margince-template` by
`make new-instance`. It shares the template's history, so template changes
merge into it later with `make template-sync`. This page covers creating one,
what it contains, and how it stays current with the template and with core.

## 1. Prerequisites

Run this from a checkout of `margince-template` with `make install` already
done: `new-instance.sh` runs `cli check` from `scripts/cli` to validate the
new instance's `instance.yaml`, which needs a working Go toolchain.

`PUSH=1` additionally needs the GitHub CLI (`gh`), authenticated with rights
to create repositories in the target organization.

The template tree must be clean (`git status --porcelain` empty) and must not
itself be an instance: `make new-instance` refuses to run inside a checkout
that already has a `.template-version` file.

## 2. Create

```sh
make new-instance NAME=acme DISPLAY_NAME="Acme"
```

| Variable | Required | Meaning |
|---|---|---|
| `NAME` | yes | The instance's short name. Must match `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters. Used in `instance.yaml`, the default `flavor`, and the default clone directory. |
| `DISPLAY_NAME` | yes | The instance's user-facing name. One line: a value containing a newline is refused, not silently folded. |
| `VENDOR` | no, defaults to `NAME` | The vendor segment of `flavor` (`<vendor>/margince`), used in image names (Section 8). |
| `DIR` | no, defaults to `../margince-<NAME>` | Where the new instance is created. Fails if the path already exists. |
| `PUSH` | no | `PUSH=1` creates a private GitHub repository and pushes the instance to it (`gh repo create <OWNER>/margince-<NAME> --private --source <DIR> --remote origin --push`). Without it, nothing is pushed anywhere; the instance exists locally only. |
| `OWNER` | no, defaults to `gradionhq` | The GitHub organization `PUSH=1` creates the repository in. |

Everything is validated before anything is created: `new-instance.sh` builds
the candidate `instance.yaml` and runs it through `cli check` first. If that
fails, nothing is created. If a later step fails (the clone, the submodule
checkout, or the commit), the half-created directory is removed rather than
left behind looking like a working instance.

On success, the new instance has a `template` remote pointing at this
template (no `origin`, unless `PUSH=1` added one), a single commit on `main`
adding `instance.yaml`, `.template-version`, and `README.md`, and `core/`
checked out at the tag the template currently pins. The command prints the
new directory and the next steps:

```
cd <dir> && make install && make dev
```

## 3. What the instance contains

Every path in the template is either template-owned or instance-owned
(design Section 6). The template ships the instance-owned paths empty or as
examples; an instance fills them in without ever touching a template-owned
path.

`.template-owned` lists the template-owned paths, one git pathspec per line
— `Makefile`, `scripts/`, `.github/workflows/`, `.githooks/`,
`.gitleaks.toml`, `.gitignore`, `.template-owned` itself, `AGENTS.md`,
`CLAUDE.md`, and `docs/*.md`.
`.template-version` holds the one commit id of the template commit the
instance last merged. `make check-template` reads `.template-owned` from
that commit — not from the working tree — and fails if any listed path
differs from it, including an added or untracked file inside one of those
directories. Instance-owned paths (`instance.yaml`, `instance.mk`,
`extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`) are not checked
and are where the instance's own work goes.

The root `.gitignore` is template-owned. Put an instance's own ignore rules
in a nested `.gitignore` inside an instance-owned directory (for example
`extensions/.gitignore` or `data/.gitignore`), or in `.git/info/exclude` for
rules that apply to one checkout only.

`make check-template` protects against honest drift: an edit made to a
template-owned path by mistake. It does not prevent a deliberate edit of
`.template-version`, which changes the commit it compares against.
Review changes to `.template-version` like any other change.

## 4. Daily work

`make dev` runs the development stack with the instance's units composed.
`make new-unit NAME=<n>` scaffolds an extension in `extensions/<n>`. `make
check` runs the full quality gate, including `check-instance` (is
`instance.yaml` valid) and `check-template` (has the instance drifted from
the template).

## 5. Receiving template changes

A fresh clone of an instance (for example from GitHub) has no `template`
remote, because `git clone` creates `origin` only. Add it once per clone:

```sh
git remote add template git@github.com:gradionhq/margince-template.git
```

Then run:

```sh
make template-sync
```

This fetches the `template` remote, merges its `main` into the instance, and
records the merged commit in `.template-version` in the merge commit
(`chore: merge template <short> and record it`). `make check` (through
`make check-template`) then compares template-owned paths against that new
commit. If nothing changed, it reports `already at template commit`.

The sync applies the following rules:

| Case | Action |
|------|--------|
| The template pins a different core commit | The instance keeps its own `core` gitlink and `core/` checkout. The sync prints the template's pin. Run `make update-core REF=<tag>` to follow it. |
| Conflict on an instance-owned path (`instance.yaml`, `instance.mk`, `README.md`, `.template-version`, `extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`) | The instance's side is kept. |
| Conflict on a path listed in the template's `.template-owned` | The template's side is taken. |
| Conflict on any other path | The sync stops. The merge stays in progress and `.template-version` is not written. Resolve the paths, finish the merge with `git commit`, then run `make template-sync` again. |
| The template changed `instance.yaml` or `README.md` | The sync prints `git diff <old> <target> -- <file>` so the change can be reviewed and applied by hand. |

## 6. Upgrading core

```sh
make update-core REF=v0.0.3
```

`REF` must match `^v[0-9]+\.[0-9]+\.[0-9]+$` (`v0.0.3`, not `main`, a bare
commit, or a non-release tag such as `archive/pr100-salvage`), because
`instance.yaml` can only record a release tag. The command moves `core/` to
that tag and rewrites `core:` in `instance.yaml` to match. It also refuses to
run if `core/` carries work of its own (see `docs/contributing-to-core.md`).

Commit the bump as its own reviewable change:

```sh
git commit core instance.yaml -m "core: bump to <tag>"
```

## 7. Instance-only targets

`instance.mk`, if present, is included by the template `Makefile` and holds
make targets only this instance needs — the template ships none. It may only
add targets, never redefine one the template already provides:
`make check-template` runs `scripts/check-instance-mk.sh` first, which
refuses an `instance.mk` that redefines a template target (make's own
"overriding recipe"/"overriding commands" warning, turned into a failure) or
that stops `make` from reading the Makefile at all (for example, a recipe
line missing its leading tab).

`instance.mk` may assign only variables whose names start with `INSTANCE_`
(for example `INSTANCE_LAB_DIR := lab`). An assignment to any other variable,
such as `CORE := elsewhere` or `override VERSION = 1`, would change what the
template's targets do, so `scripts/check-instance-mk.sh` refuses it and names
the variable.

## 8. Image names

```sh
make package
REGISTRY=myregistry.example.com make package
```

`make package` builds the `api`, `web`, and `worker` images from core's
`docker-bake.hcl`, with the instance's units staged in. The image repository
is the instance's `flavor` from `instance.yaml` (`<vendor>/margince`),
prefixed with `REGISTRY` when it is set:

- `REGISTRY` unset: `<vendor>/margince/api`, `/web`, `/worker`.
- `REGISTRY=myregistry.example.com`:
  `myregistry.example.com/<vendor>/margince/api`, `/web`, `/worker`.

`REGISTRY` is supplied at build time; it is not stored in `instance.yaml`.
Each image carries the instance's name and git revision, core's git
revision and release tag (`com.margince.core.version`, from `core:` in
`instance.yaml`), and the staged unit set as OCI labels (`docker inspect <repo>/api:<version> --format
'{{json .Config.Labels}}'`).

## 9. Deploy

Add an environment under `deploy:` in `instance.yaml`:

```yaml
deploy:
  staging:
    adapter: hook
```

The environment name must match `^[a-z0-9]+(-[a-z0-9]+)*$`. The only adapter
available today is `hook`; `adapter: d13` is refused with a message naming
issue D1 until that adapter exists. `make check-instance` fails if an
environment has no matching `deploy/<env>/` directory.

### Hook layout

The `hook` adapter runs the instance's own scripts, under
`deploy/<env>/hooks/`:

```
deploy/staging/
└── hooks/
    ├── apply.sh       required
    ├── preflight.sh   optional
    ├── verify.sh      optional
    └── rollback.sh    optional
```

Each script runs under `bash`, so it does not need the executable bit.
`apply.sh` is required — `make deploy` refuses to run if it is missing. The
other three are optional: a step with no script is reported as skipped, not
as failed.

Example `apply.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail
echo "deploying $IMAGE_API"
echo "deploying $IMAGE_WEB"
echo "deploying $IMAGE_WORKER"
# ... pull and run the images on the target host
```

`deploy/<env>/` holds configuration values only — hostnames, replica counts,
the names of required secrets — never secret values. Hooks read secret
values from the environment (see the variable table below, and "Running
`deploy.yml`" for where those values come from in CI).

### Step order and failure rules

```
preflight → apply → verify
```

A failed `preflight` stops the deployment immediately: nothing has changed,
so there is no rollback. A failed `apply` or `verify` runs `rollback.sh`, and
the deployment still fails (non-zero exit) whether or not the rollback
succeeds. If the environment has no `rollback.sh`, `make deploy` prints
`no rollback hook` and exits non-zero without attempting one — the
environment may be half-deployed.

### Variables

Each hook script runs with the following environment variables:

| Variable | Set for | Value |
|---|---|---|
| `DEPLOY_ENV` | every step | The environment name (`ENV=`). |
| `DEPLOY_VERSION` | every step | The release being deployed (`VERSION=`). |
| `DEPLOY_STEP` | every step | The step's own name (`preflight`, `apply`, `verify`, `rollback`). |
| `DEPLOY_DIR` | every step | Absolute path of `deploy/<env>/`. |
| `INSTANCE_NAME` | every step | `name` from `instance.yaml`. |
| `IMAGE_REPO` | every step | The image namespace (Section 8). |
| `IMAGE_API`, `IMAGE_WEB`, `IMAGE_WORKER` | every step | `$IMAGE_REPO/api:$DEPLOY_VERSION`, `/web`, `/worker`. |
| `DEPLOY_FAILED_STEP` | `rollback` only | The step that failed (`apply` or `verify`). |

### Running locally

```sh
make deploy ENV=staging VERSION=v1.2.3
```

This runs `bash scripts/deploy.sh staging v1.2.3`: it validates `ENV` and
`VERSION`, reads the adapter for `staging` from `instance.yaml`, and runs the
steps above with hook scripts reading secrets already present in your shell
environment.

### Running `deploy.yml`

`.github/workflows/deploy.yml` is a manually triggered workflow
(`workflow_dispatch`, with `environment` and `version` inputs) that runs
`make deploy` in the GitHub Environment named by `environment`. Create that
environment ahead of time (repository Settings → Environments), with
whatever protection rules and secrets it needs — the workflow does not
create one.

GitHub resolves the job's `environment:` (and, for a name it does not
recognize, may auto-create one) before any step runs — including before the
workflow's own "Environment name is valid" step. That step still stops the
job before any secret is exported or any hook runs, but it cannot undo an
environment GitHub already resolved or created for that run. This is why
every environment a deployment might target must be created ahead of time,
with its own protection rules: an environment that does not yet exist gets
no protection rules by being auto-created this way.

The workflow validates `environment` against `^[a-z0-9]+(-[a-z0-9]+)*$`
before doing anything else, so a malformed or unknown name stops the job
before any secret is exported or any hook runs. Every secret of the
resolved environment is then exported to the job as an environment variable
of the same name, so hooks can read it with `$NAME`; secret values never
live in the repository or in `deploy/<env>/`. A secret's name is exported
only if it matches `^[A-Z_][A-Z0-9_]*$` and is none of the following:

- the exact names `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `BASH_ENV`,
  `NODE_OPTIONS`
- a name with one of the prefixes `LD_`, `DYLD_`, `GITHUB_`, `RUNNER_`,
  `ACTIONS_`, `GIT_`

`github_token` is never exported (it is excluded before this filter runs,
and is lower-case, so the pattern above would reject it anyway). A skipped
secret's name is printed to the log; its value never is. Checkout runs with
`persist-credentials: false`, so no push credential for the repository is
left on disk for a hook to find.
