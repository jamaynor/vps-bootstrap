#!/bin/bash
# Secrets are read only from the operator's controlling terminal.
set +x +v
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
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

main() {
    [[ ${EUID} == 0 ]] || fail "run with sudo from your own SSH terminal"
    [[ $# == 0 ]] || fail "this launcher takes no arguments or secret values"
    [[ -t 1 && -r /dev/tty && -w /dev/tty ]] || fail "run interactively in your own SSH terminal"
    [[ -r /etc/os-release ]] || fail "Ubuntu is required"
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || fail "Ubuntu is required"
    ulimit -c 0
    exec 9>/root/.vps-bootstrap.lock
    flock -n 9 || fail "another bootstrap is running"
    log "checking base packages"
    if ! command -v git >/dev/null || ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed'; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
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
