#!/bin/bash
# Keeps systemd-boot signed with Kernel Pop's key and current on the ESP.
#   --sign-only    sign systemd-boot into the .signed copy bootctl installs
#   --prune        remove the "Linux Boot Manager" firmware entries
#   (no argument)  sign, bootctl update, prune; run by apt after every dpkg run
#
# shim and MOK Manager on the ESP (EFI/ubuntu, EFI/BOOT) and the "Ubuntu"
# firmware entry belong to the systemd-boot package: it installs them when a
# signed systemd-boot exists and GRUB does not, and refreshes them on shim
# updates. It reads Debian's file names, so fbx64.efi.signed and
# mmx64.efi.signed in /usr/lib/shim are links to Ubuntu's signed binaries.
set -uo pipefail

MOK_DIR=/var/lib/kernel-pop/mok
ESP=/boot/efi
SD_SRC=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
SD_SIGNED="$SD_SRC.signed"
# sha256 of the binary the .signed copy was made from. The same stamp Kernel
# Pop keeps (its sign_boot_loader), so both re-sign only for a new binary.
STAMP=/var/lib/kernel-pop/systemd-boot-signed-from

log() { echo "[custom-iso] $*"; }

have_key() { [[ -f "$MOK_DIR/signing.key" && -f "$MOK_DIR/signing.pem" ]]; }

sign_only() {
    have_key || { log "No signing key in $MOK_DIR yet"; return 1; }
    [[ -f "$SD_SRC" ]] || { log "ERROR: $SD_SRC missing"; return 1; }
    # Re-sign when the package shipped a new binary since the last signing.
    # By content: dpkg gives a file the package's time, so a new binary is
    # usually older than the .signed copy made at first boot.
    local want tmp
    want="$(sha256sum "$SD_SRC" | cut -d' ' -f1)"
    if [[ -f "$SD_SIGNED" && "$(cat "$STAMP" 2>/dev/null)" == "$want" ]] \
        && sbverify --cert "$MOK_DIR/signing.pem" "$SD_SIGNED" >/dev/null 2>&1; then
        return 0
    fi
    tmp="$(mktemp "$SD_SIGNED.XXXXXX")"
    if sbsign --key "$MOK_DIR/signing.key" --cert "$MOK_DIR/signing.pem" --output "$tmp" "$SD_SRC" >/dev/null 2>&1 \
        && sbverify --cert "$MOK_DIR/signing.pem" "$tmp" >/dev/null 2>&1 \
        && chmod 0644 "$tmp" && mv -f "$tmp" "$SD_SIGNED"; then
        echo "$want" > "$STAMP"
        log "Signed systemd-boot: $SD_SIGNED"
    else
        rm -f "$tmp"; log "ERROR: signing systemd-boot failed"; return 1
    fi
}

# bootctl update (the systemd-boot package runs it on every upgrade) adds
# "Linux Boot Manager" and "Fallback Linux Boot Manager", which start
# systemd-boot without shim. The "Ubuntu" entry (shim) is the only one kept.
prune_entries() {
    local num
    for num in $(efibootmgr 2>/dev/null | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? (Fallback )?Linux Boot Manager[[:space:]].*/\1/p'); do
        efibootmgr -q -b "$num" -B && log "Removed firmware entry Boot$num (Linux Boot Manager)"
    done
}

case "${1:-}" in
    --sign-only) sign_only ;;
    --prune) prune_entries ;;
    "")
        # Nothing to do until first boot has set systemd-boot up.
        [[ -e /var/lib/custom-iso/sdboot-installed ]] || exit 0
        sign_only && bootctl --graceful --esp-path="$ESP" --no-variables update >/dev/null 2>&1
        prune_entries
        exit 0   # never fail an apt run
        ;;
    *) echo "usage: $0 [--sign-only|--prune]" >&2; exit 2 ;;
esac
