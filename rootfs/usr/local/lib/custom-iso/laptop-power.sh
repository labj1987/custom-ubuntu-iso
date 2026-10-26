#!/bin/bash
# Laptops only: TLP for power management. Needs the network, so it runs
# after it is up and retries on later boots until it succeeds.
set -uo pipefail
STATE=/var/lib/custom-iso
mkdir -p "$STATE"
log() { echo "[custom-iso] $*"; }

chassis="$(hostnamectl chassis 2>/dev/null || cat /sys/class/dmi/id/chassis_type 2>/dev/null)"
case "$chassis" in
    laptop|notebook|convertible|tablet|8|9|10|14|31|32) ;;
    *) log "Not a laptop ($chassis): leaving power management as it is"; touch "$STATE/laptop-power-done"; exit 0 ;;
esac

export DEBIAN_FRONTEND=noninteractive
for _ in 1 2 3; do
    if apt-get update -qq && apt-get install -y tlp tlp-rdw tlp-pd; then
        systemctl enable --now tlp.service
        log "TLP installed and enabled"
        touch "$STATE/laptop-power-done"
        exit 0
    fi
    sleep 20
done
log "WARNING: TLP install failed; retried next boot"
exit 0
