# Knowledge: Repository Overview

## Overview

`secure-env-handle` is a script library for managing Docker project secrets across Windows and Linux. It provides encrypted environment variable storage, deployment automation, optional Docker secret file mounts, and per-project script installation -- not an application itself.

**Languages:** PowerShell 5.1+, Bash
**License:** MIT (Grebec-IT, 2026)
**Distribution:** Git tags (semver), installed into target projects via `init-env-handle.ps1` / `.sh`
**Current version:** v1.5.0

---

## Repository Structure

```
secure-env-handle/
├── .claude/
│   ├── settings.local.json              Claude Code permissions (git ops, gh api)
│   └── commands/
│       └── suggest-secret-variable-split.md   Migration skill for Docker secrets
├── .cursorrules                          Agent instructions (identical to CLAUDE.md)
├── docs/
│   └── ai/
│       ├── design/                       Feature design docs
│       ├── implementation/               Knowledge docs (this folder)
│       ├── planning/                     Feature task breakdowns
│       └── requirements/                 Feature requirements
├── CLAUDE.md                             Agent instructions (identical to .cursorrules)
├── LICENSE                               MIT
├── README.md                             User-facing documentation
├── SECURITY.md                           Vulnerability reporting policy
│
├── init-env-handle.ps1 / .sh            Bootstrap: install scripts into target projects
│
├── deploy.ps1 / deploy.sh               Load env, split secrets, docker compose up, cleanup
├── env-run.ps1 / env-run.sh             Load env, split secrets, run any command, cleanup
├── encrypt-env.ps1 / encrypt-env.sh     .env -> envs/{env}.env.age
├── decrypt-env.ps1 / decrypt-env.sh     envs/{env}.env.age -> .env
├── verify-env.ps1 / verify-env.sh       Compare env layers, manifest awareness
├── store-env-to-credentials.ps1         .env -> DPAPI credential store (Windows)
└── generate-env-from-credentials.ps1    DPAPI credential store -> .env (Windows)
```

---

## How Everything Connects

```mermaid
flowchart TB
    subgraph "This Repo (secure-env-handle)"
        INIT["init-env-handle.ps1 / .sh"]
        SCRIPTS["12 workflow scripts"]
        SKILL["/suggest-secret-variable-split skill"]
        CLAUDE_MD["CLAUDE.md + .cursorrules"]
        README[README.md]
    end

    subgraph "GitHub"
        TAGS["Git tags (v1.x.0)"]
        API["GitHub API (version check)"]
        ZIP["Archive zip/tar.gz download"]
    end

    subgraph "Target Project"
        direction TB
        SEH["secure-env-handle-and-deploy/"]
        SEH_SCRIPTS["deploy, env-run, encrypt, decrypt, verify, ..."]
        SEH_CLAUDE["CLAUDE.md + .cursorrules"]
        PROJ_GITIGNORE[".gitignore (updated)"]
        ENVS["envs/"]
        AGE["dev.env.age, prod.env.age"]
        MANIFEST["secrets.keys (optional)"]
        CREDS["dev.credentials.json"]
        DOTENV[".env (transient)"]
        SECRETS[".secrets/ (transient)"]
        DOCKER["docker-compose.yml"]
    end

    INIT -->|"downloads archive"| ZIP
    INIT -->|"checks version"| API
    TAGS -->|"pins version"| ZIP
    INIT -->|"installs"| SEH
    SCRIPTS -->|"pruned + OS-filtered"| SEH_SCRIPTS
    CLAUDE_MD -->|"kept in subfolder"| SEH_CLAUDE
    INIT -->|"validates entries"| PROJ_GITIGNORE

    SEH_SCRIPTS -->|"encrypt/decrypt"| AGE
    SEH_SCRIPTS -->|"DPAPI store/load"| CREDS
    AGE --> DOTENV
    CREDS --> DOTENV
    DOTENV -->|"split by manifest"| SECRETS
    DOTENV -->|"env_file (config)"| DOCKER
    SECRETS -->|"secrets: file: (sensitive)"| DOCKER
    SEH_SCRIPTS -->|"deploy/env-run"| DOCKER

    ENVS --- AGE
    ENVS --- CREDS
    ENVS --- MANIFEST
    SEH --- SEH_SCRIPTS
    SEH --- SEH_CLAUDE
```

---

## Four Layers of the System

### 1. Distribution Layer (`init-env-handle.ps1` / `.sh`)

The bootstrap script that installs everything into target projects. Runs from a workspace root, operates on subdirectories.

- **Mode 1**: Clone org repos via GitHub token + install env-handle scripts
- **Mode 2**: Install env-handle scripts into existing project directories
- Downloads tagged archive from GitHub (no git clone, no `.git` directory)
- Prunes repo-only artifacts, filters by OS, validates `.gitignore`
- Configurable org name (cached in `~/.secure-env-handle.json`, `-a` to re-prompt in Mode 1)
- Gitignore enforces: `.env`, `*.credentials.json`, `secure-env-handle-and-deploy/`, `.secrets/`

See: [knowledge-init-env-handle.md](knowledge-init-env-handle.md)

### 2. Secret Management Layer (encrypt/decrypt/credentials scripts)

Handles the encryption lifecycle of `.env` files.

| Flow | Scripts | Storage |
|------|---------|---------|
| Encrypt for git | `encrypt-env.*` | `envs/{env}.env.age` (committed) |
| Decrypt from git | `decrypt-env.*` | `.env` (transient) |
| Store in DPAPI | `store-env-to-credentials.ps1` | `envs/{env}.credentials.json` (gitignored) |
| Load from DPAPI | `generate-env-from-credentials.ps1` | `.env` (transient) |
| Verify sync | `verify-env.*` | reads all layers, reports mismatches |

### 3. Execution Layer (deploy/env-run scripts)

Loads secrets and runs Docker commands.

- **deploy.\***: Interactive "stand up the stack" with env selection and cleanup prompts
- **env-run.\***: Scriptable single-command wrapper with safety gates for destructive ops
- Both use three-tier env source priority: existing `.env` > DPAPI > age
- Both auto-cleanup `.env` (and `.secrets/`, `.env.full` if split was performed)
- **Docker secrets split** (v1.5.0): when `envs/secrets.keys` exists, splits `.env` into config (stays in `.env`) + secrets (written to `.secrets/KEY` files)

See: [knowledge-env-workflow-scripts.md](knowledge-env-workflow-scripts.md), [knowledge-docker-secrets-split.md](knowledge-docker-secrets-split.md)

### 4. Migration Layer (`/suggest-secret-variable-split` skill)

A Claude Code slash command that assists migrating a project to Docker secrets:
- Scans docker-compose.yml, .env, and app code
- Classifies variables as secret or config using heuristics
- Populates `envs/secrets.keys` manifest
- Drafts docker-compose.yml changes and app code change plan

---

## Agent Instruction Files

Two files serve different AI coding assistants. **They must always be identical** -- the user uses both tools and needs consistent behavior. Both include a "DO NOT MODIFY" header for target projects.

| File | Target | Placement in target projects |
|------|--------|------------------------------|
| `CLAUDE.md` | Claude Code | Stays in `secure-env-handle-and-deploy/` |
| `.cursorrules` | Cursor IDE | Stays in `secure-env-handle-and-deploy/` (not copied to root) |

Content: rules for env vars, docker-compose conventions, script reference, Docker secrets setup, security model. When editing one, always copy to the other.

---

## Feature Documentation (docs/ai/)

| Feature | Purpose | Status |
|---------|---------|--------|
| `feature-agent-env-docs` | Auto-copy agent instructions to target projects | Implemented |
| `feature-versioning-and-gitignore` | Semver tags, version pinning, gitignore validation | Implemented |
| `feature-docker-secrets` | Docker secret file mounts via /run/secrets/ | Implemented (v1.5.0) |

---

## Versioning & Release Model

- **Scheme**: Git tags, semver (`v1.0.0`, `v1.1.0`, etc.)
- **Pinning**: `$Version` / `VERSION` in init scripts determines which tag is downloaded
- **Version check**: On startup, queries GitHub API for latest tag, offers update if outdated
- **Self-update limitation**: PowerShell locks the running script; update flow provides URL and exits

Release workflow:
1. Update `$Version` in `init-env-handle.ps1` and `VERSION` in `init-env-handle.sh`
2. Commit
3. `git tag -a v{X.Y.Z} -m "v{X.Y.Z}: description"`
4. `git push && git push --tags`

---

## Security Model

| Threat | Protection |
|--------|------------|
| Secrets in git history | `.env` gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy/env-run; only exists briefly |
| Secrets in docker inspect/logs | Optional `/run/secrets/` file mounts via `envs/secrets.keys` manifest |
| Machine destroyed | Recover from `.age` in git + passphrase from PasswordDepot |
| Vulnerability found | SECURITY.md: private advisory or email, 48h ack, 7d fix SLA |

---

## What This Repo Is NOT

- **Not an application** -- it's a script library installed into other projects
- **Not a global tool** -- scripts are copied per-project (each project gets its own copy)
- **Not cross-platform for DPAPI** -- DPAPI scripts are Windows-only; Linux uses age only
- **No CI/CD** -- no `.github/workflows`, no automated testing
- **No .gitignore at repo root** -- intentional; everything in this repo is committed. The gitignore validation in `Install-EnvHandle` targets the implementing projects.

---

## Metadata

| Field | Value |
|-------|-------|
| Analysis date | 2026-03-27 |
| Depth | Full repository |
| Files analyzed | All files, directory structure, docs/ai/ tree |
| Repo version | v1.5.0 |
| Related knowledge | [knowledge-init-env-handle.md](knowledge-init-env-handle.md), [knowledge-env-workflow-scripts.md](knowledge-env-workflow-scripts.md), [knowledge-docker-secrets-split.md](knowledge-docker-secrets-split.md) |

---

## Next Steps

- **CI/CD**: No automated testing or linting exists -- could add GitHub Actions for shellcheck/PSScriptAnalyzer
- **Test Docker secrets end-to-end**: Run deploy with a populated manifest in a real project
