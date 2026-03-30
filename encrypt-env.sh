#!/usr/bin/env bash
# Encrypt a .env file for storage in git
# Usage:
#   ./encrypt-env.sh dev          # encrypts ../.env → ../envs/dev.env.age
#   ./encrypt-env.sh prod         # encrypts ../.env → ../envs/prod.env.age
#   ./encrypt-env.sh dev my.env   # encrypts ../my.env → ../envs/dev.env.age
#
# When .secrets/ exists (from a split deploy), secret values are merged
# back into the encrypted file automatically. The .age file always
# contains the complete set of config + secrets.
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

# Merge .env (config) + .secrets/ (secrets) into a temp file for encryption
encrypt_source="$INPUT_FILE"
temp_merged=""

if [ -d ".secrets" ]; then
    secret_count=0
    for f in .secrets/*; do
        [ -f "$f" ] && secret_count=$((secret_count + 1))
    done

    if [ $secret_count -gt 0 ]; then
        temp_merged="$(mktemp)"
        cp "$INPUT_FILE" "$temp_merged"

        for f in .secrets/*; do
            [ -f "$f" ] || continue
            key="$(basename "$f")"
            value="$(cat "$f")"
            echo "$key=$value" >> "$temp_merged"
        done
        encrypt_source="$temp_merged"
        echo "Merged: $INPUT_FILE + $secret_count secret(s) from .secrets/"
    fi
fi

echo "Encrypting: -> $OUTPUT"

age --passphrase --output "$OUTPUT" "$encrypt_source"

[ -n "$temp_merged" ] && rm -f "$temp_merged"

echo ""
echo "Encrypted: $OUTPUT"
echo ""
echo "Next steps:"
echo "  git add $OUTPUT"
echo "  git commit -m 'Update $ENV_NAME encrypted env'"
echo "  git push"
