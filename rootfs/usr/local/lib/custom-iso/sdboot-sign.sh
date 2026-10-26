#!/bin/bash
# Keeps the shim -> systemd-boot chain signed and current.
#   --sign-only    sign systemd-boot with Kernel Pop's key into the .signed copy
#   --refresh-esp  copy shim, MOK Manager and the signed systemd-boot into EFI/systemd
#   (no argument)  both, plus bootctl update; run by apt after every dpkg run
set -uo pipefail

MOK_DIR=/var/lib/kernel-pop/mok
ESP=/boot/efi
SD_SRC=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
SD_SIGNED="$SD_SRC.signed"
TARGET="$ESP/EFI/systemd"

log() { echo "[custom-iso] $*"; }

have_key() { [[ -f "$MOK_DIR/signing.key" && -f "$MOK_DIR/signing.pem" ]]; }

shim_file() {   # first existing signed shim / MOK Manager binary
    local f
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}

sign_only() {
    have_key || { log "No signing key in $MOK_DIR yet"; return 1; }
    [[ -f "$SD_SRC" ]] || { log "ERROR: $SD_SRC missing"; return 1; }
    # Re-sign when the package shipped a new binary since the last signing.
    if [[ -f "$SD_SIGNED" && "$SD_SIGNED" -nt "$SD_SRC" ]] \
        && sbverify --cert "$MOK_DIR/signing.pem" "$SD_SIGNED" >/dev/null 2>&1; then
        return 0
    fi
    local tmp; tmp="$(mktemp "$SD_SIGNED.XXXXXX")"
    if sbsign --key "$MOK_DIR/signing.key" --cert "$MOK_DIR/signing.pem" --output "$tmp" "$SD_SRC" >/dev/null 2>&1 \
        && sbverify --cert "$MOK_DIR/signing.pem" "$tmp" >/dev/null 2>&1; then
        chmod 0644 "$tmp"; mv -f "$tmp" "$SD_SIGNED"
        log "Signed systemd-boot: $SD_SIGNED"
    else
        rm -f "$tmp"; log "ERROR: signing systemd-boot failed"; return 1
    fi
}

refresh_esp() {
    mountpoint -q "$ESP" || { log "ERROR: $ESP is not mounted"; return 1; }
    [[ -f "$SD_SIGNED" ]] || { log "ERROR: no signed systemd-boot to install"; return 1; }
    local shim mm
    shim="$(shim_file /usr/lib/shim/shimx64.efi.signed.latest /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/shimx64.efi.dualsigned)" \
        || { log "ERROR: no signed shim found in /usr/lib/shim"; return 1; }
    mm="$(shim_file /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi)" || mm=""
    mkdir -p "$TARGET"
    cmp -s "$shim" "$TARGET/shimx64.efi" || cp -f "$shim" "$TARGET/shimx64.efi"
    [[ -n "$mm" ]] && { cmp -s "$mm" "$TARGET/mmx64.efi" || cp -f "$mm" "$TARGET/mmx64.efi"; }
    # shim loads grubx64.efi from its own directory: here that is systemd-boot.
    cmp -s "$SD_SIGNED" "$TARGET/grubx64.efi" || { cp -f "$SD_SIGNED" "$TARGET/grubx64.efi"; log "EFI/systemd refreshed"; }
}

case "${1:-}" in
    --sign-only)   sign_only ;;
    --refresh-esp) refresh_esp ;;
    "")
        # Nothing to do until first boot has set systemd-boot up.
        [[ -e /var/lib/custom-iso/sdboot-installed ]] || exit 0
        sign_only && bootctl --graceful --esp-path="$ESP" --no-variables update >/dev/null 2>&1
        refresh_esp
        exit 0   # never fail an apt run
        ;;
    *) echo "usage: $0 [--sign-only|--refresh-esp]" >&2; exit 2 ;;
esac
