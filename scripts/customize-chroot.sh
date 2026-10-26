#!/bin/bash
# Runs INSIDE the 26.10 chroot (the stacked install layers with an overlay
# upper dir). Everything written here ends up in the custom layer that the
# installer copies to disk. Build-only settings (proxy, CA, policy-rc.d) are
# added and removed by build.sh, never here.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

log() { printf '\n==> %s\n' "$*"; }

log "Base tools"
apt-get update
apt-get install -y curl ca-certificates gpg

log "Third-party apt repositories"
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d

# Claude desktop (Anthropic). Updates arrive through apt.
curl -fsSL https://downloads.claude.ai/claude-desktop/key.asc \
    -o /usr/share/keyrings/claude-desktop-archive-keyring.asc
cat > /etc/apt/sources.list.d/claude-desktop.list <<'EOF'
deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main
EOF

# Tailscale, 26.10 suite.
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/stonking.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/stonking.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list

# Steam (Valve).
curl -fsSL https://repo.steampowered.com/steam/archive/stable/steam.gpg \
    -o /usr/share/keyrings/steam.gpg
cat > /etc/apt/sources.list.d/steam-stable.list <<'EOF'
deb [arch=amd64,i386 signed-by=/usr/share/keyrings/steam.gpg] https://repo.steampowered.com/steam/ stable steam
deb-src [arch=amd64,i386 signed-by=/usr/share/keyrings/steam.gpg] https://repo.steampowered.com/steam/ stable steam
EOF
dpkg --add-architecture i386

# GRUB stays installed (shim-signed depends on it) as the fallback boot path.
# Keep its package updates from rewriting the firmware boot order, so the
# systemd-boot entry stays first.
echo "grub2 grub2/update_nvram boolean false" | debconf-set-selections

log "apt update and upgrade"
apt-get update
apt-get -y full-upgrade

log "Packages"
apt-get install -y --no-install-recommends \
    systemd-boot systemd-boot-efi shim-signed mokutil sbsigntool efibootmgr openssl
apt-get install -y \
    claude-desktop \
    steam-launcher steam-libs-amd64 steam-libs-i386 \
    tailscale \
    vlc \
    flatpak gnome-software gnome-software-plugin-flatpak \
    openssh-server \
    gnome-remote-desktop \
    libnotify-bin zenity curl jq pciutils

log "Flatpak: Flathub and apps (system-wide)"
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --system -y --noninteractive flathub \
    it.mijorus.gearlever \
    com.vysp3r.ProtonPlus \
    org.openrgb.OpenRGB

log "Services"
systemctl enable ssh.service tailscaled.service
systemctl enable custom-iso-firstboot.service custom-iso-laptop-power.service
# Every install gets its own Tailscale node identity.
rm -rf /var/lib/tailscale/*

log "Cleanup"
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/tmp/*
# Host keys are generated per install by the first-boot service.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
log "customize-chroot.sh done"
