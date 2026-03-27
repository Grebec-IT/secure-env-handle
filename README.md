# secure-env-handle

Centralized deploy and secret management scripts for Docker projects using **age encryption** and **Windows DPAPI**.

## How it works

Three layers of secret storage, checked in priority order:

1. **Existing `.env` file** — used as-is if present (allows manual edits before deploy)
2. **Windows DPAPI** (`.credentials.json`) — per-entry encryption, zero-prompt deploys, machine-bound
3. **age encryption** (`.env.age`) — passphrase-based, committed to git, portable across machines

Scripts live in this repo and get installed into each project by
`init-env-handle.ps1` (Windows) or `init-env-handle.sh` (Linux).
Versioned with git tags — the init script pins to its own version.

## Assumptions

- Each project uses a single **`docker-compose.yml`** with `${VAR}` substitution from `.env`
- The `envs/` folder lives in the project root
- One shared passphrase across all projects (stored in PasswordDepot or equivalent)
- **age** is installed on the target machine

## Folder structure after setup

```
C:\Projects\
├── init-env-handle.ps1              ← manually copied here (entry point)
├── sobekon-db\
│   ├── docker-compose.yml
│   ├── envs\
│   │   ├── dev.env.age           ← committed to git
│   │   ├── prod.env.age          ← committed to git
│   │   └── secrets.keys          ← optional: lists keys for /run/secrets/
│   ├── .gitignore                ← includes secure-env-handle-and-deploy/, .secrets/
│   └── secure-env-handle-and-deploy\   ← installed from this repo, gitignored
│       ├── CLAUDE.md             ← agent instructions (auto-installed, do not edit)
│       ├── .cursorrules          ← same, for Cursor IDE
│       ├── deploy.ps1
│       ├── env-run.ps1
│       ├── encrypt-env.ps1
│       ├── decrypt-env.ps1
│       ├── verify-env.ps1
│       ├── store-env-to-credentials.ps1
│       └── generate-env-from-credentials.ps1
├── another-project\
│   └── secure-env-handle-and-deploy\
│       └── ...
```

## Scripts

### Windows (PowerShell)

| Script | Purpose |
|---|---|
| `deploy.ps1` | Load env → docker compose up → optional DPAPI save |
| `env-run.ps1` | Load env → run any command → clean up (general-purpose) |
| `encrypt-env.ps1` | `.env` → `envs/{env}.env.age` |
| `decrypt-env.ps1` | `envs/{env}.env.age` → `.env` |
| `store-env-to-credentials.ps1` | `.env` → DPAPI per-entry store (Windows only) |
| `generate-env-from-credentials.ps1` | DPAPI store → `.env` for editing (Windows only) |
| `verify-env.ps1` | Compare .env, DPAPI, and age layers — report mismatches |
| `init-env-handle.ps1` | Clone repos + deploy env scripts (versioned, with update check) |

### Linux (Bash)

| Script | Purpose |
|---|---|
| `deploy.sh` | Load env → docker compose up |
| `env-run.sh` | Load env → run any command → clean up (general-purpose) |
| `encrypt-env.sh` | `.env` → `envs/{env}.env.age` |
| `decrypt-env.sh` | `envs/{env}.env.age` → `.env` |
| `verify-env.sh` | Compare .env and age layers — report mismatches |
| `init-env-handle.sh` | Clone repos + deploy env scripts (Linux equivalent) |

> DPAPI is Windows-only. On Linux, use age encryption for all secret management.

## Usage

### First-time server setup

1. Download `init-env-handle.ps1` from this repo and place it in your projects directory
2. Run it:

```powershell
.\init-env-handle.ps1
# → enter GitHub token (masked, discarded after use)
# → select repos to clone
# → each repo gets a secure-env-handle-and-deploy/ subfolder with the right scripts
```

### Deploy (Windows)

```powershell
cd sobekon-db\secure-env-handle-and-deploy
.\deploy.ps1
# → select dev/prod
# → uses .env if present, else DPAPI, else decrypts .age
# → starts containers
# → offers to save to DPAPI for next time
# → deletes .env
```

### Deploy (Linux)

```bash
cd sobekon-db/secure-env-handle-and-deploy
./deploy.sh
# → select dev/prod
# → uses .env if present, else decrypts .age
# → starts containers
# → deletes .env
```

### Run arbitrary commands with env-run

`env-run` is the general-purpose entry point for any Docker operation that needs
secrets. It loads `.env`, runs your command, and cleans up afterward.

```powershell
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

### Encrypt/decrypt secrets

```powershell
# Encrypt current .env for git storage
.\encrypt-env.ps1 dev

# Decrypt to edit secrets
.\decrypt-env.ps1 dev
notepad ..\.env
.\encrypt-env.ps1 dev
Remove-Item ..\.env
```

### DPAPI credential management (Windows only)

```powershell
# Store .env entries in DPAPI (zero-prompt future deploys)
.\store-env-to-credentials.ps1 dev

# Regenerate .env from DPAPI store (for editing)
.\generate-env-from-credentials.ps1 dev
```

## Docker Secret File Mounts (optional)

By default, all env vars are injected via `env_file: [.env]`. For sensitive
values, you can use Docker secret file mounts (`/run/secrets/`) to prevent
exposure via `docker inspect`, logs, and `/proc/*/environ`.

**If you don't create a manifest file, everything works as before.**

### Enabling Docker secrets

1. Create `envs/secrets.keys` in your project listing which keys are secrets:
   ```
   POSTGRES_PASSWORD
   WECLAPP_API_TOKEN
   SECRET_KEY
   ```

2. Add the `secrets:` section to your `docker-compose.yml`:
   ```yaml
   secrets:
     postgres_password:
       file: .secrets/POSTGRES_PASSWORD

   services:
     app:
       env_file: [.env]        # non-secret config
       secrets:
         - postgres_password
       # App reads: /run/secrets/postgres_password
   ```

3. Update your app code to read from `/run/secrets/` (with env var fallback).

When `envs/secrets.keys` exists, deploy/env-run scripts automatically split
`.env` into config (stays in `.env`) and secrets (written to `.secrets/KEY`).
Both are cleaned up after use.

### Migration helper

If you use Claude Code, run `/suggest-secret-variable-split` in your project.
It scans your docker-compose, .env, and app code, then recommends which
variables should be secrets and drafts all required changes.

## Prerequisites

- **age** — `winget install FiloSottile.age` (Windows) or `brew install age` / `apt install age` (Linux)
- **git**
- **docker + docker compose**
- **GitHub fine-grained token** (read-only Contents) for `init-env-handle.ps1`

## Limitations

- One `docker-compose.yml` per project — all environment differences via `${VAR}` substitution from `.env`
- No support for multiple `.env` files or non-Docker deployments
- DPAPI is Windows-only — Linux uses age encryption only
- Bootstrap scripts (`init-env-handle.ps1` / `.sh`) require internet access to download from GitHub
- Scripts must be run from the `secure-env-handle-and-deploy/` subfolder inside a project

## Security model

| Threat | Protection |
|---|---|
| Secrets in git | `.env` is gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy; only exists briefly |
| Secrets in docker inspect/logs | Optional `/run/secrets/` file mounts (via `envs/secrets.keys` manifest) |
| Passphrase forgotten | Stored in PasswordDepot |
| This repo compromised | Scripts contain no secrets; pin to audited tag, review before updating |

## Updating scripts

Re-run `init-env-handle.ps1` (or `.sh`) — it deletes the old copy and downloads
the version-pinned tag fresh from GitHub. The script checks for newer versions
on startup and offers to update itself.

## Adding this to a new project

1. Run `init-env-handle.ps1` (mode 2 for existing projects)
2. It auto-creates `secure-env-handle-and-deploy/` (with `CLAUDE.md` and
   `.cursorrules` for coding agent support), updates `.gitignore`
3. Create and encrypt your env files from the subfolder

## Security Notice

**These scripts handle your secrets.** Before using them, you should understand
what they do:

- **Review the code.** The scripts are short and readable. Verify they only
  perform local encryption/decryption and do not transmit data anywhere.
- **Pin to a version.** `init-env-handle.ps1` clones a specific git tag. Audit
  that tag once, then stick with it until you've reviewed the next release.
- **Fork if in doubt.** If you don't want to trust upstream updates, fork the
  repo and control your own copy.

Like any open-source dependency, using this repo means trusting its maintainers.
The full git history is public — every change is visible and attributable. If you
find a security issue, please report it privately — see [SECURITY.md](SECURITY.md).
This software is provided under the [MIT License](LICENSE) with no warranty.

## License

[MIT](LICENSE)
