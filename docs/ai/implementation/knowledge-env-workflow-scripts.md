# Knowledge: Environment Workflow Scripts

## Overview

The core of `secure-env-handle` is a set of 10 scripts (6 PowerShell for Windows, 4 Bash for Linux/macOS) that manage the full lifecycle of environment secrets: encryption, storage, decryption, deployment, and ad-hoc command execution.

**Languages:** PowerShell 5.1+, Bash (set -euo pipefail)
**External dependencies:** `age` (encryption), Docker/Docker Compose (deployment), Windows DPAPI (credential store)

All scripts live at the repo root and are copied into target projects under `secure-env-handle-and-deploy/` by `init-env-handle.ps1`.

---

## Implementation Details

### Script Inventory

| Script | Platform | Purpose |
|--------|----------|---------|
| `deploy.ps1` | Windows | Interactive deploy: load env, docker compose up, cleanup |
| `deploy.sh` | Linux | Same as above (no DPAPI tier) |
| `env-run.ps1` | Windows | Scriptable: load env, run any command, cleanup |
| `env-run.sh` | Linux | Same as above (no DPAPI tier) |
| `encrypt-env.ps1` | Windows | `.env` -> `envs/{env}.env.age` (age passphrase) |
| `encrypt-env.sh` | Linux | Same |
| `decrypt-env.ps1` | Windows | `envs/{env}.env.age` -> `.env` |
| `decrypt-env.sh` | Linux | Same |
| `store-env-to-credentials.ps1` | Windows | `.env` -> `envs/{env}.credentials.json` (DPAPI per-entry) |
| `generate-env-from-credentials.ps1` | Windows | `envs/{env}.credentials.json` -> `.env` |

### Three-Tier Env Source Priority

Used by `deploy.*` and `env-run.*` when loading secrets:

1. **Existing `.env` file** -- used as-is (allows manual edits, highest priority)
2. **DPAPI credential store** (`envs/{env}.credentials.json`) -- Windows only, no passphrase, machine-bound
3. **age-encrypted file** (`envs/{env}.env.age`) -- cross-platform, prompts for passphrase

### Core Patterns

#### Cleanup Behavior
- If `.env` was **pre-existing**, scripts leave it untouched
- If `.env` was **created** from DPAPI/age, scripts delete it after use
- `deploy.*` offers an interactive delete prompt; `env-run.*` auto-cleans via finally/trap

#### Safety Gates (env-run only)
Destructive commands require typed confirmation words:
- Commands containing `migrate` -> must type "migrate"
- Commands matching `down -v`, `volume prune`, `system prune`, `reset` -> must type "reset"

#### DPAPI Storage Model (Windows)
- Each `.env` key-value pair is encrypted individually via `System.Security.Cryptography.ProtectedData`
- Scope: `CurrentUser` (tied to Windows user profile + machine)
- Stored as Base64-encoded encrypted bytes in JSON
- Cannot be decrypted on a different machine or by a different user

#### age Encryption Model
- Passphrase-based: scrypt KDF + ChaCha20-Poly1305
- No key management needed -- just a passphrase (stored externally in PasswordDepot)
- `.age` files are binary, safe to commit to git

### Execution Flow: deploy.ps1

```
Start
  |
  v
Prompt: select environment (dev/prod)
  |
  v
Check .env exists? ----yes----> use it
  |no
  v
Check credentials.json? --yes--> DPAPI decrypt each entry -> write .env
  |no
  v
Check .env.age? ------yes-----> age --decrypt (prompt passphrase) -> write .env
  |no
  v
ERROR: no env source found
  |
  v
docker compose up --build -d
  |
  v
Offer: save .env to credential store? (if not loaded from DPAPI)
  |
  v
Offer: delete .env from disk?
  |
  v
Done
```

### Execution Flow: env-run.ps1

```
Start (args: EnvName, Command)
  |
  v
Validate params
  |
  v
Detect destructive command? --yes--> require confirmation word
  |
  v
Track: did .env already exist? (envExisted flag)
  |
  v
Load .env (same 3-tier priority)
  |
  v
Invoke-Expression $Command
  |
  v
Finally: if !envExisted -> delete .env
  |
  v
Exit with command's exit code
```

---

## Dependencies

### Internal (script-to-script)

```
encrypt-env.* <-------> decrypt-env.*          (encrypt/decrypt pair)
store-env-to-credentials <-> generate-env-from-credentials  (DPAPI pair)

deploy.* reads from:
  - envs/{env}.credentials.json (via inline DPAPI logic)
  - envs/{env}.env.age (via age CLI)

env-run.* reads from:
  - same sources as deploy.*
```

### External

| Dependency | Required By | Purpose |
|------------|-------------|---------|
| `age` | encrypt/decrypt scripts, deploy/env-run (tier 3) | Passphrase-based encryption |
| Docker + Compose | deploy, env-run | Container orchestration |
| DPAPI (`System.Security`) | store/generate credentials, deploy.ps1, env-run.ps1 | Windows-native encryption |
| `PasswordDepot` | Human operator | External passphrase storage for age |

---

## Visual Diagrams

### Secret Lifecycle

```mermaid
flowchart TB
    subgraph "Initial Setup"
        ENV[".env (plaintext)"]
        ENV -->|encrypt-env.*| AGE["envs/{env}.env.age<br/>(git-tracked)"]
        ENV -->|store-env-to-credentials.ps1| DPAPI["envs/{env}.credentials.json<br/>(gitignored, Windows)"]
    end

    subgraph "Recovery / Editing"
        AGE -->|decrypt-env.*| ENV2[".env (plaintext)"]
        DPAPI -->|generate-env-from-credentials.ps1| ENV2
    end

    subgraph "Deployment / Runtime"
        direction TB
        DEPLOY["deploy.* / env-run.*"]
        DEPLOY -->|"priority 1"| EXISTING[".env (if exists)"]
        DEPLOY -->|"priority 2"| DPAPI2["DPAPI store (Windows)"]
        DEPLOY -->|"priority 3"| AGE2[".age file"]
        DEPLOY --> DOCKER["docker compose up"]
        DEPLOY --> CLEANUP["delete .env (if created)"]
    end
```

### Platform Feature Matrix

```mermaid
graph LR
    subgraph Windows
        D1[deploy.ps1]
        E1[env-run.ps1]
        EN1[encrypt-env.ps1]
        DE1[decrypt-env.ps1]
        S1[store-env-to-credentials.ps1]
        G1[generate-env-from-credentials.ps1]
    end

    subgraph Linux/macOS
        D2[deploy.sh]
        E2[env-run.sh]
        EN2[encrypt-env.sh]
        DE2[decrypt-env.sh]
    end

    style S1 fill:#4a9,stroke:#333
    style G1 fill:#4a9,stroke:#333
```

*Green = Windows-only (DPAPI). Linux has no credential store equivalent -- relies on age passphrase.*

---

## Additional Insights

### Security Model

| Threat | Protection |
|--------|------------|
| Secrets in git history | `.env` gitignored; only encrypted `.age` files committed |
| Git repo compromised | `.age` files need passphrase to decrypt |
| Server compromised (offline) | DPAPI files unreadable without Windows user profile |
| `.env` on disk | Deleted after deploy/env-run; only exists briefly |
| Machine destroyed | Recover from `.age` in git + passphrase from PasswordDepot |

### Design Decisions

- **deploy.ps1 is interactive, env-run.ps1 is scriptable** -- deploy handles the common "stand up the stack" flow with prompts; env-run is a single-command wrapper for CI/scripts/ad-hoc use.
- **DPAPI is convenience, age is portability** -- DPAPI avoids passphrase fatigue on dev machines; age is the cross-platform/cross-machine fallback.
- **No per-environment compose files** -- a single `docker-compose.yml` uses `${VAR}` substitution; environment differences live entirely in the encrypted env files.
- **Cleanup is conditional** -- scripts track whether they created `.env` or found it pre-existing, to avoid deleting the user's manual edits.

### Potential Risks

- `env-run.ps1` uses `Invoke-Expression` / `env-run.sh` uses `eval` -- these execute arbitrary commands. This is intentional (the script's purpose), but the input comes from the local operator, not untrusted sources.
- DPAPI `.credentials.json` stores encrypted values but key names are plaintext -- key names are visible if the file is leaked.
- No automatic rotation mechanism -- passphrase and credential updates are manual.

---

## Metadata

| Field | Value |
|-------|-------|
| Analysis date | 2026-03-27 |
| Depth | Full (all 10 scripts) |
| Files analyzed | deploy.ps1, deploy.sh, env-run.ps1, env-run.sh, encrypt-env.ps1, encrypt-env.sh, decrypt-env.ps1, decrypt-env.sh, store-env-to-credentials.ps1, generate-env-from-credentials.ps1 |
| Repo version | v1.2.0 |

---

## Next Steps

- **Deeper dive candidates:** `init-env-handle.ps1` (installer/bootstrap), individual script internals
- **Possible improvements:** automated secret rotation, CI/CD integration patterns, Linux credential store alternative (e.g., `pass` or `secret-tool`)
