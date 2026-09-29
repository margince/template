# Create an instance

This guide covers the life of your instance repository: creating it from
the template with `make new-instance`, what it contains, receiving template
changes with `make template-sync`, upgrading core with `make update-core`, and
adding instance-only `make` targets. It is for the developer who sets up and
maintains an instance. An instance shares the template's git history, so
template changes reach it by merge.

## 1. Prerequisites

- A checkout of `margince/template` on which `make install` has run.
  `make new-instance` validates the new `instance.yaml` with the Go CLI in
  `scripts/cli` and checks out `core/` from the template's own `core/`.
- A clean template working tree: `git status --porcelain` prints nothing.
- The checkout is the template, not an instance: `make new-instance` refuses
  to run where a `.template-version` file exists.
- For `PUSH=1`: the GitHub CLI (`gh`), signed in with the right to create
  repositories in the target owner.

## 2. Create the instance

1. Run `make new-instance` in the template:

   ```sh
   make new-instance NAME=acme DISPLAY_NAME="Acme"
   ```

2. Go to the new directory and install it:

   ```sh
   cd ../margince-acme
   make install
   ```

| Variable | Required | Meaning |
|---|---|---|
| `NAME` | yes | The instance's short name. Must match `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters. Used in `instance.yaml`, the image names, the bundle names, and the default directory. |
| `DISPLAY_NAME` | yes | The user-facing name. One line; a value with a line break is refused. |
| `DIR` | no | Where the instance is created. Default: `../margince-<NAME>`, next to the template checkout. Fails if the path exists. |
| `DOMAIN` | no | `HOST_DOMAIN` of the `production` environment. Default: empty, to fill in later. |
| `SSH` | no | `HOST_SSH` (`user@host`) of the `production` environment. Default: empty, to fill in later. |
| `ADMIN_EMAIL` | no | The first admin email of the `production` environment. Default: `admin@<DOMAIN>` when `DOMAIN` is given, otherwise the placeholder `admin@example.com`. |
| `PUSH` | no | `PUSH=1` runs `gh repo create <OWNER>/margince-<NAME> --private --source <DIR> --remote origin --push`. Without it, nothing is pushed. |
| `OWNER` | with `PUSH=1` | The GitHub user or organization that owns the new repository. There is no default. |

`make new-instance` does the following:

1. Checks the variables, the clean working tree, and that `DIR` does not
   exist.
2. Prints a notice, and continues, when the template's `HEAD` is not on
   `origin/main`.
3. Builds the new `instance.yaml` (`name`, `display_name`, `core`) and
   validates it with `cli check`. Nothing is created before this step passes.
4. Clones the template into `DIR`, removes the `origin` remote, and adds a
   `template` remote with the template's `origin` URL (or its local path when
   it has no `origin`).
5. Checks out `core/` at the commit the template pins.
6. Writes `instance.yaml`, `.template-version` (the template commit), and a
   new `README.md`.
7. Replaces `deploy/` with a new `deploy/production/` from
   `make deploy-init ENV=production ADAPTER=host`, for the instance's own
   `display_name` and the given `DOMAIN`, `SSH`, and `ADMIN_EMAIL`.
8. Commits these files as one commit on `main`.
9. With `PUSH=1`, creates the GitHub repository and pushes to it.

If a step before the commit fails, the new directory is removed. A failed push
in step 9 leaves the committed instance in place; push it as Section 3
describes. Without `PUSH=1` the command prints the next steps:
`cd <dir> && make install && make dev`.

## 3. Push an existing instance to GitHub

Without `PUSH=1`, the instance has no `origin`. Create an empty repository,
then add it and push:

```sh
git remote add origin <repository-url>
git push -u origin main
```

A fresh clone of the instance has an `origin` but no `template` remote. Add it
once per clone before you run `make template-sync`:

```sh
git remote add template <template-url>
```

## 4. What the instance contains

Every path is either template-owned or instance-owned. `.template-owned` lists
the template-owned paths, one git pathspec per line: `Makefile`, `scripts/`,
`.github/workflows/`, `.githooks/`, `.gitleaks.toml`, `.gitignore`,
`.template-owned`, `AGENTS.md`, `CLAUDE.md`, and `docs/*.md`. Every other path
is instance-owned. Make changes to template-owned paths in `margince/template`
and merge them with `make template-sync`.

| Path | Content |
|---|---|
| `instance.yaml` | `name`, `display_name`, `core`, an optional `data.dataset` (`<git-url>@<ref>`), and `deploy:`. `make check-instance` refuses unknown keys. |
| `.template-version` | The one template commit the instance last merged. |
| `README.md` | The instance's own README, written by `make new-instance`. |
| `extensions/` | Extension units. A directory here is an enabled unit. See [adding-an-extension.md](adding-an-extension.md). |
| `config/` | Local configuration created by `make config`. |
| `data/` | Demo dataset references. |
| `deploy/<env>/` | One directory per deployment environment. See [deploy.md](deploy.md). |
| `docs/client/` | Client documentation. |
| `instance.mk` | Optional instance-only `make` targets (Section 8). |

`make check-template`, which `make check` runs, reads `.template-owned` from
the commit in `.template-version`, not from the working tree. It fails when a
listed path differs from that commit, including an added or untracked file
inside a listed directory. It fetches the commit from `origin` when a shallow
checkout lacks it. It does not detect a deliberate edit of
`.template-version`; review changes to that file like any other change.

The root `.gitignore` is template-owned. Put instance ignore rules in a
`.gitignore` inside an instance-owned directory (for example
`extensions/.gitignore`), or in `.git/info/exclude` for one checkout only.

## 5. Daily work

| Command | Function |
|---|---|
| `make dev` | Run the development stack with the instance's units. |
| `make new-unit NAME=<name>` | Create a unit in `extensions/<name>`. |
| `make u NAME=<unit>` | Run one unit's tests and the policy gates. |
| `make check` | Run the full gate, including `check-instance` and `check-template`. |

See [adding-an-extension.md](adding-an-extension.md) for the unit workflow.

## 6. Receive template changes

1. Commit or discard local changes. `make template-sync` refuses a working tree
   with changes.
2. Run the sync:

   ```sh
   make template-sync
   ```

3. Read the messages it prints, and review each file it names.
4. Run `make check`.

`make template-sync` fetches `main` from the `template` remote, merges it, and
writes the merged commit to `.template-version` in the merge commit
(`chore: merge template <short> and record it`). When there is nothing to
merge it prints `already at template commit <short>`. `TEMPLATE_REMOTE`
(default `template`) and `TEMPLATE_BRANCH` (default `main`) select another
remote or branch.

| Case | Result |
|---|---|
| The template pins a different core commit | The instance keeps its own `core` pin. The sync prints the template's pin and the `make update-core REF=<tag>` command that follows it. |
| Conflict on an instance-owned path (`instance.yaml`, `instance.mk`, `README.md`, `.template-version`, `extensions/`, `config/`, `data/`, `deploy/`, `docs/client/`) | The instance's side is kept. |
| Conflict on a path in the template's `.template-owned` | The template's side is taken. |
| Conflict on any other path | The sync stops with the merge in progress and does not write `.template-version`. Resolve the paths, run `git commit`, then run `make template-sync` again. |
| The merge adds a file under `deploy/` that the instance did not have | The file is removed, and the instance's own `deploy:` block in `instance.yaml` is restored. When it is a `deploy/production/` file, the sync prints the `make deploy-init ENV=production` command to create your own. |
| The merge changes an existing `deploy/` file without a conflict | The change is kept, and the sync names the file for review. |
| The template changed `instance.yaml` or `README.md` | The sync prints the `git diff <old> <new> -- <file>` command to review the change and apply it by hand. |

## 7. Upgrade core

1. Move `core/` to a core release tag:

   ```sh
   make update-core REF=v0.0.3
   ```

2. Run `make check`.
3. Commit the change on its own:

   ```sh
   git commit core instance.yaml -m "core: bump to v0.0.3"
   ```

`REF` must be a core release tag that matches `^v[0-9]+\.[0-9]+\.[0-9]+$`,
because `instance.yaml` records only release tags. A branch, a commit, or
another tag is refused. `git -C core tag --list 'v*'` lists the tags. The
command also refuses to run while `core/` holds work of its own (see
[contributing-to-core.md](contributing-to-core.md)). After the move it runs
`make config`, `make config-check`, and `make check-instance`; `make
config-check` reports configuration keys that the new core added.

## 8. Instance-only make targets

`instance.mk` is optional and instance-owned; the template has none. The
`Makefile` includes it with `-include instance.mk`. `make check-template` runs
`scripts/check-instance-mk.sh`, which refuses an `instance.mk` that:

- redefines a target the template defines;
- assigns a variable whose name does not start with `INSTANCE_` (for example
  `CORE := elsewhere` or `override VERSION = 1`);
- prevents `make` from reading the `Makefile`, for example a recipe line
  without its leading tab.

Example:

```make
INSTANCE_LAB_DIR := lab

lab-report: ## Print the lab report
	@cat $(INSTANCE_LAB_DIR)/report.txt
```

## 9. Release and deploy the instance

Every new instance has the environment `production` in `instance.yaml`
(`production: { adapter: host }`) and its files in `deploy/production/`. Fill
in the values that are still placeholders, then follow
[deploy.md](deploy.md#2-first-deployment-of-the-default-production-environment).
The images that `make deploy` runs come from a release; see
[release.md](release.md).

## Related guides

- [adding-an-extension.md](adding-an-extension.md): create and test a unit.
- [release.md](release.md): cut a release and name the images.
- [deploy.md](deploy.md): deploy a release to an environment.
- [contributing-to-core.md](contributing-to-core.md): change core itself.
- [troubleshooting.md](troubleshooting.md): known errors.
