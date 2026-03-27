---
feature: versioning-and-gitignore
status: draft
created: 2026-03-27
---

# Planning: Script versioning + gitignore secure-env-handle-and-deploy

## Task Breakdown

### Task 1: Add secure-env-handle-and-deploy/ to .gitignore entries
- Add to `$requiredEntries` in `Install-EnvHandle`

### Task 2: Add $Version variable and version check on startup
- Add `$Version = "1.0.0"` near top of script
- Fetch latest tag from GitHub API (handle failure gracefully)
- Compare versions, show update/continue prompt if outdated
- Update option: copy URL to clipboard or open browser, then exit
- Continue option: proceed with embedded version

### Task 3: Pin Install-EnvHandle to version tag
- Change clone to `git clone --branch v{Version} --depth 1`
- Replace pull-if-exists with delete-and-re-clone (ensures exact version)

### Task 4: Update header comment
- Fix stale `Usage: .\setup-server.ps1` reference

### Task 5: Create initial git tag v1.0.0

## Implementation Order

1. Task 4 (trivial fix)
2. Task 1 (simple array addition)
3. Task 2 (version check — new block)
4. Task 3 (clone logic change)
5. Task 5 (tag after commit)
