#!/bin/bash
# First boot of an install from the custom ISO, as root, before the login
# screen. Safe to run again: each step checks whether it is already done.
#
#  1. SSH host keys for this install.
#  2. OpenRGB: udev rules from the Flatpak, i2c-dev for GPU RGB control.
#  3. systemd-boot as the default boot entry, loaded through shim and signed
#     with Kernel Pop's kernel-signing key (same key, same location, so one
#     MOK enrollment covers the boot loader and Kernel Pop's kernels).
#     It becomes the default boot entry only after the key is enrolled (or
#     right away with Secure Boot off); until then GRUB keeps booting.
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

esp_disk_and_part() {
    local src dev
    src="$(findmnt -no SOURCE "$ESP")" || return 1
    dev="$(basename "$(readlink -f "$src")")"
    echo "/dev/$(lsblk -no PKNAME "/dev/$dev") $(cat "/sys/class/block/$dev/partition")"
}

setup_systemd_boot() {
    is_done sdboot-installed && return 0
    mountpoint -q "$ESP" || { log "ERROR: $ESP is not mounted"; return 1; }
    generate_signing_key || { log "ERROR: could not create the signing key"; return 1; }

    # Kernel command line for the boot entries: what this boot was started
    # with, minus the GRUB-only parts.
    if [[ ! -s /etc/kernel/cmdline ]]; then
        tr ' ' '\n' < /proc/cmdline | grep -vE '^(BOOT_IMAGE=|initrd=|$)' | tr '\n' ' ' \
            | sed 's/ $//' > /etc/kernel/cmdline
        log "Kernel command line: $(cat /etc/kernel/cmdline)"
    fi

    # Signed copy next to the original; bootctl installs the .signed one.
    /usr/local/lib/custom-iso/sdboot-sign.sh --sign-only || return 1

    # Keep the removable-media fallback (GRUB's shim) as it is.
    local keep; keep="$(mktemp -d)"
    cp -a "$ESP/EFI/BOOT" "$keep/" 2>/dev/null || true
    bootctl install --no-variables --esp-path="$ESP" || { log "ERROR: bootctl install failed"; return 1; }
    if [[ -d "$keep/BOOT" ]]; then
        rm -rf "$ESP/EFI/BOOT"; cp -a "$keep/BOOT" "$ESP/EFI/BOOT"
    fi
    rm -rf "$keep"

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

    # shim + signed systemd-boot in EFI/systemd, and a firmware entry for it.
    # The entry goes LAST in the boot order: shim refuses this systemd-boot
    # until its key is enrolled, and the firmware does not fall back after
    # that refusal. promote_sdboot moves it first once the key is trusted.
    /usr/local/lib/custom-iso/sdboot-sign.sh --refresh-esp || return 1
    if [[ -z "$(sdboot_entry)" ]]; then
        local order; order="$(efibootmgr | awk -F': ' '/^BootOrder:/ {print $2}')"
        read -r disk part <<< "$(esp_disk_and_part)"
        efibootmgr -q -c -d "$disk" -p "$part" -L "Ubuntu (systemd-boot)" -l '\EFI\systemd\shimx64.efi' \
            || { log "ERROR: efibootmgr could not create the boot entry"; return 1; }
        [[ -n "$order" ]] && efibootmgr -q -o "$order,$(sdboot_entry)"
        log "Firmware boot entry created on $disk partition $part (after GRUB until the key is enrolled)"
    fi
    done_mark sdboot-installed
}

sdboot_entry() { efibootmgr | awk '/Ubuntu \(systemd-boot\)/ {sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1; exit}'; }

key_trusted() {
    ! secure_boot_on && return 0
    mokutil --test-key "$MOK_DIR/signing.der" 2>/dev/null | grep -qiE "already enrolled|already in db|built-in"
}

# systemd-boot becomes the default only once shim will accept it.
promote_sdboot() {
    is_done sdboot-default && return 0
    is_done sdboot-installed || return 0
    key_trusted || { log "Signing key not enrolled yet: GRUB stays the default boot entry"; return 0; }
    local id order rest
    id="$(sdboot_entry)"; [[ -n "$id" ]] || { log "WARNING: systemd-boot firmware entry missing"; return 0; }
    order="$(efibootmgr | awk -F': ' '/^BootOrder:/ {print $2}')"
    rest="$(tr ',' '\n' <<< "$order" | grep -vx "$id" | paste -sd, -)"
    efibootmgr -q -o "$id${rest:+,$rest}" \
        && { log "systemd-boot is now the default boot entry"; done_mark sdboot-default; }
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

setup_systemd_boot || log "systemd-boot setup failed; GRUB still boots this system. Retried next boot."
setup_remote_login
is_done sdboot-installed && queue_mok
promote_sdboot

# Runs every boot until everything, including the switch to systemd-boot
# after enrollment, is done.
if is_done sdboot-default && is_done mok-queued && is_done remote-login; then
    done_mark firstboot-done
fi

# Reboot once into MOK Manager when a key is waiting.
if secure_boot_on && [[ -e /var/lib/kernel-pop/mok-pending ]] && ! is_done mok-reboot; then
    done_mark mok-reboot
    log "Rebooting into MOK Manager to enroll the signing key (password: $MOK_PASSWORD)"
    systemctl --no-block reboot
fi
exit 0
