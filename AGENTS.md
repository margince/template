# Agent Instructions

Rules for AI agents and human contributors who change this repository.

## Context

- This repository is `margince-template`, the template that every Margince
  client instance is created from. Without extensions it is itself an
  instance, Margince Default. Read [README.md](README.md) first.
- The design is
  [docs/superpowers/specs/2026-09-24-client-instance-template-design.md](docs/superpowers/specs/2026-09-24-client-instance-template-design.md).
  Do not implement anything that contradicts it; propose a change to the spec
  instead. `docs/superpowers/` is design history: do not rewrite it.
- The guides are listed in [docs/README.md](docs/README.md).

## Rules

- **Path ownership.** `.template-owned` lists the template-owned paths; every
  other path is instance-owned (design Section 6). This repository holds the
  template-owned files and the empty or default versions of instance-owned
  files (`instance.yaml`, `extensions/`, `deploy/production/`). Never add
  client-specific code or values.
- **Core.** `core/` is a submodule pinned to a core release tag. Never edit
  files in `core/`. Only `make update-core REF=<tag>` moves the pin. A change
  to core goes to `margince/margince`
  ([docs/contributing-to-core.md](docs/contributing-to-core.md)).
- **Reuse.** Use the existing functions in `scripts/lib.sh` (for example
  `instance_get`, `image_repo`, `is_release_version`) and the Go CLI in
  `scripts/cli` for `instance.yaml`. Extend an existing script before you add
  a new one. Cover new behavior in the script's `*.test.sh`, and add a new
  test file to the `test-scripts` target in the `Makefile`.
- **Secrets.** Never commit a license, token, key, or password. Scripts read
  them from the environment, never print them, and never pass them on a
  command line. `deploy/<env>/secrets` holds names only.
- **Public-only rule.** The template is public. No file outside
  `docs/superpowers/` and `scripts/check-public.patterns` may name a private
  repository, host, organization, or service (design Section 7).
  `make check-public` enforces this.

## Writing style

- Write in technical standard English: short declarative sentences, present
  tense, active voice, and the terms of [docs/glossary.md](docs/glossary.md).
- Use numbered sections in long guides, tables for options and decisions, and
  one action per numbered step. Put placeholders in `<angle-brackets>`.
- Do not use idioms, rhetorical phrasing, or incident stories. Design
  rationale belongs in the spec.
- Every command, target, variable, and default in a document must match the
  code. Each topic has one guide; other documents link to it.
- `make check-docs` treats every `make <word>` in `README.md`, `CLAUDE.md`, and
  `docs/*.md` as a target name, so write it only for real targets.

## Commits

- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `test:`,
  `refactor:`.
- One logical change per commit.
- Commits to `core/` need a DCO sign-off (`git commit -s`); `make core-pr`
  checks it.

## Tests to run

| Change | Run |
|---|---|
| Any change | `make test-scripts` (the pre-push hook runs it with `make core-check-pin`). |
| Documentation | `make check-docs` and `make check-public`, and check every relative link and anchor. |
| Scripts, `Makefile`, workflows | `make test-scripts`, then `make check`. |
| The instance lifecycle (`new-instance`, `template-sync`, `release`, `deploy`) | `make test-lifecycle`. |
| Before a release | `make ci`. |
