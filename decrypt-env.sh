#!/usr/bin/env bash
# Decrypt an .age file back to .env
# Usage:
#   ./decrypt-env.sh dev          # decrypts ../envs/dev.env.age → ../.env (+ .secrets/ if manifest exists)
#   ./decrypt-env.sh prod         # decrypts ../envs/prod.env.age → ../.env (+ .secrets/ if manifest exists)
#   ./decrypt-env.sh dev out.env  # decrypts ../envs/dev.env.age → ../out.env (+ .secrets/ if manifest exists)
#   ./decrypt-env.sh dev --full   # decrypts everything into a single .env (no split)
#
# When envs/secrets.keys exists, the output is automatically split:
#   - .env (or output file) contains config-only entries
#   - .secrets/KEY files contain secret values
# Use --full to skip splitting and write everything to a single file.
#
# Run from: <project>/secure-env-handle-and-deploy/

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Parse arguments
FULL_MODE=false
ENV_NAME=""
OUTPUT_FILE=".env"

for arg in "$@"; do
    case "$arg" in
        --full) FULL_MODE=true ;;
        *)
            if [ -z "$ENV_NAME" ]; then
                ENV_NAME="$arg"
            else
                OUTPUT_FILE="$arg"
            fi
            ;;
    esac
done

if [ -z "$ENV_NAME" ]; then
    echo "Usage: $0 <dev|prod> [output-file] [--full]" >&2
    exit 1
fi

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
    while true; do
        read -rp "Continue? [Y/n]: " confirm
        case "$confirm" in
            ""|[Yy]) break ;;
            [Nn]) echo "Aborted."; exit 0 ;;
            *) echo "Invalid input. Please enter Y or N." ;;
        esac
    done
fi

# Check if we should split secrets
MANIFEST="envs/secrets.keys"
should_split=false

if [ "$FULL_MODE" = false ] && [ -f "$MANIFEST" ]; then
    secret_count=0
    while IFS= read -r line; do
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        secret_count=$((secret_count + 1))
    done < "$MANIFEST"
    [ $secret_count -gt 0 ] && should_split=true
fi

if [ "$should_split" = true ]; then
    # Decrypt to temp file, then split — secrets never touch the output file
    temp_file="$(mktemp)"
    echo "Decrypting: $AGE_FILE (splitting via envs/secrets.keys)"
    echo "Enter passphrase:"
    echo ""

    if ! age --decrypt --output "$temp_file" "$AGE_FILE"; then
        rm -f "$temp_file"
        echo "ERROR: Decryption failed." >&2
        exit 1
    fi

    # Read secret keys from manifest
    declare -a secret_keys=()
    while IFS= read -r line; do
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        secret_keys+=("$line")
    done < "$MANIFEST"

    # Split into config (output file) and secrets (.secrets/)
    secret_dir=".secrets"
    rm -rf "$secret_dir"
    mkdir -p "$secret_dir"
    chmod 700 "$secret_dir"
    split_count=0

    config_lines=""
    while IFS= read -r line; do
        trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -z "$trimmed" ] || [[ "$trimmed" == \#* ]]; then
            config_lines+="$line"$'\n'
            continue
        fi
        key="${trimmed%%=*}"
        value="${trimmed#*=}"

        is_secret=false
        for sk in "${secret_keys[@]}"; do
            if [ "$key" = "$sk" ]; then
                is_secret=true
                break
            fi
        done

        if $is_secret; then
            [ -d "$secret_dir/$key" ] && rm -rf "$secret_dir/$key"
            printf '%s' "$value" > "$secret_dir/$key"
            split_count=$((split_count + 1))
        else
            config_lines+="$line"$'\n'
        fi
    done < "$temp_file"

    printf '%s' "$config_lines" > "$OUTPUT_FILE"
    rm -f "$temp_file"

    echo ""
    echo "Decrypted (split mode):"
    echo "  Config:  $OUTPUT_FILE"
    echo "  Secrets: $split_count key(s) -> .secrets/"
    echo ""
    echo "Remember to delete both when done:"
    echo "  rm $OUTPUT_FILE"
    echo "  rm -rf .secrets"
else
    # No split — write everything to a single file
    echo "Decrypting: $AGE_FILE -> $OUTPUT_FILE"
    age --decrypt --output "$OUTPUT_FILE" "$AGE_FILE"

    echo ""
    echo "Decrypted: $OUTPUT_FILE"
    echo ""
    echo "Remember to delete $OUTPUT_FILE when done:"
    echo "  rm $OUTPUT_FILE"
fi
