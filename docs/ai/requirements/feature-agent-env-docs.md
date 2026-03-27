---
feature: agent-env-docs
status: draft
created: 2026-03-27
---

# Feature: Deploy env_handling docs for coding agents

## Problem Statement

When coding agents (Claude Code, Cursor, etc.) work on projects that use the
secure-env-handle workflow, they have no awareness of how environment variables
are managed — leading to hardcoded secrets, incorrect `.env` assumptions, or
generated code that bypasses the encryption/DPAPI pipeline.

The documentation (`env_handling.md`) exists in the secure-env-handle repo but
is never copied to target projects. Coding agents operating in those projects
never see it.

## Goals

- **G1**: `init-env-handle.ps1` copies an up-to-date env handling guide into
  each target project during setup (both modes).
- **G2**: The document is placed where Claude Code automatically reads it
  (`CLAUDE.md` in project root).
- **G3**: The document content is updated to reflect the current script names,
  folder structure, and workflows.
- **G4**: The document is written as agent-facing instructions (not human
  tutorial prose) so coding agents produce correct code on first attempt.

## Non-Goals

- Supporting other agent config formats (`.cursorrules`, `.github/copilot-instructions.md`)
  in this iteration — can be added later.
- Generating per-project customized docs (all projects get the same guide).

## User Stories

1. **As a developer running `init-env-handle.ps1`**, I want the env handling
   guide automatically placed in my project root so I don't have to copy it
   manually.
2. **As a coding agent (Claude Code)**, when I see code that needs environment
   variables, I should know to use the `secure-env-handle-and-deploy/` scripts
   rather than creating a plain `.env` or hardcoding values.
3. **As a developer reading the guide**, I want it to match the actual script
   names and folder layout so I'm not confused by stale references.

## Success Criteria

- [ ] Running `init-env-handle.ps1` (either mode) produces a `CLAUDE.md` in
      each selected project root.
- [ ] `CLAUDE.md` contains accurate script names, paths, and workflows.
- [ ] Claude Code, when asked to add an env var to a project with this setup,
      references the correct scripts and never commits plaintext secrets.

## Constraints

- The source document lives in the `secure-env-handle` repo and is copied
  during init — it must be self-contained (no relative links to other repo files).
- Must not overwrite an existing `CLAUDE.md` without merging/appending.

## Open Questions

1. **Append vs overwrite**: If a project already has a `CLAUDE.md`, should we
   append the env section or create a separate file (e.g., `CLAUDE-env.md`)?
   Claude Code reads all `CLAUDE.md` files in subdirectories too — so placing
   it at `secure-env-handle-and-deploy/CLAUDE.md` is an alternative.
2. **Should the file be named `CLAUDE.md` directly**, or should it remain
   `env_handling.md` and be referenced from a `CLAUDE.md`?
