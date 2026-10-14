# Release Precondition — Design Specification

- **Date:** 2026-10-14.
- **Status:** Proposed in the pull request that implements it.
- **Amends:** [2026-09-24-client-instance-template-design.md](2026-09-24-client-instance-template-design.md), Section 9.2, the last precondition of `make release`.

## 1. Background

Section 9.2 makes `make check` the last precondition of `make release`.
`release.yml` then runs `full-check.yml` on the pushed tag, which is
`make check`'s gate plus the database lanes. The full gate runs twice for
every release: once on the developer's machine and once in CI.

The local run adds no protection that the CI run lacks:

1. `release.yml` runs the full gate before it builds, pushes, or publishes
   anything. A tag that fails the gate publishes nothing.
2. Pass 1 of `make check` runs core's own gate on a core release tag. Core's
   `release-tag.yml` accepts a tag only on a commit with a passing
   `merge-attest` verdict, so pass 1 repeats a gate that commit has passed.
3. The two runs can disagree. Node sizes its default heap from the machine's
   memory: about 4 GB on a 16 GB laptop and about 2 GB on the CI runner. A
   gate that needs more than 2 GB passes locally and fails in CI. The CI run
   is the one that decides.

The local run costs more than 20 minutes on a laptop, before the tag exists.

## 2. Decision

The last precondition of `make release` is `make release-check`:

| Target | What it proves | Why it stays local |
|---|---|---|
| `make check-instance` | `instance.yaml` is valid and names the tag `core/` is at. | A wrong `core:` makes every image label wrong. |
| `make check-template` | The template-owned paths match the merged template commit. | `full-check.yml` refuses a drifted path only after the tag exists. |
| `make core-check-pin` | The pinned core commit is on core's `main`. | A pin to an unmerged commit would ship unreviewed core code. |

`release-check` runs in about 2 seconds. Each check fails on a condition that
a new tag cannot correct, so finding it before the tag saves a version
number.

`RELEASE_CHECK_TARGET` keeps its meaning. `RELEASE_CHECK_TARGET=check`
restores the full local gate.

## 3. Consequences

1. A tag can now fail the full gate in CI. The fix is the existing one in
   `docs/release.md` Section 4: correct the cause, delete the tag, and cut it
   again, or cut the next version.
2. The pre-push hook still runs `make test-scripts` and `make core-check-pin`
   when the tag is pushed, if the hook is installed.
3. `docs/release.md`, `README.md`, and `docs/troubleshooting.md` describe
   `make release-check`.
