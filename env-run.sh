#!/usr/bin/env bash
# General-purpose env runner: load env, execute command, clean up
#
# Usage:
#   ./env-run.sh dev "docker compose up --build -d"
#   ./env-run.sh dev "docker compose run --rm app pytest"
#   ./env-run.sh dev "docker compose exec app bash"
#   ./env-run.sh dev "docker compose down -v"
#
# Run from: <project>/secure-env-handle-and-deploy/
# Operates on the parent project directory.
#
# Env source priority:
#   1. Existing .env file (allows manual edits)
#   2. Encrypted .age file (asks for passphrase)
#
# When envs/secrets.keys exists, the loaded env is automatically split:
#   - .env contains config-only entries (used by env_file:)
#   - .secrets/KEY files contain secret values (used by secrets: file:)
# Secrets never appear in .env — not even temporarily.
#
# Note: No DPAPI on Linux — only age encryption is supported.
#
# Safety: commands containing "migrate" or data-destructive operations
# require typing a confirmation word before execution.

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PROJECT_NAME="$(basename "$PROJECT_ROOT")"

# -- Helper: split full env into config + secret files -------------------------
split_env_secrets() {
    local source_file="${1:-.env.full}"
    local manifest="envs/secrets.keys"
    [ -f "$manifest" ] || return 1

    local -a secret_keys=()
    while IFS= read -r line; do
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        secret_keys+=("$line")
    done < "$manifest"

    [ ${#secret_keys[@]} -eq 0 ] && return 1

    local secret_dir=".secrets"
    mkdir -p "$secret_dir"
    chmod 700 "$secret_dir"
    local split_count=0

    local config_lines=""
    while IFS= read -r line; do
        local trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -z "$trimmed" ] || [[ "$trimmed" == \#* ]]; then
            config_lines+="$line"$'\n'
            continue
        fi
        local key="${trimmed%%=*}"
        local value="${trimmed#*=}"

        local is_secret=false
        for sk in "${secret_keys[@]}"; do
            if [ "$key" = "$sk" ]; then
                is_secret=true
                break
            fi
        done

        if $is_secret; then
            printf '%s' "$value" > "$secret_dir/$key"
            split_count=$((split_count + 1))
        else
            config_lines+="$line"$'\n'
        fi
    done < "$source_file"

    # Write config-only .env — secrets never appear in this file
    printf '%s' "$config_lines" > .env

    echo "  Secrets: $split_count key(s) -> .secrets/"
    return 0
}

if [ $# -lt 2 ]; then
    echo "Usage: $0 {dev|prod} \"command\""
    echo ""
    echo "Examples:"
    echo "  $0 dev \"docker compose up --build -d\""
    echo "  $0 dev \"docker compose run --rm app pytest\""
    echo "  $0 dev \"docker compose exec app bash\""
    echo "  $0 dev \"docker compose down -v\""
    exit 1
fi

ENV_NAME="$1"
COMMAND="$2"

if [ "$ENV_NAME" != "dev" ] && [ "$ENV_NAME" != "prod" ]; then
    echo "ERROR: Environment must be 'dev' or 'prod'." >&2
    exit 1
fi

echo "========================================"
echo "  Run: $PROJECT_NAME ($ENV_NAME)"
echo "========================================"
echo ""
echo "  Command: $COMMAND"
echo ""

# -- Safety: confirm destructive commands -----------------------------------
cmd_lower="$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')"

if echo "$cmd_lower" | grep -q 'migrate'; then
    echo "  WARNING: This command involves a migration."
    echo ""
    read -rp "  Type 'migrate' to confirm: " confirm
    if [ "$confirm" != "migrate" ]; then
        echo "  Aborted."
        exit 1
    fi
    echo ""
fi

if echo "$cmd_lower" | grep -qE 'down .*(-v|--volumes)|volume (rm|prune)|system prune' || echo "$cmd_lower" | grep -qw 'reset'; then
    echo "  WARNING: This command will destroy data."
    echo ""
    read -rp "  Type 'reset' to confirm: " confirm
    if [ "$confirm" != "reset" ]; then
        echo "  Aborted."
        exit 1
    fi
    echo ""
fi

# Detect if this command stops containers (cleanup .secrets/ only then)
is_down_command=false
if echo "$cmd_lower" | grep -qw 'down'; then
    is_down_command=true
fi

# -- Load env into .env.full ------------------------------------------------
# All sources load into .env.full first — secrets never touch .env directly.
echo "Loading environment..."

env_created=false
from_source=""

# Try 1: Existing .env file (highest priority — allows manual edits)
if [ -f ".env" ]; then
    cp .env .env.full
    from_source="existing .env file"
fi

# Try 2: Encrypted .age file
if [ -z "$from_source" ]; then
    age_file="envs/${ENV_NAME}.env.age"
    if [ -f "$age_file" ]; then
        if ! command -v age &>/dev/null; then
            echo "ERROR: age not found. Install with: brew install age (or apt install age)" >&2
            exit 1
        fi
        echo "  No .env found. Decrypting $age_file..."
        echo "  Enter passphrase:"
        age --decrypt --output .env.full "$age_file"
        env_created=true
        from_source="age-encrypted file"
    fi
fi

if [ -z "$from_source" ]; then
    echo "ERROR: No env source found. Create a .env file or run encrypt-env.sh first." >&2
    exit 1
fi

echo "  Loaded from: $from_source"

# Split .env.full → .env (config) + .secrets/ (secrets)
secrets_split=false
if split_env_secrets ".env.full"; then
    secrets_split=true
else
    # No secrets manifest — full content becomes .env
    mv .env.full .env
fi
echo ""

# -- Execute command ---------------------------------------------------------
echo "Running..."
echo ""

# Cleanup: delete .env only if we created it (from age)
cleanup() {
    if [ "$env_created" = true ] && [ -f ".env" ]; then
        rm -f .env
        echo ""
        echo "  .env deleted."
    fi
    rm -f .env.full
    # .secrets/ is only cleaned up when containers are being stopped
    if [ "$secrets_split" = true ] && [ "$is_down_command" = true ] && [ -d ".secrets" ]; then
        rm -rf .secrets
        echo "  .secrets/ deleted."
    fi
}
trap cleanup EXIT

set +e
eval "$COMMAND"
cmd_exit=$?
set -e

echo ""
if [ $cmd_exit -eq 0 ]; then
    echo "========================================"
    echo "  Done ($ENV_NAME)"
    echo "========================================"
else
    echo "========================================"
    echo "  Failed (exit: $cmd_exit)"
    echo "========================================"
    exit $cmd_exit
fi
