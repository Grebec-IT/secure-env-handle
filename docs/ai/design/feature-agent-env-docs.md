---
feature: agent-env-docs
status: draft
created: 2026-03-27
---

# Design: Deploy env_handling docs for coding agents

## Architecture Decision

### Where to place the file

**Recommended: `secure-env-handle-and-deploy/CLAUDE.md`** in each target project.

Rationale:
- Claude Code reads `CLAUDE.md` from every directory in the project tree, not
  just the root — so a subdirectory `CLAUDE.md` is automatically picked up.
- Avoids conflicting with a project-level `CLAUDE.md` that may already exist
  (or that the user wants for project-specific instructions).
- Keeps env-handle docs co-located with the scripts they describe.
- Gets cleaned up naturally if the `secure-env-handle-and-deploy/` folder is
  ever removed.

Alternative considered: project root `CLAUDE.md` — rejected because it would
need merge logic for projects that already have one.

### Cursor support: `.cursorrules`

Cursor AI reads `.cursorrules` only from the **project root** (does not walk
subdirectories). So the init script must copy `.cursorrules` from the cloned
subfolder to the project root and then delete it from the subfolder.

### Source files in this repo

- `env_handling.md` → replaced by `CLAUDE.md` (agent-instruction style)
- New `.cursorrules` with identical content (self-referencing header adjusted)

The `init-env-handle.ps1` `Install-EnvHandle` function clones the entire repo
into the subfolder. It then:
- Keeps `CLAUDE.md` at `secure-env-handle-and-deploy/CLAUDE.md`
- Copies `.cursorrules` to project root, deletes it from subfolder
- Deletes `init-env-handle.ps1`, `setup-server.ps1`, `README.md`, `env_handling.md`

### Content rewrite

The document must be rewritten from human-tutorial style to
**agent-instruction style**:

- Lead with rules/constraints (what NOT to do with secrets)
- List available scripts with exact paths relative to project root
- Describe the env source priority so the agent knows what exists at runtime
- Omit installation/setup instructions (agents don't run setup)
- Keep "how age/DPAPI works" as reference (agents may need to debug)

## Components Changed

1. **`env_handling.md`** → replaced by **`CLAUDE.md`** + **`.cursorrules`**, content rewritten
2. **`init-env-handle.ps1`** → `Install-EnvHandle` updated to:
   - Delete `init-env-handle.ps1`, `setup-server.ps1`, `README.md`, `env_handling.md`
   - Keep `CLAUDE.md` in subfolder
   - Copy `.cursorrules` to project root, delete from subfolder

## Security Considerations

- `CLAUDE.md` contains no secrets — only instructions about how secrets are
  managed. Safe to commit.
- The document should explicitly instruct agents to never commit `.env`,
  `.credentials.json`, or plaintext secrets.
