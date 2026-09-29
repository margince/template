# Contributing to core

This guide covers sending a change from an instance to core
(`margince/margince`): when a change belongs in core, and the `core-*`
targets that create a contribution branch in the `core/` submodule, test it
against the instance's units, and open a pull request. It is for the
developer who finds that a unit needs something core does not provide.
Moving the instance to a new core release is in
[create-an-instance.md](create-an-instance.md#7-upgrade-core).

## 1. When a change belongs in core

| The change | Where it goes |
|---|---|
| A unit's own behavior, tables, screen, or tests | The unit, in `extensions/<name>/` ([adding-an-extension.md](adding-an-extension.md)). |
| A core package that a unit needs to import but that has no `//margince:extension-surface` marker | Core. Units may import only marked packages under `core/backend/pkg/`; the `arch` gate refuses other imports. |
| A change to an existing extension seam (a type, a field, or an interface in a marked package) | Core. |
| A fix to a core bug, a core `make` lane, core's composer, or the desktop build in `core/desktop/` | Core. |
| A lifecycle script, workflow, or `make` target of this repository | The template ([create-an-instance.md](create-an-instance.md#6-receive-template-changes)). |

Never edit `core/` to change the instance. The instance pins a core release
tag, and `make update-core REF=<tag>` is the only way the pin moves.

## 2. Prerequisites

- An instance checkout on which `make install` has run.
- Write access to `margince/margince`, or a fork of it (Section 6).
- The GitHub CLI (`gh`), to open the pull request. Without it, `make core-pr`
  pushes the branch and prints where to open the pull request by hand.
- `core/CONTRIBUTING.md` read. It is core's authority on contributions.

## 3. The contribution loop

1. Start a branch in `core/`:

   ```sh
   make core-branch NAME=<type>/<slug>
   ```

2. Edit the files under `core/`.
3. Test the change against a real unit:

   ```sh
   MARGINCE_ALLOW_DIRTY_CORE=1 make u NAME=<unit>
   ```

4. Commit in `core/` with a sign-off:

   ```sh
   git -C core commit -s
   ```

5. Run core's own merge gate:

   ```sh
   make core-check
   ```

6. Push the branch and open the pull request:

   ```sh
   make core-pr
   ```

7. Put `core/` back on the pinned commit:

   ```sh
   make core-restore
   ```

`make core-pr` does not restore `core/`. Until you run `make core-restore`,
`git status` in the instance shows `core` as modified.

### 3.1 `make core-branch`

`NAME` must match `<type>/<slug>`: the type is `feat`, `fix`, `chore`,
`docs`, `refactor`, `test`, or `perf`, and the slug is lower-case letters and
digits in words joined by single hyphens, for example `feat/ext-seam-contacts`.

`make core-branch`:

1. Refuses when `core/` is on a branch, has modified tracked files, or is a
   detached `HEAD` with commits that `origin/main` does not have, or when
   `origin/main` does not resolve.
2. Runs `git -C core fetch origin main`.
3. Creates the branch from `origin/main` and checks it out.

The branch starts from `origin/main`, not from the pinned release tag. Core's
`main` is usually ahead of the pin, so `make u` then composes the units with
a newer core than the instance builds with. A failure unrelated to your change
can come from that difference. `make core-status` shows how far `core/` is
from `origin/main`.

### 3.2 `MARGINCE_ALLOW_DIRTY_CORE=1`

`make stage` refuses to run when `core/` has modified tracked files, because
staging replaces files in `core/extensions/`. A change to core modifies tracked
files, so every lane that stages (`make u`, `make compose`, `make build`,
`make check`) needs `MARGINCE_ALLOW_DIRTY_CORE=1` while the change is not
committed.

- Set it on each command, as in step 3. Do not `export` it: the check stays off
  for every later command in that shell.
- Do not edit files under `core/extensions/<unit>/` for one of the instance's
  units. Staging replaces them.

`make core-check` runs `make unstage` and then core's `check`; it does not
stage, so it does not need the variable.

### 3.3 `make core-pr`

`make core-pr`:

1. Refuses when `core/` is not on a branch or has uncommitted changes.
2. Runs `git -C core fetch origin main`, and refuses when the branch has no
   commits that `origin/main` does not have.
3. Refuses when a commit in `origin/main..HEAD` has no `Signed-off-by: <name>
   <email>` trailer, and prints the fix:

   ```sh
   git -C core rebase --signoff origin/main
   ```

4. Chooses the push remote: `origin` when a dry-run push to it succeeds,
   else `fork` when a dry-run push to it succeeds. Refuses when neither accepts
   a push (Section 6).
5. Pushes the branch with `git push -u <remote> <branch>`.
6. Prints the AI disclosure that core asks for, then runs `gh pr create` with
   base `main` on `margince/margince`. For a push to `fork`, the head is
   `<fork-owner>:<branch>`.

## 4. Core's requirements

`core/CONTRIBUTING.md` is the authority. These three block a review or a merge:

| Requirement | What to do |
|---|---|
| DCO sign-off on every commit | `git -C core commit -s`. `make core-pr` checks it before the push. |
| AI disclosure in the pull request description | State **Assisted** (you wrote or directed it with AI help, the default) or **Generated** (AI produced substantial portions that you reviewed and own). |
| Human accountability | You can explain every line you submit. |

## 5. After the pull request

1. Run `make core-restore`. It checks out the pinned commit in `core/` as a
   detached `HEAD`, and keeps your branch.
2. For review changes, check the branch out again and repeat steps 2 to 7 of
   Section 3:

   ```sh
   git -C core checkout <type>/<slug>
   ```

3. When core publishes a release tag that contains the change, move the
   instance to it with `make update-core REF=<tag>`
   ([create-an-instance.md](create-an-instance.md#7-upgrade-core)).

`make core-restore` refuses while `core/` has modified tracked files. Commit
them on the branch, or discard them, first.

## 6. Push access

`make core-pr` needs a remote in `core/` that accepts a push:

| Access | Setup |
|---|---|
| Write access to `margince/margince` | None. The branch goes to `origin`. |
| No write access | Create a fork and add it as the remote `fork`. |

```sh
gh repo fork margince/margince --remote=false --clone=false
git -C core remote add fork git@github.com:<you>/margince.git
```

## 7. The core pointer

While a contribution branch is checked out, `git status` in the instance shows
`core` as modified: the submodule's `HEAD` is not the commit the instance
records. Do not commit it. The instance may pin only a commit that is on
core's `origin/main`, and a pin to a contribution branch breaks for everyone
when that branch is squashed or deleted.

- `make core-restore` clears the change. `git checkout core` does not: it does
  not enter the submodule, and with `submodule.recurse=true` it detaches `core/`
  from your branch.
- `make core-check-pin` fails when the recorded commit is not on
  `origin/main`. The pre-push hook and `make ci` run it, and so does CI.

To undo a committed pointer change:

```sh
git checkout <good-commit> -- core
git commit -m "core: restore the pinned commit"
make core-restore
```

`<good-commit>` is the last commit with the correct pointer, for example
`HEAD~1` when the pointer change is in the last commit. `make core-restore`
reads the pointer from `HEAD`, so run it after the commit.

## 8. Commands

| Command | Effect |
|---|---|
| `make core-status` | Shows the branch or detached commit of `core/`, the pinned commit and whether `HEAD` matches it, the distance from `origin/main`, and modified tracked files. Changes nothing. |
| `make core-branch NAME=<type>/<slug>` | Creates a contribution branch from `origin/main` (Section 3.1). |
| `make core-check` | Runs `make unstage`, then core's `check`. |
| `make core-pr` | Checks the sign-off, pushes the branch, and opens the pull request (Section 3.3). |
| `make core-restore` | Checks out the pinned commit in `core/`; keeps the branch. |
| `make core-check-pin` | Fails when the pinned commit is not on `origin/main`. Prints `SKIPPED` and exits 0 when it cannot find out (no network, or a shallow clone). |
| `make core-root-<lane>`, `make core-backend-<lane>` | Stage the units, then run a core target from `core/Makefile` or `core/backend/Makefile`. |

`UPSTREAM_REMOTE` (default `origin`) and `UPSTREAM_BRANCH` (default `main`)
change the remote and branch that these targets compare with and branch from.

## Related guides

- [adding-an-extension.md](adding-an-extension.md): the units that use a seam.
- [create-an-instance.md](create-an-instance.md#7-upgrade-core): upgrade core.
- [troubleshooting.md](troubleshooting.md#9-the-core-submodule): core
  submodule errors.
- `core/CONTRIBUTING.md`: core's contribution rules.
