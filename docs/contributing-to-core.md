# Contributing a change to core

Normally, changes flow one way: from upstream into this repository. `core/` is
upstream Margince as a git submodule, `make update-core REF=<tag>` moves it to
a core release tag, and CI checks that no build modified any tracked file
inside `core/`.

Sometimes you need to send a change the other way. A unit is written against an
*extension seam* — a package under `core/backend/pkg/` that units are allowed to
import. The person who finds a seam missing is the person writing the unit: you,
here, downstream. The make targets on this page let you change core from here
without losing the change or breaking the submodule pointer.

## The invariant still holds

`core/` is read-only **as a dependency**. Nothing you do here changes that:

- A contribution branch is the one exception, and it is created by
  `make core-branch` — never by editing a staged copy, and never under
  `core/extensions/<our-unit>/`.
- The branch is **never committed in this repository**. While it is checked out,
  `git status` here reports `core` as modified. That is the submodule pointer
  moving. Committing it records a pointer to a commit other people cannot fetch,
  and `make core-check-pin` refuses it — in the pre-push hook and in CI.
- **To clear it, run `make core-restore`.** It puts `core/` back on the commit
  this repository pins, and keeps your branch.

  Do not use `git checkout core`. It does nothing here: the "modified" state
  comes from the submodule's `HEAD` differing from the index, and
  `git checkout <path>` does not enter the submodule. If you have
  `submodule.recurse=true` set, it does something worse — it detaches `core/`
  off your contribution branch without a word.

`make core-status` answers "what is core right now" at any point: branch or
detached, the pinned sha, how far from `origin/main`, and whether tracked files
are modified.

## The loop

```sh
make core-branch NAME=feat/ext-seam-foo   # branch off origin/main
$EDITOR core/backend/pkg/extension/...    # change the seam

MARGINCE_ALLOW_DIRTY_CORE=1 \
  make u NAME=acme-sync                   # prove it against a real unit

git -C core commit -s                     # sign off — upstream blocks without it
make core-check                           # upstream's own merge gate
make core-pr                              # push and open the PR
make core-restore                         # put core/ back — your branch is kept
```

The last line matters. `make core-pr` opens the pull request; it does not put
`core/` back. Until you run `make core-restore`, `core/` is still on your branch
and this repo still reports the pointer as moved.

**`MARGINCE_ALLOW_DIRTY_CORE=1` is required on that middle step, not optional.**
Staging refuses to run when `core/` has modified tracked files. It deletes and
recopies each staged unit, so an edit made inside one would be lost without
warning. Editing a seam modifies tracked files by design, so the refusal fires
on legitimate work.

The variable is safe here because the two paths do not overlap: your edits are
under `core/backend/`, and staging only writes under
`core/extensions/<our-unit>/`.

The same override applies to `make check`, `make build` and every other composed
gate — they all run `stage` first. **Prefix it on each command. Do not `export`
it**, or the guard stays off for the rest of your session, including for the
lanes that would have caught a real mistake.

**`make core-branch` branches off `origin/main`, not off the commit this repo
pins.** Upstream's main is usually ahead of the pin, sometimes by a lot — run
`make core-status` to see by how much. So `make u` in that loop composes our
units against a core this installation has never been built against. If it fails
in a way that has nothing to do with your seam, that is the likely reason.

`make u` in the middle is why you contribute from here. The composed
installation is a real consumer of the seam you are changing, so a
seam that does not serve a real unit fails in seconds, on your machine, before
review.

Branch names follow upstream's own shape, `<type>/<slug>` — `feat`, `fix`,
`chore`, `docs`, `refactor`, `test` or `perf`, then lower-case words joined by
single hyphens. `make core-branch` refuses anything else, because a rename after
the pull request is open costs a force-push and a stale review link.

## Worked example: adding an extension seam

A unit may import only packages under `core/backend/pkg/` that carry the
`//margince:extension-surface` marker. Today that is `pkg/extension`,
`pkg/extension/jurisdiction` and `pkg/extension/crm`. Anything else fails
upstream's arch test, which is the correct outcome: the surface is deliberately
minimal, and widening it is a decision upstream makes, not one a downstream unit
takes by importing.

So "my unit needs something core does not expose" is a *core* change:

1. `make core-branch NAME=feat/ext-seam-<thing>`
2. Add the package under `core/backend/pkg/extension/<thing>/`, carrying the
   marker. `TestSurfaceMarkerLivesOnlyUnderPkg` enforces where the marker may
   live; `TestExtensionsImportOnlyTheAllowlistedSurface` is what then admits a
   unit's import of it. Both run in `make arch` here and in core's own gate.
3. Use it from a real unit in `extensions/` and run `make u NAME=<unit>`. If the
   seam cannot be used comfortably by an actual consumer, that is the design
   review, and it costs nothing here.
4. `git -C core commit -s`, then `make core-check`, then `make core-pr`.

`core/docs/how-to/add-an-extension.md` and
`core/docs/explanation/extensibility.md` remain the authority on what the
contract means. This page is only about the mechanics of getting a change there
from here.

## What upstream requires

Read `core/CONTRIBUTING.md`; it is short and it is the authority. The three
things that block a merge or a review:

- **DCO sign-off on every commit.** `git commit -s`. The check is required and
  a commit without the trailer blocks the merge. `make core-pr` refuses to push
  an unsigned branch rather than let CI tell you afterwards — fix a whole branch
  with `git -C core rebase --signoff origin/main`.
- **Proportionate AI disclosure** in the pull request description: *Assisted*
  (you wrote or directed it with AI help — the default) or *Generated* (AI
  produced substantial portions you reviewed and own).
- **Human accountability.** You must be able to explain every line you submit.
  "The model wrote it" is not an answer to a review question.

## Where the change goes

`make core-pr` decides where to push by probing, not by configuration:

- Write access to `origin` (`margince/margince`) — it pushes there. That
  is how the team already works; `origin` carries `chore/craft-strict` and
  siblings.
- No write access — it requires a `fork` remote on `core/` and pushes there:

  ```sh
  gh repo fork margince/margince --remote=false --clone=false
  git -C core remote add fork git@github.com:<you>/margince.git
  ```

## After the pull request

```sh
make core-restore     # core/ back on the commit this repo pins
```

Your branch is kept; `git -C core checkout <branch>` returns to it for review
fixes. Once the change lands upstream, this installation picks it up the same way
it picks up every other upstream change:

```sh
make update-core REF=<tag>
make check
git commit core instance.yaml -m "core: bump to <tag>"
```

## Troubleshooting

| Symptom | What it is |
|---|---|
| `git status` here shows `core` modified | The pointer moved because a branch is checked out. Expected. Clear it with `make core-restore`. `git checkout core` does **not** work — see above. |
| I already committed the moved pointer | `git checkout HEAD~1 -- core` if it is the last commit, then `make core-restore`. On a pushed branch, add a commit restoring the pinned sha. `make core-check-pin` tells you when it is right again. |
| `core-check-pin` refuses | `core/` is pinned to a commit upstream has not merged. The message names the fix; usually `make core-restore` then commit the pointer. |
| `update-core` refuses | It is protecting a branch, uncommitted work, or detached commits, or `REF` names something other than a core release tag. `make core-status` says which of the first three applies; `git -C core tag --list 'v*'` lists the release tags. |
| `core-pr` refuses on sign-off | `git -C core rebase --signoff origin/main`. |
| `core-pr` says no remote accepts a push | Add a `fork` remote, as above. |
| `make u` refuses: "core has modified tracked files" | Expected while a seam edit is open. Prefix the command with `MARGINCE_ALLOW_DIRTY_CORE=1`, as the loop above shows. |
| Lost track of what `core/` is | `make core-status`. |
