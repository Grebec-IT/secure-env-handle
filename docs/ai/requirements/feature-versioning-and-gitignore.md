---
feature: versioning-and-gitignore
status: draft
created: 2026-03-27
---

# Feature: Script versioning + gitignore secure-env-handle-and-deploy

## Problem Statement

1. The `secure-env-handle-and-deploy/` folder is cloned into target projects
   but not gitignored — it could accidentally be committed, creating a
   repo-inside-a-repo problem. Scripts should be treated as ephemeral tooling
   refreshed by init, not committed project code.

2. There is no versioning. If a breaking change is made to the scripts, all
   projects silently get the latest on next init run. There's no way to pin
   a known-good version, and no way to know if `init-env-handle.ps1` itself
   is outdated.

## Goals

- **G1**: Add `secure-env-handle-and-deploy/` to the required `.gitignore`
  entries managed by `Install-EnvHandle`.
- **G2**: Version the secure-env-handle repo with git tags (semver).
- **G3**: `init-env-handle.ps1` embeds its own version and checks it against
  the latest git tag on startup.
- **G4**: If outdated, offer: (1) Update script (copy URL / open browser),
  (2) Continue with current version.
- **G5**: `Install-EnvHandle` clones the tag matching the script's version,
  not just latest main.

## Non-Goals

- Auto-updating the script in-place (a running script can't reliably replace
  itself on Windows).
- Changelog generation or release notes.

## User Stories

1. **As a developer running init**, I want to be warned if my script is
   outdated so I don't unknowingly use old behavior.
2. **As a developer choosing "Update"**, I want a quick path to get the latest
   script (URL to clipboard or open in browser) since self-update isn't possible.
3. **As a developer choosing "Continue"**, I want the scripts installed to
   match the version of init I'm running, not latest main.
4. **As a developer**, I don't want `secure-env-handle-and-deploy/` committed
   to my project repo.

## Success Criteria

- [ ] `secure-env-handle-and-deploy/` is in the `.gitignore` required entries
- [ ] `init-env-handle.ps1` has a `$Version` variable matching a git tag
- [ ] On startup, script checks latest tag via GitHub API (public, no auth)
- [ ] Outdated version shows update/continue prompt before mode selection
- [ ] `Install-EnvHandle` clones at the specific version tag
- [ ] Running with an older version still works (clones that older tag)

## Open Questions

1. Should `.cursorrules` also be gitignored? (It's copied to project root —
   arguably it should be committed so Cursor users in the team see it.)
   **Decision: keep .cursorrules committed** — it's a project-level config.
