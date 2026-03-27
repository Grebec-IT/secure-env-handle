---
feature: docker-secrets
status: draft
created: 2026-03-27
---

# Design: Docker secret file mounts via /run/secrets

## Architecture Decision

### Manifest file

**File:** `envs/secrets.keys` (single file per project, committed to git)

Format: one key name per line, comments with `#`, blank lines ignored.

```
# Database
POSTGRES_PASSWORD

# API tokens
WECLAPP_API_TOKEN
WEBHOOK_SECRET_TOKEN
```

One manifest shared across all environments — a key is either a secret or it
isn't, regardless of dev/prod. If `envs/secrets.keys` is absent or empty, all
keys stay in `.env` as today.

### Secret file output directory

**Directory:** `.secrets/` in project root (sibling to `.env`)

```
<project>/
  .env                    # non-secret config only (when manifest exists)
  .secrets/               # one file per secret key
    POSTGRES_PASSWORD
    WECLAPP_API_TOKEN
  docker-compose.yml
```

- `.secrets/` must be added to `.gitignore` (alongside `.env`).
- Each file contains the raw value only (no `KEY=` prefix, no trailing newline).
- Filenames are UPPERCASE, matching the .env key names (e.g., `.secrets/POSTGRES_PASSWORD`).
- In docker-compose.yml, the `secrets:` key names are lowercase by convention
  (e.g., `postgres_password`). Docker maps these to `/run/secrets/postgres_password`
  inside the container.
- Directory is created by deploy/env-run, deleted during cleanup.

### docker-compose.yml pattern

Users manually add the `secrets:` section to their compose file. The deploy
script does NOT auto-modify compose files.

```yaml
secrets:
  postgres_password:
    file: .secrets/POSTGRES_PASSWORD
  weclapp_api_token:
    file: .secrets/WECLAPP_API_TOKEN

services:
  app:
    env_file: [.env]              # non-secret config
    secrets:
      - postgres_password
      - weclapp_api_token
    # App reads from /run/secrets/postgres_password
```

### How deploy/env-run change

The split happens **after** the `.env` is loaded (from any of the 3 tiers)
and **before** `docker compose up` runs:

```
Load .env (existing 3-tier priority — unchanged)
        ↓
Read envs/secrets.keys
        ↓
    manifest empty/absent? ──yes──→ use .env as-is (current behaviour)
        ↓ no
Split .env:
  - Copy .env → .env.full (backup for rollback)
  - Secret keys → .secrets/{KEY} (one file each, UPPERCASE filenames)
  - Remaining keys → rewrite .env (non-secret config only)
        ↓
Run docker compose (reads .env + mounts .secrets/)
        ↓
Cleanup: delete .env, .env.full, AND .secrets/ (if created)
```

### Changes to verify-env

`verify-env` gains awareness of the manifest:
- Shows which keys are classified as secrets vs config.
- Warns if a key in the manifest doesn't exist in any layer.
- Warns if a key that looks sensitive (contains `PASSWORD`, `SECRET`, `TOKEN`,
  `KEY`) is NOT in the manifest (suggestion, not error).

## Components Changed

### Modified scripts

1. **deploy.ps1 / deploy.sh** — add split logic after `.env` load, add
   `.secrets/` cleanup alongside `.env` cleanup.
2. **env-run.ps1 / env-run.sh** — same split logic and cleanup.
3. **verify-env.ps1 / verify-env.sh** — manifest awareness, classification
   display, heuristic warnings.
4. **init-env-handle.ps1 / init-env-handle.sh** — add `.secrets/` to the
   `.gitignore` required entries list.

### New files (in this repo)

- **`.claude/commands/suggest-secret-variable-split.md`** — Claude Code skill
  that automates Docker secrets migration for a target project. Shipped in
  this repo, copied to target projects during `Install-EnvHandle` at
  `secure-env-handle-and-deploy/.claude/commands/`.

### Skill: `/suggest-secret-variable-split`

A Claude Code slash command. Ships with secure-env-handle, deployed to target
projects alongside the other scripts. Runs in the target project context.

**Flow:**

1. **Version check** — read `secure-env-handle-and-deploy/CLAUDE.md` or check
   installed script version. If outdated, offer to re-run init-env-handle.
2. **Scan docker-compose.yml** — collect all variables referenced via
   `env_file`, `environment:`, and existing `secrets:` sections.
3. **Scan .env** (or decrypt from age/DPAPI) — collect all key-value pairs.
4. **Classify each variable** using heuristics:
   - **Auto-secret** (high confidence): key name contains `PASSWORD`, `SECRET`,
     `TOKEN`, `CREDENTIAL`, `PRIVATE`, or ends with `_API_KEY`. Auto-add to
     manifest.
   - **Auto-config** (high confidence): key name matches `PORT`, `HOST`, `URL`
     (without auth), `LOG_LEVEL`, `VERSION`, `TAG`, `ENV`, `DEBUG`. Keep in .env.
   - Note: bare `KEY` in a name is treated as uncertain (too broad — matches
     `PRIMARY_KEY`, `CACHE_KEY`, etc.).
   - **Uncertain**: ask the user (e.g., `DATABASE_URL` — contains credentials
     in the connection string, but is typically used as an env var).
5. **Write/update `envs/secrets.keys`** with the classified secret keys.
6. **Scan app code** — search for `os.getenv`, `os.environ`, `decouple.config`,
   pydantic `BaseSettings`, and similar patterns that read the secret keys.
   Draft a change plan showing which files need to read from `/run/secrets/`
   instead.
7. **Draft docker-compose.yml changes** — show the `secrets:` section and
   per-service `secrets:` entries that need to be added.
8. **Present plan to user** — show manifest, compose changes, and code changes.
   User reviews and approves before any edits.

### Updated documentation

- **CLAUDE.md / .cursorrules** — document the manifest file, `.secrets/`
  directory, and the docker-compose pattern. Must remain identical.

## Data Flow

```
envs/dev.env.age ──decrypt──→ .env (full)
                                ↓
                    envs/secrets.keys
                                ↓
                    ┌───────────┴───────────┐
                    ↓                       ↓
              .env (config)          .secrets/KEY1
                                     .secrets/KEY2
                    ↓                       ↓
              env_file: [.env]      secrets: file: .secrets/KEY
                    ↓                       ↓
              container env vars    /run/secrets/key (tmpfs)
                    ↓                       ↓
                    └───────────┬───────────┘
                                ↓
                          cleanup both
```

## Security Considerations

- Secret files in `.secrets/` and the backup `.env.full` exist briefly on disk,
  same as `.env` today. All are deleted after deploy/env-run.
- `.secrets/` must be gitignored. The init script enforces this.
- Key names in the manifest are not sensitive — safe to commit.
- Docker secret file mounts use tmpfs inside the container — not written to
  the container's filesystem layer.

## Backward Compatibility

**100% backward compatible.** The split only activates when a non-empty
manifest file exists. Projects without a manifest see zero change in behaviour.
This is the critical design constraint.
