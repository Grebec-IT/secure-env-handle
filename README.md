# secure-env-handle

Centralized deploy and secret management scripts for Docker projects using **age encryption** and **Windows DPAPI**.

## How it works

Two layers of secret storage:

1. **age encryption** (`.env.age`) — passphrase-based, committed to git, portable across machines
2. **Windows DPAPI** (`.credentials.json`) — per-entry encryption, zero-prompt deploys, machine-bound

Scripts live in this repo and get pulled into each project by `init-env-handle.ps1`.
Versioned with git tags — the init script pins to its own version.

## Assumptions

- Each project uses a simple **`docker-compose.yml` + `.env`** pattern
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
| `init-env-handle.ps1` | Clone repos + deploy env scripts (versioned, with update check) |

### Linux (Bash)

| Script | Purpose |
|---|---|
| `deploy.sh` | Decrypt env → docker compose up |
| `encrypt-env.sh` | `.env` → `envs/{env}.env.age` |
| `decrypt-env.sh` | `envs/{env}.env.age` → `.env` |

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
- **GitHub fine-grained token** (read-only Contents) for `init-env-handle.ps1`

## Limitations

- Only works with projects that use a single `docker-compose.yml` + `.env` pattern
- No support for multiple `.env` files or non-Docker deployments
- DPAPI is Windows-only — Linux uses age encryption only
- `init-env-handle.ps1` is PowerShell — Linux servers need manual setup or a bash equivalent
- Scripts must be run from the `secure-env-handle-and-deploy/` subfolder inside a project

## Security model

| Threat | Protection |
|---|---|
| Secrets in git | `.env` is gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy; only exists briefly |
| Passphrase forgotten | Stored in PasswordDepot |
| This repo compromised | Scripts contain no secrets; pin to audited tag, review before updating |

## Updating scripts

Re-run `init-env-handle.ps1` — it deletes the old copy and clones the
version-pinned tag fresh. The script checks for newer versions on startup
and offers to update itself.

## Adding this to a new project

1. Run `init-env-handle.ps1` (mode 2 for existing projects)
2. It auto-creates `secure-env-handle-and-deploy/`, updates `.gitignore`,
   copies `.cursorrules` and `CLAUDE.md` for coding agent support
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
