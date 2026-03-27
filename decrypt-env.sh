#!/usr/bin/env bash
# Decrypt an .age file back to .env
# Usage:
#   ./decrypt-env.sh dev          # decrypts ../envs/dev.env.age → ../.env
#   ./decrypt-env.sh prod         # decrypts ../envs/prod.env.age → ../.env
#   ./decrypt-env.sh dev out.env  # decrypts ../envs/dev.env.age → ../out.env
#
# Run from: <project>/secure-env-handle-and-deploy/

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

ENV_NAME="${1:?Usage: $0 <dev|prod> [output-file]}"
OUTPUT_FILE="${2:-.env}"

if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "prod" ]]; then
    echo "ERROR: Environment must be 'dev' or 'prod'." >&2
    exit 1
fi

AGE_FILE="envs/${ENV_NAME}.env.age"

if [ ! -f "$AGE_FILE" ]; then
    echo "ERROR: $AGE_FILE not found. Encrypt first with: ./encrypt-env.sh $ENV_NAME" >&2
    exit 1
fi

if ! command -v age &>/dev/null; then
    echo "ERROR: age not found. Install with: brew install age (or apt install age)" >&2
    exit 1
fi

if [ -f "$OUTPUT_FILE" ]; then
    echo "WARNING: $OUTPUT_FILE already exists and will be overwritten."
    read -rp "Continue? [Y/n]: " confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "Decrypting: $AGE_FILE -> $OUTPUT_FILE"
echo "Enter passphrase:"
echo ""

age --decrypt --output "$OUTPUT_FILE" "$AGE_FILE"

echo ""
echo "Decrypted: $OUTPUT_FILE"
echo ""
echo "Remember to delete $OUTPUT_FILE when done:"
echo "  rm $OUTPUT_FILE"
