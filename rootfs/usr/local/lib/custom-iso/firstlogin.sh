#!/bin/bash
# First login of each user on an install from the custom ISO.
#  1. Latest Green Light, Kernel Pop, Steam Punk and Neural Forge AppImages
#     from GitHub, integrated through Gear Lever.
#  2. GNOME Remote Desktop: Desktop Sharing on 3390 (this user) and the
#     Remote Login on 3389 (system), one login asked for once.
#  3. NVIDIA GPU without its driver: point at Green Light.
# Each part is retried on the next login until it has succeeded.
set -uo pipefail

STATE="$HOME/.local/state/custom-iso"
mkdir -p "$STATE"
exec >> "$STATE/firstlogin.log" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
notify() { notify-send -a "Setup" -i "${2:-system-software-install}" "Setup" "$1" || true; }

gearlever() { flatpak run it.mijorus.gearlever "$@"; }

wait_for_network() {
    local _
    for _ in $(seq 1 60); do
        curl -fsS -o /dev/null -m 5 https://api.github.com && return 0
        sleep 5
    done
    return 1
}

# ── 1. AppImages ──────────────────────────────────────────────────────────
install_apps() {
    [[ -e "$STATE/apps-done" ]] && return 0
    wait_for_network || { log "No network: AppImages are retried next login"; return 1; }
    local repo url name dl ok=1
    mkdir -p "$HOME/.cache"
    dl="$(mktemp -d "$HOME/.cache/custom-iso-apps.XXXXXX")"
    for repo in green-light kernel-pop steam-punk neural-forge; do
        url="$(curl -fsSL "https://api.github.com/repos/labj1987/$repo/releases/latest" \
            | jq -r '.assets[] | select(.name | endswith("-x86_64.AppImage")) | .browser_download_url' | head -1)"
        if [[ -z "$url" ]]; then log "ERROR: no AppImage in the latest $repo release"; ok=0; continue; fi
        name="$(basename "$url")"
        if curl -fsSL -o "$dl/$name" "$url"; then
            chmod +x "$dl/$name"
            # Exits 0 with "already integrated" when it is.
            if gearlever --integrate "$dl/$name" -y; then
                log "Integrated $name"
            else
                log "ERROR: Gear Lever could not integrate $name"; ok=0
            fi
        else
            log "ERROR: download failed: $url"; ok=0
        fi
    done
    rm -rf "$dl"
    (( ok )) && { touch "$STATE/apps-done"; notify "Green Light, Kernel Pop, Steam Punk and Neural Forge are installed."; }
}

# ── 2. Remote desktop ─────────────────────────────────────────────────────
setup_rdp() {
    [[ -e "$STATE/rdp-done" ]] && return 0
    local d="$HOME/.local/share/gnome-remote-desktop" form user pass
    mkdir -p "$d"
    if [[ ! -f "$d/rdp-tls.crt" ]]; then
        openssl req -new -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=$(hostname)" \
            -keyout "$d/rdp-tls.key" -out "$d/rdp-tls.crt" 2>/dev/null
        chmod 0600 "$d/rdp-tls.key"
    fi
    # The username/password dialog submits on Enter (a --forms dialog doesn't).
    # It prints "user|password"; a username cannot contain "|".
    form="$(zenity --password --username \
        --title="RDP login for this computer (Desktop Sharing 3390, Remote Login 3389)" 2>/dev/null)" \
        || { log "Remote desktop login skipped; asked again next login"; return 1; }
    user="${form%%|*}"; pass="${form#*|}"
    [[ -n "$user" && -n "$pass" ]] || { log "Empty remote desktop login; asked again next login"; return 1; }

    # Desktop Sharing: this user's live session.
    grdctl rdp set-tls-cert "$d/rdp-tls.crt" \
        && grdctl rdp set-tls-key "$d/rdp-tls.key" \
        && grdctl rdp set-credentials "$user" "$pass" \
        && grdctl rdp disable-view-only \
        && grdctl rdp set-port 3390 \
        && grdctl rdp disable-port-negotiation \
        && grdctl rdp enable \
        && systemctl --user enable --now gnome-remote-desktop.service \
        || { log "ERROR: Desktop Sharing setup failed"; return 1; }

    # Remote Login: the login screen (system service, set up at first boot).
    sudo -n grdctl --system rdp set-credentials "$user" "$pass" \
        && sudo -n systemctl restart gnome-remote-desktop.service \
        || { log "ERROR: Remote Login credentials failed"; return 1; }
    user=""; pass=""; form=""
    touch "$STATE/rdp-done"
    log "Remote desktop ready: 3390 Desktop Sharing, 3389 Remote Login"
}

# ── 3. NVIDIA driver hint ─────────────────────────────────────────────────
nvidia_hint() {
    [[ -e "$STATE/nvidia-hint-done" ]] && return 0
    if lspci -n | grep -qE ' 03[0-9a-f]{2}: 10de:' && ! lsmod | grep -q '^nvidia '; then
        notify "An NVIDIA GPU was found without its driver. Open Green Light to install it." video-display
    fi
    touch "$STATE/nvidia-hint-done"
}

install_apps
setup_rdp
nvidia_hint
if [[ -e "$STATE/apps-done" && -e "$STATE/rdp-done" ]]; then
    touch "$STATE/done"
fi
