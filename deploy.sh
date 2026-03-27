#!/usr/bin/env bash
# Deploy script: load env, start Docker containers
# Usage: ./deploy.sh
#
# Run from: <project>/secure-env-handle-and-deploy/
# Operates on the parent project directory.
#
# Env source priority:
#   1. Encrypted .age file (asks for passphrase)
#   2. Existing .env file
#
# Note: No DPAPI on Linux — only age encryption is supported.

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PROJECT_NAME="$(basename "$PROJECT_ROOT")"

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

# Try 1: Encrypted .age file
age_file="envs/${ENV_NAME}.env.age"
if [ "$env_loaded" = false ] && [ -f "$age_file" ]; then
    if ! command -v age &>/dev/null; then
        echo "ERROR: age not found. Install with: brew install age (or apt install age)" >&2
        exit 1
    fi
    echo "      Decrypting $age_file..."
    echo "      Enter passphrase:"
    age --decrypt --output .env "$age_file"
    env_loaded=true
    from_source="age-encrypted file"
fi

# Try 2: Existing .env
if [ "$env_loaded" = false ] && [ -f ".env" ]; then
    env_loaded=true
    from_source="existing .env file"
fi

if [ "$env_loaded" = false ]; then
    echo "ERROR: No env source found. Run encrypt-env.sh first." >&2
    exit 1
fi

echo "      Loaded from: $from_source"
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

echo ""
echo "========================================"
echo "  Deploy complete: $ENV_NAME"
echo "========================================"
