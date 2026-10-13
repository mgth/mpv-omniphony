# mpv-omniphony

mpv with a **spatial audio decoder** that renders objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. **This repository holds the build, the
packaging and the releases of the player only.**

[![Download Omniphony Studio](https://img.shields.io/badge/Download-Omniphony-2ea44f?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/latest)
[![Download mpv-omniphony](https://img.shields.io/badge/Download-mpv--omniphony-1f6feb?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/tag/mpv-v0.7.0)
[![Download mpv-omniphony FEL](https://img.shields.io/badge/Download-mpv--omniphony%20FEL-8957e5?style=for-the-badge&logo=github)](https://github.com/mgth/Omniphony/releases/tag/mpv-v0.7.0-fel-beta.1)

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

This repo holds **only** the build recipe, the packaging and the CI. The
mpv-side code (the `ad_orender` decoder and what wires it into mpv) lives in
one place, the fork [`mgth/mpv`](https://github.com/mgth/mpv): every build
here compiles a tag of that fork, named in [`mpv-fork.env`](mpv-fork.env). The
renderer itself (`liborender.so` + the decoder bridge) is built and packaged
from the `Omniphony` repo (`packaging/arch/`).

mpv loads liborender at **runtime** (dlopen + ABI version handshake) — building
mpv needs no engine at all, and an updated engine (e.g. deployed by Omniphony
Studio) is picked up without rebuilding mpv. The library search order and the
`--ad-orender-library` option are documented in the
[usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md).

> **Limit: 64 output channels.** Through mpv, a speaker layout can have at most
> 64 speakers (LFE and non-spatialized ones included). The engine has no such
> limit; mpv does: the rendered audio goes back through mpv's audio chain, whose
> channel maps hold 64 channels (`MP_NUM_CHANNELS`), and FFmpeg's resampler
> behind its conversions stops there too. With a wider layout `ad_orender` says
> so and the track plays through mpv's native decoder, without spatial
> rendering. This limit is accepted for this frontend: play a wider layout with
> the engine's standalone `orender` renderer, which writes to its own audio
> output. Details in the
> [usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md#limit-64-output-channels).

## Layout

```
mpv-fork.env            # the fork tags the builds compile (stable and master track)
scripts/mpv-source.sh        # fetch the pinned fork tag into build/ (both tracks)
scripts/export-patches.sh    # the fork's delta as patch series (ASIO, then orender)
scripts/check-abi-header.sh  # the fork's vendored engine header vs. Omniphony's
scripts/build-appimage.sh    # package a built mpv + liborender as a Linux AppImage
scripts/smoke-test-appimage.sh  # run that AppImage in a Fedora container (CI gate)
meson-options.txt       # canonical `orender` meson feature option
packaging/PKGBUILD          # Arch package of the stable track (provides/conflicts mpv)
packaging/PKGBUILD-fel      # Arch package of the master track with Dolby Vision P7 FEL (pinned fork tag + libplacebo)
packaging/PKGBUILD-master   # Arch -git package tracking mpv master HEAD
packaging/libmpv-README.md  # shipped inside the Windows libmpv SDK zip
.github/workflows/ci.yml             # stable build, loader tests, fork checks
.github/workflows/build-master.yml   # daily smoke test on mpv master HEAD
```

## Where the mpv code lives

In the fork, and nowhere else. This repository carries no copy of the decoder
and no committed patches.

| Track | Fork branch | Based on | Pinned in `mpv-fork.env` as |
|---|---|---|---|
| stable | `orender` | the upstream release `MPV_TAG` (`v0.41.0`) | `MPV_FORK_STABLE_TAG` + its commit |
| master | `orender-master` | the upstream master commit `MPV_MASTER_BASE` | `MPV_FORK_MASTER_TAG` + its commit |

- The decoder is
  [`audio/decode/ad_orender.c`](https://github.com/mgth/mpv/blob/orender/audio/decode/ad_orender.c)
  in the fork.
- The engine header mpv compiles against is the fork's
  `common/orender_abi.h`: a verbatim copy of Omniphony's
  `orender_ffi/include/orender.h` below a leading comment. CI diffs it against
  the header of the Omniphony release the builds pin (`OMNIPHONY_REF` in
  `release.yml`), on both tracks, and the release build diffs it against the
  engine it bundles: a copy that has drifted fails a build, not a playback.
- A fork tag is never moved, and the scripts refuse a tag that does not
  resolve to the commit recorded next to it.

### Patch series

For a distribution package or a review, `scripts/export-patches.sh stable`
(or `master`) writes the fork's delta as two series, to apply in this order on
the track's upstream base:

- `asio/`: the ASIO audio output (`ao_asio`), which is not part of the orender
  integration;
- `orender/`: the integration itself.

The fork's branches interleave the two. The script replays the ASIO commits
first and the others after, and fails unless that gives the tree of the pinned
tag, or when a commit touches both. CI runs it on every push, and each
release attaches the series as `…-patches.tar.gz`.

## Build (dev)

```sh
# 1. fetch the pinned fork tag into build/mpv-v0.41.0:
scripts/mpv-source.sh stable

# 2. build it (no liborender needed at build time — it is dlopen'd at runtime):
cd build/mpv-v0.41.0
meson setup _b -Dorender=enabled && meson compile -C _b
```

To build fork work that is not tagged yet, point the script at a checkout:

```sh
MPV_FORK_URL=/path/to/mpv-fork MPV_SOURCE_REF=orender scripts/mpv-source.sh stable
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

## Shipping a change of the fork

1. Merge it in the fork, on **both** branches: `orender` and
   `orender-master` carry the same commits on different bases. Keep ASIO
   changes in commits of their own.
2. Tag the two new heads. The first tags of a player version are
   `orender-v<version>` and `orender-master-v<version>`; later ones add `.1`,
   `.2`, …:

   ```sh
   git tag -a orender-v0.7.0.1 origin/orender -m "orender-v0.7.0.1"
   git tag -a orender-master-v0.7.0.1 origin/orender-master -m "orender-master-v0.7.0.1"
   git push origin orender-v0.7.0.1 orender-master-v0.7.0.1
   ```
3. Here, update the tags and their commits in `mpv-fork.env`, in a pull
   request. Its CI builds the stable tag, replays both patch series and checks
   the vendored engine header.

Do not rebase `orender` onto `master`: the stable track stays on the pinned
upstream release. Only `orender-master`, below, follows upstream `master`.

## Tracking mpv master

A second build path targets **upstream mpv master HEAD**: the fork's master
tag is merged into whatever mpv master is that day. Useful for catching
breakage early and for power users who want the freshest mpv with the orender
decoder. The stable flow above is the default — the master flow may break on
any upstream merge.

```sh
scripts/mpv-source.sh master            # -> build/mpv-master-<upstream sha>
cd build/mpv-master-<upstream sha>
meson setup _b -Dorender=enabled && meson compile -C _b

scripts/mpv-source.sh master --pinned   # the fork tag as it is, reproducible
```

When the daily CI (`build-master.yml`) goes red, an upstream merge collided
with the fork's commits. Rebase `orender-master`, then ship it as above with
the new base:

```sh
cd /path/to/mpv-fork
git checkout orender-master
git fetch upstream
git rebase upstream/master                      # resolve conflicts
git merge-base orender-master upstream/master   # the new MPV_MASTER_BASE
```

Packaging: `packaging/PKGBUILD-master` builds an `mpv-omniphony-git` package
that clones mpv master at install time and merges the fork's master tag into
it. It conflicts with both stock `mpv` and the stable `mpv-omniphony` —
install one.

## Dolby Vision FEL (experimental)

Optional support for **Dolby Vision Profile 7 FEL** (Full Enhancement Layer). As
of 2026-07-01 this is a **native, upstream mpv feature** (no fork, no vendored
patch): mpv [PR #17932](https://github.com/mpv-player/mpv/pull/17932) is **merged
into mpv master** (v0.42.0), and the two deps it needs are in their own upstream
masters. We still build those two deps from source only because no released
distro/package ships the FEL API yet:

| Component | Role | Source |
|---|---|---|
| mpv master | demux P7, split BL/EL, pair, hand EL to libplacebo | native (mpv PR #17932, merged); the fork's master tag adds orender only |
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

This pairs with the **master-tracking** flow (mpv master + the fork's master tag);
the pinned `v0.41.0` tree does not have the feature (it will inherit it once mpv
0.42.0 is released and the stable track rebases onto it).

Refs come from `deps-fel/pins-fel.env` — now the **canonical upstream master**
branches (`videolan/libplacebo` and `git.ffmpeg.org/ffmpeg`).

```sh
# 1. build the dependency stack (libplacebo + ffmpeg + libdovi) into a prefix
PREFIX="$PWD/fel-prefix" scripts/build-fel-deps.sh        # native (Linux)
#    (cross/MinGW: PREFIX=/usr/x86_64-w64-mingw32 CROSS_FILE=cross.ini \
#                  scripts/build-fel-deps.sh --cross)

# 2. assemble the mpv tree (mpv master + the fork's master tag; FEL is native)
scripts/mpv-source.sh master                             # -> build/mpv-master-<sha>

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

`mpv-omniphony` is built from a fork of
[mpv](https://github.com/mpv-player/mpv) (**GPL-2.0-or-later**, © the mpv
authors) that adds the `ad_orender` audio decoder. `ad_orender` loads
**`liborender`** from [Omniphony](https://github.com/mgth/Omniphony) at
runtime, which is **GPL-3.0-or-later**.

- Our first-party additions — `ad_orender.c` and the other integration commits
  of the fork, and the build tooling here — are **GPL-2.0-or-later**. The
  bundled Steinberg ASIO output driver (`ao_asio.c`, the fork's ASIO series)
  keeps its **LGPL-2.1-or-later** header.
- mpv's own license files (`Copyright`, `LICENSE.GPL`, `LICENSE.LGPL`) ship
  unchanged inside the built mpv tree.

**The binaries we distribute combine GPLv2-or-later mpv with GPLv3-or-later
liborender, so the combined work is licensed `GPL-3.0-or-later`** (the GPLv2+
parts under their "or later" option). Full text: [`COPYING`](COPYING).

**Corresponding source (GPLv3 §6):** each release is built from the fork tag
named in its notes (<https://github.com/mgth/mpv>), which is mpv `v0.41.0`
plus the patch series attached to the release, and from `liborender` built
from Omniphony at the `OMNIPHONY_REF` printed in the same notes
(<https://github.com/mgth/Omniphony>).

**Bundled third-party libraries** (ffmpeg, libplacebo, LuaJIT, …, plus the
Windows/macOS runtime libraries) retain their own licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). The decoder **bridge** plugin
is not included and is licensed separately.
