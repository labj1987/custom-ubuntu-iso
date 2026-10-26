#!/bin/bash
# Installs the built ISO onto a virtual disk the way the installer does,
# without its desktop UI (which cannot start in a VM with no GPU), then
# boots it under UEFI Secure Boot with Microsoft keys (OVMF).
#
#   tests/disk-test.sh install ISO   # build work/disktest/disk.raw from the ISO
#   tests/disk-test.sh boot          # boot it (SSH: tester@localhost:2222, test1234)
#
# The install resolves the layer stack from casper/install-sources.yaml by
# splitting the file name on dots, exactly as the installer (curtin) does,
# so a wrongly named layer fails here too.
#
# Optional, for a host behind an HTTPS proxy (test VM only, never the ISO):
#   TEST_PROXY=http://10.0.2.2:PORT TEST_CA=/path/ca.pem
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${DISKTEST_DIR:-$HERE/../work/disktest}"
mkdir -p "$W"
W="$(cd "$W" && pwd)"
CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
PASS_HASH='$6$testsalt$94BDrjBBTI.wuCfWdfx6B/AgWUD0PgWiE8SanatLntzmej2fPex1EEHetoKv96Mfx2/fahQvekxgNJz7AqyJA1'
log() { printf '\n### %s\n' "$*"; }

cleanup() {
    set +e
    for m in "$W/target/dev" "$W/target/proc" "$W/target/sys" "$W/target/run" "$W/target"; do
        mountpoint -q "$m" && umount -R "$m"
    done
    mountpoint -q "$W/stack" && umount "$W/stack"
    for d in "$W"/layer-*; do mountpoint -q "$d" && umount "$d"; done
}

install_disk() {
    local iso="$1" path parts i name stack=() lower=""
    trap cleanup EXIT
    log "Reading the installer's source list"
    xorriso -osirrox on -indev "$iso" -extract /casper/install-sources.yaml "$W/install-sources.yaml" >/dev/null 2>&1
    path="$(awk '/^  path:/ {print $2; exit}' "$W/install-sources.yaml")"
    [[ -n "$path" ]] || { echo "no source path in install-sources.yaml" >&2; exit 1; }
    IFS=. read -r -a parts <<< "${path%.squashfs}"
    for i in "${!parts[@]}"; do
        name="$(IFS=.; echo "${parts[*]:0:i+1}").squashfs"
        stack+=("$name")
    done
    echo "Layer stack: ${stack[*]}"

    log "Mounting the layers"
    for name in "${stack[@]}"; do
        [[ -f "$W/$name" ]] || xorriso -osirrox on -indev "$iso" -extract "/casper/$name" "$W/$name" >/dev/null 2>&1
        [[ -s "$W/$name" ]] || { echo "layer $name missing from the ISO" >&2; exit 1; }
        mkdir -p "$W/layer-$name"
        mount -t squashfs -o loop,ro "$W/$name" "$W/layer-$name"
        lower="$W/layer-$name${lower:+:$lower}"
    done
    mkdir -p "$W/stack"
    mount -t overlay overlay -o "ro,lowerdir=$lower" "$W/stack"

    log "Partitioning (ESP 512 MiB + ext4 root)"
    rm -f "$W/disk.raw" "$W/esp.img"
    truncate -s 24G "$W/disk.raw"
    sgdisk -n1:2048:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8304 -c2:root "$W/disk.raw" >/dev/null
    local start2 end2
    read -r start2 end2 < <(sgdisk -p "$W/disk.raw" | awk '$1 == 2 {print $2, $3}')
    local off=$((start2 * 512)) blocks=$(((end2 - start2 + 1) / 8))
    mkfs.ext4 -q -F -b 4096 -L root -E offset="$off" "$W/disk.raw" "$blocks"
    local root_uuid esp_uuid esp_id
    root_uuid="$(blkid -p -O "$off" -s UUID -o value "$W/disk.raw")"
    esp_id="$(printf '%04X%04X' $((RANDOM)) $((RANDOM)))"
    esp_uuid="${esp_id:0:4}-${esp_id:4:4}"
    mkfs.fat -F 32 -i "$esp_id" -n EFI -C "$W/esp.img" $((512 * 1024)) >/dev/null

    log "Copying the installed system"
    mkdir -p "$W/target"
    mount -o loop,offset="$off",sizelimit=$((blocks * 4096)) "$W/disk.raw" "$W/target"
    cp -a "$W/stack/." "$W/target/"
    umount "$W/stack"

    log "Configuring the target (what the installer does)"
    local T="$W/target"
    mount -t proc proc "$T/proc"; mount --rbind /sys "$T/sys"; mount --rbind /dev "$T/dev"; mount -t tmpfs tmpfs "$T/run"
    cat > "$T/etc/fstab" <<EOF
UUID=$root_uuid / ext4 errors=remount-ro 0 1
UUID=$esp_uuid /boot/efi vfat umask=0077 0 1
EOF
    echo isotest > "$T/etc/hostname"
    : > "$T/etc/machine-id"
    chroot "$T" useradd -m -s /bin/bash -G sudo,adm -c Tester -p "$PASS_HASH" tester
    mkdir -p "$T/etc/gdm3"
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=tester\n' > "$T/etc/gdm3/custom.conf"
    if [[ -n "${TEST_CA:-}" ]]; then
        install -D -m 0644 "$TEST_CA" "$T/usr/local/share/ca-certificates/test-proxy.crt"
        chroot "$T" update-ca-certificates >/dev/null
    fi
    if [[ -n "${TEST_PROXY:-}" ]]; then
        printf 'https_proxy=%s\nHTTPS_PROXY=%s\n' "$TEST_PROXY" "$TEST_PROXY" >> "$T/etc/environment"
        printf 'Acquire::https::Proxy "%s";\n' "$TEST_PROXY" > "$T/etc/apt/apt.conf.d/00test-proxy"
        mkdir -p "$T/etc/systemd/system.conf.d"
        printf '[Manager]\nDefaultEnvironment=https_proxy=%s HTTPS_PROXY=%s\n' "$TEST_PROXY" "$TEST_PROXY" > "$T/etc/systemd/system.conf.d/test-proxy.conf"
    fi

    log "GRUB behind shim, as the installer leaves it"
    local esp="$W/esp" kver
    rm -rf "$esp"; mkdir -p "$esp/EFI/ubuntu" "$esp/EFI/BOOT"
    cp "$T/usr/lib/shim/shimx64.efi.signed.latest" "$esp/EFI/ubuntu/shimx64.efi"
    cp "$T/usr/lib/shim/mmx64.efi" "$esp/EFI/ubuntu/mmx64.efi"
    cp "$T/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$esp/EFI/ubuntu/grubx64.efi"
    cp "$T/usr/lib/shim/BOOTX64.CSV" "$esp/EFI/ubuntu/BOOTX64.CSV"
    cp "$esp/EFI/ubuntu/shimx64.efi" "$esp/EFI/BOOT/BOOTX64.EFI"
    cp "$T/usr/lib/shim/fbx64.efi" "$esp/EFI/BOOT/fbx64.efi"
    cp "$esp/EFI/ubuntu/mmx64.efi" "$esp/EFI/BOOT/mmx64.efi"
    printf "search.fs_uuid %s root\nset prefix=(\$root)'/boot/grub'\nconfigfile \$prefix/grub.cfg\n" "$root_uuid" > "$esp/EFI/ubuntu/grub.cfg"
    kver="$(basename "$(readlink -f "$T/boot/vmlinuz")")"; kver="${kver#vmlinuz-}"
    mkdir -p "$T/boot/grub"
    cat > "$T/boot/grub/grub.cfg" <<EOF
set timeout=1
menuentry 'Ubuntu' {
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-$kver root=UUID=$root_uuid ro console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img-$kver
}
EOF
    echo "grub2 grub2/update_nvram boolean false" | chroot "$T" debconf-set-selections
    mcopy -s -i "$W/esp.img" "$esp/EFI" ::/
    dd if="$W/esp.img" of="$W/disk.raw" bs=1M seek=1 conv=notrunc status=none

    cleanup; trap - EXIT
    rm -f "$W"/minimal*.squashfs "$W/esp.img"
    cp "$VARS_TEMPLATE" "$W/vars.fd"
    log "Disk ready: $W/disk.raw"
}

boot_disk() {
    local accel=tcg; [[ -w /dev/kvm ]] && accel=kvm
    qemu-system-x86_64 -machine q35,smm=on -accel "$accel" -cpu max -smp "$(nproc)" -m "${VM_MEM:-4096}" \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
        -drive file="$W/disk.raw",if=virtio,format=raw \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
        -device virtio-vga -display none \
        -monitor unix:"$W/monitor.sock",server,nowait \
        -serial file:"$W/serial.log"
}

case "${1:-}" in
    install) install_disk "$2" ;;
    boot) boot_disk ;;
    *) echo "usage: $0 install ISO | boot" >&2; exit 2 ;;
esac
