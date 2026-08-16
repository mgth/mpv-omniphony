# mpv-omniphony

mpv with a **spatial audio decoder** that renders objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. **This repository holds the mpv-side
integration and build only.**

[![Download Omniphony Studio](https://img.shields.io/badge/Download-Omniphony-2ea44f?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/latest)
[![Download mpv-omniphony](https://img.shields.io/badge/Download-mpv--omniphony-1f6feb?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/tag/mpv-v0.4.2)
[![Download mpv-omniphony FEL](https://img.shields.io/badge/Download-mpv--omniphony%20FEL-8957e5?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/tag/mpv-v0.4.2-fel-beta.1)

> 📖 **Usage** (playback, Studio supervision, overlay controls) and **prebuilt
> downloads** live with the engine:
> **[Omniphony → mpv-omniphony usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md)**.
> Releases are published on the **engine** repo — this repo carries no downloads.

> ⭐ **mpv-omniphony is one frontend for the
> [Omniphony](https://github.com/mgth/Omniphony) spatial audio engine — the engine
> is the project.** If this is useful to you, please
> **[star the engine ↗](https://github.com/mgth/Omniphony)**.
>
> [![Star Omniphony](https://img.shields.io/github/stars/mgth/Omniphony?style=social&label=Star%20the%20engine)](https://github.com/mgth/Omniphony)

This repo holds **only** the mpv-side integration: the decoder source
(`src/ad_orender.c`), the patches that wire it into the mpv build, packaging and
CI. The renderer itself (`liborender.so` + the decoder bridge) is built and
packaged from the `Omniphony` repo (`packaging/arch/`).

mpv loads liborender at **runtime** (dlopen + ABI version handshake) — building
mpv needs no engine at all, and an updated engine (e.g. deployed by Omniphony
Studio) is picked up without rebuilding mpv. The library search order and the
`--ad-orender-library` option are documented in the
[usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md).

## Layout

```
src/ad_orender.c        # readable copy of the decoder (patch 0001 adds it to mpv)
patches/                # generated diffs vs. pinned mpv v0.41.0
patches-master/         # generated diffs vs. upstream mpv master HEAD (live tracker)
scripts/apply-patches.sh             # clone pinned mpv + apply patches/
scripts/apply-patches-master.sh      # clone mpv master HEAD + apply patches-master/
scripts/regenerate-patches.sh        # rebuild patches/ from the fork's `orender`
scripts/regenerate-patches-master.sh # rebuild patches-master/ from `orender-master`
meson-options.txt       # canonical `orender` meson feature option
packaging/PKGBUILD          # Arch package against v0.41.0 (provides/conflicts mpv)
packaging/PKGBUILD-master   # Arch -git package tracking master HEAD
packaging/libmpv-README.md  # shipped inside the Windows libmpv SDK zip
.github/workflows/ci.yml             # weekly drift check on v0.41.0
.github/workflows/build-master.yml   # daily smoke test on master HEAD
```

## Build (dev)

```sh
# 1. assemble a patched mpv tree at build/mpv-v0.41.0 (clones the pinned tag):
scripts/apply-patches.sh v0.41.0

# 2. build it (no liborender needed at build time — it is dlopen'd at runtime):
cd build/mpv-v0.41.0
meson setup _b -Dorender=enabled && meson compile -C _b

# (to refresh patches/ after editing the fork's `orender` branch:)
scripts/regenerate-patches.sh /path/to/mpv-fork v0.41.0
```

Running it (playback, the shared `~/.config/omniphony/config.yaml`, OSC, Studio
supervision and the on-video overlay) is documented in the
[usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md).

### Embedding (libmpv)

Windows releases carry a second asset,
`libmpv-omniphony-<tag>-windows-x86_64.zip`: `libmpv-2.dll` from the same
build, with the MinGW import library, an `mpv.def` for MSVC, the `mpv/`
headers and the runtime DLLs. Details in
[`packaging/libmpv-README.md`](packaging/libmpv-README.md) — note it is a
**GPL-3.0-or-later** libmpv (mpv `-Dgpl=true` combined with liborender), not
the LGPL build upstream publishes.

## mpv fork workflow

Develop the integration in a fork of `mpv-player/mpv`:

- `master` mirrors upstream (never modified).
- `orender` carries the integration commits based on the pinned `v0.41.0` tag.
- `orender-master` carries the same commits rebased onto `upstream/master` (feeds
  `patches-master/`; rebase periodically when the daily CI flags drift).

```sh
git remote add upstream https://github.com/mpv-player/mpv.git
git fetch upstream
git checkout master && git merge upstream/master
git checkout orender
# Integrate the decoder changes here, but keep this branch based on v0.41.0.
scripts/regenerate-patches.sh /path/to/mpv-fork v0.41.0
```

Do not rebase `orender` onto `master`: the stable patch series is intentionally
generated from the pinned `v0.41.0` base. Only `orender-master`, described
below, follows current upstream `master`.

## Tracking mpv master

A second build path targets **upstream mpv master HEAD** (no SHA pin, live
tracker). Useful for catching breakage early and for power users who want the
freshest mpv with the orender decoder. The pinned `v0.41.0` flow above is the
stable default — the master flow may break on any upstream merge.

```sh
# Local build (clones mpv master + applies patches-master/):
scripts/apply-patches-master.sh
cd build/mpv-master-<short-sha>
meson setup _b -Dorender=enabled && meson compile -C _b
```

When the daily CI (`build-master.yml`) goes red, it means an upstream merge
collided with one of the 7 integration commits. Rebase `orender-master`:

```sh
cd /path/to/mpv-fork
git checkout orender-master
git fetch upstream
git rebase upstream/master                      # resolve conflicts
cd /path/to/mpv-omniphony
scripts/regenerate-patches-master.sh /path/to/mpv-fork
git add patches-master/ && git commit -m "patches-master: rebase onto upstream/master"
```

Packaging: `packaging/PKGBUILD-master` builds an `mpv-omniphony-git` package
that clones mpv master at install time and applies `patches-master/`. It
conflicts with both stock `mpv` and the stable `mpv-omniphony` — install one.

## Dolby Vision FEL (experimental)

Optional support for **Dolby Vision Profile 7 FEL** (Full Enhancement Layer). As
of 2026-07-01 this is a **native, upstream mpv feature** (no fork, no vendored
patch): mpv [PR #17932](https://github.com/mpv-player/mpv/pull/17932) is **merged
into mpv master** (v0.42.0), and the two deps it needs are in their own upstream
masters. We still build those two deps from source only because no released
distro/package ships the FEL API yet:

| Component | Role | Source |
|---|---|---|
| mpv master | demux P7, split BL/EL, pair, hand EL to libplacebo | native (mpv PR #17932, merged); applied via `patches-master/` (orender only) |
| libplacebo master | reconstructs the FEL (needs `PL_API_VER >= 370`) | built by `build-fel-deps.sh` (upstream MR !851, merged to master) |
| ffmpeg master | `dovi_split` BSF + DoVi stream group → BL/EL packets | built by `build-fel-deps.sh` (upstream) |
| libdovi | RPU parsing for the EL | built by `build-fel-deps.sh` (quietvoid/dovi_tool) |

**Credits:** the Dolby Vision Profile 7 FEL work is by **kasper93** (Kacper
Michajłow) — mpv [PR #17932](https://github.com/mpv-player/mpv/pull/17932),
merged into mpv master, building on the matching libplacebo + ffmpeg upstream
support. This repo only tracks upstream master and packages it.

**The trap:** FEL renders only if mpv is *linked* to a libplacebo with the FEL
API (`PL_API_VER >= 370`) **and** an ffmpeg with `dovi_split`. Binaries that
launch but only show the base layer were linked against a too-old (system)
libplacebo. So this build links a dedicated prefix **first** on
`PKG_CONFIG_PATH`, shadowing the system/Martchus libs — until distros ship a
new-enough libplacebo/ffmpeg (see the exit plan below).

This pairs with the **master-tracking** flow (mpv master + `patches-master/`);
the pinned `v0.41.0` tree does not have the feature (it will inherit it once mpv
0.42.0 is released and the stable track rebases onto it).

Refs come from `deps-fel/pins-fel.env` — now the **canonical upstream master**
branches (`videolan/libplacebo` and `git.ffmpeg.org/ffmpeg`).

```sh
# 1. build the dependency stack (libplacebo + ffmpeg + libdovi) into a prefix
PREFIX="$PWD/fel-prefix" scripts/build-fel-deps.sh        # native (Linux)
#    (cross/MinGW: PREFIX=/usr/x86_64-w64-mingw32 CROSS_FILE=cross.ini \
#                  scripts/build-fel-deps.sh --cross)

# 2. assemble the mpv tree (mpv master + orender patches; FEL is native)
scripts/apply-patches-master.sh                          # -> build/mpv-master-<sha>

# 3. build mpv linked against the prefix (prefix FIRST so it wins)
export PKG_CONFIG_PATH="$PWD/fel-prefix/lib/pkgconfig:$PKG_CONFIG_PATH"
export PATH="$PWD/fel-prefix/bin:$PATH"
cd build/mpv-master-<sha>
meson setup _b -Dorender=enabled && meson compile -C _b
```

Verify it is really active on a **DV P7 bi-layer** clip (`el_present_flag=1`):

```sh
mpv -v --vo=gpu-next sample.mkv
#   [mkv] Dolby Vision Profile 7 splitter: ... virtual EL stream 1 (dependent_track)
#   [vf]  [el_pair] ... dolbyvision/bt.2020/pq
#   header shows libplacebo API >= 370; NO 'dovi_split BSF not available' / 'Invalid NAL unit size'
```

For an A/B proof, disable FEL application with the upstream toggle
`--vf=format=enhancement-layer=no` and compare a `screenshot` against the default
(a real P7 clip differs by ~PSNR 20 dB / SSIM 0.7).

CI: prerelease workflow `.github/workflows/build-master-beta.yml` (Linux, macOS
arm64, Windows/MinGW; `workflow_dispatch` + weekly). It does **not** touch the
nightly/release builds.

**macOS (Apple Silicon):** `build-fel-deps.sh` auto-detects Darwin (skips
NVIDIA, uses `sysctl`/`DYLD_LIBRARY_PATH`). It needs the Homebrew Vulkan stack —
`brew install molten-vk vulkan-headers vulkan-loader shaderc glslang lcms2` — so
libplacebo's `-Dvulkan=enabled` resolves to Vulkan-on-Metal via MoltenVK. The
CI artifact bundles every dylib plus `libMoltenVK` and a MoltenVK ICD; at
runtime point the loader at it with
`VK_ICD_FILENAMES=<dir>/share/vulkan/icd.d/MoltenVK_icd.json`. This is
**experimental**: MoltenVK is not yet fully conformant, so FEL reconstruction on
Apple Silicon is unverified and may not render on every machine.

**Exit plan:** all three components are already merged upstream; the only
remaining gate is **releases + distro packaging**. Once a released libplacebo
(with the FEL API) and a released ffmpeg (with `dovi_split` + the DoVi stream
group) are packaged by distros, drop the from-source dep build entirely — delete
`deps-fel/`, `scripts/build-fel-deps.sh`, and the dep-building steps of
`build-master-beta.yml`, and link the system libs. FEL then comes for free from a
plain mpv master build. (mpv 0.42.0 additionally brings it to the stable track.)

## License

`mpv-omniphony` is a patch-set fork of
[mpv](https://github.com/mpv-player/mpv) (**GPL-2.0-or-later**, © the mpv
authors) that adds the `ad_orender` audio decoder. `ad_orender` loads
**`liborender`** from [Omniphony](https://github.com/mgth/Omniphony) at
runtime, which is **GPL-3.0-or-later**.

- Our first-party additions — `src/ad_orender.c`, the integration commits in
  `patches/` / `patches-master/`, and the build tooling — are
  **GPL-2.0-or-later**. The bundled Steinberg ASIO output driver (`ao_asio.c`,
  added by `patches/`) keeps its **LGPL-2.1-or-later** header.
- mpv's own license files (`Copyright`, `LICENSE.GPL`, `LICENSE.LGPL`) ship
  unchanged inside the built mpv tree.

**The binaries we distribute combine GPLv2-or-later mpv with GPLv3-or-later
liborender, so the combined work is licensed `GPL-3.0-or-later`** (the GPLv2+
parts under their "or later" option). Full text: [`COPYING`](COPYING).

**Corresponding source (GPLv3 §6):** each release ships from mpv `v0.41.0` (the
pinned tag) plus this repository's `patches/`, and `liborender` built from
Omniphony at the `OMNIPHONY_REF` printed in the release notes
(<https://github.com/mgth/Omniphony>).

**Bundled third-party libraries** (ffmpeg, libplacebo, LuaJIT, …, plus the
Windows/macOS runtime libraries) retain their own licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). The decoder **bridge** plugin
is not included and is licensed separately.
