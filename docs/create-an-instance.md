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
`.gitleaks.toml`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, and `docs/*.md`.
`.template-version` holds the one commit id of the template commit the
instance last merged. `make check-template` reads `.template-owned` from
that commit — not from the working tree — and fails if any listed path
differs from it, including an added or untracked file inside one of those
directories. Instance-owned paths (`instance.yaml`, `instance.mk`,
`extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`) are not checked
and are where the instance's own work goes.

## 4. Daily work

`make dev` runs the development stack with the instance's units composed.
`make new-unit NAME=<n>` scaffolds an extension in `extensions/<n>`. `make
check` runs the full quality gate, including `check-instance` (is
`instance.yaml` valid) and `check-template` (has the instance drifted from
the template).

## 5. Receiving template changes

```sh
make template-sync
```

This fetches the `template` remote, merges its `main` into the instance, and
records the merged commit in `.template-version`. `make check` (through
`make check-template`) then compares template-owned paths against that new
commit.

Conflict rule: for a template-owned path, keep the template's side —
`git checkout --theirs -- <path>` — since the instance must not diverge from
the template there. Finish the merge with `git commit`, then run
`make template-sync` again so it records the commit (the first run stops
before recording it, because a merge with conflicts is not a clean merge).

## 6. Upgrading core

```sh
make update-core REF=v0.0.3
```

`REF` must be a core release tag (`v0.0.x`); a branch or a bare commit is
refused, because `instance.yaml` can only record a tag. The command moves
`core/` to that tag and rewrites `core:` in `instance.yaml` to match. It also
refuses to run if `core/` carries work of its own (see
`docs/contributing-to-core.md`).

## 7. Instance-only targets

`instance.mk`, if present, is included by the template `Makefile` and holds
make targets only this instance needs — the template ships none. It may only
add targets, never redefine one the template already provides:
`make check-template` runs `scripts/check-instance-mk.sh` first, which
refuses an `instance.mk` that redefines a template target (make's own
"overriding recipe"/"overriding commands" warning, turned into a failure) or
that stops `make` from reading the Makefile at all (for example, a recipe
line missing its leading tab).

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
Each image carries the instance's git revision, core's git revision, and the
staged unit set as OCI labels (`docker inspect <repo>/api:<version> --format
'{{json .Config.Labels}}'`).
