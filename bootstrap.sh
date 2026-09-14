#!/bin/bash
# Secrets are read only from the operator's controlling terminal.
set +x +v
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SECRET_DIR=/root/.secrets
SECRET_FILE=${SECRET_DIR}/gh_pat.txt
CREDENTIAL_FILE=${SECRET_DIR}/git-credential-vps
CHECKOUT=/srv/repos/jamaynor/vps-services
REPOSITORY=https://github.com/jamaynor/vps-services.git

log() { printf '[vps-bootstrap] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

check_private_file() {
    [[ -f "$1" && ! -L "$1" ]] || fail "expected a regular credential file"
    [[ $(stat -c '%u:%a:%h' "$1") == 0:600:1 ]] || fail "credential file must be root-owned, mode 0600, with one link"
}

prompt_pat() {
    local pat
    printf 'GitHub PAT (hidden; saved for future installs): ' >/dev/tty
    if ! IFS= read -r -s pat </dev/tty; then
        printf '\n' >/dev/tty
        fail "credential entry cancelled; rerun when ready"
    fi
    printf '\n' >/dev/tty
    [[ "$pat" =~ ^[A-Za-z0-9_]+$ ]] || fail "empty or invalid credential; no value saved"
    local candidate
    candidate=$(mktemp "${SECRET_DIR}/.gh_pat.XXXXXX")
    printf '%s\n' "$pat" >"$candidate"
    unset pat
    chmod 600 "$candidate"
    mv -T "$candidate" "$SECRET_FILE"
}

install_credential() {
    umask 077
    [[ ! -L "$SECRET_DIR" ]] || fail "secret directory must not be a symlink"
    if [[ -e "$SECRET_DIR" ]]; then
        [[ -d "$SECRET_DIR" && $(stat -c '%u:%a' "$SECRET_DIR") == 0:700 ]] || fail "secret directory must be root-owned and mode 0700"
    else
        install -d -m 700 -o root -g root "$SECRET_DIR"
    fi
    if [[ -e "$SECRET_FILE" || -L "$SECRET_FILE" ]]; then
        check_private_file "$SECRET_FILE"
        log "using retained GitHub credential"
    else
        prompt_pat
    fi
    [[ ! -e "$CREDENTIAL_FILE" && ! -L "$CREDENTIAL_FILE" ]] || {
        [[ -f "$CREDENTIAL_FILE" && ! -L "$CREDENTIAL_FILE" && $(stat -c '%u:%h' "$CREDENTIAL_FILE") == 0:1 ]] || fail "unsafe credential helper path"
    }
    local candidate
    candidate=$(mktemp "${SECRET_DIR}/.credential.XXXXXX")
    cat >"$candidate" <<'CREDENTIAL'
#!/bin/bash
set +x +v
set -eu
# Invoked by Git, never by an agent to inspect stored credentials.
[[ ${1:-} == get ]] || exit 0
protocol= host= path=
while IFS='=' read -r key value && [[ -n "$key" ]]; do
    case "$key" in
        protocol) protocol=$value ;;
        host) host=$value ;;
        path) path=$value ;;
    esac
done
[[ "$protocol" == https && "$host" == github.com && "$path" == jamaynor/* ]] || exit 0
secret=/root/.secrets/gh_pat.txt
[[ ! -L /root/.secrets && $(stat -c '%u:%a' /root/.secrets) == 0:700 ]] || exit 1
[[ -f "$secret" && ! -L "$secret" && $(stat -c '%u:%a:%h' "$secret") == 0:600:1 ]] || exit 1
IFS= read -r pat <"$secret"
[[ "$pat" =~ ^[A-Za-z0-9_]+$ ]] || exit 1
printf 'username=x-access-token\npassword=%s\n' "$pat"
CREDENTIAL
    chmod 700 "$candidate"
    mv -T "$candidate" "$CREDENTIAL_FILE"
}

# No inherited Git tracing, injected configuration, askpass, or token environment.
trusted_git() {
    env -i HOME=/root PATH="$PATH" GIT_TERMINAL_PROMPT=0 \
        git -c credential.helper= -c "credential.helper=$CREDENTIAL_FILE" \
        -c credential.useHttpPath=true -c http.followRedirects=false "$@"
}

check_checkout_tree() {
    [[ -d "$CHECKOUT" && ! -L "$CHECKOUT" ]] || fail "checkout path is not a directory"
    # Git configuration and hooks are executable input to root. Check before Git runs.
    [[ -z $(find "$CHECKOUT" -xdev \( ! -user root -o -perm /022 -o -type l \) -print -quit) ]] || fail "checkout contains non-root-owned, writable, or symlinked paths; inspect it manually"
    [[ -d "$CHECKOUT/.git" && ! -L "$CHECKOUT/.git" ]] || fail "expected a standalone Git checkout"
}

prepare_checkout() {
    local directory
    for directory in /srv /srv/repos /srv/repos/jamaynor; do
        [[ ! -L "$directory" ]] || fail "source parent must not be a symlink"
        if [[ -e "$directory" ]]; then
            [[ -d "$directory" && $(stat -c %u "$directory") == 0 && -z $(find "$directory" -maxdepth 0 -perm /022 -print) ]] || fail "source parent must be root-owned and not group/world writable"
        else
            install -d -m 755 -o root -g root "$directory"
        fi
    done
    if [[ -e "$CHECKOUT" || -L "$CHECKOUT" ]]; then
        check_checkout_tree
        [[ $(trusted_git -C "$CHECKOUT" remote get-url origin) == "$REPOSITORY" ]] || fail "unexpected checkout origin"
        [[ -z $(trusted_git -C "$CHECKOUT" status --porcelain) ]] || fail "checkout has local changes; preserve and resolve them before rerunning"
        [[ $(trusted_git -C "$CHECKOUT" branch --show-current) == main ]] || fail "checkout is not on main; select its branch manually"
        trusted_git -C "$CHECKOUT" pull --ff-only origin main || fail "update failed; current installer was not launched"
    else
        # A failed clone may leave partial state. Preserve it for explicit operator inspection.
        trusted_git clone --branch main "$REPOSITORY" "$CHECKOUT" || fail "clone failed; check GitHub access and any partial checkout before rerunning"
    fi
    check_checkout_tree
}

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

One-command entry point for native Ubuntu service provisioning with
jamaynor/vps-services.

Options:
  --prereqs, --shared-prereqs, --prerequisites
      Install shared prerequisites only, print the checklist, and exit.
  --check, --status
      Display the status checklist for all shared prerequisites and exit.
  -h, --help
      Show this help message.

When run without options, shared prerequisites are checked and installed,
a status checklist is displayed with green checkmarks, and you are prompted
to either install VPS services or quit.
EOF
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

ensure_caddy() {
    if command -v caddy >/dev/null 2>&1 || package_installed caddy; then
        return 0
    fi
    log "installing Caddy"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y caddy 2>/dev/null; then
        log "adding official Caddy apt repository"
        install -d -o root -g root -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
            chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
        fi
        if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
            curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                -o /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
            chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
        fi
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    fi
}

ensure_gh() {
    if command -v gh >/dev/null 2>&1 || package_installed gh; then
        return 0
    fi
    log "installing GitHub CLI (gh)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y gh 2>/dev/null; then
        log "adding official GitHub CLI apt repository"
        mkdir -p -m 755 /etc/apt/keyrings
        if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1 || true
            chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
        fi
        if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                > /etc/apt/sources.list.d/github-cli.list
            chmod 0644 /etc/apt/sources.list.d/github-cli.list
        fi
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y gh
    fi
}

ensure_node_and_npm() {
    local need_node=false
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        need_node=true
    else
        local major_ver
        major_ver="$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1 || echo 0)"
        if [[ "$major_ver" =~ ^[0-9]+$ ]] && [[ "$major_ver" -lt 20 ]]; then
            need_node=true
        fi
    fi
    if [[ "$need_node" == true ]]; then
        log "installing Node.js 22 LTS and npm via NodeSource"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs 2>/dev/null || true
        fi
        if ! command -v node >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm 2>/dev/null || true
        fi
    fi
}

ensure_claude() {
    if command -v claude >/dev/null 2>&1 || [[ -x /usr/local/bin/claude || -x /usr/bin/claude ]]; then
        return 0
    fi
    log "installing Claude Code"
    local installed=false
    if command -v npm >/dev/null 2>&1; then
        if npm install -g --no-audit --no-fund @anthropic-ai/claude-code; then
            installed=true
        fi
    fi
    if [[ "$installed" == false ]] && command -v curl >/dev/null 2>&1; then
        if curl -fsSL https://claude.ai/install.sh | env CLAUDE_INSTALL_ALLOW_SUDO=1 bash; then
            installed=true
        fi
    fi
    if [[ -f /root/.local/bin/claude ]]; then
        cp -f /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null || true
    fi
    if [[ -x /usr/local/bin/claude ]]; then
        chmod 755 /usr/local/bin/claude 2>/dev/null || true
        ln -sf /usr/local/bin/claude /usr/bin/claude 2>/dev/null || true
    fi
    if command -v claude >/dev/null 2>&1 || [[ -x /usr/local/bin/claude || -x /usr/bin/claude ]]; then
        log "Claude Code installed successfully"
    else
        log "WARNING: Claude Code installation failed; check node/npm or install manually"
    fi
}

ensure_codex() {
    if command -v codex >/dev/null 2>&1 || [[ -x /usr/local/bin/codex || -x /usr/bin/codex ]]; then
        return 0
    fi
    log "installing OpenAI Codex CLI"
    if command -v npm >/dev/null 2>&1; then
        npm install -g --no-audit --no-fund @openai/codex || true
    fi
    if [[ -f /root/.local/bin/codex ]]; then
        cp -f /root/.local/bin/codex /usr/local/bin/codex 2>/dev/null || true
    fi
    if [[ -x /usr/local/bin/codex ]]; then
        chmod 755 /usr/local/bin/codex 2>/dev/null || true
        ln -sf /usr/local/bin/codex /usr/bin/codex 2>/dev/null || true
    fi
    if command -v codex >/dev/null 2>&1 || [[ -x /usr/local/bin/codex || -x /usr/bin/codex ]]; then
        log "OpenAI Codex CLI installed successfully"
    else
        log "WARNING: OpenAI Codex CLI installation failed"
    fi
}

ensure_copilot() {
    if command -v copilot >/dev/null 2>&1 || [[ -x /usr/local/bin/copilot || -x /usr/bin/copilot ]]; then
        return 0
    fi
    log "installing GitHub Copilot CLI"
    if command -v npm >/dev/null 2>&1; then
        npm install -g --no-audit --no-fund @github/copilot || true
    fi
    if [[ -f /root/.local/bin/copilot ]]; then
        cp -f /root/.local/bin/copilot /usr/local/bin/copilot 2>/dev/null || true
    fi
    if [[ -x /usr/local/bin/copilot ]]; then
        chmod 755 /usr/local/bin/copilot 2>/dev/null || true
        ln -sf /usr/local/bin/copilot /usr/bin/copilot 2>/dev/null || true
    fi
    if command -v copilot >/dev/null 2>&1 || [[ -x /usr/local/bin/copilot || -x /usr/bin/copilot ]]; then
        log "GitHub Copilot CLI installed successfully"
    else
        log "WARNING: GitHub Copilot CLI installation failed"
    fi
}

ensure_typescript() {
    if command -v tsc >/dev/null 2>&1 || [[ -x /usr/local/bin/tsc || -x /usr/bin/tsc ]]; then
        return 0
    fi
    if command -v npm >/dev/null 2>&1; then
        log "installing TypeScript"
        npm install -g --no-audit --no-fund typescript || true
    fi
    if [[ -x /usr/local/bin/tsc ]]; then
        chmod 755 /usr/local/bin/tsc 2>/dev/null || true
        ln -sf /usr/local/bin/tsc /usr/bin/tsc 2>/dev/null || true
    fi
}

ensure_antigravity_cli() {
    if command -v agy >/dev/null 2>&1 || command -v antigravity >/dev/null 2>&1 || [[ -x /usr/local/bin/agy || -x /usr/bin/agy ]]; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        log "installing Antigravity CLI"
        curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin || true
        if [[ ! -x /usr/local/bin/agy && -x /root/.local/bin/agy ]]; then
            cp -f /root/.local/bin/agy /usr/local/bin/agy 2>/dev/null || true
        fi
        if [[ -x /usr/local/bin/agy ]]; then
            chmod 755 /usr/local/bin/agy 2>/dev/null || true
            ln -sf /usr/local/bin/agy /usr/bin/agy 2>/dev/null || true
            ln -sf /usr/local/bin/agy /usr/bin/antigravity 2>/dev/null || true
        fi
    fi
    if command -v agy >/dev/null 2>&1 || [[ -x /usr/local/bin/agy || -x /usr/bin/agy ]]; then
        log "Antigravity CLI installed successfully"
    else
        log "WARNING: Antigravity CLI installation failed"
    fi
}

ensure_agent_paths() {
    # Ensure /etc/profile.d script exports /usr/local/bin for all login shells
    install -d -m 0755 -o root -g root /etc/profile.d
    cat >/etc/profile.d/vps-shared-path.sh <<'EOF'
case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) export PATH="/usr/local/sbin:/usr/local/bin:$PATH" ;;
esac
EOF
    chmod 0644 /etc/profile.d/vps-shared-path.sh

    # Ensure all agent binaries exist in /usr/local/bin and /usr/bin with world-executable permissions (755)
    local bin src
    for bin in claude codex copilot agy antigravity tsc; do
        src=""
        if [[ -x "/usr/local/bin/$bin" ]]; then
            src="/usr/local/bin/$bin"
        elif [[ -x "/root/.local/bin/$bin" ]]; then
            src="/root/.local/bin/$bin"
            cp -f "$src" "/usr/local/bin/$bin" 2>/dev/null || true
            chmod 755 "/usr/local/bin/$bin" 2>/dev/null || true
            src="/usr/local/bin/$bin"
        elif command -v "$bin" >/dev/null 2>&1; then
            src="$(command -v "$bin")"
        fi
        if [[ -n "$src" ]]; then
            chmod 755 "$src" 2>/dev/null || true
            if [[ "$src" != "/usr/bin/$bin" ]]; then
                ln -sf "$src" "/usr/bin/$bin" 2>/dev/null || true
            fi
            if [[ "$src" != "/usr/local/bin/$bin" ]]; then
                ln -sf "$src" "/usr/local/bin/$bin" 2>/dev/null || true
            fi
        fi
    done

    # Ensure antigravity alias exists if agy is present
    if [[ -x "/usr/bin/agy" && ! -e "/usr/bin/antigravity" ]]; then
        ln -sf "/usr/bin/agy" "/usr/bin/antigravity" 2>/dev/null || true
    fi

    # Target non-root users: SUDO_USER and ubuntu
    local target_users=()
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        target_users+=("${SUDO_USER}")
    fi
    if id -u ubuntu >/dev/null 2>&1; then
        if [[ " ${target_users[*]:-} " != *" ubuntu "* ]]; then
            target_users+=("ubuntu")
        fi
    fi

    local user user_home
    for user in "${target_users[@]}"; do
        user_home="$(getent passwd "$user" | cut -d: -f6 2>/dev/null || true)"
        if [[ -n "$user_home" && -d "$user_home" ]]; then
            install -d -m 0755 -o "$user" -g "$user" "$user_home/.local" "$user_home/.local/bin"
            for bin in claude codex copilot agy antigravity tsc caddy gh; do
                if [[ -x "/usr/bin/$bin" ]]; then
                    ln -sf "/usr/bin/$bin" "$user_home/.local/bin/$bin" 2>/dev/null || true
                elif [[ -x "/usr/local/bin/$bin" ]]; then
                    ln -sf "/usr/local/bin/$bin" "$user_home/.local/bin/$bin" 2>/dev/null || true
                fi
            done
            chown -h "$user:$user" "$user_home/.local/bin"/* 2>/dev/null || true

            # Also ensure ~/.bashrc has ~/.local/bin and /usr/local/bin
            if [[ -f "$user_home/.bashrc" ]] && ! grep -q 'vps-shared-path' "$user_home/.bashrc" 2>/dev/null; then
                printf '\n# VPS Shared Tooling PATH\nexport PATH="$HOME/.local/bin:/usr/local/bin:$PATH"\n' >> "$user_home/.bashrc"
                chown "$user:$user" "$user_home/.bashrc" 2>/dev/null || true
            fi
        fi
    done

    # Fix world-readable permissions for global npm node_modules
    if [[ -d /usr/local/lib/node_modules ]]; then
        chmod -R a+rX /usr/local/lib/node_modules 2>/dev/null || true
    fi
}

install_shared_prerequisites() {
    umask 022
    log "checking base OS packages"
    local base_pkgs=(
        ca-certificates
        curl
        git
        gnupg
        ufw
        python3
        python3-pip
        python3-venv
        python-is-python3
        nodejs
        npm
    )
    local missing_pkgs=()
    local pkg
    for pkg in "${base_pkgs[@]}"; do
        if ! package_installed "$pkg"; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log "installing missing OS packages: ${missing_pkgs[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_pkgs[@]}"
    fi

    ensure_node_and_npm
    ensure_caddy
    ensure_gh
    ensure_typescript
    ensure_claude
    ensure_codex
    ensure_copilot
    ensure_antigravity_cli
    ensure_agent_paths
}

display_prerequisites_status() {
    local green="" red="" reset=""
    if [[ -t 1 ]]; then
        green=$'\033[32m'
        red=$'\033[31m'
        reset=$'\033[0m'
    fi

    printf '\n=== Shared Prerequisites Status ===\n'

    check_status_item() {
        local name="$1"
        local cmd="$2"
        local check_type="${3:-cmd}"

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
            printf '  [%s✓%s] %-20s %s\n' "$green" "$reset" "$name" "$info"
        else
            printf '  [%s✗%s] %-20s missing\n' "$red" "$reset" "$name"
        fi
    }

    check_status_item "Git" "git"
    check_status_item "CA Certificates" "ca-certificates" "pkg"
    check_status_item "Curl" "curl"
    check_status_item "GnuPG" "gpg"
    check_status_item "UFW" "ufw"
    check_status_item "Python 3" "python3"
    check_status_item "Python" "python"
    check_status_item "Node.js" "node"
    check_status_item "NPM" "npm"
    check_status_item "TypeScript" "tsc"
    check_status_item "Caddy" "caddy"
    check_status_item "GitHub CLI" "gh"
    check_status_item "Claude Code" "claude"
    check_status_item "OpenAI Codex" "codex"
    check_status_item "GitHub Copilot" "copilot"
    check_status_item "Antigravity CLI" "agy"

    printf '===================================\n\n'
}

main() {
    local prereqs_only=false
    local check_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prereqs|--shared-prereqs|--prerequisites|--shared-prerequisites)
                prereqs_only=true
                shift
                ;;
            --check|--status)
                check_only=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "unknown argument: $1; this launcher takes no secret values or unrecognized flags"
                ;;
        esac
    done

    [[ ${EUID} == 0 ]] || fail "run with sudo from your own SSH terminal"
    if [[ "$prereqs_only" == false && "$check_only" == false ]]; then
        [[ -t 1 && -r /dev/tty && -w /dev/tty ]] || fail "run interactively in your own SSH terminal"
    fi
    [[ -r /etc/os-release ]] || fail "Ubuntu is required"
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || fail "Ubuntu is required"
    ulimit -c 0
    exec 9>/root/.vps-bootstrap.lock
    flock -n 9 || fail "another bootstrap is running"

    if [[ "$check_only" == true ]]; then
        display_prerequisites_status
        exit 0
    fi

    log "checking and installing shared prerequisites"
    install_shared_prerequisites
    display_prerequisites_status

    if [[ "$prereqs_only" == true ]]; then
        log "shared prerequisites installed successfully"
        exit 0
    fi

    install_credential
    # Source checkouts and installer output must remain readable build inputs.
    umask 022
    log "fetching the installer repository"
    prepare_checkout
    # Scope persistence to HTTPS GitHub requests; helper additionally limits owner to jamaynor.
    env -i HOME=/root PATH="$PATH" git config --global --replace-all credential.https://github.com.helper ''
    env -i HOME=/root PATH="$PATH" git config --global --add credential.https://github.com.helper "$CREDENTIAL_FILE"
    env -i HOME=/root PATH="$PATH" git config --global credential.https://github.com.useHttpPath true
    [[ -f "$CHECKOUT/install.sh" ]] || fail "service installer is missing"
    log "opening service selection"
    # Keep the checkout lock until installation ends. Only the parent holds it,
    # so service children cannot retain the bootstrap lock after exit.
    env -i HOME=/root USER=root LOGNAME=root PATH="/usr/local/sbin:/usr/local/bin:$PATH" \
        TERM="${TERM:-xterm}" bash "$CHECKOUT/install.sh" </dev/tty 9>&-
}

if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
