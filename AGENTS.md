# Agent Instructions

This file applies to AI agents and human contributors working in this
repository.

## Context

- This repository is the template for Margince client instances. Read
  `README.md` first.
- The design is in `docs/superpowers/specs/2026-09-24-client-instance-template-design.md`.
  Do not implement anything that contradicts it. Propose a spec change instead.
- The repository is in the design phase. No tooling is implemented yet.

## Rules

- **Path ownership.** Each path is template-owned or instance-owned (design
  Section 6). This repository contains template-owned files and empty or
  example versions of instance-owned files. Never add client-specific code or
  values.
- **Core.** `core/` is a submodule pinned to a core tag. Never edit files in
  `core/`. Changes to how Margince is compiled belong in `margince/margince`.
- **Reuse.** Tooling is copied from `margince-automation-world` (design
  Section 7). Reuse an existing script before writing a new one.
- **Secrets.** Never commit licenses, tokens, or credentials. Licenses are
  provided through `MARGINCE_LICENSE` or the environment secret store.

## Writing style

Write documentation in technical standard English: short declarative
sentences, standard terms, numbered sections, and tables for decisions and
responsibilities. Do not use idioms or rhetorical phrasing.

## Commits

Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
