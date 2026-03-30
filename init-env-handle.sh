#!/usr/bin/env bash
# Setup script: clone repos and/or deploy secure-env-handle scripts
#
# Usage: ./init-env-handle.sh [-a]
#
# Flags:
#   -a    Always prompt for GitHub organisation (overrides cached value)
#
# Modes:
#   1) Pull Git repos + setup secure-env-handle (server provisioning)
#   2) Setup secure-env-handle only (development / new project init)
#
# Prerequisites:
#   - curl, tar installed
#   - jq installed (for version check and mode 1)
#   - Git installed (mode 1 only)
#   - Docker + Docker Compose installed (for deployment)
#   - GitHub fine-grained token with read-only Contents access (mode 1 only)

set -euo pipefail

VERSION="1.6.6"
DEFAULT_ORG="Grebec-IT"
CONFIG_PATH="$HOME/.secure-env-handle.json"
TARGET_DIR="$(pwd)"
ASK_ORG=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Parse flags
while getopts "a" opt; do
    case $opt in
        a) ASK_ORG=true ;;
        *) echo "Usage: $0 [-a]"; exit 1 ;;
    esac
done

# -- Helper: deploy env-handle scripts into a project directory ------------
install_env_handle() {
    local repo_path="$1"
    local repo_name="$2"
    local env_handle_dir="$repo_path/secure-env-handle-and-deploy"

    # Always fresh download at the pinned version (folder is gitignored)
    if [ -d "$env_handle_dir" ]; then
        rm -rf "$env_handle_dir"
        echo -e "    env-scripts - ${YELLOW}removed old copy${NC}"
    fi

    echo -e "    env-scripts - ${CYAN}downloading v$VERSION...${NC}"
    local archive_url="https://github.com/${ORG}/secure-env-handle/archive/refs/tags/v${VERSION}.tar.gz"
    local temp_tar temp_extract
    temp_tar="$(mktemp /tmp/secure-env-handle-XXXXXX.tar.gz)"
    temp_extract="$(mktemp -d /tmp/secure-env-handle-extract-XXXXXX)"

    if ! curl -sfL "$archive_url" -o "$temp_tar"; then
        echo -e "    env-scripts - ${RED}FAILED (tag v$VERSION may not exist)${NC}"
        rm -f "$temp_tar"; rm -rf "$temp_extract"
        return
    fi

    # Verify we got a real tarball (not a 404 HTML page)
    if ! tar tzf "$temp_tar" > /dev/null 2>&1; then
        echo -e "    env-scripts - ${RED}FAILED (tag v$VERSION may not exist)${NC}"
        rm -f "$temp_tar"; rm -rf "$temp_extract"
        return
    fi

    # Extract and move the inner folder to the target path
    tar xzf "$temp_tar" -C "$temp_extract"
    local inner_dir
    inner_dir="$(find "$temp_extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
    mv "$inner_dir" "$env_handle_dir"
    rm -f "$temp_tar"
    rm -rf "$temp_extract"

    echo -e "    env-scripts - ${GREEN}installed v$VERSION${NC}"

    # Remove directories that belong to the source repo only
    for dir in docs .claude .github; do
        [ -d "$env_handle_dir/$dir" ] && rm -rf "$env_handle_dir/$dir"
    done

    # Remove files that belong at parent level only
    for file in init-env-handle.ps1 init-env-handle.sh setup-server.ps1 README.md env_handling.md LICENSE; do
        [ -f "$env_handle_dir/$file" ] && rm -f "$env_handle_dir/$file"
    done

    # Filter by OS: remove Windows scripts on Linux
    find "$env_handle_dir" -maxdepth 1 -name '*.ps1' -delete 2>/dev/null || true

    # -- Ensure .gitignore contains required entries ---------------------------
    local gitignore="$repo_path/.gitignore"
    local required=(".env" "*.credentials.json" "secure-env-handle-and-deploy/" ".secrets/")
    local missing=()

    for entry in "${required[@]}"; do
        if [ ! -f "$gitignore" ] || ! grep -qxF "$entry" "$gitignore"; then
            missing+=("$entry")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        echo -e "    .gitignore - ${YELLOW}missing entries for secure-env-handle:${NC}"
        for entry in "${missing[@]}"; do
            echo -e "      ${YELLOW}+ $entry${NC}"
        done
        read -rp "    Append to .gitignore? [Y/n] " approve
        if [ "$approve" != "n" ] && [ "$approve" != "N" ]; then
            # Add a blank line separator if file exists and doesn't end with newline
            if [ -f "$gitignore" ] && [ -s "$gitignore" ] && [ -n "$(tail -c1 "$gitignore")" ]; then
                echo "" >> "$gitignore"
            fi
            {
                echo ""
                echo "# secure-env-handle"
                for entry in "${missing[@]}"; do
                    echo "$entry"
                done
            } >> "$gitignore"
            echo -e "    .gitignore - ${GREEN}updated${NC}"
        else
            echo -e "    .gitignore - ${YELLOW}skipped (manual update needed)${NC}"
        fi
    else
        echo -e "    .gitignore - ${GREEN}already up to date${NC}"
    fi
}

# ==========================================================================
# Banner
# ==========================================================================
echo "========================================"
echo "  Secure Env Handle Setup  v$VERSION"
echo "========================================"
echo ""

# -- Resolve GitHub organisation silently (for version check) ---------------
cached_org=""
if [ -f "$CONFIG_PATH" ]; then
    cached_org="$(sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH" 2>/dev/null || true)"
fi
ORG="${cached_org:-$DEFAULT_ORG}"

# ==========================================================================
# Version check (public repo, no auth needed)
# ==========================================================================
if command -v jq > /dev/null 2>&1; then
    tags_json="$(curl -sf --max-time 5 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$ORG/secure-env-handle/tags?per_page=1" 2>/dev/null || true)"

    if [ -n "$tags_json" ]; then
        latest_tag="$(echo "$tags_json" | jq -r '.[0].name // empty' 2>/dev/null | sed 's/^v//')"

        if [ -n "$latest_tag" ]; then
            if [ "$latest_tag" = "$VERSION" ]; then
                echo -e "  ${GREEN}v$VERSION (up to date)${NC}"
            else
                echo -e "  ${YELLOW}WARNING: You are running v$VERSION, latest is v$latest_tag${NC}"
                echo ""
                echo "  1) Show download command"
                echo "  2) Continue with current version (v$VERSION)"
                echo ""
                read -rp "Choice [1/2]: " version_choice

                if [ "$version_choice" = "1" ]; then
                    raw_url="https://raw.githubusercontent.com/$ORG/secure-env-handle/v$latest_tag/init-env-handle.sh"
                    echo ""
                    echo -e "  ${CYAN}Download with:${NC}"
                    echo "  curl -sfL \"$raw_url\" -o init-env-handle.sh && chmod +x init-env-handle.sh"
                    echo ""
                    echo -e "  ${YELLOW}Re-run after updating. Exiting.${NC}"
                    exit 0
                fi
                echo ""
                echo -e "  ${YELLOW}Continuing with v$VERSION...${NC}"
            fi
        fi
    else
        echo -e "  ${YELLOW}Could not check for updates (offline?). Continuing with v$VERSION.${NC}"
    fi
else
    echo -e "  ${YELLOW}(jq not installed — skipping version check)${NC}"
fi

echo ""
echo "  1) Pull Git repos + setup secure-env-handle"
echo "  2) Setup secure-env-handle only (existing projects)"
echo ""
read -rp "Choose mode (1 or 2): " mode

if [ "$mode" != "1" ] && [ "$mode" != "2" ]; then
    echo "Invalid selection. Please enter 1 or 2." >&2
    exit 1
fi

# ==========================================================================
# MODE 1: Clone repos with token, then deploy env-handle
# ==========================================================================
if [ "$mode" = "1" ]; then
    echo ""
    echo "--- Mode 1: Pull Git Repos + Setup ---"
    echo ""

    # Check dependencies for mode 1
    for cmd in git jq; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Error: $cmd is required for Mode 1. Install it and retry." >&2
            exit 1
        fi
    done

    # -- GitHub organisation ---------------------------------------------------
    if $ASK_ORG || [ -z "$cached_org" ]; then
        suggestion="${cached_org:-$DEFAULT_ORG}"
        read -rp "  GitHub organisation [$suggestion]: " org_input
        ORG="${org_input:-$suggestion}"
        ORG="$(echo "$ORG" | xargs)"
        printf '{ "org": "%s" }\n' "$ORG" > "$CONFIG_PATH"
    else
        echo -e "  Organisation: ${GRAY}$ORG${NC} (use -a to change)"
    fi
    echo ""

    # -- GitHub token ----------------------------------------------------------
    echo "Enter your GitHub fine-grained token (read-only):"
    echo "(from: GitHub > Settings > Developer settings > Fine-grained tokens)"
    echo ""
    read -rsp "Token: " token
    echo ""

    if [ -z "$token" ]; then
        echo "No token provided." >&2
        exit 1
    fi

    # -- Fetch accessible repos from GitHub API --------------------------------
    echo ""
    echo "Fetching repos your token has access to..."

    repos_json="$(curl -sf \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/user/repos?per_page=100" 2>/dev/null)" || {
        echo "Failed to list repos. Check your token." >&2
        exit 1
    }

    # Filter to org, exclude secure-env-handle, sort
    mapfile -t org_repos < <(echo "$repos_json" | jq -r \
        --arg org "$ORG" \
        '.[] | select(.owner.login == $org and .name != "secure-env-handle") | .name' | sort)

    if [ ${#org_repos[@]} -eq 0 ]; then
        echo "No repos found for org $ORG. Check token permissions." >&2
        exit 1
    fi

    # -- Select repos ----------------------------------------------------------
    echo ""
    echo "Available repos (from token permissions):"
    for i in "${!org_repos[@]}"; do
        echo "  $((i+1))) ${org_repos[$i]}"
    done
    echo "  A) All"
    echo ""
    read -rp "Select repos (comma-separated numbers, or A for all): " selection

    if [ "$selection" = "A" ] || [ "$selection" = "a" ]; then
        selected_repos=("${org_repos[@]}")
    else
        selected_repos=()
        IFS=',' read -ra indices <<< "$selection"
        for idx in "${indices[@]}"; do
            idx="$(echo "$idx" | xargs)"
            selected_repos+=("${org_repos[$((idx-1))]}")
        done
    fi

    echo ""
    echo "Will clone: ${selected_repos[*]}"
    echo "Into: $TARGET_DIR"
    echo ""

    # -- Clone / Pull project repos --------------------------------------------
    clone_url="https://x-access-token:${token}@github.com/${ORG}"

    for repo in "${selected_repos[@]}"; do
        repo_path="$TARGET_DIR/$repo"

        if [ -d "$repo_path" ]; then
            echo -e "  $repo - ${YELLOW}already exists, pulling...${NC}"
            if git -C "$repo_path" pull --ff-only > /dev/null 2>&1; then
                echo -e "  $repo - ${GREEN}updated${NC}"
            else
                echo -e "  $repo - ${RED}pull FAILED${NC}"
            fi
        else
            echo -e "  $repo - ${CYAN}cloning...${NC}"
            if git clone "${clone_url}/${repo}.git" "$repo_path" > /dev/null 2>&1; then
                echo -e "  $repo - ${GREEN}cloned${NC}"
            else
                echo -e "  $repo - ${RED}FAILED${NC}"
                continue
            fi
        fi

        install_env_handle "$repo_path" "$repo"
    done

    # Clear token from memory
    token=""
    clone_url=""
fi

# ==========================================================================
# MODE 2: Setup secure-env-handle only (for existing subdirectories)
# ==========================================================================
if [ "$mode" = "2" ]; then
    echo ""
    echo "--- Mode 2: Setup Secure Env Handle Only ---"
    echo ""

    # List subdirectories (exclude hidden and secure-env-handle)
    mapfile -t subdirs < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' ! -name 'secure-env-handle' -printf '%f\n' | sort)

    if [ ${#subdirs[@]} -eq 0 ]; then
        echo "No project subdirectories found in $TARGET_DIR." >&2
        exit 1
    fi

    echo "Available projects:"
    for i in "${!subdirs[@]}"; do
        echo "  $((i+1))) ${subdirs[$i]}"
    done
    echo "  A) All"
    echo ""
    read -rp "Select projects (comma-separated numbers, or A for all): " selection

    if [ "$selection" = "A" ] || [ "$selection" = "a" ]; then
        selected_dirs=("${subdirs[@]}")
    else
        selected_dirs=()
        IFS=',' read -ra indices <<< "$selection"
        for idx in "${indices[@]}"; do
            idx="$(echo "$idx" | xargs)"
            selected_dirs+=("${subdirs[$((idx-1))]}")
        done
    fi

    echo ""
    echo "Will setup env-handle in: ${selected_dirs[*]}"
    echo ""

    for dir in "${selected_dirs[@]}"; do
        echo -e "  ${CYAN}$dir:${NC}"
        install_env_handle "$TARGET_DIR/$dir" "$dir"
    done
fi

# ==========================================================================
echo ""
echo "========================================"
echo -e "  ${GREEN}Setup complete${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo "  cd <project>/secure-env-handle-and-deploy"
echo "  ./deploy.sh"
