#!/bin/bash
# Enrolls the queued MOK key in a VM started by `tests/disk-test.sh boot`.
# Waits for MOK Manager on the serial console, stops its 10 s countdown and
# steps through Enroll MOK -> Continue -> Yes -> password -> Reboot via the
# QEMU monitor. A screenshot of every screen goes to work/disktest/mok/.
#
#   sudo tests/mok-enroll.sh [PASSWORD]   # default: enrollmok, as firstboot.sh queues it
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(cd "${DISKTEST_DIR:-$HERE/../work/disktest}" && pwd)"
PASSWORD="${1:-enrollmok}"
SHOTS="$W/mok"
mkdir -p "$SHOTS"
n=0

mon() { printf '%s\n' "$1" | socat - UNIX-CONNECT:"$W/monitor.sock" >/dev/null; }
key() { mon "sendkey $1"; sleep "${2:-1.5}"; }
shot() { n=$((n + 1)); mon "screendump $SHOTS/$n-$1.ppm"; echo "screen $n: $1"; }

echo "Waiting for MOK Manager..."
timeout "${MOK_WAIT:-900}" bash -c "until grep -q 'perform MOK management' '$W/serial.log' 2>/dev/null; do sleep 0.5; done"
sleep 1
key down; shot main-menu
key down 0.5; key ret; shot enroll-mok
key down 0.5; key ret; shot enroll-the-keys
key down 0.5; key ret; shot password
for ((i = 0; i < ${#PASSWORD}; i++)); do key "${PASSWORD:i:1}" 0.2; done
key ret 3; shot enrolled
key ret
echo "Enrolled; the VM is rebooting. Screens: $SHOTS"
