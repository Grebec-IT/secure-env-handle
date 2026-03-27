#!/usr/bin/env bash
# Verify that all env storage layers are in sync for a given environment.
#
# Usage: ./verify-env.sh <dev|prod>
#
# Compares values across:
#   1. Existing .env file (if present)
#   2. age-encrypted file (if present — prompts for passphrase)
#
# Reports mismatches, missing keys, and overall sync status.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
NC='\033[0m'

ENV_NAME="${1:?Usage: $0 <dev|prod>}"

if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "prod" ]]; then
    echo "ERROR: Environment must be 'dev' or 'prod'." >&2
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

ENV_FILE=".env"
AGE_FILE="envs/${ENV_NAME}.env.age"

# -- Helper: parse .env file into KEY=VALUE lines (skip comments/blanks) ----
parse_env_file() {
    local file="$1"
    grep -v '^\s*#' "$file" | grep -v '^\s*$' | grep '='
}

# ==========================================================================
echo ""
echo "  Verify Env — $ENV_NAME"
echo "  ========================"
echo ""

# Temp files for layer data
env_data=""
age_data=""
layers_found=0
layer_names=()

# -- Detect available layers -----------------------------------------------

# Layer 1: .env file
if [ -f "$ENV_FILE" ]; then
    echo -e "  ${GREEN}[found]${NC}   .env"
    env_data="$(parse_env_file "$ENV_FILE")"
    layer_names+=("env")
    layers_found=$((layers_found + 1))
else
    echo -e "  ${GRAY}[absent]${NC}  .env"
fi

# Layer 2: age-encrypted file
if [ -f "$AGE_FILE" ]; then
    if command -v age > /dev/null 2>&1; then
        echo -e "  ${GREEN}[found]${NC}   $AGE_FILE — decrypting..."
        temp_file="$(mktemp /tmp/verify-env-XXXXXX)"
        if age --decrypt --output "$temp_file" "$AGE_FILE" 2>/dev/null; then
            age_data="$(parse_env_file "$temp_file")"
            layer_names+=("age")
            layers_found=$((layers_found + 1))
        else
            echo -e "  ${RED}[error]${NC}   age decryption failed"
        fi
        rm -f "$temp_file"
    else
        echo -e "  ${YELLOW}[skip]${NC}    $AGE_FILE — age not installed"
    fi
else
    echo -e "  ${GRAY}[absent]${NC}  $AGE_FILE"
fi

echo ""

# -- Check we have at least 2 layers to compare ----------------------------
if [ $layers_found -lt 2 ]; then
    echo -e "  ${YELLOW}Need at least 2 layers to compare. Found $layers_found.${NC}"
    echo ""
    exit 0
fi

# -- Load manifest (if present) --------------------------------------------
manifest="envs/secrets.keys"
declare -a secret_keys=()
has_manifest=false
if [ -f "$manifest" ]; then
    while IFS= read -r line; do
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        secret_keys+=("$line")
    done < "$manifest"
    if [ ${#secret_keys[@]} -gt 0 ]; then
        has_manifest=true
        echo -e "  Manifest:  envs/secrets.keys (${#secret_keys[@]} secret keys)"
        echo ""
    fi
fi

# -- Build associative arrays for comparison --------------------------------
declare -A env_vals age_vals all_keys

# Parse env layer
if [ -n "$env_data" ]; then
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        key="$(echo "$key" | xargs)"
        env_vals["$key"]="$value"
        all_keys["$key"]=1
    done <<< "$env_data"
fi

# Parse age layer
if [ -n "$age_data" ]; then
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        key="$(echo "$key" | xargs)"
        age_vals["$key"]="$value"
        all_keys["$key"]=1
    done <<< "$age_data"
fi

# -- Compare ---------------------------------------------------------------
in_sync=0
out_of_sync=0
missing=0

# Header
suggestions=()
if $has_manifest; then
    printf "  %-28s %-8s %-10s %-10s\n" "Key" "type" "env" "age"
    printf "  %-28s %-8s %-10s %-10s\n" "----------------------------" "--------" "----------" "----------"
else
    printf "  %-28s %-10s %-10s\n" "Key" "env" "age"
    printf "  %-28s %-10s %-10s\n" "----------------------------" "----------" "----------"
fi

for key in $(echo "${!all_keys[@]}" | tr ' ' '\n' | sort); do
    env_has="${env_vals[$key]+set}"
    age_has="${age_vals[$key]+set}"

    display_key="$key"
    if [ ${#display_key} -gt 26 ]; then
        display_key="${display_key:0:23}..."
    fi

    # Type classification
    type_str=""
    if $has_manifest; then
        is_secret=false
        for sk in "${secret_keys[@]}"; do
            [ "$key" = "$sk" ] && is_secret=true && break
        done
        if $is_secret; then
            type_str="$(printf '%-8s' 'secret')"
        else
            type_str="$(printf '%-8s' 'config')"
            # Heuristic: suggest if key looks sensitive
            if echo "$key" | grep -qiE 'PASSWORD|SECRET|TOKEN|CREDENTIAL|PRIVATE' || echo "$key" | grep -qE '_API_KEY$'; then
                suggestions+=("$key")
            fi
        fi
    fi

    if [ -z "$env_has" ] || [ -z "$age_has" ]; then
        missing=$((missing + 1))
        printf "  %-28s %s" "$display_key" "$type_str"
        if [ -n "$env_has" ]; then
            echo -ne "${GREEN}$(printf '%-10s' 'ok')${NC}"
        else
            echo -ne "${YELLOW}$(printf '%-10s' 'MISSING')${NC}"
        fi
        if [ -n "$age_has" ]; then
            echo -e "${GREEN}$(printf '%-10s' 'ok')${NC}"
        else
            echo -e "${YELLOW}$(printf '%-10s' 'MISSING')${NC}"
        fi
    elif [ "${env_vals[$key]}" = "${age_vals[$key]}" ]; then
        in_sync=$((in_sync + 1))
        printf "  %-28s %s" "$display_key" "$type_str"
        echo -e "${GREEN}$(printf '%-10s' 'ok')${NC}${GREEN}$(printf '%-10s' 'ok')${NC}"
    else
        out_of_sync=$((out_of_sync + 1))
        printf "  %-28s %s" "$display_key" "$type_str"
        env_preview="${env_vals[$key]:0:4}..."
        age_preview="${age_vals[$key]:0:4}..."
        echo -ne "${RED}$(printf '%-10s' "$env_preview")${NC}"
        echo -e "${RED}$(printf '%-10s' "$age_preview")${NC}  ${RED}MISMATCH${NC}"
    fi
done

# Warn about manifest keys not found in any layer
if $has_manifest; then
    for sk in "${secret_keys[@]}"; do
        if [ -z "${all_keys[$sk]+set}" ]; then
            echo ""
            echo -e "  ${YELLOW}WARNING: manifest key '$sk' not found in any layer${NC}"
        fi
    done
fi

# -- Summary ---------------------------------------------------------------
total_keys=${#all_keys[@]}
echo ""
echo "  ========================"
echo "  Layers compared: ${layer_names[*]}"
echo "  Keys total:      $total_keys"
echo -e "  In sync:         ${GREEN}$in_sync${NC}"
if [ $missing -gt 0 ]; then
    echo -e "  Missing:         ${YELLOW}$missing${NC}"
fi
if [ $out_of_sync -gt 0 ]; then
    echo -e "  Out of sync:     ${RED}$out_of_sync${NC}"
fi

if [ $out_of_sync -eq 0 ] && [ $missing -eq 0 ]; then
    echo ""
    echo -e "  ${GREEN}All layers are in sync.${NC}"
else
    echo ""
    if [ $out_of_sync -gt 0 ]; then
        echo -e "  ${RED}WARNING: $out_of_sync key(s) have different values across layers.${NC}"
        echo -e "  ${YELLOW}Re-run encrypt-env.sh to fix.${NC}"
    fi
    if [ $missing -gt 0 ]; then
        echo -e "  ${YELLOW}NOTE: $missing key(s) missing from one or more layers.${NC}"
    fi
fi

if [ ${#suggestions[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${YELLOW}Suggestion: these keys look sensitive but are NOT in envs/secrets.keys:${NC}"
    for s in "${suggestions[@]}"; do
        echo -e "    ${YELLOW}+ $s${NC}"
    done
fi
echo ""
