# secure-env-handle

Centralized deploy and secret management scripts for Docker projects using **age encryption** and **Windows DPAPI**.

## How it works

Two layers of secret storage:

1. **age encryption** (`.env.age`) — passphrase-based, committed to git, portable across machines
2. **Windows DPAPI** (`.credentials.json`) — per-entry encryption, zero-prompt deploys, machine-bound

Scripts live in this repo and get pulled into each project by `setup-server.ps1`.

## Assumptions

- Each project uses a simple **`docker-compose.yml` + `.env`** pattern
- The `envs/` folder lives in the project root
- One shared passphrase across all projects (stored in PasswordDepot or equivalent)
- **age** is installed on the target machine

## Folder structure after setup

```
C:\Projects\
├── setup-server.ps1              ← manually copied here (entry point)
├── sobekon-db\
│   ├── docker-compose.yml
│   ├── envs\
│   │   ├── dev.env.age           ← committed to git
│   │   └── prod.env.age          ← committed to git
│   ├── .gitignore                ← includes secure-env-handle-and-deploy/
│   └── secure-env-handle-and-deploy\   ← cloned from this repo, gitignored
│       ├── deploy.ps1
│       ├── encrypt-env.ps1
│       ├── decrypt-env.ps1
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
| `deploy.ps1` | Decrypt env → docker compose up → optional DPAPI save |
| `encrypt-env.ps1` | `.env` → `envs/{env}.env.age` |
| `decrypt-env.ps1` | `envs/{env}.env.age` → `.env` |
| `store-env-to-credentials.ps1` | `.env` → DPAPI per-entry store (Windows only) |
| `generate-env-from-credentials.ps1` | DPAPI store → `.env` for editing (Windows only) |
| `setup-server.ps1` | First-time server setup: clone repos + pull env scripts |

### Linux (Bash)

| Script | Purpose |
|---|---|
| `deploy.sh` | Decrypt env → docker compose up |
| `encrypt-env.sh` | `.env` → `envs/{env}.env.age` |
| `decrypt-env.sh` | `envs/{env}.env.age` → `.env` |

> DPAPI is Windows-only. On Linux, use age encryption for all secret management.

## Usage

### First-time server setup

1. Download `setup-server.ps1` from this repo and place it in your projects directory
2. Run it:

```powershell
.\setup-server.ps1
# → enter GitHub token (masked, discarded after use)
# → select repos to clone
# → each repo gets a secure-env-handle-and-deploy/ subfolder with the right scripts
```

### Deploy (Windows)

```powershell
cd sobekon-db\secure-env-handle-and-deploy
.\deploy.ps1
# → select dev/prod
# → decrypts .age (or loads from DPAPI)
# → starts containers
# → offers to save to DPAPI for next time
# → deletes .env
```

### Deploy (Linux)

```bash
cd sobekon-db/secure-env-handle-and-deploy
./deploy.sh
# → select dev/prod
# → decrypts .age
# → starts containers
# → deletes .env
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

## Prerequisites

- **age** — `winget install FiloSottile.age` (Windows) or `brew install age` / `apt install age` (Linux)
- **git**
- **docker + docker compose**
- **GitHub fine-grained token** (read-only Contents) for `setup-server.ps1`

## Limitations

- Only works with projects that use a single `docker-compose.yml` + `.env` pattern
- No support for multiple `.env` files or non-Docker deployments
- DPAPI is Windows-only — Linux uses age encryption only
- `setup-server.ps1` is PowerShell — Linux servers need manual setup or a bash equivalent
- Scripts must be run from the `secure-env-handle-and-deploy/` subfolder inside a project

## Security model

| Threat | Protection |
|---|---|
| Secrets in git | `.env` is gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy; only exists briefly |
| Passphrase forgotten | Stored in PasswordDepot |
| This repo compromised | Contains only scripts, no secrets |

## Updating scripts

When scripts are updated in this repo, run `setup-server.ps1` again to pull the latest version into all projects. Or manually:

```bash
cd <project>/secure-env-handle-and-deploy
git pull
```

## Adding this to a new project

1. Add to the project's `.gitignore`:
   ```
   secure-env-handle-and-deploy/
   ```
2. Run `setup-server.ps1` (it will auto-create the subfolder)
3. Create and encrypt your env files from the subfolder
