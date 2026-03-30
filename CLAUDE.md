# Environment Variable Handling — Agent Instructions

> **DO NOT MODIFY THIS FILE.**
> This file is auto-installed by [secure-env-handle](https://github.com/Grebec-IT/secure-env-handle)
> and will be overwritten on the next update. It is reference-only documentation
> for how this project handles secrets and environment variables.
> If you need to change these instructions, do so in the secure-env-handle
> repository and re-run the installer.

> This project uses encrypted environment variables. Follow these rules when
> writing code that depends on configuration or secrets.

## Rules

1. **NEVER** commit `.env` files, `.credentials.json` files, or plaintext secrets.
2. **NEVER** hardcode secrets in source code — all secrets come from `.env` at runtime.
3. **NEVER** create or modify `.env` files directly — use the scripts below.
4. Docker services consume secrets via `env_file: [.env]` in `docker-compose.yml`.
5. The `.env` file only exists briefly during deployment and is deleted afterward.
6. All scripts live in `secure-env-handle-and-deploy/` and operate on the
   **parent directory** (the project root).

## docker-compose.yml Conventions

Each project has **one** `docker-compose.yml` — committed to git, shared across
all environments. Everything that differs between environments is controlled via
`.env` variable substitution.

1. **NEVER** put secrets or environment-specific values directly in `docker-compose.yml`.
2. **NEVER** create per-environment compose files (no `docker-compose.dev.yml` etc.).
3. Use `${VAR_NAME}` for values that change per environment — Docker Compose
   interpolates these from `.env` automatically.
4. Use `${VAR:-default}` syntax for optional vars with sensible defaults.
5. Services consume runtime secrets via `env_file: [.env]`.

Example:
```yaml
services:
  app:
    image: myapp:${APP_TAG:-latest}
    ports:
      - "${APP_PORT:-8080}:8080"
    env_file: [.env]
    environment:
      - LOG_LEVEL=${LOG_LEVEL:-info}
  db:
    image: postgres:${PG_VERSION:-16}
    volumes:
      - db-data:/var/lib/postgresql/data
```

The encrypted `.env` files per environment (`dev.env.age`, `prod.env.age`)
contain all values that make the same `docker-compose.yml` behave differently
in dev vs prod.

## Project Structure

```
<project>/
  docker-compose.yml
  .env                                  # transient — created by deploy, deleted after
  .cursorrules                          # Cursor agent instructions (auto-installed, do not edit)
  envs/
    dev.env.age                         # age-encrypted full .env (committed to git)
    prod.env.age                        # same for prod (committed to git)
    dev.credentials.json                # DPAPI per-entry store (gitignored, Windows only)
    prod.credentials.json               # same for prod (gitignored, Windows only)
  secure-env-handle-and-deploy/
    CLAUDE.md                           # Claude Code agent instructions (auto-installed, do not edit)
    deploy.ps1                          # decrypt env + docker compose up
    env-run.ps1                         # load env + run any command + clean up
    encrypt-env.ps1                     # .env → envs/{env}.env.age
    decrypt-env.ps1                     # envs/{env}.env.age → .env (+ .secrets/ auto-split)
    store-env-to-credentials.ps1        # .env → DPAPI per-entry store
    generate-env-from-credentials.ps1   # DPAPI store → .env
    verify-env.ps1                      # compare all env layers for sync
    deploy.sh                           # Linux: decrypt + docker compose up
    env-run.sh                          # Linux: load env + run any command + clean up
    encrypt-env.sh                      # Linux: .env → .age
    decrypt-env.sh                      # Linux: .age → .env
    verify-env.sh                       # Linux: compare all env layers for sync
```

## Available Scripts (run from `secure-env-handle-and-deploy/`)

| Script | Purpose |
|--------|---------|
| `deploy.ps1` | Load env (DPAPI → age → .env fallback), run `docker compose up`, clean up |
| `env-run.ps1 {dev\|prod} "command"` | Load env, run any command, clean up (general-purpose) |
| `encrypt-env.ps1 {dev\|prod}` | Encrypt `.env` → `envs/{env}.env.age` for git |
| `decrypt-env.ps1 {dev\|prod} [-Full]` | Decrypt `envs/{env}.env.age` → `.env` + `.secrets/` (auto-split when `secrets.keys` exists; `-Full` skips split) |
| `store-env-to-credentials.ps1 {dev\|prod}` | Store `.env` entries in DPAPI (Windows, machine-bound) |
| `generate-env-from-credentials.ps1 {dev\|prod}` | Regenerate `.env` from DPAPI store |
| `verify-env.ps1 {dev\|prod}` | Compare .env, DPAPI, and age layers — report mismatches |

Linux equivalents: `deploy.sh`, `env-run.sh`, `encrypt-env.sh`, `decrypt-env.sh` (`--full` instead of `-Full`).

## Env Source Priority (used by deploy.ps1 and env-run.ps1)

1. **Existing `.env` file** — used as-is (highest priority, allows manual edits)
2. **DPAPI credential store** (`envs/{env}.credentials.json`) — no passphrase, Windows only
3. **age-encrypted file** (`envs/{env}.env.age`) — asks for passphrase

## Docker Secret File Mounts (optional)

By default, all env vars are injected via `env_file: [.env]`. For sensitive
values, Docker secret file mounts (`/run/secrets/`) are more secure — they
are not visible via `docker inspect`, `docker logs`, or `/proc/*/environ`.

**If no manifest exists, everything works as before — no changes needed.**

### Setup

1. Create `envs/secrets.keys` listing which keys are secrets (one per line):
   ```
   POSTGRES_PASSWORD
   WECLAPP_API_TOKEN
   SECRET_KEY
   ```
2. Add `secrets:` section to `docker-compose.yml`:
   ```yaml
   secrets:
     postgres_password:
       file: .secrets/POSTGRES_PASSWORD
     weclapp_api_token:
       file: .secrets/WECLAPP_API_TOKEN

   services:
     app:
       env_file: [.env]        # non-secret config
       secrets:
         - postgres_password
         - weclapp_api_token
       # App reads from /run/secrets/postgres_password
   ```
3. Update app code to read secrets from `/run/secrets/` instead of env vars.

### How it works

When `envs/secrets.keys` exists and is non-empty, all scripts (deploy, env-run,
decrypt-env) automatically split the decrypted content so that **secrets never
appear in `.env`** — not even temporarily:
- **`.env`** — non-secret config only (used by `env_file:`)
- **`.secrets/{KEY}`** — one file per secret (used by `secrets: file:`)

**Cleanup:** `.env` and `.env.full` are deleted after deploy/env-run completes.
`.secrets/` **persists** while containers are running (Docker Compose
bind-mounts these files). It is deleted automatically when running
`docker compose down` via env-run.
`decrypt-env` leaves all files on disk for inspection (use `-Full`/`--full` to
skip the split and write everything to a single file for debugging).

## When writing code that needs env vars

- Reference env vars by name (e.g., `DATABASE_URL`, `API_KEY`) — they will be
  available at runtime via `.env` loaded by Docker Compose.
- To see which keys exist: run `.\decrypt-env.ps1 dev -Full` to get a
  single `.env` with all entries, or inspect a `.credentials.json` with:
  ```powershell
  Get-Content envs/dev.credentials.json | ConvertFrom-Json | Get-Member -MemberType NoteProperty | Select-Object Name
  ```
- Add new env vars by editing `.env` and re-encrypting:
  ```powershell
  .\generate-env-from-credentials.ps1 dev   # creates .env from DPAPI
  # edit .env — add new var
  .\store-env-to-credentials.ps1 dev         # save back to DPAPI
  .\encrypt-env.ps1 dev                      # update .age for git
  ```

## Running Tasks with env-run

`env-run` is the general-purpose entry point for any Docker operation that needs
secrets. It loads `.env`, runs your command, and cleans up afterward.

```powershell
# Deploy (same as deploy.ps1)
.\env-run.ps1 dev "docker compose up --build -d"

# Run tests
.\env-run.ps1 dev "docker compose run --rm app pytest"

# Open a shell in a running container
.\env-run.ps1 dev "docker compose exec app bash"

# Run a one-off command
.\env-run.ps1 prod "docker compose exec app python manage.py collectstatic"
```

**Destructive commands require typing a confirmation word:**

```powershell
# Migration — requires typing "migrate"
.\env-run.ps1 dev "docker compose exec app python manage.py migrate"

# Data reset (down -v, volume rm, etc.) — requires typing "reset"
.\env-run.ps1 dev "docker compose down -v"
```

Linux:
```bash
./env-run.sh dev "docker compose run --rm app pytest"
```

**When to use env-run vs deploy.ps1:**
- `deploy.ps1` — quick "stand up the stack" with interactive prompts (env
  selection, DPAPI save offer). Best for routine deploys.
- `env-run.ps1` — scriptable, single command. Best for tests, migrations,
  debugging, or any non-deploy task that needs secrets.

## .gitignore requirements

These entries must be present in every project using this workflow:

```
.env
.env.full
*.credentials.json
secure-env-handle-and-deploy/
.secrets/
```

## Encryption Reference

- **age**: passphrase-based (scrypt + ChaCha20-Poly1305). No keys to manage.
  `.age` files are binary, safe to commit.
- **DPAPI** (Windows): per-entry encryption tied to the current Windows user +
  machine. `.credentials.json` files are useless if stolen — cannot be
  decrypted on another machine or by another user.

## Security Model

| Threat | Protection |
|--------|------------|
| Secrets in git history | `.env` gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy; never contains secrets when `secrets.keys` exists |
| `.secrets/` on disk | Persists while containers run (bind-mount); cleaned up on `docker compose down` |
| Machine destroyed | Recover from `.age` in git + passphrase from PasswordDepot |
