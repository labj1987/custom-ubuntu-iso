#!/bin/bash
# Builds the custom Ubuntu 26.10 ISO from the official desktop image.
#
#   ./build.sh [--iso PATH] [--keep-work]
#
# Run as root on an x86_64 Linux host with overlayfs, squashfs and loop
# devices (any Ubuntu machine, or a container that allows loop mounts).
# Needs: xorriso squashfs-tools gpg curl.
#
# How it works: the 26.10 installer copies a stack of squashfs layers
# (minimal -> minimal.standard -> minimal.standard.en for an English full
# install). This script mounts that stack read-only under an overlay,
# customizes it in a chroot, and squashes only the changes into one new
# layer on top: minimal.standard.en.custom.squashfs. The installer's source
# list is pointed at it, and the ISO is repacked with Ubuntu's own boot
# records, minus the layers nothing uses any more.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
# Mounts live in a private mount namespace: nothing propagates to the host or
# to other namespaces (services, Flatpak/Steam sandboxes), and all of them go
# away when the script exits.
[[ -n "${CUSTOM_ISO_PRIVATE_MOUNTS:-}" ]] \
    || CUSTOM_ISO_PRIVATE_MOUNTS=1 exec unshare --mount --propagation private "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE=26.10
BASE_URL="https://releases.ubuntu.com/$RELEASE"
ISO_NAME="ubuntu-$RELEASE-desktop-amd64.iso"
WORK="${WORK:-$HERE/work}"
OUT_DIR="${OUT_DIR:-$HERE/out}"
UBUNTU_CD_KEY=843938DF228D22F7B3742BC0D94AA3F0EFE21092
LAYER=minimal.standard.en.custom
ISO=""
KEEP_WORK=0

while (( $# )); do
    case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for t in xorriso mksquashfs unsquashfs gpg curl; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

log() { printf '\n### %s\n' "$*"; }
ROOT="$WORK/rootfs"

cleanup() {
    set +e
    for m in run dev/pts dev sys proc; do
        mountpoint -q "$ROOT/$m" && umount -R "$ROOT/$m"
    done
    mountpoint -q "$ROOT" && umount "$ROOT"
    for l in l3 l2 l1; do mountpoint -q "$WORK/$l" && umount "$WORK/$l"; done
}
trap cleanup EXIT

# ── 1. Official ISO, verified ─────────────────────────────────────────────
mkdir -p "$WORK/src" "$OUT_DIR"
if [[ -z "$ISO" ]]; then
    ISO="$WORK/src/$ISO_NAME"
    [[ -f "$ISO" ]] || { log "Downloading $ISO_NAME"; curl -fL -o "$ISO.part" "$BASE_URL/$ISO_NAME"; mv "$ISO.part" "$ISO"; }
fi
log "Verifying $ISO against Ubuntu's signed checksums"
curl -fsSL -o "$WORK/src/SHA256SUMS" "$BASE_URL/SHA256SUMS"
curl -fsSL -o "$WORK/src/SHA256SUMS.gpg" "$BASE_URL/SHA256SUMS.gpg"
export GNUPGHOME; GNUPGHOME="$(mktemp -d)"
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$UBUNTU_CD_KEY" | gpg -q --import
gpg -q --status-fd 1 --verify "$WORK/src/SHA256SUMS.gpg" "$WORK/src/SHA256SUMS" | grep -q "VALIDSIG $UBUNTU_CD_KEY" \
    || { echo "SHA256SUMS signature is not valid" >&2; exit 1; }
rm -rf "$GNUPGHOME"; unset GNUPGHOME
want="$(grep " \*$ISO_NAME\$" "$WORK/src/SHA256SUMS" | cut -d' ' -f1)"
have="$(sha256sum "$ISO" | cut -d' ' -f1)"
[[ -n "$want" && "$want" == "$have" ]] || { echo "ISO checksum mismatch" >&2; exit 1; }

# ── 2. Install layers ─────────────────────────────────────────────────────
log "Extracting the install layers"
mkdir -p "$WORK/layers"
# md5sum.txt always comes from this ISO, and a layer kept from an earlier run
# (of another ISO, or cut off part way) is used only while it matches it.
rm -f "$WORK/layers/md5sum.txt"
xorriso -osirrox on -indev "$ISO" -extract /md5sum.txt "$WORK/layers/md5sum.txt" >/dev/null 2>&1
chmod u+w "$WORK/layers/md5sum.txt"
layer_ok() {
    local want
    want="$(awk -v p="./casper/$1" '$2 == p {print $1; exit}' "$WORK/layers/md5sum.txt")"
    [[ -n "$want" && -f "$WORK/layers/$1" && "$(md5sum < "$WORK/layers/$1" | cut -d' ' -f1)" == "$want" ]]
}
for f in minimal.squashfs minimal.standard.squashfs minimal.standard.en.squashfs; do
    layer_ok "$f" && continue
    rm -f "$WORK/layers/$f"
    xorriso -osirrox on -indev "$ISO" -extract "/casper/$f" "$WORK/layers/$f" >/dev/null 2>&1
    layer_ok "$f" || { echo "$f does not match the ISO's md5sum.txt" >&2; exit 1; }
done

log "Stacking minimal -> standard -> en under an overlay"
rm -rf "$WORK/upper" "$WORK/ovl-work"
mkdir -p "$WORK/l1" "$WORK/l2" "$WORK/l3" "$WORK/upper" "$WORK/ovl-work" "$ROOT"
mount -t squashfs -o loop,ro "$WORK/layers/minimal.squashfs" "$WORK/l1"
mount -t squashfs -o loop,ro "$WORK/layers/minimal.standard.squashfs" "$WORK/l2"
mount -t squashfs -o loop,ro "$WORK/layers/minimal.standard.en.squashfs" "$WORK/l3"
mount -t overlay overlay -o "lowerdir=$WORK/l3:$WORK/l2:$WORK/l1,upperdir=$WORK/upper,workdir=$WORK/ovl-work" "$ROOT"
mount -t proc proc "$ROOT/proc"
mount --rbind /sys "$ROOT/sys"
mount --rbind /dev "$ROOT/dev"
mount -t tmpfs tmpfs "$ROOT/run"

# ── 3. Build-only chroot settings (all removed in step 6) ────────────────
STASH="$WORK/stash"; rm -rf "$STASH"; mkdir -p "$STASH" "$ROOT/run/systemd/resolve" "$ROOT/tmp/build"
cp /etc/resolv.conf "$ROOT/run/systemd/resolve/stub-resolv.conf"
mv "$ROOT/etc/apt/sources.list.d/cdrom.sources" "$STASH/"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"
CHROOT_ENV=(LC_ALL=C DEBIAN_FRONTEND=noninteractive)
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
    # Building behind an HTTPS proxy (with its own CA when BUILD_CA is set).
    proxy="${HTTPS_PROXY:-$https_proxy}"
    CHROOT_ENV+=("https_proxy=$proxy" "HTTPS_PROXY=$proxy")
    echo "Acquire::https::Proxy \"$proxy\";" > "$ROOT/etc/apt/apt.conf.d/00build-proxy"
    if [[ -n "${BUILD_CA:-}" ]]; then
        cp "$BUILD_CA" "$ROOT/tmp/build/ca.crt"
        echo 'Acquire::https::CaInfo "/tmp/build/ca.crt";' >> "$ROOT/etc/apt/apt.conf.d/00build-proxy"
        CHROOT_ENV+=(SSL_CERT_FILE=/tmp/build/ca.crt CURL_CA_BUNDLE=/tmp/build/ca.crt GIT_SSL_CAINFO=/tmp/build/ca.crt)
    fi
fi
in_chroot() { chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root "${CHROOT_ENV[@]}" "$@"; }

# ── 4. Files, then the customization ─────────────────────────────────────
log "Copying the image's own files"
# Files belong to root in the image, whoever owns the checkout (a user-owned
# /etc makes sudo refuse to run).
cp -a --no-preserve=ownership "$HERE/rootfs/." "$ROOT/"
chmod 0440 "$ROOT/etc/sudoers.d/90-sudo-nopasswd"
chmod 0755 "$ROOT"/usr/local/lib/custom-iso/*.sh
if [[ -f "$HERE/keys/zerocool.pub" ]]; then
    install -d -m 0700 "$ROOT/etc/skel/.ssh"
    install -m 0600 "$HERE/keys/zerocool.pub" "$ROOT/etc/skel/.ssh/authorized_keys"
else
    echo "WARNING: keys/zerocool.pub missing; installs will not pre-authorize ZeroCool" >&2
fi

log "Customizing (packages, repos, Flatpaks)"
cp "$HERE/scripts/customize-chroot.sh" "$ROOT/tmp/build/"
in_chroot /bin/bash /tmp/build/customize-chroot.sh

if [[ -f "$HERE/remmina-gpu/build-in-chroot.sh" ]]; then
    log "Building GPU Remmina into /opt/remmina-gpu"
    rm -rf "$ROOT/tmp/build/remmina-gpu"; cp -a --no-preserve=ownership "$HERE/remmina-gpu" "$ROOT/tmp/build/remmina-gpu"
    in_chroot /bin/bash /tmp/build/remmina-gpu/build-in-chroot.sh
else
    echo "WARNING: remmina-gpu/build-in-chroot.sh missing; GPU Remmina is not in this build" >&2
fi

# ── 5. Size and manifest of the finished install ──────────────────────────
in_chroot dpkg-query -W --showformat='${Package}\t${Version}\n' > "$WORK/$LAYER.manifest"
rm -rf "$ROOT"/var/lib/apt/lists/* "$ROOT"/var/cache/apt/*.bin "$ROOT"/var/cache/apt/archives/*.deb
SIZE="$(du -sb "$ROOT/" --exclude=proc --exclude=sys --exclude=dev --exclude=run | cut -f1)"

# ── 6. Remove the build-only settings ─────────────────────────────────────
log "Removing build-only settings"
rm -rf "$ROOT/tmp/build" "$ROOT/etc/apt/apt.conf.d/00build-proxy" "$ROOT/usr/sbin/policy-rc.d" \
    "$ROOT/root/src" "$ROOT/root/.cache" "$ROOT"/var/lib/apt/lists/* "$ROOT"/var/cache/apt/*.bin "$ROOT"/var/cache/apt/archives/*.deb
mv "$STASH/cdrom.sources" "$ROOT/etc/apt/sources.list.d/"
cleanup; trap - EXIT

# ── 7. The new layer ──────────────────────────────────────────────────────
log "Squashing the changes into $LAYER.squashfs"
rm -f "$WORK/$LAYER.squashfs"
mksquashfs "$WORK/upper" "$WORK/$LAYER.squashfs" -comp xz -b 1M -noappend -xattrs -no-progress
echo -n "$SIZE" > "$WORK/$LAYER.size"
cat > "$WORK/install-sources.yaml" <<EOF
kernel:
  default: linux-generic-hwe-26.04
sources:
- default: true
  description:
    en: Ubuntu Desktop with Steam, Claude, Tailscale, Flatpak and remote desktop set up.
  id: ubuntu-desktop
  locale_support: locale-only
  name:
    en: Ubuntu Desktop (custom)
  path: $LAYER.squashfs
  size: $SIZE
  type: fsimage-layered
  variant: desktop
  variations:
    standard:
      path: $LAYER.squashfs
      size: $SIZE
version: 2
EOF

# ── 8. Repack ─────────────────────────────────────────────────────────────
log "Repacking the ISO"
OUT="$OUT_DIR/ubuntu-$RELEASE-custom-amd64.iso"
mapfile -t ALL < <(xorriso -indev "$ISO" -find /casper -type f 2>/dev/null | tr -d "'" | grep '^/casper/')
KEEP_RE='^/casper/(vmlinuz|initrd|minimal\.squashfs|minimal\.standard\.squashfs|minimal\.standard\.en\.squashfs|minimal\.standard\.live\..*|minimal(\.standard)?(\.en)?\.(size|manifest)|filesystem\..*)$'
RM=()
for f in "${ALL[@]}"; do [[ "$f" =~ $KEEP_RE ]] || RM+=("$f"); done
RM=("${RM[@]/#\/casper\/install-sources.yaml/}")

# md5sum.txt: drop removed files, replace changed ones.
md5="$WORK/md5sum.txt"
cp "$WORK/layers/md5sum.txt" "$md5"
for f in "${RM[@]}" /casper/install-sources.yaml /.disk/info; do
    [[ -n "$f" ]] && grep -v "  \.$f\$" "$md5" > "$md5.new" && mv "$md5.new" "$md5"
done
echo "Ubuntu $RELEASE custom amd64 ($(date -u +%Y%m%d))" > "$WORK/disk-info"
for pair in "$WORK/$LAYER.squashfs:/casper/$LAYER.squashfs" "$WORK/$LAYER.size:/casper/$LAYER.size" \
            "$WORK/$LAYER.manifest:/casper/$LAYER.manifest" "$WORK/install-sources.yaml:/casper/install-sources.yaml" \
            "$WORK/disk-info:/.disk/info"; do
    echo "$(md5sum < "${pair%%:*}" | cut -d' ' -f1)  .${pair#*:}" >> "$md5"
done

RM_ARGS=()
for f in "${RM[@]}"; do [[ -n "$f" ]] && RM_ARGS+=("$f"); done
rm -f "$OUT"
# -rm takes every path up to "--".
xorriso -indev "$ISO" -outdev "$OUT" -boot_image any replay \
    -rm "${RM_ARGS[@]}" -- \
    -map "$WORK/$LAYER.squashfs" "/casper/$LAYER.squashfs" \
    -map "$WORK/$LAYER.size" "/casper/$LAYER.size" \
    -map "$WORK/$LAYER.manifest" "/casper/$LAYER.manifest" \
    -map "$WORK/install-sources.yaml" /casper/install-sources.yaml \
    -map "$WORK/disk-info" /.disk/info \
    -map "$md5" /md5sum.txt \
    -volid "Ubuntu 26.10 custom amd64"

(cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
(( KEEP_WORK )) || rm -rf "$WORK/upper" "$WORK/ovl-work" "$WORK/l1" "$WORK/l2" "$WORK/l3" "$WORK/rootfs"
log "Done: $OUT"
ls -lh "$OUT"
