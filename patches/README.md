# Patches

These `.patch` files are **generated** from the mpv fork's `orender` branch by
`scripts/regenerate-patches.sh` (`git format-patch v0.41.0..orender`). Do not
hand-edit them — edit the fork, then regenerate (and regenerate
`../patches-master/` from `orender-master` in the same change, so both tracks
carry the same integration). `src/ad_orender.c` is the readable copy of the
decoder source; keep it in sync with the fork.

Generated against mpv **v0.41.0**. What the series adds, by area:

- **Spatial decoder** — `audio/decode/ad_orender.{c,h}`, registered in
  `filters/f_decoder_wrapper.{c,h}`: decodes TrueHD/E-AC-3/AC-3/DTS through the
  Omniphony engine (VBAP object rendering), with live host/spatial mode
  switching driven by Studio over OSC.
- **Runtime engine loading** — `common/orender_dl.{c,h}` +
  `common/orender_abi.h` (vendored cbindgen header): liborender is dlopen'd at
  runtime with an ABI-major handshake, searching `--ad-orender-library` /
  `$ORENDER_LIBRARY` → the Studio-deployed per-user library → next to the mpv
  executable → the system loader. mpv builds with **no** liborender/pkg-config
  present, and an incompatible engine degrades to native decode instead of
  breaking the build or the player.
- **Spatial overlay** — `player/orender_overlay.c`: built-in client that pulls
  the engine's ASS overlay + BGRA heatmap (replaces the old Lua shim).
- **Audio outputs** — ASIO driver (`ao_asio`), WASAPI/waveext multichannel
  layout advertisement (5.1.4/7.1.4/9.1.6), and a timed mode for `ao_pcm`
  (`--ao-pcm-timed`, `--ao-pcm-buffer`, `--ao-pcm-latency`): the PCM/pipe
  writer plays at the nominal rate on mpv's clock, so a standalone orender
  reading the pipe can follow mpv's clock (the only input on Windows).
- **Build** — `orender` meson feature (source-only since the dlopen change:
  no build-time dependency).

CI validates the build with no engine installed plus a stub-library handshake
matrix (`.github/scripts/stub-liborender.sh`); full playback is the downstream
job of a real engine + decoder bridge.
