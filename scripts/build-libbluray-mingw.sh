#!/usr/bin/env bash
# Build libbluray from source into the MinGW cross sysroot, WITH its vendored
# libudfread (BD-ISO / UDF image support) statically embedded.
#
# Why this exists: the Martchus prebuilt `mingw-w64-libbluray` is compiled
# without libudfread, so it can only read Blu-ray *folders* (an extracted
# BDMV/), not raw .iso images. libbluray 1.4.x bundles libudfread under
# contrib/ and its meson build falls back to that subproject when no system
# libudfread is found, linking it statically (embed_udfread=true). The result
# is a single libbluray DLL that opens BD ISOs, with no extra DLL to bundle.
#
# Use: drop `mingw-w64-libbluray` from the pacman install and run this instead.
# It installs over the same MinGW prefix, so mpv's meson finds it via
# pkg-config. libdvdnav/libdvdread (DVD, incl. ISO) still come from Martchus —
# they read disc images natively and need no rebuild.
#
# Env:
#   CROSS_FILE      meson cross-file for x86_64-w64-mingw32 (required)
#   SYS             MinGW sysroot / install prefix (default /usr/x86_64-w64-mingw32)
#   LIBBLURAY_VER   libbluray release to build (default 1.4.1, matches Martchus)
set -euo pipefail

: "${CROSS_FILE:?set CROSS_FILE to the meson mingw cross-file}"
SYS="${SYS:-/usr/x86_64-w64-mingw32}"
LIBBLURAY_VER="${LIBBLURAY_VER:-1.4.1}"
HOST=x86_64-w64-mingw32

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

url="https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VER}/libbluray-${LIBBLURAY_VER}.tar.xz"
echo ">> fetching $url"
curl -fsSL -o libbluray.tar.xz "$url"
tar xf libbluray.tar.xz
cd "libbluray-${LIBBLURAY_VER}"

# default_library=shared    -> ship libbluray as a DLL (mpv links it dynamically)
# embed_udfread=true (default) -> vendored libudfread linked statically into the DLL
# bdj_jar=disabled          -> no BD-J Java menus (no JDK in CI; A/V playback only)
# enable_tools=false        -> skip the bd_info/etc. CLI tools we don't ship
# fontconfig/freetype/libxml2 stay at auto: resolved from $SYS via the cross
# pkg-config named in CROSS_FILE (fontconfig auto-disables on Windows by design).
meson setup _b \
  --cross-file "$CROSS_FILE" \
  --prefix "$SYS" \
  --libdir lib \
  --buildtype release \
  -Ddefault_library=shared \
  -Dbdj_jar=disabled \
  -Denable_tools=false
meson compile -C _b
meson install -C _b

# `meson setup` above would already have failed if libudfread were unavailable
# (the dependency() call is not optional). Assert the DLL + .pc actually landed
# so the mpv build that follows finds them.
dll="$(ls "$SYS"/bin/libbluray*.dll 2>/dev/null | head -1 || true)"
test -n "$dll" || { echo "!! libbluray DLL not installed into $SYS/bin" >&2; exit 1; }
"${HOST}-pkg-config" --exists libbluray \
  || { echo "!! libbluray.pc not visible to the MinGW pkg-config" >&2; exit 1; }
echo "OK: installed $(basename "$dll") (libbluray ${LIBBLURAY_VER} + embedded libudfread, BD-ISO enabled)"
