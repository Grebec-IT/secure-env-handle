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
# Note: No DPAPI on Linux — only age encryption is supported.

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PROJECT_NAME="$(basename "$PROJECT_ROOT")"

# -- Helper: split .env into config + secret files -------------------------
split_env_secrets() {
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

    # Backup full .env before splitting
    cp .env .env.full

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
    done < .env

    # Rewrite .env with config-only entries
    printf '%s' "$config_lines" > .env

    echo "      Secrets: $split_count key(s) -> .secrets/"
    return 0
}

echo "========================================"
echo "  Deploy: $PROJECT_NAME"
echo "========================================"
echo ""

# -- Step 1: Select environment -----------------------------------------
echo "[1/3] Select environment:"
echo "  1) dev"
echo "  2) prod"
read -rp "Choice [1/2]: " choice

case "$choice" in
    1|dev)  ENV_NAME="dev" ;;
    2|prod) ENV_NAME="prod" ;;
    *)
        echo "ERROR: Invalid choice." >&2
        exit 1
        ;;
esac

echo "Selected: $ENV_NAME"
echo ""

# -- Step 2: Load .env --------------------------------------------------
echo "[2/3] Loading environment..."

env_loaded=false
from_source=""

# Try 1: Existing .env file (highest priority — allows manual edits)
if [ -f ".env" ]; then
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
    age --decrypt --output .env "$age_file"
    env_loaded=true
    from_source="age-encrypted file"
fi

if [ "$env_loaded" = false ]; then
    echo "ERROR: No env source found. Create a .env file or run encrypt-env.sh first." >&2
    exit 1
fi

echo "      Loaded from: $from_source"

# Split secrets if manifest exists
secrets_split=false
if split_env_secrets; then
    secrets_split=true
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
read -rp "[Y/n]: " del
if [ "$del" != "n" ] && [ "$del" != "N" ]; then
    rm -f .env
    echo "      .env deleted."
fi

# Clean up secret files and backup
rm -f .env.full
if [ "$secrets_split" = true ] && [ -d ".secrets" ]; then
    rm -rf .secrets
    echo "      .secrets/ deleted."
fi

echo ""
echo "========================================"
echo "  Deploy complete: $ENV_NAME"
echo "========================================"
