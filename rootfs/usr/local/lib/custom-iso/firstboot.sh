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
#     files and its firmware entry. GRUB stays bootable until the "Ubuntu"
#     entry and its files are checked; only then do its files go.
#  4. GNOME Remote Desktop "Remote Login" (port 3389): TLS certificate and
#     enabled; the login itself is set at first user login.
#  5. With Secure Boot on: queue the key for enrollment and reboot once into
#     MOK Manager.
set -uo pipefail

STATE=/var/lib/custom-iso
MOK_DIR=/var/lib/kernel-pop/mok
SIGN_KEY_CN="Kernel Pop kernel signing key"
MOK_PASSWORD="enrollmok"      # one-time, typed once at the blue MOK Manager screen
MOK_PENDING_LIST=/var/lib/mok-pending/list
MOKNEW=/sys/firmware/efi/efivars/MokNew-605dab50-e046-4300-abb6-3dd810dd8b23
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

# "systemd-boot" in UTF-16LE: efibootmgr prints a load option as hex.
SDBOOT_HEX="730079007300740065006d0064002d0062006f006f007400"

# Firmware entries that start EFI/ubuntu's shim (or GRUB): "<num> sdboot" for
# the "Ubuntu" entry (systemd-boot as the load option), "<num> grub" for
# GRUB's (nothing or anything else passed).
ubuntu_entries() {
    local line lc
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        lc="${line,,}"
        [[ "$lc" == *'efi\ubuntu\shimx64.efi'* || "$lc" == *'efi\ubuntu\grubx64.efi'* ]] || continue
        if [[ "$lc" == *'efi\ubuntu\shimx64.efi'* && ( "$lc" == *'systemd-bootx64.efi'* || "$lc" == *"$SDBOOT_HEX"* ) ]]; then
            echo "${BASH_REMATCH[1]} sdboot"
        else
            echo "${BASH_REMATCH[1]} grub"
        fi
    done < <(efibootmgr 2>/dev/null)
}

same_file() { [[ -f "$1" && -f "$2" ]] && cmp -s "$1" "$2"; }

# The installer always sets up GRUB. Swap its packages for custom-iso-no-grub
# (shim-signed depends on GRUB; this stands in for it). Only removed, not
# purged: purging deletes /boot/grub/grub.cfg, which GRUB on the ESP still
# loads until systemd-boot is in place.
remove_grub_packages() {
    if dpkg-query -W -f='${Status}\n' 'grub*' os-prober 2>/dev/null | grep -q '^install ok installed'; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y install /usr/local/lib/custom-iso/no-grub.deb \
            || { log "ERROR: could not remove the GRUB packages"; return 1; }
        log "GRUB packages replaced by custom-iso-no-grub"
    fi
}

# After the "Ubuntu" entry is checked: what GRUB leaves behind. Only GRUB's
# own files: shim, fb and MOK Manager in EFI/ubuntu and EFI/BOOT now belong
# to the systemd-boot package.
wipe_grub() {
    local pkgs num kind ok=0
    mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'grub*' os-prober 2>/dev/null | awk '$1 == "rc" {print $2}')
    if (( ${#pkgs[@]} )); then
        DEBIAN_FRONTEND=noninteractive dpkg --purge "${pkgs[@]}" >/dev/null || { log "ERROR: could not purge ${pkgs[*]}"; ok=1; }
    fi
    rm -rf /boot/grub
    rm -f "$ESP"/EFI/ubuntu/grub*.efi "$ESP"/EFI/ubuntu/grub.cfg "$ESP"/EFI/BOOT/grub*.efi
    while read -r num kind; do
        [[ "$kind" == grub ]] || continue
        efibootmgr -q -b "$num" -B || { log "ERROR: could not remove GRUB's firmware entry Boot$num"; ok=1; }
    done < <(ubuntu_entries)
    (( ok == 0 )) && log "GRUB removed (packages, /boot/grub, ESP files, firmware entry)"
    return $ok
}

# Whether shim -> systemd-boot is complete on the ESP: the signed systemd-boot
# bootctl installed, shim and MOK Manager in EFI/ubuntu, and the fallback's
# CSV pointing at systemd-boot (so a firmware that loses its entries gets
# "Ubuntu" back, not GRUB's).
sdboot_files_ok() {
    local csv="$ESP/EFI/ubuntu/BOOTX64.CSV"
    same_file "$ESP/EFI/systemd/systemd-bootx64.efi" /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
        || { log "ERROR: $ESP/EFI/systemd/systemd-bootx64.efi is not the signed systemd-boot"; return 1; }
    same_file "$ESP/EFI/ubuntu/shimx64.efi" /usr/lib/shim/shimx64.efi.signed \
        || { log "ERROR: shim is missing from $ESP/EFI/ubuntu"; return 1; }
    same_file "$ESP/EFI/ubuntu/mmx64.efi" /usr/lib/shim/mmx64.efi.signed \
        || { log "ERROR: MOK Manager is missing from $ESP/EFI/ubuntu"; return 1; }
    [[ -f "$csv" ]] && iconv -f UCS-2LE "$csv" 2>/dev/null | grep -qi 'systemd-bootx64\.efi' \
        || { log "ERROR: $csv does not start systemd-boot"; return 1; }
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

    # Until the end GRUB still boots through its own entry: the packages are
    # removed but /boot/grub, EFI/ubuntu/grubx64.efi and its entry stay.
    # Removing them already runs install_shim (systemd-boot's trigger on
    # /usr/lib/grub), which adds "Ubuntu" first in the boot order, so every
    # failure from here puts the order back the way GRUB had it.
    local order
    order="$(efibootmgr | sed -n 's/^BootOrder: //p')"
    keep_grub() {
        [[ -n "$order" ]] && efibootmgr -q -o "$order"
        log "GRUB is kept as the boot loader until this works"
        return 1
    }
    remove_grub_packages || { keep_grub; return 1; }
    # install_shim writes the fallback's CSV only when there is none; GRUB's
    # starts shim with nothing passed, which loads GRUB.
    local csv="$ESP/EFI/ubuntu/BOOTX64.CSV"
    if [[ -f "$csv" ]] && ! iconv -f UCS-2LE "$csv" 2>/dev/null | grep -qi 'systemd-bootx64\.efi'; then
        rm -f "$csv"
    fi

    bootctl install --no-variables --esp-path="$ESP" || { log "ERROR: bootctl install failed"; keep_grub; return 1; }
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
    local num rest
    if ! DEBIAN_FRONTEND=noninteractive dpkg-reconfigure systemd-boot; then
        log "ERROR: systemd-boot could not install shim on the ESP"
        keep_grub; return 1
    fi
    /usr/local/lib/custom-iso/sdboot-sign.sh --prune
    num="$(ubuntu_entries | awk '$2 == "sdboot" {print $1; exit}')"
    if [[ -z "$num" ]] || ! sdboot_files_ok; then
        [[ -z "$num" ]] && log "ERROR: no Ubuntu (shim -> systemd-boot) firmware entry"
        keep_grub; return 1
    fi
    # install_shim puts the entry first only when it creates it.
    rest="$(efibootmgr | sed -n 's/^BootOrder: //p' | tr ',' '\n' | grep -vix "$num" | paste -sd,)"
    efibootmgr -q -o "$num${rest:+,$rest}" || { log "ERROR: could not put Boot$num first in the boot order"; keep_grub; return 1; }
    log "systemd-boot installed behind shim; firmware entry \"Ubuntu\" (Boot$num) is first in the boot order"
    done_mark sdboot-installed
}

# GRUB's leftovers go only once systemd-boot is in place. A failure here
# leaves harmless files behind and is retried next boot; it does not hold
# up the key enrollment.
remove_grub() {
    is_done grub-removed && return 0
    is_done sdboot-installed || return 1
    wipe_grub && done_mark grub-removed
}

secure_boot_on() { mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; }

# The list of keys waiting in shim's enrollment request that Kernel Pop and
# the other apps rebuilding that request share (Kernel Pop's AGENTS.md):
# "moknew-size <MokNew's size>", then each waiting key's lowercase SHA1.
# They trust it only while MokNew still has that size.
write_mok_pending_list() {
    local list="$MOK_PENDING_LIST" size sha1 tmp
    size="$(stat -c %s "$MOKNEW" 2>/dev/null)" || return 1
    sha1="$(openssl x509 -inform DER -in "$MOK_DIR/signing.der" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
    [[ -n "$sha1" ]] || return 1
    mkdir -p "$(dirname "$list")" && chmod 0755 "$(dirname "$list")" || return 1
    tmp="$(mktemp "$(dirname "$list")/.list.XXXXXX")" || return 1
    if printf 'moknew-size %s\n%s\n' "$size" "$sha1" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$list"; then
        return 0
    fi
    rm -f "$tmp"; return 1
}

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
    if mokutil --import "$MOK_DIR/signing.der" --hash-file "$hash"; then
        log "Key queued for enrollment"
        done_mark mok-queued; done_mark mok-waiting
        write_mok_pending_list || log "WARNING: could not write $MOK_PENDING_LIST: Kernel Pop shows the key as not enrolled until it is"
    fi
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
is_done sdboot-installed && { remove_grub || log "WARNING: GRUB's leftovers are removed next boot"; }
setup_remote_login
is_done sdboot-installed && queue_mok

if is_done sdboot-installed && is_done grub-removed && is_done mok-queued && is_done remote-login; then
    done_mark firstboot-done
fi

# Reboot once into MOK Manager when a key is waiting.
if secure_boot_on && is_done mok-waiting && ! is_done mok-reboot; then
    done_mark mok-reboot
    log "Rebooting into MOK Manager to enroll the signing key (password: $MOK_PASSWORD)"
    systemctl --no-block reboot
fi
exit 0
