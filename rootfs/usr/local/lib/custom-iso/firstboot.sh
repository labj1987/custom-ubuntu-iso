#!/bin/bash
# First boot of an install from the custom ISO, as root, before the login
# screen. Safe to run again: each step checks whether it is already done.
#
#  1. SSH host keys for this install.
#  2. OpenRGB: udev rules from the Flatpak, i2c-dev for GPU RGB control.
#  3. systemd-boot as the only boot loader, loaded through shim and signed
#     with Kernel Pop's kernel-signing key (same key, same location, so one
#     MOK enrollment covers the boot loader and Kernel Pop's kernels). The
#     GRUB the installer put down is wiped: packages, /boot/grub, its ESP
#     files and its firmware entry.
#  4. GNOME Remote Desktop "Remote Login" (port 3389): TLS certificate and
#     enabled; the login itself is set at first user login.
#  5. With Secure Boot on: queue the key for enrollment and reboot once into
#     MOK Manager.
set -uo pipefail

STATE=/var/lib/custom-iso
MOK_DIR=/var/lib/kernel-pop/mok
SIGN_KEY_CN="Kernel Pop kernel signing key"
MOK_PASSWORD="enrollmok"      # one-time, typed once at the blue MOK Manager screen
ESP=/boot/efi
LOG=/var/log/custom-iso-firstboot.log

mkdir -p "$STATE"
exec > >(tee -a "$LOG") 2>&1
log() { echo "[custom-iso] $*"; }
done_mark() { touch "$STATE/$1"; }
is_done() { [[ -e "$STATE/$1" ]]; }

# ── 1. SSH host keys ──────────────────────────────────────────────────────
ssh-keygen -A && log "SSH host keys ready"

# ── 2. OpenRGB ────────────────────────────────────────────────────────────
rules="$(ls /var/lib/flatpak/app/org.openrgb.OpenRGB/current/active/files/lib/udev/rules.d/*openrgb*.rules 2>/dev/null | head -1)"
if [[ -n "$rules" ]]; then
    ln -sf "$rules" /etc/udev/rules.d/60-openrgb.rules
    udevadm control --reload-rules || true
    log "OpenRGB udev rules linked from the Flatpak"
fi
echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
modprobe i2c-dev 2>/dev/null || true

# ── 3. systemd-boot behind shim ───────────────────────────────────────────
generate_signing_key() {
    [[ -f "$MOK_DIR/signing.key" && -f "$MOK_DIR/signing.pem" && -f "$MOK_DIR/signing.der" ]] && return 0
    local parent tmpd
    parent="$(dirname "$MOK_DIR")"
    mkdir -p "$parent" && chmod 0755 "$parent"
    tmpd="$(mktemp -d "$parent/.mok.new.XXXXXX")" || return 1
    cat > "$tmpd/req.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = $SIGN_KEY_CN
[ v3 ]
basicConstraints = critical,CA:FALSE
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
    if (umask 077 && openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
            -config "$tmpd/req.cnf" -keyout "$tmpd/signing.key" -out "$tmpd/signing.pem") \
        && openssl x509 -in "$tmpd/signing.pem" -outform DER -out "$tmpd/signing.der"; then
        rm -f "$tmpd/req.cnf"
        chmod 0600 "$tmpd/signing.key"; chmod 0644 "$tmpd/signing.pem" "$tmpd/signing.der"; chmod 0755 "$tmpd"
        mv -T "$tmpd" "$MOK_DIR" && log "Created the kernel/boot-loader signing key in $MOK_DIR"
    else
        rm -rf "$tmpd"; return 1
    fi
}

# The installer always sets up GRUB. Swap its packages for custom-iso-no-grub
# (shim-signed depends on GRUB; this stands in for it), then remove what the
# packages leave: /boot/grub, its ESP files and its firmware entry.
wipe_grub() {
    local pkgs num
    if dpkg-query -W -f='${Status}\n' 'grub*' os-prober 2>/dev/null | grep -q '^install ok installed'; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y install /usr/local/lib/custom-iso/no-grub.deb \
            || { log "ERROR: could not remove the GRUB packages"; return 1; }
    fi
    mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'grub*' os-prober 2>/dev/null | awk '$1 == "rc" {print $2}')
    (( ${#pkgs[@]} )) && dpkg --purge "${pkgs[@]}" >/dev/null
    rm -rf /boot/grub "$ESP/EFI/ubuntu" "$ESP/EFI/BOOT"
    # GRUB's entry is shim (or GRUB) in EFI/ubuntu with nothing passed to it.
    for num in $(efibootmgr | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? .*[\\/]EFI\\ubuntu\\(shim|grub)x64\.efi$/\1/Ip'); do
        efibootmgr -q -b "$num" -B
    done
    log "GRUB removed (packages, /boot/grub, ESP files, firmware entry)"
}

setup_systemd_boot() {
    is_done sdboot-installed && return 0
    mountpoint -q "$ESP" || { log "ERROR: $ESP is not mounted"; return 1; }
    generate_signing_key || { log "ERROR: could not create the signing key"; return 1; }

    # Kernel command line for the boot entries: what this boot was started
    # with, minus the boot loader's own parts.
    if [[ ! -s /etc/kernel/cmdline ]]; then
        tr ' ' '\n' < /proc/cmdline | grep -vE '^(BOOT_IMAGE=|initrd=|$)' | tr '\n' ' ' \
            | sed 's/ $//' > /etc/kernel/cmdline
        log "Kernel command line: $(cat /etc/kernel/cmdline)"
    fi

    # Signed copy next to the original; bootctl installs the .signed one.
    /usr/local/lib/custom-iso/sdboot-sign.sh --sign-only || return 1

    wipe_grub || return 1
    bootctl install --no-variables --esp-path="$ESP" || { log "ERROR: bootctl install failed"; return 1; }
    cat > "$ESP/loader/loader.conf" <<'EOF'
timeout 3
editor no
EOF

    # Boot entries for every installed kernel.
    local k
    for k in /boot/vmlinuz-*; do
        k="${k#/boot/vmlinuz-}"
        [[ -f "/boot/initrd.img-$k" ]] || dracut -f "/boot/initrd.img-$k" "$k"
        kernel-install add "$k" "/boot/vmlinuz-$k" "/boot/initrd.img-$k" \
            && log "Boot entry added for $k" || log "WARNING: kernel-install failed for $k"
    done

    # The systemd-boot package puts shim and MOK Manager in EFI/ubuntu and
    # EFI/BOOT and creates the "Ubuntu" firmware entry, first in the boot
    # order: shim with \EFI\systemd\systemd-bootx64.efi as what it loads.
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure systemd-boot \
        || { log "ERROR: systemd-boot could not install shim on the ESP"; return 1; }
    /usr/local/lib/custom-iso/sdboot-sign.sh --prune
    efibootmgr | grep -qiE '^Boot[0-9A-F]{4}\*? Ubuntu[[:space:]].*[\\/]EFI\\ubuntu\\shimx64\.efi.+' \
        || { log "ERROR: no Ubuntu (shim -> systemd-boot) firmware entry"; return 1; }
    log "systemd-boot installed behind shim; firmware entry \"Ubuntu\" is first in the boot order"
    done_mark sdboot-installed
}

secure_boot_on() { mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; }

queue_mok() {
    is_done mok-queued && return 0
    if ! secure_boot_on; then
        log "Secure Boot is off: no key enrollment needed (Kernel Pop can enroll the key later)"
        done_mark mok-queued; return 0
    fi
    if mokutil --test-key "$MOK_DIR/signing.der" 2>/dev/null | grep -qiE "already enrolled|already in"; then
        log "Signing key already enrolled"; done_mark mok-queued; return 0
    fi
    local hash
    hash="$(mktemp)"
    printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --generate-hash 2>/dev/null \
        | grep -E '^\$' > "$hash"
    mokutil --import "$MOK_DIR/signing.der" --hash-file "$hash" \
        && { log "Key queued for enrollment"; done_mark mok-queued; echo "$(openssl x509 -inform DER -in "$MOK_DIR/signing.der" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')" > /var/lib/kernel-pop/mok-pending; chmod 0644 /var/lib/kernel-pop/mok-pending; }
    rm -f "$hash"
}

# ── 4. GNOME Remote Desktop, Remote Login (system) ────────────────────────
setup_remote_login() {
    is_done remote-login && return 0
    local d=/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop
    install -d -o gnome-remote-desktop -g gnome-remote-desktop -m 0700 "$d"
    if [[ ! -f "$d/rdp-tls.crt" ]]; then
        openssl req -new -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=$(hostname)" \
            -keyout "$d/rdp-tls.key" -out "$d/rdp-tls.crt" 2>/dev/null
        chown gnome-remote-desktop:gnome-remote-desktop "$d/rdp-tls.key" "$d/rdp-tls.crt"
        chmod 0600 "$d/rdp-tls.key"
    fi
    grdctl --system rdp set-tls-cert "$d/rdp-tls.crt" \
        && grdctl --system rdp set-tls-key "$d/rdp-tls.key" \
        && grdctl --system rdp set-port 3389 \
        && grdctl --system rdp disable-port-negotiation \
        && grdctl --system rdp enable \
        && systemctl enable gnome-remote-desktop.service \
        && { log "Remote Login set up on port 3389 (login set at first user login)"; done_mark remote-login; } \
        || log "WARNING: Remote Login setup failed; it is retried next boot"
}

setup_systemd_boot || log "ERROR: systemd-boot setup failed; retried next boot"
setup_remote_login
is_done sdboot-installed && queue_mok

if is_done sdboot-installed && is_done mok-queued && is_done remote-login; then
    done_mark firstboot-done
fi

# Reboot once into MOK Manager when a key is waiting.
if secure_boot_on && [[ -e /var/lib/kernel-pop/mok-pending ]] && ! is_done mok-reboot; then
    done_mark mok-reboot
    log "Rebooting into MOK Manager to enroll the signing key (password: $MOK_PASSWORD)"
    systemctl --no-block reboot
fi
exit 0
