# libmpv-omniphony (Windows x86_64)

`libmpv` built from [mpv-omniphony](https://github.com/mgth/mpv-omniphony) —
mpv plus the `ad_orender` spatial audio decoder. Same build as the
`mpv-omniphony-…-windows-x86_64.zip` player bundle, exposed as a library for
embedders.

## Contents

```
libmpv-2.dll        the library (client API, same ABI as upstream libmpv)
libmpv.dll.a        import library for MinGW / clang toolchains
mpv.def             export list, to build an import library for MSVC
include/mpv/*.h     client.h, render.h, render_gl.h, stream_cb.h
include/orender.h   engine ABI header (only needed to load liborender yourself)
orender.dll         the spatial rendering engine, loaded at runtime
*.dll               MinGW runtime + ffmpeg/libplacebo/libass/… dependencies
```

Keep every DLL next to your executable (or on `PATH`); they are the exact set
`libmpv-2.dll` was built against.

## Linking

**MSVC** — generate the import library from `mpv.def`, then link `mpv.lib`:

```
lib /def:mpv.def /name:libmpv-2.dll /out:mpv.lib /MACHINE:X64
```

**MinGW / clang** — link `libmpv.dll.a` directly (`-lmpv` with this directory
on the library path).

## Spatial audio from an embedder

Spatial decoding is on by default for the codecs `ad_orender` claims. The
engine is loaded at runtime and searched in this order:

1. the `ad-orender-library` option (`mpv_set_option_string`)
2. the `ORENDER_LIBRARY` environment variable
3. the engine deployed by Omniphony Studio (per-user data dir)
4. **next to the host executable**
5. the system library path

Step 4 resolves against *your* `.exe`, not against `libmpv-2.dll`: if you keep
the DLLs in a subdirectory, point mpv at the engine explicitly rather than
relying on it. An engine whose ABI does not match is rejected with a log line
and mpv falls back to its native decoders.

The decoder **bridge** (Dolby/DTS front-ends) is not bundled — licensing
constraints mean you fetch it yourself from
[harletty-bridge](https://github.com/harletty/harletty-bridge/releases) and set
the `ad-orender-bridge-path` option.

## License — GPL-3.0-or-later

This is a **GPL** libmpv, not the LGPL build published upstream: mpv is
compiled with `-Dgpl=true` and combined with `liborender`
(GPL-3.0-or-later), so the combined work — and any application you link it
into — is **GPL-3.0-or-later**. If you need LGPL terms, use an upstream libmpv
build; it has no spatial decoder.

Corresponding source: mpv at the tag recorded in the release notes plus this
repo's `patches/`, and `liborender` from
[Omniphony](https://github.com/mgth/Omniphony). Bundled third-party libraries:
see `THIRD-PARTY-NOTICES.md` in the mpv-omniphony repository.
