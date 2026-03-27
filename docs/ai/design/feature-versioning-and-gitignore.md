---
feature: versioning-and-gitignore
status: draft
created: 2026-03-27
---

# Design: Script versioning + gitignore secure-env-handle-and-deploy

## Versioning Scheme

Use **git tags** with semver format: `v1.0.0`, `v1.1.0`, `v2.0.0`.

`init-env-handle.ps1` embeds: `$Version = "1.0.0"` near the top.

## Version Check Flow (runs before mode selection)

```
Startup
  │
  ├─ Fetch latest tag from GitHub API (public, no auth)
  │   GET https://api.github.com/repos/Grebec-IT/secure-env-handle/tags?per_page=1
  │
  ├─ If fetch fails → warn, continue (don't block offline usage)
  │
  ├─ If current == latest → show "v1.0.0 (up to date)", continue
  │
  └─ If current != latest → show warning:
       "You are running v1.0.0, latest is v1.2.0"
       1) Update script
          C) Copy download URL to clipboard
          B) Open in browser
          → then exit (can't self-update while running)
       2) Continue with current version
          → proceed normally, clone at v1.0.0 tag
```

### Update URLs

- **Raw file URL** (for clipboard):
  `https://raw.githubusercontent.com/Grebec-IT/secure-env-handle/v{latest}/init-env-handle.ps1`
- **Browser URL** (releases page):
  `https://github.com/Grebec-IT/secure-env-handle/releases/tag/v{latest}`

## Install-EnvHandle Changes

### Clone at specific tag

Current: `git clone {repo} {dir}`
New: `git clone --branch v{Version} --depth 1 {repo} {dir}`

- `--branch v{Version}` pins to the matching tag
- `--depth 1` since we don't need history for deployed scripts

### Update existing installs

Since `secure-env-handle-and-deploy/` is now gitignored (ephemeral),
simplify: **delete and re-clone** at the correct tag. No more `git pull`.
This guarantees exact version match and avoids merge conflicts.

### .gitignore entries

Add `secure-env-handle-and-deploy/` to the `$requiredEntries` array:

```powershell
$requiredEntries = @(".env", "*.credentials.json", "secure-env-handle-and-deploy/")
```

## Components Changed

1. **`init-env-handle.ps1`**:
   - Add `$Version` variable at top
   - Add version check block before mode selection
   - Update `Install-EnvHandle`: delete+re-clone at tag, add folder to gitignore
2. **Git repo**: create initial tag `v1.0.0` after implementation
