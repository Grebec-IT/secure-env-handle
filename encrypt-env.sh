#!/usr/bin/env bash
# Encrypt a .env file for storage in git
# Usage:
#   ./encrypt-env.sh dev          # encrypts ../.env → ../envs/dev.env.age
#   ./encrypt-env.sh prod         # encrypts ../.env → ../envs/prod.env.age
#   ./encrypt-env.sh dev my.env   # encrypts ../my.env → ../envs/dev.env.age
#
# Run from: <project>/secure-env-handle-and-deploy/

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

ENV_NAME="${1:?Usage: $0 <dev|prod> [input-file]}"
INPUT_FILE="${2:-.env}"

if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "prod" ]]; then
    echo "ERROR: Environment must be 'dev' or 'prod'." >&2
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: $INPUT_FILE not found in $PROJECT_ROOT" >&2
    exit 1
fi

if ! command -v age &>/dev/null; then
    echo "ERROR: age not found. Install with: brew install age (or apt install age)" >&2
    exit 1
fi

mkdir -p envs
OUTPUT="envs/${ENV_NAME}.env.age"

echo "Encrypting: $INPUT_FILE -> $OUTPUT"
echo "Enter a passphrase (save this in PasswordDepot):"
echo ""

age --passphrase --output "$OUTPUT" "$INPUT_FILE"

echo ""
echo "Encrypted: $OUTPUT"
echo ""
echo "Next steps:"
echo "  git add $OUTPUT"
echo "  git commit -m 'Update $ENV_NAME encrypted env'"
echo "  git push"
