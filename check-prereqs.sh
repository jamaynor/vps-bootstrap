#!/bin/bash
# VPS Shared Prerequisites Status Checker and Service Launcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap.sh"
BOOTSTRAP_URL="https://raw.githubusercontent.com/jamaynor/vps-bootstrap/main/bootstrap.sh"

# Colors
if [[ -t 1 ]]; then
    GREEN=$'\033[32m'
    RED=$'\033[31m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    GREEN=""
    RED=""
    BOLD=""
    RESET=""
fi

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

TOTAL_COUNT=0
INSTALLED_COUNT=0
MISSING_COUNT=0

check_item() {
    local name="$1"
    local cmd="$2"
    local check_type="${3:-cmd}"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    local info=""
    local ok=false

    if [[ "$check_type" == "pkg" ]]; then
        if package_installed "$cmd"; then
            ok=true
            info="installed (deb)"
        fi
    else
        if command -v "$cmd" >/dev/null 2>&1; then
            ok=true
            info="$(command -v "$cmd")"
        elif [[ -x "/usr/local/bin/$cmd" ]]; then
            ok=true
            info="/usr/local/bin/$cmd"
        elif [[ -x "/usr/bin/$cmd" ]]; then
            ok=true
            info="/usr/bin/$cmd"
        fi
    fi

    if [[ "$ok" == true ]]; then
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
        printf '  [%s✓%s] %-22s %s\n' "${GREEN}" "${RESET}" "$name" "$info"
    else
        MISSING_COUNT=$((MISSING_COUNT + 1))
        printf '  [%s✗%s] %-22s %smissing%s\n' "${RED}" "${RESET}" "$name" "${RED}" "${RESET}"
    fi
}

display_status() {
    printf '\n%s=== VPS Shared Prerequisites Status ===%s\n' "${BOLD}" "${RESET}"

    check_item "Git" "git"
    check_item "CA Certificates" "ca-certificates" "pkg"
    check_item "Curl" "curl"
    check_item "GnuPG" "gpg"
    check_item "UFW" "ufw"
    check_item "Python 3" "python3"
    check_item "Python (symlink)" "python"
    check_item "Node.js" "node"
    check_item "NPM" "npm"
    check_item "TypeScript" "tsc"
    check_item "Caddy Web Server" "caddy"
    check_item "GitHub CLI (gh)" "gh"
    check_item "Claude Code" "claude"
    check_item "OpenAI Codex" "codex"
    check_item "GitHub Copilot" "copilot"
    check_item "Antigravity CLI (agy)" "agy"

    printf '%s========================================%s\n' "${BOLD}" "${RESET}"
    printf 'Summary: %s%d/%d installed%s' "${GREEN}" "$INSTALLED_COUNT" "$TOTAL_COUNT" "${RESET}"
    if [[ $MISSING_COUNT -gt 0 ]]; then
        printf ' (%s%d missing%s)\n\n' "${RED}" "$MISSING_COUNT" "${RESET}"
    else
        printf ' (all prerequisites present)\n\n'
    fi
}

launch_bootstrap() {
    local args=("$@")
    if [[ -f "$BOOTSTRAP_SCRIPT" ]]; then
        if [[ ${EUID:-0} == 0 ]]; then
            exec bash "$BOOTSTRAP_SCRIPT" "${args[@]}"
        else
            exec sudo bash "$BOOTSTRAP_SCRIPT" "${args[@]}"
        fi
    else
        if [[ ${EUID:-0} == 0 ]]; then
            exec curl -fsSL "$BOOTSTRAP_URL" | bash -s -- "${args[@]}"
        else
            exec curl -fsSL "$BOOTSTRAP_URL" | sudo bash -s -- "${args[@]}"
        fi
    fi
}

prompt_menu() {
    printf 'Next action:\n'
    printf '  1) Install VPS operations tools\n'
    if [[ $MISSING_COUNT -gt 0 ]]; then
        printf '  2) Install missing prerequisites\n'
        printf '  3) Exit\n\n'
        printf 'Select [1-3] (default: 1): '
    else
        printf '  2) Exit\n\n'
        printf 'Select [1-2] (default: 1): '
    fi

    local choice=""
    if ! IFS= read -r choice </dev/tty 2>/dev/null; then
        if ! IFS= read -r choice; then
            printf '\n'
            printf '[vps-bootstrap] Exiting.\n'
            exit 0
        fi
    fi
    choice="${choice:-1}"

    if [[ $MISSING_COUNT -gt 0 ]]; then
        case "$choice" in
            1|install|vps|y|Y|yes|YES)
                printf '[vps-bootstrap] Proceeding with VPS operations tools installation...\n'
                launch_bootstrap
                ;;
            2|prereqs|missing)
                printf '[vps-bootstrap] Installing missing prerequisites...\n'
                launch_bootstrap --prereqs
                ;;
            3|exit|Exit|quit|Quit|q|Q|n|N|no|NO)
                printf '[vps-bootstrap] Exiting.\n'
                exit 0
                ;;
            *)
                printf 'Invalid selection: %s\n' "$choice" >&2
                exit 1
                ;;
        esac
    else
        case "$choice" in
            1|install|vps|y|Y|yes|YES)
                printf '[vps-bootstrap] Proceeding with VPS operations tools installation...\n'
                launch_bootstrap
                ;;
            2|exit|Exit|quit|Quit|q|Q|n|N|no|NO)
                printf '[vps-bootstrap] Exiting.\n'
                exit 0
                ;;
            *)
                printf 'Invalid selection: %s\n' "$choice" >&2
                exit 1
                ;;
        esac
    fi
}

main() {
    local check_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|--status|-c)
                check_only=true
                shift
                ;;
            --install|--prereqs)
                launch_bootstrap --prereqs
                ;;
            -h|--help)
                printf 'Usage: check-prereqs.sh [options]\n\n'
                printf 'Checks prerequisites and presents options to install VPS operations tools or quit.\n\n'
                printf 'Options:\n'
                printf '  --check, -c    Display prerequisites checklist and exit\n'
                printf '  --install      Install missing shared prerequisites\n'
                printf '  -h, --help     Show this help\n'
                exit 0
                ;;
            *)
                printf 'Unknown argument: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done

    display_status

    if [[ "$check_only" == true ]]; then
        exit 0
    fi

    if [[ ! -t 0 && ! -r /dev/tty ]]; then
        exit 0
    fi

    prompt_menu
}

if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
