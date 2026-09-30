#!/usr/bin/env bash
# Smoke-test a built AppImage on a distro other than the build host, so a
# library that silently resolved from the Ubuntu runner cannot slip through
# (mgth/Omniphony#605: the zip worked on Ubuntu 24.04 and nowhere else).
#
# Runs the extracted AppImage in a container with only what a desktop always
# has (glibc, X11/Wayland client libs, EGL, Vulkan loader, libva, PipeWire,
# ALSA), then checks that: every library resolves; mpv starts; the desktop
# video and audio backends are compiled in; the bundled ffmpeg can encode and
# decode; and ad_orender loads the liborender shipped inside the image.
#
# Usage: scripts/smoke-test-appimage.sh <file.AppImage> [image]
#   image  container image to run in (default: fedora:latest)
set -euo pipefail

APPIMAGE="$(realpath "$1")"
IMAGE="${2:-fedora:latest}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --appimage-extract needs no FUSE (containers and CI runners have none).
(cd "$WORK" && "$APPIMAGE" --appimage-extract >/dev/null)

# One second of 5.1 tone for the decode probe below (mpv has no libavdevice,
# so it cannot synthesise one through lavfi itself).
python3 - "$WORK/tone51.wav" <<'EOF'
import math, struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(6); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 48000))) * 6
        for i in range(48000)))
EOF

# The host libraries build-appimage.sh deliberately leaves out, plus the base
# X11/EGL/fontconfig set from linuxdeploy's excludelist.
HOST_PKGS="libX11 libXext libXScrnSaver libXpresent libXrandr libXfixes libxcb \
libglvnd-egl libglvnd-glx mesa-libEGL mesa-libgbm libdrm vulkan-loader \
libva pipewire-libs alsa-lib pulseaudio-libs libwayland-client \
libwayland-cursor libwayland-egl libxkbcommon fontconfig freetype \
harfbuzz expat zlib-ng-compat libstdc++ libgcc"

docker run --rm --network host -v "$WORK/squashfs-root:/app:ro" -v "$WORK:/work:ro" \
    "$IMAGE" bash -euo pipefail -c "
    dnf install -y -q $HOST_PKGS >/dev/null 2>&1
    cd /tmp
    mpv=/app/usr/bin/mpv

    missing=\$(ldd \$mpv /app/usr/lib/*.so* 2>/dev/null | awk '/not found/ {print \$1}' | sort -u)
    [ -z \"\$missing\" ] || { echo '!! unresolved on $IMAGE:'; echo \"\$missing\"; exit 1; }

    # Captured, not piped into head: pipefail would turn mpv's SIGPIPE into
    # a failure.
    version=\$(/app/AppRun --version)
    grep -m1 '^mpv ' <<<\"\$version\"

    aos=\$(/app/AppRun --ao=help)
    for ao in pipewire pulse alsa; do
        grep -qw \$ao <<<\"\$aos\" || { echo \"!! ao \$ao missing\"; exit 1; }
    done
    vos=\$(/app/AppRun --vo=help)
    for vo in gpu gpu-next; do
        grep -qw \$vo <<<\"\$vos\" || { echo \"!! vo \$vo missing\"; exit 1; }
    done

    # The tone encoded to E-AC-3 by the bundled ffmpeg, then decoded through
    # ad_orender: no bridge is configured here, so the stream falls back to
    # ad_lavc, but only after the engine was found next to the binary.
    /app/AppRun --no-config --really-quiet /work/tone51.wav \
        --o=probe.mka --oac=eac3 --of=matroska
    log=\$(/app/AppRun --no-config --ad=orender,lavc --ao=null --vo=null \
        probe.mka 2>&1 || true)
    line=\$(grep -E 'orender: loaded liborender .*/app/usr/bin/liborender\.so\.[0-9]+ \(next to mpv\)' <<<\"\$log\") \
        || { echo '!! bundled liborender not loaded:'; echo \"\$log\" | tail -30; exit 1; }
    echo \"\$line\"
    echo '>> AppImage OK on $IMAGE'
"
