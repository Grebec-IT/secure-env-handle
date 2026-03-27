Analyze this project's environment variables and Docker setup, then recommend which variables should be Docker secrets (file-mounted via /run/secrets/) versus plain config (env vars via .env).

## Steps

### 1. Version Check
- Read `secure-env-handle-and-deploy/CLAUDE.md` to confirm secure-env-handle is installed.
- Check for the "Docker Secret File Mounts" section. If missing, the installed version is outdated.
- If outdated, tell the user and ask if they want to update by re-running init-env-handle. Stop if they decline.

### 2. Scan docker-compose.yml
- Find and read all docker-compose files (docker-compose.yml, compose.yml, etc.).
- For each service, collect:
  - Variables from `env_file:` references
  - Variables from `environment:` sections
  - Any existing `secrets:` configuration
- Note which services exist and what images they use.

### 3. Scan .env
- Read the `.env` file if it exists.
- If no `.env`, check `envs/` for `.credentials.json` or `.env.age` and note that the user needs to decrypt first.
- Collect all KEY=VALUE pairs.

### 4. Classify Variables
For each variable found, classify using these heuristics:

**Auto-secret** (high confidence — add to manifest without asking):
- Key contains: `PASSWORD`, `SECRET`, `TOKEN`, `CREDENTIAL`, `PRIVATE`
- Key ends with: `_API_KEY`

**Auto-config** (high confidence — keep in .env without asking):
- Key matches: `PORT`, `HOST`, `LOG_LEVEL`, `VERSION`, `TAG`, `ENV`, `DEBUG`, `TIMEOUT`, `INTERVAL`
- Key is a URL without embedded credentials (no `://user:pass@` pattern)

**Uncertain** (ask the user):
- `DATABASE_URL` or similar connection strings (may contain embedded credentials)
- Keys containing `KEY` that aren't `_API_KEY` (e.g., `CACHE_KEY`, `PRIMARY_KEY`)
- Anything else that doesn't match either category

For uncertain variables, present them to the user one by one:
> `DATABASE_URL` — contains a connection string that may embed credentials.
> Classify as: [S]ecret / [C]onfig?

### 5. Read Existing Manifest
- Check if `envs/secrets.keys` already exists.
- If yes, load it and compare against the new classification.
- Show additions and removals.

### 6. Write/Update Manifest
- Write the classified secret keys to `envs/secrets.keys` with category comments.
- Show the user the final manifest content before writing.

### 7. Scan App Code for Required Changes
Search the project's source code for patterns that read the secret keys as env vars:

- Python: `os.getenv("KEY")`, `os.environ["KEY"]`, `os.environ.get("KEY")`, `decouple.config("KEY")`, pydantic `BaseSettings` field matching the key name
- JavaScript/TypeScript: `process.env.KEY`
- Shell: `$KEY`, `${KEY}`
- Go: `os.Getenv("KEY")`
- Java: `System.getenv("KEY")`
- Docker/Compose: `${KEY}` in docker-compose.yml environment sections

For each match, note:
- File path and line number
- Current pattern (e.g., `os.getenv("POSTGRES_PASSWORD")`)
- Required change (e.g., read from `/run/secrets/postgres_password` with env var fallback)

### 8. Draft docker-compose.yml Changes
Generate the `secrets:` section that needs to be added to docker-compose.yml:
- Top-level `secrets:` block with `file:` paths
- Per-service `secrets:` entries

Show as a diff or code block.

### 9. Present Full Plan
Summarize everything in a clear plan:

1. **Manifest** (`envs/secrets.keys`): list of secret keys (already written)
2. **docker-compose.yml changes**: the secrets section to add
3. **App code changes**: files and lines that need updating, with before/after examples
4. **Testing checklist**: steps to verify the migration works

Ask the user to review and confirm before making any code changes.
