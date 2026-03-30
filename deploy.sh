#!/usr/bin/env bash
# Deploy script: load env, start Docker containers
# Usage: ./deploy.sh
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

    echo "      Secrets: $split_count key(s) -> .secrets/"
    return 0
}

echo "========================================"
echo "  Deploy: $PROJECT_NAME"
echo "========================================"
echo ""

# -- Step 1: Select environment -----------------------------------------
ENV_NAME=""
while [ -z "$ENV_NAME" ]; do
    echo "[1/3] Select environment:"
    echo "  1) dev"
    echo "  2) prod"
    read -rp "Choice [1/2]: " choice

    case "$choice" in
        1|dev)  ENV_NAME="dev" ;;
        2|prod) ENV_NAME="prod" ;;
        *) echo "Invalid input. Please enter 1 or 2." ;;
    esac
done

echo "Selected: $ENV_NAME"
echo ""

# -- Step 2: Load env into .env.full ------------------------------------
# All sources load into .env.full first — secrets never touch .env directly.
echo "[2/3] Loading environment..."

env_loaded=false
from_source=""

# Try 1: Existing .env file (highest priority — allows manual edits)
if [ -f ".env" ]; then
    cp .env .env.full
    env_loaded=true
    from_source="existing .env file"
fi

# Try 2: Encrypted .age file
age_file="envs/${ENV_NAME}.env.age"
if [ "$env_loaded" = false ] && [ -f "$age_file" ]; then
    if ! command -v age &>/dev/null; then
        echo "ERROR: age not found. Install with: brew install age (or apt install age)" >&2
        exit 1
    fi
    echo "      No .env found. Decrypting $age_file..."
    echo "      Enter passphrase:"
    age --decrypt --output .env.full "$age_file"
    env_loaded=true
    from_source="age-encrypted file"
fi

if [ "$env_loaded" = false ]; then
    echo "ERROR: No env source found. Create a .env file or run encrypt-env.sh first." >&2
    exit 1
fi

echo "      Loaded from: $from_source"

# Split .env.full → .env (config) + .secrets/ (secrets)
secrets_split=false
if split_env_secrets ".env.full"; then
    secrets_split=true
else
    # No secrets manifest — full content becomes .env
    mv .env.full .env
fi
echo ""

# -- Step 3: Start containers -------------------------------------------
echo "[3/3] Starting Docker containers..."
docker compose up --build -d

echo ""
echo "      Containers running:"
docker compose ps
echo ""

# -- Cleanup: delete .env -----------------------------------------------
echo "Delete .env from disk?"
while true; do
    read -rp "[Y/n]: " del
    case "$del" in
        ""|[Yy]) rm -f .env; echo "      .env deleted."; break ;;
        [Nn]) break ;;
        *) echo "Invalid input. Please enter Y or N." ;;
    esac
done

# Clean up intermediate file
rm -f .env.full

# .secrets/ persists — Docker Compose bind-mounts these into containers.
# Cleaned up on 'docker compose down' via env-run.
if [ "$secrets_split" = true ]; then
    echo "      .secrets/ kept (required by running containers)."
fi

echo ""
echo "========================================"
echo "  Deploy complete: $ENV_NAME"
echo "========================================"
