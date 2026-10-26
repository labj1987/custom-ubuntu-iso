#!/usr/bin/env bash
# Builds FreeRDP (with FFmpeg + VA-API hardware H.264 decode) and Remmina against it into
# /opt/remmina-gpu. Private prefix on purpose: a libfreerdp3.so.3 in /usr/local/lib would be
# picked up by gnome-remote-desktop (which links the system FreeRDP) and could break it.
set -euo pipefail

PREFIX=/opt/remmina-gpu
FREERDP_TAG=3.32.0
REMMINA_TAG=v1.4.43
SRC=$HOME/src/remmina-gpu
JOBS=$(nproc)

log() { printf '\n==> %s\n' "$*"; }

log "installing build dependencies"
sudo -n apt-get install -y -q --no-install-recommends \
  build-essential cmake ninja-build pkg-config git gettext \
  libssl-dev libkrb5-dev libcjson-dev libicu-dev uuid-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev libva-dev vainfo \
  libx11-dev libxext-dev libxinerama-dev libxcursor-dev libxdamage-dev libxv-dev \
  libxkbfile-dev libxrandr-dev libxi-dev libxrender-dev libxfixes-dev libxkbcommon-dev \
  libwayland-dev wayland-protocols \
  libasound2-dev libpulse-dev libopus-dev libcups2-dev libfuse3-dev libsystemd-dev \
  libusb-1.0-0-dev libudev-dev libjpeg-dev libpng-dev libwebp-dev \
  libgtk-3-dev libsecret-1-dev libsodium-dev libjson-glib-dev libgcrypt20-dev \
  libayatana-appindicator3-dev libavahi-ui-gtk3-dev libsoup-3.0-dev libpcre2-dev \
  libssh-dev libvte-2.91-dev libvncserver-dev libxcb1-dev libcurl4-openssl-dev

if lspci | grep -iE 'vga|display' | grep -qi intel; then
  log "Intel GPU present: installing the iHD VA-API driver"
  sudo -n apt-get install -y -q intel-media-va-driver
fi
if lspci | grep -iE 'vga|display' | grep -qE '\bAMD\b|\bATI\b|Radeon'; then
  log "AMD GPU present: ensuring Mesa VA-API drivers"
  sudo -n apt-get install -y -q mesa-va-drivers
fi

log "fetching sources"
mkdir -p "$SRC" && cd "$SRC"
[ -d FreeRDP ] || git clone -q --depth 1 --branch "$FREERDP_TAG" https://github.com/FreeRDP/FreeRDP.git
[ -d Remmina ] || git clone -q --depth 1 --branch "$REMMINA_TAG" https://gitlab.com/Remmina/Remmina.git

PATCH="$(dirname "$(readlink -f "$0")")/freerdp-hwaccel-nv12-download.patch"
if ! git -C FreeRDP apply --reverse --check "$PATCH" 2>/dev/null; then
  log "applying FreeRDP patch: download GPU frames as NV12 (avoids Intel iHD vaGetImage crash)"
  git -C FreeRDP apply "$PATCH"
fi

RPATCH="$(dirname "$(readlink -f "$0")")/remmina-rdp-relative-mouse.patch"
if ! git -C Remmina apply --reverse --check "$RPATCH" 2>/dev/null; then
  log "applying Remmina patch: relative mouse while the remote cursor is hidden (games over RDP)"
  git -C Remmina apply "$RPATCH"
fi

log "building FreeRDP $FREERDP_TAG"
cmake -S FreeRDP -B build-freerdp -G Ninja -Wno-dev \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF \
  -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_DSP_FFMPEG=ON -DWITH_SWSCALE=ON \
  -DWITH_FFMPEG_HWACCEL=ON -DWITH_OPENH264=OFF \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
  -DWITH_CLIENT_SDL=OFF -DWITH_X11=ON -DWITH_WAYLAND=ON \
  -DWITH_PULSE=ON -DWITH_ALSA=ON -DWITH_CUPS=ON -DWITH_FUSE=ON -DWITH_KRB5=ON \
  -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PKCS11=OFF \
  -DWITH_MANPAGES=OFF -DBUILD_TESTING=OFF -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_VERBOSE_WINPR_ASSERT=OFF
cmake --build build-freerdp -j "$JOBS"
sudo -n cmake --install build-freerdp

log "building Remmina $REMMINA_TAG"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" cmake -S Remmina -B build-remmina -G Ninja -Wno-dev \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
  -DWITH_FREERDP3=ON \
  -DWITH_NEWS=OFF -DWITH_STATS=OFF -DWITH_TIP=OFF -DWITH_WWW=OFF \
  -DWITH_PYTHONLIBS=OFF -DWITH_MANPAGES=OFF -DWITH_ICON_CACHE=OFF -DWITH_KF5WALLET=OFF
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" cmake --build build-remmina -j "$JOBS"
sudo -n cmake --install build-remmina

log "installing launcher"
# FREERDP_HWCTX_DEVICE picks the GPU; default is the first render node.
DEVICE=${REMMINA_GPU_DEVICE:-/dev/dri/renderD128}
sudo -n tee "$PREFIX/bin/remmina-gpu" >/dev/null <<EOF
#!/bin/sh
export FREERDP_HWCTX_TYPE=vaapi
export FREERDP_HWCTX_DEVICE=\${FREERDP_HWCTX_DEVICE:-$DEVICE}
exec $PREFIX/bin/remmina "\$@"
EOF
sudo -n chmod 755 "$PREFIX/bin/remmina-gpu"

# Same desktop ID as the packaged Remmina, so this one replaces its menu entry instead of
# adding a second icon.
mkdir -p "$HOME/.local/share/applications"
sed -e "s|^Exec=remmina-file-wrapper |Exec=$PREFIX/bin/remmina-gpu |" \
    -e "s|^Exec=$PREFIX/bin/remmina |Exec=$PREFIX/bin/remmina-gpu |" \
    -e "s|^TryExec=.*|TryExec=$PREFIX/bin/remmina-gpu|" \
    "$PREFIX/share/applications/org.remmina.Remmina.desktop" \
  > "$HOME/.local/share/applications/org.remmina.Remmina.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

log "done: $($PREFIX/bin/remmina --version 2>/dev/null | head -1)"
strings "$PREFIX/lib/libfreerdp3.so.3" | grep -oE 'WITH_(GFX_H264|VIDEO_FFMPEG|FFMPEG_HWACCEL)=[A-Z]+' | sort -u
