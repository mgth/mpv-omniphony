#!/usr/bin/env bash
# Build the Dolby Vision FEL dependency stack into an isolated $PREFIX, to be
# linked afterwards by the normal mpv build (export PKG_CONFIG_PATH / PATH).
#
# FEL needs three libs that no released distro/package ships yet (but which are
# all now in their UPSTREAM masters — no fork/patch, see deps-fel/pins-fel.env):
#   libdovi      RPU parsing for the enhancement layer (pkg-config: dovi)
#   libplacebo   upstream master, reconstructs the FEL (needs PL_API_VER >= 370)
#   ffmpeg       upstream master, carries the dovi_split BSF + DoVi stream group
#
# This is NOT the mpv build — it is only the FEL delta on the dependency side.
# Refs/branches come from deps-fel/pins-fel.env (upstream master, built from
# source only because no release ships these yet).
#
# Usage:
#   PREFIX=/path/to/prefix scripts/build-fel-deps.sh            # native (Linux)
#   PREFIX=/path CROSS_FILE=cross.ini scripts/build-fel-deps.sh --cross   # MinGW
#
# Env:
#   PREFIX        install prefix (default: $PWD/fel-prefix)
#   WORK          checkout/build scratch dir (default: $PWD/fel-work)
#   JOBS          parallelism (default: nproc)
#   CROSS_FILE    meson cross-file (required with --cross)
#   CROSS_PREFIX  toolchain prefix for --cross (default: x86_64-w64-mingw32-)
#   RUST_TARGET   cargo target for --cross (default: x86_64-pc-windows-gnu)
#   SKIP_LIBDOVI  set to 1 to reuse a libdovi already on PKG_CONFIG_PATH
#   SKIP_FFMPEG   set to 1 to reuse the ffmpeg already installed in $PREFIX
#                 (e.g. to rebuild only libplacebo after a patches-libplacebo change)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps-fel/pins-fel.env
source "$REPO_ROOT/deps-fel/pins-fel.env"

PREFIX="${PREFIX:-$PWD/fel-prefix}"
WORK="${WORK:-$PWD/fel-work}"
# macOS lacks nproc / NVIDIA / LD_LIBRARY_PATH; detect it once and branch below.
[ "$(uname -s)" = "Darwin" ] && MACOS=1 || MACOS=0
JOBS="${JOBS:-$( [ "$MACOS" = 1 ] && sysctl -n hw.ncpu || nproc )}"

CROSS=0
[ "${1:-}" = "--cross" ] && CROSS=1
[ "${MINGW:-0}" = "1" ] && CROSS=1
CROSS_PREFIX="${CROSS_PREFIX:-x86_64-w64-mingw32-}"
RUST_TARGET="${RUST_TARGET:-x86_64-pc-windows-gnu}"

# pkg-config the rest of the build will consult; our $PREFIX must win so the
# master libplacebo shadows any system/Martchus libplacebo (the classic FEL trap).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Only put $PREFIX/bin on PATH in native mode (to run the freshly built ffmpeg
# for the dovi_split check). In cross mode $PREFIX is the MinGW sysroot, whose
# bin holds Windows target binaries/DLLs; prepending it breaks ffmpeg's *host*
# compiler detection ("Host compiler lacks C11 support").
[ "${CROSS:-0}" = 0 ] && export PATH="$PREFIX/bin:$PATH"

mkdir -p "$WORK" "$PREFIX"
log(){ printf '\n>> %s\n' "$*"; }

if [ "$CROSS" = 1 ]; then
    [ -n "${CROSS_FILE:-}" ] || { echo "!! --cross needs CROSS_FILE=<meson cross-file>" >&2; exit 2; }
    PKGCONFIG="${CROSS_PREFIX}pkg-config"
    log "cross mode: prefix=$CROSS_PREFIX cross-file=$CROSS_FILE rust-target=$RUST_TARGET"
else
    PKGCONFIG="pkg-config"
    log "native mode"
fi

# ---------------------------------------------------------------------------
# 1. libdovi (quietvoid/dovi_tool, dolby_vision crate) via cargo-c.
#    Skipped if a usable libdovi is already discoverable, or SKIP_LIBDOVI=1.
# ---------------------------------------------------------------------------
if [ "${SKIP_LIBDOVI:-0}" = 1 ] || "$PKGCONFIG" --exists dovi 2>/dev/null; then
    log "libdovi already present ($("$PKGCONFIG" --modversion dovi 2>/dev/null || echo external)) — skipping"
else
    log "libdovi (cargo cinstall)"
    command -v cargo-cinstall >/dev/null 2>&1 || cargo install cargo-c --locked
    if [ ! -d "$WORK/dovi_tool/.git" ]; then
        git clone https://github.com/quietvoid/dovi_tool.git "$WORK/dovi_tool"
    fi
    capi_args=(--release --prefix="$PREFIX" --libdir="$PREFIX/lib")
    if [ "$CROSS" = 1 ]; then
        rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
        capi_args+=(--target "$RUST_TARGET")
        # Point the cc crate and cargo's linker at the MinGW toolchain for the
        # target, else transitive C deps (e.g. libz-sys) get built with the host
        # compiler and the assembler rejects the host asm ('.hidden' etc.).
        rt_lc="$(printf '%s' "$RUST_TARGET" | tr 'A-Z-' 'a-z_')"
        rt_uc="$(printf '%s' "$RUST_TARGET" | tr 'a-z-' 'A-Z_')"
        export "CC_${rt_lc}=${CROSS_PREFIX}gcc"
        export "CXX_${rt_lc}=${CROSS_PREFIX}g++"
        export "AR_${rt_lc}=${CROSS_PREFIX}ar"
        export "CARGO_TARGET_${rt_uc}_LINKER=${CROSS_PREFIX}gcc"
    fi
    ( cd "$WORK/dovi_tool/dolby_vision" && cargo cinstall "${capi_args[@]}" )
fi

# ---------------------------------------------------------------------------
# 2. libplacebo (upstream master, PL_API_VER >= 370) — has the FEL API.
# ---------------------------------------------------------------------------
log "libplacebo $LIBPLACEBO_REF"
if [ ! -d "$WORK/libplacebo/.git" ]; then
    git clone --branch "$LIBPLACEBO_REF" --recurse-submodules "$LIBPLACEBO_URL" "$WORK/libplacebo"
else
    git -C "$WORK/libplacebo" fetch origin "$LIBPLACEBO_REF"
    git -C "$WORK/libplacebo" reset --hard "origin/$LIBPLACEBO_REF"
    git -C "$WORK/libplacebo" submodule update --init --recursive
fi
PLACEBO_SHA="$(git -C "$WORK/libplacebo" rev-parse --short HEAD)"

# Keep local integration fixes separate from upstream tracking. In particular,
# the Wayland color-management path requests a PASS_THROUGH Vulkan colorspace;
# without the 9001 patch below, libplacebo prefers 16-bit UNORM over FP16 and
# clips extended-range scRGB values above 1.0. 9002 carries the not-yet-merged
# tone/gamut mapping rework (upstream MR !875, mpv-omniphony#72); it bumps the
# soname, so mpv must be relinked after a rebuild. Each patch's header says
# where it comes from and when it can be dropped.
pl_patches=("$REPO_ROOT"/patches-libplacebo/*.patch)
if [ -e "${pl_patches[0]}" ]; then
    for patch in "${pl_patches[@]}"; do
        if git -C "$WORK/libplacebo" apply --check "$patch"; then
            git -C "$WORK/libplacebo" apply "$patch"
        elif git -C "$WORK/libplacebo" apply --reverse --check "$patch"; then
            log "libplacebo patch already applied: $(basename "$patch")"
        else
            echo "!! libplacebo patch no longer applies: $patch" >&2
            exit 1
        fi
    done
fi

# Force --libdir=lib so the .pc lands in $PREFIX/lib/pkgconfig everywhere;
# Ubuntu/Debian meson otherwise defaults to a multiarch lib/<triplet> dir that
# our PKG_CONFIG_PATH ($PREFIX/lib/pkgconfig) would miss. (Homebrew is not
# multiarch, so this is a no-op but still correct on macOS.)
# Vulkan is still required for the FEL reconstruction path. On macOS there is no
# native Vulkan driver: -Dvulkan=enabled resolves against the Homebrew Vulkan
# stack (molten-vk + vulkan-loader + vulkan-headers, plus shaderc/glslang), i.e.
# Vulkan-on-Metal via MoltenVK. The caller must have those on PKG_CONFIG_PATH.
pl_args=(--prefix="$PREFIX" --libdir=lib --buildtype=release
         -Dvulkan=enabled -Dshaderc=enabled -Dlcms=enabled
         -Ddovi=enabled -Dlibdovi=enabled -Ddemos=false)
# d3d11 (Windows only) needs spirv-cross for SPIR-V→HLSL; without it libplacebo
# builds d3d11 stubs and mpv's --gpu-api/--gpu-context=d3d11 is unavailable.
[ "$CROSS" = 1 ] && pl_args+=(--cross-file="$CROSS_FILE" -Dd3d11=enabled)

rm -rf "$WORK/libplacebo/build"
meson setup "$WORK/libplacebo/build" "$WORK/libplacebo" "${pl_args[@]}"
ninja -C "$WORK/libplacebo/build"
ninja -C "$WORK/libplacebo/build" install

pl_ver="$("$PKGCONFIG" --modversion libplacebo)"
log "libplacebo $pl_ver installed (sha=$PLACEBO_SHA)"
# modversion 7.370 == PL_API_VER 370. pl_frame.enhancement_layer landed at 367,
# but mpv master dropped the deprecated pl_avdovi_metadata_supported (removed at
# 370), so it needs >= 370. Upstream master is already there. Refuse anything older.
"$PKGCONFIG" --atleast-version=7.370 libplacebo || {
    echo "!! libplacebo $pl_ver lacks the FEL API (need >= 7.370 / PL_API_VER 370)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2b. nv-codec-headers (ffnvcodec) — lets the ffmpeg below build NVIDIA nvdec/
#     cuvid and lets the mpv build's cuda-hwaccel configure. Header-only;
#     nvcuda/nvcuvid are dlopen'd at runtime, so no CUDA SDK is needed and the
#     cross build works the same. Installs ffnvcodec.pc into $PREFIX/lib/pkgconfig
#     (already first on PKG_CONFIG_PATH).
# ---------------------------------------------------------------------------
# No NVIDIA on Apple Silicon — skip ffnvcodec entirely there.
if [ "$MACOS" = 1 ]; then
    log "nv-codec-headers skipped (macOS: no NVIDIA)"
else
    NVCODEC_REF=n13.0.19.0
    log "nv-codec-headers $NVCODEC_REF"
    if [ ! -d "$WORK/nv-codec-headers/.git" ]; then
        git clone --depth 1 --branch "$NVCODEC_REF" \
            https://github.com/FFmpeg/nv-codec-headers "$WORK/nv-codec-headers"
    fi
    make -C "$WORK/nv-codec-headers" install PREFIX="$PREFIX"
fi

# ---------------------------------------------------------------------------
# 3. ffmpeg (upstream master — carries the dovi_split BSF + DoVi stream group).
# ---------------------------------------------------------------------------
if [ "${SKIP_FFMPEG:-0}" = 1 ] && "$PKGCONFIG" --exists libavcodec 2>/dev/null; then
    log "ffmpeg already present in prefix (libavcodec $("$PKGCONFIG" --modversion libavcodec)) — skipping (SKIP_FFMPEG=1)"
else
log "ffmpeg $FFMPEG_REF"
if [ ! -d "$WORK/ffmpeg/.git" ]; then
    git clone --branch "$FFMPEG_REF" "$FFMPEG_URL" "$WORK/ffmpeg"
else
    # We track master now, so an existing clone must re-fetch (like libplacebo
    # above) — a bare reset would freeze it at the clone-time origin/master.
    git -C "$WORK/ffmpeg" fetch origin "${FFMPEG_REF##*/}"
fi
git -C "$WORK/ffmpeg" reset --hard -q "origin/${FFMPEG_REF##*/}" 2>/dev/null || true
git -C "$WORK/ffmpeg" clean -fdx >/dev/null 2>&1 || true

# libopus: the wrapper decoder must be available as a fallback next to the
# native opus decoder (mpv-omniphony#64 shipped FEL bundles without it).
ff_args=(--prefix="$PREFIX" --enable-shared --disable-static
         --enable-gpl --enable-version3 --disable-doc
         --enable-libopus)
# NVIDIA nvdec/cuvid only where NVIDIA exists; macOS auto-detects VideoToolbox
# instead, which is fine — FEL needs only the dovi_split BSF + libdovi.
[ "$MACOS" = 1 ] || ff_args+=(--enable-ffnvcodec --enable-nvdec --enable-cuvid)
if [ "$CROSS" = 1 ]; then
    ff_args+=(--enable-cross-compile --cross-prefix="$CROSS_PREFIX"
              --arch=x86_64 --target-os=mingw32
              --pkg-config="$PKGCONFIG")
else
    # Native (Linux): let ffmpeg auto-detect VA-API + Vulkan video decode rather
    # than forcing them. --enable-vulkan hard-fails configure when the runner's
    # Vulkan headers/loader are older than ffmpeg requires; auto enables each when
    # sufficient and skips otherwise. CUDA/nvdec + the libplacebo master FEL
    # reconstruction path are the essentials and remain.
    :
fi
( cd "$WORK/ffmpeg" && ./configure "${ff_args[@]}" )
make -C "$WORK/ffmpeg" -j"$JOBS"
make -C "$WORK/ffmpeg" install
fi

# Run the freshly built ffmpeg CLI against ITS OWN libavcodec (loader path),
# not whatever libavcodec happens to be on the system loader path — otherwise the
# check silently inspects the wrong (dovi_split-less) library. Native only; under
# cross there is no runnable host ffmpeg, so we trust the configure/compile of the
# BSF instead. macOS uses DYLD_LIBRARY_PATH (SIP doesn't strip it for our own,
# non-system binary).
if [ "$CROSS" = 0 ]; then
    if [ "$MACOS" = 1 ]; then
        DYLD_LIBRARY_PATH="$PREFIX/lib:${DYLD_LIBRARY_PATH:-}" \
            "${PREFIX}/bin/ffmpeg" -hide_banner -bsfs 2>/dev/null | grep -q dovi_split \
            || { echo "!! dovi_split BSF missing from built ffmpeg" >&2; exit 1; }
    else
        LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
            "${PREFIX}/bin/ffmpeg" -hide_banner -bsfs 2>/dev/null | grep -q dovi_split \
            || { echo "!! dovi_split BSF missing from built ffmpeg" >&2; exit 1; }
    fi
    log "ffmpeg OK (dovi_split present)"
elif [ "${SKIP_FFMPEG:-0}" = 1 ]; then
    log "ffmpeg cross-built earlier (SKIP_FFMPEG=1, source tree not re-checked)"
else
    grep -q dovi_split "$WORK/ffmpeg/libavcodec/bitstream_filters.c" \
        || { echo "!! dovi_split not registered in cross ffmpeg" >&2; exit 1; }
    log "ffmpeg cross-built (dovi_split registered)"
fi

cat <<EOF

=== FEL deps ready in: $PREFIX ===
  libplacebo $pl_ver (master $PLACEBO_SHA, API >= 370)
  ffmpeg     $FFMPEG_REF (dovi_split BSF + DoVi stream group, upstream)
  libdovi    $("$PKGCONFIG" --modversion dovi 2>/dev/null || echo present)

Link your mpv build against it:
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:\$PKG_CONFIG_PATH"
  export PATH="$PREFIX/bin:\$PATH"
Then apply the orender patches onto mpv master (FEL is native there now):
  scripts/apply-patches-master.sh
EOF
