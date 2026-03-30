# Knowledge: Test Suite

## Overview

The test suite verifies the complete secret lifecycle: splitting, merging,
encryption round-trips, DPAPI round-trips, and Docker container integration.
All tests are plain PowerShell scripts (no Pester dependency) using custom
`Assert-True` / `Assert-Equal` functions that track pass/fail counts.

**Location:** `tests/`
**Language:** PowerShell 5.1+
**Run all:** `.\tests\Test-SecretSplit.ps1; .\tests\Test-EncryptMerge.ps1; .\tests\Test-RoundTrip.ps1`
**Run with Docker:** `.\tests\Test-DockerSecrets.ps1; .\tests\Test-DeployFlow.ps1`

Tests exit with code 1 on any failure, 0 on all-pass. Tests that require
unavailable prerequisites (age, Docker) gracefully SKIP instead of failing.

---

## Implementation Details

### Test Files

| File | Tests | Prerequisites | Cleanup | What it covers |
|------|-------|--------------|---------|----------------|
| `Test-SecretSplit.ps1` | 34 | None | Auto (temp dir) | Split function in isolation: files vs dirs, values, edge cases |
| `Test-EncryptMerge.ps1` | 18 | None | Auto (temp dir) | Merge logic: .env + .secrets/ combination, special chars |
| `Test-RoundTrip.ps1` | 95 | age + age-keygen (optional) | Auto (temp dir) | Full lifecycle: split, merge, encrypt/decrypt, DPAPI, deploy scenario |
| `Test-DockerSecrets.ps1` | 15 | Docker running | Auto (down + rm) | Secrets readable in containers, survive restart, update on redeploy |
| `Test-DeployFlow.ps1` | 17 | Docker running | **NO cleanup** | Real deploy flow with Docker, keeps artifacts for inspection |

**Total: 179 assertions** (164 without Docker, 32 with Docker)

### Test Architecture

Each test file follows the same pattern:

```powershell
$ErrorActionPreference = "Stop"
$passed = 0; $failed = 0

function Assert-True { ... $script:passed++ or $script:failed++ }
function Assert-Equal { ... prints hex diff on failure }

# Setup temp directory
$testRoot = Join-Path $env:TEMP "seh-test-$(Get-Random)"
Push-Location $testRoot

# Tests run in temp dir...

# Cleanup
Pop-Location
Remove-Item $testRoot -Recurse -Force

# Summary + exit code
if ($failed -gt 0) { exit 1 }
```

Tests are **isolated**: each creates a temp directory, runs assertions, cleans
up. No test depends on another test's state. Exception: `Test-DeployFlow.ps1`
intentionally leaves artifacts for manual inspection.

### Critical Invariants Guarded

| Invariant | Test | Assertion |
|-----------|------|-----------|
| Secrets are FILES, not directories | Split T1, T2; DeployFlow T2, T3 | `Test-Path -PathType Leaf` |
| Secret values have no BOM/newline | Split T10 | Byte-level check on last byte |
| `.env` never contains secret keys | Split T1, T5, T8; RoundTrip T1, T2b | `-notmatch` on .env content |
| Merge produces all entries | EncryptMerge T1; RoundTrip T2 | Count == 10, each value matches |
| Deploy with split .env + .secrets/ | **RoundTrip T2b** | `"Deploy split: 7 secrets (NOT 0!)"` |
| age encrypt/decrypt preserves all | RoundTrip T3 | 10 entries in, 10 out, values match |
| DPAPI store/restore preserves all | RoundTrip T4 | 10 entries in, 10 out, values match |
| Full lifecycle end-to-end | RoundTrip T5 | original → split → encrypt → decrypt → split → compare |
| Docker reads correct values | DockerSecrets T1, T4 | `cat /run/secrets/` matches expected |
| Secrets survive container restart | DockerSecrets T2 | Value unchanged after `docker compose restart` |
| Updated secrets after redeploy | DockerSecrets T3; DeployFlow T5 | New value after down+up |
| Docker creates dirs for missing | DeployFlow T1 | `Test-Path -PathType Container` (expected behavior) |
| WriteSecrets=false preserves old | DeployFlow T4 | Old value + no wipe |

---

### Test-SecretSplit.ps1 (34 assertions)

Tests the `Split-EnvSecrets` function extracted from `deploy.ps1`:

| # | Test | Key assertion |
|---|------|---------------|
| 1 | Basic split: files not dirs | `.secrets\KEY` is Leaf, values correct, `.env` has no secrets |
| 2 | Overwrite stale directories | Pre-create directory, split replaces with file |
| 3 | Value with `=` sign | `KEY=pass=word` → value is `pass=word` |
| 4 | Empty value | `KEY=` → empty file (0 bytes), still a file |
| 5 | Single key manifest | Array vs string edge case (wrapped in `@()`) |
| 6 | No manifest | Returns false, no `.secrets/` created |
| 7 | Empty manifest (comments only) | Returns false |
| 8 | WriteSecrets=false | `.env` is config-only, `.secrets/` not created |
| 9 | Comments and blank lines | Preserved in `.env` output |
| 10 | No trailing newline | Last byte is not `0x0A` or `0x0D` |

### Test-EncryptMerge.ps1 (18 assertions)

Tests the merge logic from `encrypt-env.ps1`:

| # | Test | Key assertion |
|---|------|---------------|
| 1 | Merge .env + .secrets/ | All 4 entries present in merged output |
| 2 | No .secrets/ | Only .env content, exact line count |
| 3 | Empty .secrets/ dir | No extra lines added |
| 4 | Special characters | `@`, `=`, `/` in values preserved |
| 5 | Round-trip: merge → split | Config in .env, secrets in .secrets/, values match |

### Test-RoundTrip.ps1 (95 assertions)

Uses 3 config + 7 secrets (10 total) to catch off-by-one errors:

| # | Test | Prerequisites | Key assertion |
|---|------|--------------|---------------|
| 1 | Split 10 → 3 config + 7 secrets | None | Counts, types, values |
| 2 | Merge reconstructs 10 | None | All 10 entries, values match |
| **2b** | **Deploy scenario** | **None** | **Config-only .env + .secrets/ → merge → split = 7 secrets (NOT 0!)** |
| 3 | age encrypt → decrypt | age, age-keygen | 10 in, 10 out, split correct after |
| 4 | DPAPI store → restore | Windows | 10 in, 10 out, values match |
| 5 | Full lifecycle | age, age-keygen | original → split → encrypt → decrypt → split → compare all 10 |

**Test 2b is the most important** — it catches the v1.6.0–v1.6.12 bug where
deploy loaded config-only `.env` without merging `.secrets/`, causing the split
to find 0 secrets and wipe `.secrets/`.

### Test-DockerSecrets.ps1 (15 assertions)

Requires Docker Desktop running. Cleans up after itself.

| # | Test | Key assertion |
|---|------|---------------|
| 1 | Secrets readable via /run/secrets/ | `cat` inside container matches expected value |
| 2 | Survive container restart | Same value after `docker compose restart` |
| 3 | Updated values after redeploy | New value after down + update + up |
| 4 | Split function → Docker | Values correct, env vars correct, secrets NOT in `/proc/1/environ` |

### Test-DeployFlow.ps1 (17 assertions)

Requires Docker Desktop. **Does NOT clean up** — artifacts left for inspection.

| # | Test | Key assertion |
|---|------|---------------|
| 1 | Docker creates dirs for missing secrets | `.secrets\KEY` is Container (expected) |
| 2 | Split replaces dirs with files | `.secrets\KEY` becomes Leaf, value correct |
| 3 | Files survive docker compose up | Still Leaf after up, container reads correct |
| 4 | WriteSecrets=false preserves old | Old value unchanged, `.env` updated |
| 5 | WriteSecrets=true updates values | New value, container reads new |

---

## Dependencies

### External Tools (optional, graceful skip)

| Tool | Required by | Skips if missing |
|------|------------|-----------------|
| `age` | RoundTrip T3, T5 | Yes — tests skip with message |
| `age-keygen` | RoundTrip T3, T5 | Yes — tests skip with message |
| Docker Desktop | DockerSecrets, DeployFlow | Yes — tests skip with message |
| Windows DPAPI | RoundTrip T4 | No skip — Windows-only test |

### Fixtures

| File | Purpose |
|------|---------|
| `tests/docker-test/docker-compose.yml` | Minimal alpine service with 2 secret mounts |
| `tests/docker-test/envs/` | Created at runtime for `secrets.keys` manifest |
| `tests/docker-test/.env` | Created at runtime (config entries) |
| `tests/docker-test/.secrets/` | Created at runtime (secret files) |

---

## Visual Diagrams

### Test Coverage Map

```
                    ┌──────────────────────┐
                    │   Test-SecretSplit    │
                    │   (34 assertions)    │
                    │   Split function     │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Test-EncryptMerge   │
                    │   (18 assertions)    │
                    │   Merge logic        │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Test-RoundTrip     │
                    │   (95 assertions)    │
                    │   Split + Merge +    │
                    │   age + DPAPI +      │
                    │   Deploy scenario    │
                    └──────────┬───────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
   ┌──────────▼───────────┐         ┌──────────▼───────────┐
   │  Test-DockerSecrets  │         │  Test-DeployFlow     │
   │   (15 assertions)    │         │   (17 assertions)    │
   │   Container reads    │         │   Dir→File, redeploy │
   │   Cleans up          │         │   Keeps artifacts    │
   └──────────────────────┘         └──────────────────────┘

   Unit tests (no Docker)           Integration tests (Docker required)
```

### What Each Layer Tests

```
encrypt-env ──merge──→ .age ──decrypt──→ split ──→ .env + .secrets/ ──→ Docker
     │                  │                  │              │                 │
     │           Test-RoundTrip      Test-RoundTrip  Test-RoundTrip   Test-Docker
     │              T3, T5              T3, T5          T1, T2b       Secrets T1-4
     │                                                                     │
Test-EncryptMerge                  Test-SecretSplit                  Test-DeployFlow
    T1-5                              T1-10                            T1-5
```

---

## Additional Insights

### How to Run

```powershell
# All unit tests (no Docker, ~5 seconds)
.\tests\Test-SecretSplit.ps1
.\tests\Test-EncryptMerge.ps1
.\tests\Test-RoundTrip.ps1

# Docker integration tests (~30 seconds, requires Docker running)
.\tests\Test-DockerSecrets.ps1
.\tests\Test-DeployFlow.ps1

# All at once
.\tests\Test-SecretSplit.ps1; .\tests\Test-EncryptMerge.ps1; .\tests\Test-RoundTrip.ps1; .\tests\Test-DockerSecrets.ps1; .\tests\Test-DeployFlow.ps1
```

### Design Decisions

- **No Pester dependency** — plain PowerShell scripts keep the test suite
  self-contained. Any machine with PowerShell can run them.
- **Temp directories** — each test creates a random temp dir, avoiding
  interference with the repo or other tests.
- **Hex diff on failure** — `Assert-Equal` prints hex bytes on mismatch,
  catching invisible issues like BOM or trailing newlines.
- **Docker tests skip gracefully** — if Docker isn't running, tests exit 0
  (skip), not 1 (failure). CI without Docker still passes.
- **DeployFlow keeps artifacts** — unlike other tests, it leaves `.secrets/`,
  `.env`, and running containers for manual inspection after the test.
- **Test 2b was added AFTER the bug** — the deploy-with-split-state scenario
  was missing from the original test suite. This is now the most important test.

### Test Data

RoundTrip uses 3 config + 7 secrets = 10 entries to catch off-by-one errors.
Secret values include special characters: `!`, `@`, `#`, `=`, `-`, `_`.

```
Config:  APP_PORT=8080, DB_SCHEMA=public, LOG_LEVEL=info
Secrets: POSTGRES_PASSWORD=pg_s3cret!, API_TOKEN=tok_abc123xyz,
         JWT_SECRET=eyJhbGciOiJIUzI1NiJ9, SMTP_PASSWORD=mail=pass@#,
         REDIS_PASSWORD=r3d!s, AUTHENTICATOR_PASSWORD=auth_pw_456,
         ENCRYPTION_KEY=aes-256-key-value
```

### What's NOT Tested

- **verify-env.ps1** — no tests for layer comparison or heuristic suggestions
- **init-env-handle.ps1** — no tests for self-update or installation logic
- **Linux (bash) scripts** — all tests are PowerShell; bash split/merge logic
  is identical but untested
- **Concurrent access** — no tests for multiple deploy.ps1 instances running
  simultaneously
- **Large .env files** — test data is small (10 entries); performance with
  hundreds of entries is untested

---

## Metadata

| Field | Value |
|-------|-------|
| Analysis date | 2026-03-30 |
| Depth | Full (all 5 test files, all assertions catalogued) |
| Files analyzed | Test-SecretSplit.ps1, Test-EncryptMerge.ps1, Test-RoundTrip.ps1, Test-DockerSecrets.ps1, Test-DeployFlow.ps1, docker-test/docker-compose.yml |
| Repo version | v1.6.13 |
| Total assertions | 179 (147 unit + 32 Docker integration) |
| Related knowledge | [knowledge-deploy-flow.md](knowledge-deploy-flow.md), [knowledge-env-full-lifecycle.md](knowledge-env-full-lifecycle.md) |

---

## Next Steps

- **Add bash tests** — port Test-SecretSplit to a `.sh` equivalent to verify the bash split logic
- **Add verify-env tests** — test layer comparison, manifest warnings, heuristic suggestions
- **CI integration** — run unit tests in GitHub Actions on push (skip Docker tests)
- **Test large .env** — generate 100+ entry .env files to test performance and edge cases
