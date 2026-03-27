---
feature: docker-secrets
status: draft
created: 2026-03-27
---

# Feature: Docker secret file mounts via /run/secrets

## Problem Statement

All projects using secure-env-handle inject secrets into Docker containers via
environment variables (`env_file: [.env]` or `environment:` in compose). This
works but exposes secrets through `docker inspect`, `docker logs` (if an app
prints its env), `/proc/*/environ` inside the container, and crash dumps.

Docker's native secrets mechanism mounts sensitive values as files in
`/run/secrets/` (tmpfs, in-memory only), which mitigates all of these
exposure vectors.

The challenge: the current workflow encrypts/decrypts a single flat `.env`
file. There is no distinction between "this is a secret" and "this is just
config." Adding Docker secrets requires knowing which keys are sensitive.

## Goals

- **G1**: Introduce a manifest file (`envs/secrets.keys`) that lists which
  `.env` keys are secrets and should be mounted via `/run/secrets/`.
- **G2**: The deploy and env-run scripts split the decrypted `.env` into two
  outputs: a reduced `.env` (non-secret config only) and individual secret
  files for Docker secret mounts.
- **G3**: If the manifest file is empty or absent, behaviour is identical to
  today — all values stay in `.env`, no secret files are generated. Full
  backward compatibility.
- **G4**: Secret files are cleaned up after deploy/env-run, just like `.env`
  is today.
- **G5**: Update CLAUDE.md / .cursorrules to document the new workflow so
  coding agents understand both patterns.
- **G6**: Provide a `/suggest-secret-variable-split` skill that automates the
  migration for a project: scans docker-compose.yml + .env + app code,
  classifies variables, populates the manifest, and drafts a code change plan.

## Non-Goals

- Automatically modifying application code in target projects. The skill drafts
  a change plan and the user/agent executes it per-project. secure-env-handle
  handles the infrastructure; app-level changes are guided but not automated.
- Docker Swarm external secrets — this uses compose file-based secrets only
  (works without Swarm).
- Encrypting secret files separately from `.env` — they are derived from the
  same `.env` at deploy time and deleted immediately after.

## User Stories

1. **As a developer**, I want to mark certain env keys as secrets so they are
   mounted as files instead of passed as environment variables, reducing the
   attack surface of my containers.
2. **As a developer with existing projects**, I want the tool to behave exactly
   as before until I explicitly create a manifest file — zero disruption.
3. **As a coding agent**, when I see a project with a secrets manifest, I should
   know that secrets are in `/run/secrets/` and write code that reads from
   files, not `os.getenv()`.
4. **As an operator running deploy.ps1**, I want to see which keys are being
   split into secret files so I can verify the setup is correct.
5. **As a developer migrating an existing project to Docker secrets**, I want
   a skill that scans my project, classifies variables, populates the manifest,
   and tells me what app code changes are needed — so I don't have to figure
   it all out manually.

## Success Criteria

- [ ] Empty or absent `envs/secrets.keys` → identical behaviour to today.
- [ ] Populated manifest → deploy/env-run produce individual secret files and
      a reduced `.env` containing only non-secret keys.
- [ ] Secret files are deleted after deploy/env-run (same cleanup as `.env`).
- [ ] `verify-env` reports secret/non-secret classification alongside sync status.
- [ ] CLAUDE.md and .cursorrules document the new workflow.
- [ ] `/suggest-secret-variable-split` skill scans a project and produces a
      populated manifest + code change plan.

## Constraints

- Must work with plain `docker compose` (no Swarm required). Docker Compose
  supports file-based secrets natively via `secrets: ... file: <path>`.
- The manifest file (`envs/secrets.keys`) must be committed to git (key names
  are not secret). One manifest per project, shared across all environments.
- The `.env` file format and all encryption/DPAPI workflows remain unchanged.
- Secret files must be placed in a known directory that docker-compose can
  reference (e.g., `.secrets/` in project root, gitignored).

## Open Questions

1. ~~Secret file directory~~ — resolved: `.secrets/` in project root.
2. ~~Per-environment or shared manifest~~ — resolved: single `envs/secrets.keys`,
   shared across all environments. A key is either a secret or it isn't.
3. ~~docker-compose.yml changes~~ — resolved: deploy script does not modify
   committed files. The `/suggest-secret-variable-split` skill assists users by
   scanning the project and drafting all needed changes (manifest, compose,
   app code).
