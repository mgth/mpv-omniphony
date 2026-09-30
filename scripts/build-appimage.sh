#!/usr/bin/env bash
# Package a built mpv (with ad_orender) and its fallback liborender into a
# portable Linux AppImage.
#
# The plain Linux zip links the build host's own ffmpeg/libplacebo/lua sonames
# (Ubuntu 24.04: libavcodec.so.60, libplacebo.so.338, liblua5.2.so.0) and runs
# nowhere else — on Fedora or Arch it stops at "error while loading shared
# libraries" (mgth/Omniphony#605). The AppImage carries that library closure
# with it, so the host only needs glibc >= the build host's and its desktop
# stack.
#
# Usage: scripts/build-appimage.sh <mpv-build-dir> <liborender.so.N> <out.AppImage>
#   <mpv-build-dir>  the meson build dir holding the `mpv` binary (…/_b); the
#                    desktop file and icon come from its source tree (..)
#   <liborender.so.N> fallback engine, named after its own soname
#
# Env: TOOLS_DIR  where the pinned linuxdeploy/appimagetool are cached
#                 (default: build/appimage-tools)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -eq 3 ] || { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//;$d' >&2; exit 2; }
BUILD_DIR="$(cd "$1" && pwd)"
LIBORENDER="$2"
OUT="$(realpath -m "$3")"
MPV_SRC="$(cd "$BUILD_DIR/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/build/appimage-tools}"

[ -x "$BUILD_DIR/mpv" ] || { echo "!! no mpv binary in $BUILD_DIR" >&2; exit 1; }
[ -f "$LIBORENDER" ] || { echo "!! no liborender at $LIBORENDER" >&2; exit 1; }

# Pinned tools. appimagetool >= 1.9 embeds the static type2 runtime, so the
# resulting AppImage mounts through fusermount3 and does not need libfuse2 on
# the host (Fedora and recent Ubuntu no longer install it).
LINUXDEPLOY_URL=https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage
LINUXDEPLOY_SHA256=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
APPIMAGETOOL_URL=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
# appimagetool otherwise downloads the runtime from the `continuous` tag.
RUNTIME_URL=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

fetch_tool() { # <url> <sha256> -> path
    local dest="$TOOLS_DIR/$(basename "$1")"
    if [ ! -f "$dest" ] || ! echo "$2  $dest" | sha256sum -c --status; then
        curl -fsSL --retry 3 -o "$dest.part" "$1"
        echo "$2  $dest.part" | sha256sum -c --quiet
        mv "$dest.part" "$dest"
    fi
    chmod +x "$dest"
    echo "$dest"
}
mkdir -p "$TOOLS_DIR"
LINUXDEPLOY=$(fetch_tool "$LINUXDEPLOY_URL" "$LINUXDEPLOY_SHA256")
APPIMAGETOOL=$(fetch_tool "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256")
RUNTIME=$(fetch_tool "$RUNTIME_URL" "$RUNTIME_SHA256")
# CI runners and containers have no FUSE: run the tools from their own
# extracted payload instead of mounting them.
export APPIMAGE_EXTRACT_AND_RUN=1

APPDIR="$(mktemp -d)/mpv-omniphony.AppDir"
trap 'rm -rf "$(dirname "$APPDIR")"' EXIT
mkdir -p "$APPDIR/usr/bin"

# Desktop entry: mpv's own, renamed so an AppImage integrator (Gear Lever,
# AppImageLauncher) does not collide with a distro mpv. Exec stays `mpv`, the
# binary inside the AppDir.
sed -e 's/^Name=.*/Name=mpv-omniphony/' \
    -e 's/^Icon=.*/Icon=mpv-omniphony/' \
    -e '/^Name\[/d' \
    "$MPV_SRC/etc/mpv.desktop" > "$(dirname "$APPDIR")/mpv-omniphony.desktop"
cp "$MPV_SRC/etc/mpv.svg" "$(dirname "$APPDIR")/mpv-omniphony.svg"

# Libraries that must come from the host, on top of linuxdeploy's own
# excludelist (glibc, libGL/EGL, libdrm, X11, fontconfig, …):
#  - libstdc++/libgcc_s: the host's GPU driver (Mesa's LLVM, NVIDIA) is loaded
#    into this process and needs the host's, newer C++ runtime.
#  - libvulkan: the loader must match the host's ICDs.
#  - libva*: libva finds its drivers under a compile-time path
#    (/usr/lib/x86_64-linux-gnu/dri on the build host, /usr/lib64/dri on
#    Fedora) and refuses drivers built for a newer VA-API minor, so a bundled
#    copy would silently disable VA-API decoding.
#  - libpipewire: its client modules are looked up under a compile-time path
#    too, and must speak the host daemon's protocol version.
#  - libasound: its plugins (pipewire, pulse) and config live on the host.
#  - libwayland-*: the host's EGL/Vulkan WSI links them and needs its own.
EXCLUDES=(
    'libstdc++.so*' 'libgcc_s.so*'
    'libvulkan.so*'
    'libva.so*' 'libva-drm.so*' 'libva-x11.so*' 'libva-wayland.so*'
    'libpipewire-0.3.so*'
    'libasound.so*'
    'libwayland-client.so*' 'libwayland-cursor.so*' 'libwayland-egl.so*'
)
exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude-library "$e"); done

# The reverse: on linuxdeploy's excludelist, but not on every desktop (a
# Plasma install without GTK apps has no fribidi), and self-contained — no
# plugins, no data paths — so safe to carry.
FORCE=(libfribidi.so.0)
force_args=()
for l in "${FORCE[@]}"; do
    path=$(ldconfig -p | awk -v l="$l" '$1 == l && /x86-64/ {print $NF; exit}')
    force_args+=(--library "${path:?$l not found on the build host}")
done

"$LINUXDEPLOY" --appdir "$APPDIR" \
    --executable "$BUILD_DIR/mpv" \
    "${force_args[@]}" \
    --desktop-file "$(dirname "$APPDIR")/mpv-omniphony.desktop" \
    --icon-file "$(dirname "$APPDIR")/mpv-omniphony.svg" \
    "${exclude_args[@]}"

# liborender is dlopen'd, not linked, so linuxdeploy does not see it. mpv's
# loader looks next to /proc/self/exe — usr/bin inside the mounted image —
# after $ORENDER_LIBRARY and the Studio-deployed engine, same as the zip.
cp "$LIBORENDER" "$APPDIR/usr/bin/$(basename "$LIBORENDER")"

# Nothing in the bundle may still point at a library that is neither bundled,
# excluded on purpose, nor part of the base system linuxdeploy trusts.
unresolved=$(find "$APPDIR/usr" -type f \( -name mpv -o -name '*.so*' \) -print0 \
    | xargs -0 ldd 2>/dev/null | awk '/not found/ {print $1}' | sort -u || true)
if [ -n "$unresolved" ]; then
    echo "!! libraries not found on the build host:" >&2
    echo "$unresolved" >&2
    exit 1
fi

ARCH=x86_64 "$APPIMAGETOOL" --no-appstream --runtime-file "$RUNTIME" "$APPDIR" "$OUT"
echo ">> $OUT ($(du -h "$OUT" | cut -f1))"
