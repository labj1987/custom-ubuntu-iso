#!/bin/bash
# Runs inside the image chroot (as root). Builds GPU Remmina into
# /opt/remmina-gpu with build.sh, then removes everything the build needed
# except the runtime libraries the result links against, which are marked
# manually installed so autoremove can never take them.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX=/opt/remmina-gpu

log() { printf '\n==> %s\n' "$*"; }

apt-get update
dpkg-query -W -f='${Package}:${Architecture}\n' | sort > /tmp/pkgs-before

# The image runs on any GPU: install both VA-API drivers instead of
# detecting the build machine's.
apt-get install -y intel-media-va-driver mesa-va-drivers
apt-mark manual intel-media-va-driver mesa-va-drivers

# build.sh is the same script used on the machines; it builds in $HOME/src.
HOME=/root bash "$HERE/build.sh"

# System-wide menu entry (build.sh writes a per-user one into root's home).
sed -e "s|^Exec=remmina-file-wrapper |Exec=$PREFIX/bin/remmina-gpu |" \
    -e "s|^Exec=$PREFIX/bin/remmina |Exec=$PREFIX/bin/remmina-gpu |" \
    -e "s|^TryExec=.*|TryExec=$PREFIX/bin/remmina-gpu|" \
    "$PREFIX/share/applications/org.remmina.Remmina.desktop" \
    > /usr/share/applications/org.remmina.Remmina.desktop
install -d /usr/share/icons/hicolor
cp -a "$PREFIX/share/icons/hicolor/." /usr/share/icons/hicolor/ 2>/dev/null || true
echo "$PREFIX/lib" > /etc/ld.so.conf.d/remmina-gpu.conf && ldconfig
rm -rf /root/src /root/.local/share/applications/org.remmina.Remmina.desktop

log "Keeping the runtime libraries the build links against"
mapfile -t libs < <(find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -exec ldd {} + 2>/dev/null \
    | awk '/=> \// {print $3}' | grep -v "^$PREFIX/" | sort -u)
keep=()
for l in "${libs[@]}"; do
    p="$(dpkg -S "$(readlink -f "$l")" 2>/dev/null | head -1 | cut -d: -f1-2 | cut -d' ' -f1)" || true
    [[ -z "$p" ]] && p="$(dpkg -S "$l" 2>/dev/null | head -1 | cut -d: -f1-2 | cut -d' ' -f1)" || true
    [[ -n "$p" ]] && keep+=("${p%:}")
done
mapfile -t keep < <(printf '%s\n' "${keep[@]}" | sort -u)
apt-mark manual "${keep[@]}" >/dev/null
printf '%s\n' "${keep[@]}" > "$PREFIX/runtime-packages.txt"

log "Purging build-only packages"
dpkg-query -W -f='${Package}:${Architecture}\n' | sort > /tmp/pkgs-after
mapfile -t added < <(comm -13 /tmp/pkgs-before /tmp/pkgs-after)
# Everything the build added becomes removable, except the runtime libraries
# and the VA-API drivers; autoremove then takes the rest along with anything
# only they needed, never a dependency of what is kept.
(( ${#added[@]} )) && apt-mark auto "${added[@]}" >/dev/null
apt-mark manual "${keep[@]}" intel-media-va-driver mesa-va-drivers >/dev/null
apt-get autoremove --purge -y
rm -f /tmp/pkgs-before /tmp/pkgs-after

log "Checking every binary still resolves its libraries"
if find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -exec ldd {} + 2>/dev/null | grep -q "not found"; then
    find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -exec ldd {} + 2>/dev/null | grep "not found" | sort -u
    echo "ERROR: missing libraries after purge" >&2; exit 1
fi
"$PREFIX/bin/remmina" --version 2>/dev/null | head -1 || true
log "GPU Remmina ready in $PREFIX"
