---
feature: agent-env-docs
status: draft
created: 2026-03-27
---

# Planning: Deploy env_handling docs for coding agents

## Task Breakdown

### Task 1: Rewrite env_handling.md → CLAUDE.md
- Update script names (`setup-server.ps1` → `init-env-handle.ps1`)
- Add `decrypt-env.ps1` / `decrypt-env.sh` to script listing
- Fix folder structure (scripts in `secure-env-handle-and-deploy/`, not root)
- Remove "copy from weclapp-db-mirror" references
- Remove "Setting up a new project" manual steps (automated by init script)
- Rewrite in agent-instruction style (rules first, then reference)
- Rename file from `env_handling.md` to `CLAUDE.md`

### Task 2: Update init-env-handle.ps1 Install-EnvHandle function
- Delete `init-env-handle.ps1` from cloned subfolder (currently only deletes
  `setup-server.ps1`)
- Keep `CLAUDE.md` in the subfolder (currently deletes `README.md` — adjust
  to not delete `CLAUDE.md`, or only delete `README.md`)

### Task 3: Verify end-to-end
- Confirm `CLAUDE.md` ends up at `<project>/secure-env-handle-and-deploy/CLAUDE.md`
- Confirm Claude Code can see it when working in the project

## Dependencies

- Task 2 depends on Task 1 (need to know the final filename)

## Implementation Order

1. Task 1 (content rewrite + rename)
2. Task 2 (script update)
3. Task 3 (verification)

## Risks

- **Existing projects** that already ran init won't get the new `CLAUDE.md`
  until they re-run init or manually pull. Mitigation: document in commit
  message, re-run mode 2.
