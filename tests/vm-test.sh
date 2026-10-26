#!/bin/bash
# Installs the built ISO into a QEMU VM with UEFI Secure Boot (OVMF with
# Microsoft keys), unattended through tests/user-data, then boots it.
#
#   tests/vm-test.sh install ISO     # unattended install, powers off at the end
#   tests/vm-test.sh boot            # boot the installed disk (SSH on localhost:2222)
#
# Optional, for building behind an HTTPS proxy:
#   TEST_PROXY=http://10.0.2.2:PORT TEST_CA=/path/ca.pem  (installed into the
#   test VM only; the ISO itself is never changed)
#
# Control: QEMU monitor on $VM/monitor.sock (screendump, sendkey).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VM="${VM_DIR:-$HERE/../work/vm}"
mkdir -p "$VM"
CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
ACCEL=tcg; [[ -w /dev/kvm ]] && ACCEL=kvm

seed() {
    local ud="$VM/seed/user-data"
    mkdir -p "$VM/seed"
    cp "$HERE/user-data" "$ud"
    {
        echo "  late-commands:"
        echo "    - mkdir -p /target/etc/gdm3"
        echo "    - printf '[daemon]\\nAutomaticLoginEnable=true\\nAutomaticLogin=tester\\n' > /target/etc/gdm3/custom.conf"
        if [[ -n "${TEST_CA:-}" ]]; then
            echo "    - mkdir -p /target/usr/local/share/ca-certificates"
            echo "    - echo '$(base64 -w0 "$TEST_CA")' | base64 -d > /target/usr/local/share/ca-certificates/test-proxy.crt"
            echo "    - curtin in-target -- update-ca-certificates"
        fi
        if [[ -n "${TEST_PROXY:-}" ]]; then
            echo "    - printf 'https_proxy=$TEST_PROXY\\nHTTPS_PROXY=$TEST_PROXY\\n' >> /target/etc/environment"
            echo "    - printf 'Acquire::https::Proxy \"$TEST_PROXY\";\\n' > /target/etc/apt/apt.conf.d/00test-proxy"
            echo "    - mkdir -p /target/etc/systemd/system.conf.d"
            echo "    - printf '[Manager]\\nDefaultEnvironment=https_proxy=$TEST_PROXY HTTPS_PROXY=$TEST_PROXY\\n' > /target/etc/systemd/system.conf.d/test-proxy.conf"
        fi
    } >> "$ud"
    echo "instance-id: isotest" > "$VM/seed/meta-data"
    genisoimage -quiet -output "$VM/seed.iso" -volid cidata -joliet -rock "$VM/seed/user-data" "$VM/seed/meta-data"
}

qemu() {
    qemu-system-x86_64 -machine q35,smm=on -accel "$ACCEL" -cpu max -smp "$(nproc)" -m 6144 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$VM/vars.fd" \
        -drive file="$VM/disk.qcow2",if=virtio,format=qcow2 \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
        -device virtio-vga -display none -vnc 127.0.0.1:0 \
        -monitor unix:"$VM/monitor.sock",server,nowait \
        -serial file:"$VM/serial.log" \
        "$@"
}

case "${1:-}" in
    install)
        ISO="$2"
        rm -f "$VM/disk.qcow2" "$VM/vars.fd"
        cp "$VARS_TEMPLATE" "$VM/vars.fd"
        qemu-img create -q -f qcow2 "$VM/disk.qcow2" 40G
        seed
        qemu -drive file="$ISO",media=cdrom,readonly=on,index=2 \
             -drive file="$VM/seed.iso",media=cdrom,readonly=on,index=3 \
             -boot order=d -no-reboot
        ;;
    boot)
        qemu -boot order=c
        ;;
    *) echo "usage: $0 install ISO | boot" >&2; exit 2 ;;
esac
