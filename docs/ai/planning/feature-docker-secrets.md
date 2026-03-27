---
feature: docker-secrets
status: draft
created: 2026-03-27
---

# Planning: Docker secret file mounts via /run/secrets

## Task Breakdown

### Task 1: Add .secrets/ to gitignore enforcement
**Scripts:** `init-env-handle.ps1`, `init-env-handle.sh`
**Change:** Add `.secrets/` to the `$requiredEntries` / `required` array in
the gitignore validation section of `Install-EnvHandle`.

Subtasks:
- [ ] Update PS1 `$requiredEntries` array
- [ ] Update SH `required` array
- [ ] Verify existing projects get the new entry on next init run

---

### Task 2: Implement env split helper
**Scripts:** New shared logic in `deploy.ps1`, `deploy.sh`, `env-run.ps1`, `env-run.sh`
**Change:** After `.env` is loaded, read the manifest and split if non-empty.

Subtasks:
- [ ] PS1: function `Split-EnvSecrets` that reads `envs/secrets.keys`,
      creates `.secrets/` directory, writes individual secret files, rewrites
      `.env` without secret keys. Returns `$true` if split was performed.
- [ ] SH: function `split_env_secrets` with identical logic.
- [ ] Both: no-op if manifest is absent or empty (return `$false` / `false`).
- [ ] Both: create `.secrets/` with restrictive permissions (PS1: no change
      needed on Windows; SH: `chmod 700`).
- [ ] Each secret file: raw value only, no trailing newline, no `KEY=` prefix.

---

### Task 3: Integrate split into deploy scripts
**Scripts:** `deploy.ps1`, `deploy.sh`
**Change:** Call split helper after `.env` load, before `docker compose up`.
Add `.secrets/` to cleanup.

Subtasks:
- [ ] PS1: call `Split-EnvSecrets` after env load section.
- [ ] PS1: show which keys were split ("Secrets: 3 keys → .secrets/").
- [ ] PS1: add `.secrets/` removal to cleanup (alongside `.env` deletion).
- [ ] SH: same three changes.
- [ ] Both: if split was NOT performed (no manifest), skip the message and
      cleanup — identical to current behaviour.

---

### Task 4: Integrate split into env-run scripts
**Scripts:** `env-run.ps1`, `env-run.sh`
**Change:** Same as Task 3 but in the env-run flow.

Subtasks:
- [ ] PS1: call `Split-EnvSecrets` after env load, before command execution.
- [ ] PS1: add `.secrets/` to finally cleanup (only if split was performed).
- [ ] SH: same, using trap for cleanup.
- [ ] Both: preserve the "only cleanup if we created it" logic — if `.secrets/`
      existed before the script ran, don't delete it.

---

### Task 5: Update verify-env with manifest awareness
**Scripts:** `verify-env.ps1`, `verify-env.sh`
**Change:** Read the manifest if present, classify keys, add heuristic warnings.

Subtasks:
- [ ] Read `envs/secrets.keys` if it exists.
- [ ] Add a "Type" column to the comparison table: `secret` or `config`.
- [ ] Warn if a manifest key doesn't exist in any layer.
- [ ] Warn (suggestion) if a key name contains PASSWORD, SECRET, TOKEN, or KEY
      but is not in the manifest.
- [ ] If no manifest exists, skip classification entirely (no noise).

---

### Task 6: Update CLAUDE.md and .cursorrules
**Files:** `CLAUDE.md`, `.cursorrules` (must remain identical)
**Change:** Document the manifest file, `.secrets/` directory, docker-compose
pattern, and the backward-compatible behaviour.

Subtasks:
- [ ] Add "Docker Secret File Mounts" section after "Env Source Priority".
- [ ] Document the manifest format and location.
- [ ] Document the `.secrets/` directory and gitignore requirement.
- [ ] Add docker-compose.yml example with `secrets:` section.
- [ ] Note: "If no manifest exists, all values stay in .env as before."
- [ ] Copy CLAUDE.md to .cursorrules to keep them identical.

---

### Task 7: Update README.md
**File:** `README.md`
**Change:** Add user-facing documentation for the Docker secrets feature.

Subtasks:
- [ ] Add section explaining the manifest file.
- [ ] Add migration guide: how to enable Docker secrets for an existing project.
- [ ] Add example docker-compose.yml with secrets section.

---

### Task 8: Create `/suggest-secret-variable-split` skill
**File:** `.claude/commands/suggest-secret-variable-split.md`
**Change:** New Claude Code slash command for assisted migration.

Subtasks:
- [ ] Create skill prompt file at `.claude/commands/suggest-secret-variable-split.md`.
- [ ] Step 1: Check secure-env-handle version, offer update if outdated.
- [ ] Step 2: Scan docker-compose.yml for variable references.
- [ ] Step 3: Scan .env (or decrypt) for all key-value pairs.
- [ ] Step 4: Classify variables using name heuristics (PASSWORD, TOKEN, SECRET,
      KEY → secret; PORT, HOST, LOG_LEVEL, VERSION → config; uncertain → ask user).
- [ ] Step 5: Write/update `envs/secrets.keys` manifest.
- [ ] Step 6: Scan app code (`os.getenv`, `os.environ`, `decouple.config`,
      pydantic `BaseSettings`) for secret key usage, draft code change plan.
- [ ] Step 7: Draft docker-compose.yml `secrets:` section changes.
- [ ] Step 8: Present full plan (manifest + compose + code) for user review.

---

### Task 9: Version bump and release
**Files:** `init-env-handle.ps1`, `init-env-handle.sh`
**Change:** Bump `$Version` / `VERSION`, tag, push.

Subtasks:
- [ ] Update version in both init scripts.
- [ ] Commit all changes.
- [ ] Create annotated tag.
- [ ] Push with tags.

## Dependencies

```
Task 1 (gitignore) ──────────────────────────────────┐
Task 2 (split helper) ──→ Task 3 (deploy) ──→ Task 9 (release)
                     └──→ Task 4 (env-run) ──→ Task 9
Task 5 (verify-env) ─────────────────────────────────→ Task 9
Task 6 (CLAUDE.md) ──────────────────────────────────→ Task 9
Task 7 (README.md) ──────────────────────────────────→ Task 9
Task 8 (skill) ──────────────────────────────────────→ Task 9
```

Tasks 1, 2, 5, 6, 7, 8 can be done in parallel.
Tasks 3 and 4 depend on Task 2.
Task 9 depends on all others.

## Implementation Order

1. Task 2 (split helper — core logic, everything depends on it)
2. Task 1 + Task 3 + Task 4 (can be parallelized)
3. Task 5 (verify-env update)
4. Task 8 (skill — can be built in parallel with docs)
5. Task 6 + Task 7 (documentation)
6. Task 9 (version bump and release)

## Risks

- **Manifest out of sync with docker-compose.yml**: If a key is in the manifest
  but the compose file doesn't reference it as a secret, the file is created
  but unused. Low risk — no functional impact, just wasted files.
- **App code not updated**: If the manifest lists a key as a secret but the app
  still reads from `os.getenv()`, it will get `None`. This is the user's
  responsibility per-project, not a secure-env-handle concern. Mitigated by
  documentation and backward compatibility (empty manifest = no change).
- **Existing .secrets/ directory**: If a project already has a `.secrets/`
  directory for other purposes, the cleanup step could delete it. Mitigated by
  the same "only cleanup if we created it" pattern used for `.env`.
