/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright (C) 2025-2026 Mathieu GRENET <mathieu@mgth.fr> */

/*
 * ad_orender.c — mpv audio decoder that renders spatial audio through liborender.
 *
 * Companion to ad_lavc/ad_spdif: when the user opts in with `--ad=orender` on a
 * supported stream, decode + VBAP-render the spatial objects to N-channel float
 * PCM via liborender (orender_*), instead of letting FFmpeg downmix.
 *
 * Unlike the earlier design, ad_orender does NOT hand the track back to the
 * decoder wrapper in host mode. It stays selected for the whole track and owns
 * the orender engine the whole time, so the engine's OSC listener — and thus the
 * Studio connection — stays alive and keeps receiving the live
 * `channel_render_mode` switch. Each packet is routed on that live mode:
 *
 *   - spatial : decode + VBAP-render through the engine (objects, or the virtual
 *               bed for plain channel content);
 *   - host    : delegate to a native child decoder (ad_lavc → PCM, or ad_spdif →
 *               bitstream passthrough; chosen by --ad-orender-host-decoder) and
 *               forward its frames untouched.
 *
 * Toggling "Spatialize 2D sources" in Studio flips the engine's mode over OSC,
 * so the switch is applied live, in both directions, with no mpv restart and no
 * polling — the engine never leaves, never yields the OSC port to the standby
 * renderer. The bridge and speaker layout come from the shared omniphony config
 * YAML (render.bridge_path), resolved by liborender when the config path is NULL.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "mpv_talloc.h"
#include "audio/aframe.h"
#include "audio/chmap.h"
#include "audio/format.h"
#include "common/codecs.h"
#include "common/common.h"
#include "common/msg.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "filters/f_decoder_wrapper.h"
#include "filters/filter_internal.h"
#include "options/m_config.h"

#include <orender.h>

/* --ad-orender-* options. All paths/hosts default to empty → passed to
 * liborender as NULL, which then resolves the shared omniphony config
 * (~/.config/omniphony/config.yaml, the same one the CLI + studio use) for the
 * bridge path, speaker layout, and OSC settings. These options only override
 * the config on a per-mpv-invocation basis. */
#define OPT_BASE_STRUCT struct ad_orender_params
struct ad_orender_params {
    char *config_path;          // override render config YAML (else shared default)
    char *bridge_path;          // override render.bridge_path
    bool osc;                   // force OSC on (else follows config render.osc)
    int osc_port;               // outgoing/monitoring port (0 = config/default)
    int osc_rx_port;            // incoming control port  (0 = config/default 9000)
    char *osc_bind;             // listener bind address (else config/default)
    char *osc_monitor_target;   // monitoring host (else config/default)
    int channel_mode_idx;       // initial render override: 0=auto 1=host 2=spatial
    int host_decoder_idx;       // host-mode native decoder: 0=lavc 1=spdif
};

const struct m_sub_options ad_orender_conf = {
    .opts = (const m_option_t[]) {
        {"config", OPT_STRING(config_path), .flags = M_OPT_FILE},
        {"bridge-path", OPT_STRING(bridge_path), .flags = M_OPT_FILE},
        {"osc", OPT_BOOL(osc)},
        {"osc-port", OPT_INT(osc_port), M_RANGE(0, 65535)},
        {"osc-rx-port", OPT_INT(osc_rx_port), M_RANGE(0, 65535)},
        {"osc-bind", OPT_STRING(osc_bind)},
        {"osc-monitor-target", OPT_STRING(osc_monitor_target)},
        /* Initial render mode for channel-based (non-object) content. "auto" =
         * follow the shared config's render.channel_render_mode. "host" decodes
         * natively (see host-decoder); "spatial" renders through orender's
         * virtual bed. "direct"/"virtual" are legacy aliases of "spatial". The
         * live mode is then driven by Studio over OSC. */
        {"channel-mode", OPT_CHOICE(channel_mode_idx,
            {"auto", 0}, {"host", 1}, {"spatial", 2}, {"direct", 2}, {"virtual", 2})},
        /* Which native decoder to use in host mode: "lavc" decodes to PCM (mpv's
         * audio chain applies — the default), "spdif" passes the compressed
         * bitstream through to an AV receiver. */
        {"host-decoder", OPT_CHOICE(host_decoder_idx, {"lavc", 0}, {"spdif", 1})},
        {0}
    },
    .size = sizeof(struct ad_orender_params),
    .defaults = &(const struct ad_orender_params){
        .osc = false,
        .osc_port = 0,
        .osc_rx_port = 0,
    },
};

/* An empty option string means "unset" → pass NULL to the FFI. */
static const char *nz(const char *s) { return (s && s[0]) ? s : NULL; }

enum { HOST_DEC_LAVC = 0, HOST_DEC_SPDIF = 1 };
enum { PATH_NONE = -1, PATH_HOST = 0, PATH_SPATIAL = 1 };

/* liborender channel labels — mirror bridge_api::RChannelLabel. cbindgen runs
 * with parse_deps=false, so orender.h does not emit this enum; keep in sync. */
enum {
    OR_L = 0, OR_R = 1, OR_C = 2, OR_LFE = 3, OR_LS = 4, OR_RS = 5,
    OR_TFL = 6, OR_TFR = 7, OR_TSL = 8, OR_TSR = 9, OR_TBL = 10, OR_TBR = 11,
    OR_LSC = 12, OR_RSC = 13, OR_LB = 14, OR_RB = 15, OR_CB = 16, OR_TC = 17,
    OR_LSD = 18, OR_RSD = 19, OR_LW = 20, OR_RW = 21, OR_TFC = 22, OR_LFE2 = 23,
    OR_UNKNOWN = 255,
};

struct priv {
    struct mp_log *log;
    struct mp_codec_params *codec;
    OrenderRenderer *renderer;
    int sample_rate;
    int channels;
    struct mp_chmap chmap;
    bool checked_spatial;       // built the output chmap for the spatial path
    int last_mapping;           // last orender_channel_mapping() the chmap was built for (live switch)
    bool force_host;            // engine unusable (no layout / create failed): always native
    int host_decoder_idx;       // HOST_DEC_LAVC (PCM) or HOST_DEC_SPDIF (passthrough)
    struct mp_decoder *native;  // lazily-created native child decoder for host mode
    int active_path;            // PATH_* of the last packet, for clean transitions
    /* Track-info codec profile (shift+I) for the spatial path. Two concerns:
     *
     *  - Lifetime: the core thread reads codec_profile from the track list
     *    (player/misc.c) and the codec-profile property, and p->codec (the
     *    demuxer-owned sh_stream codec params) outlives this decoder filter. So
     *    the storage must NOT live in our priv, which is freed when the track's
     *    decoder is torn down on a switch — a pointer into it would dangle into
     *    freed talloc that the next decode reuses as float PCM scratch (garbage
     *    in shift+I, and a c0000005 in ucrtbase's %s walk when the reused bytes
     *    carry no NUL before a page edge). profile_buf is therefore a talloc
     *    child of p->codec (allocated lazily in refresh_codec_profile), giving
     *    the published pointer demuxer lifetime: it can never dangle, even if a
     *    reader races the decoder teardown. mpv's own decoders rely on the same
     *    contract — they point codec_profile at static libavcodec literals
     *    (av_common.c) that outlive every decoder.
     *  - Concurrency: double-buffered so the reader never sees a half-written
     *    string — we fill the inactive slot, then atomically publish its pointer.
     *
     * Rebuilt only when the composed value changes (its inputs are stable per
     * presentation segment), so the hot path does no work. The cache (last_*)
     * starts at impossible sentinels so the first frame always publishes; it is
     * reset on a host->spatial switch because host-mode's child ad_lavc
     * overwrites codec_profile with its own string. */
    const char *orender_desc;   // official-cased codec name (codec_desc literal)
    char (*profile_buf)[128];   // [2][128] double-buffer; talloc child of p->codec
    int profile_slot;
    int last_objs;
    int last_dnorm;
    unsigned last_bed_sig;      // fingerprint of the bed labels (change detection)
    struct mp_decoder public;
};

/* Map a liborender label to an mpv speaker id. The 7.1.4 default maps exactly.
 * mpv's chmap has no top-side L/R, so those degrade to NA (Phase 5: custom
 * order). */
static int label_to_mp_speaker(uint8_t lbl)
{
    switch (lbl) {
    case OR_L:    return MP_SPEAKER_ID_FL;
    case OR_R:    return MP_SPEAKER_ID_FR;
    case OR_C:    return MP_SPEAKER_ID_FC;
    case OR_LFE:  return MP_SPEAKER_ID_LFE;
    case OR_LS:   return MP_SPEAKER_ID_SL;
    case OR_RS:   return MP_SPEAKER_ID_SR;
    case OR_LB:   return MP_SPEAKER_ID_BL;
    case OR_RB:   return MP_SPEAKER_ID_BR;
    case OR_CB:   return MP_SPEAKER_ID_BC;
    case OR_LSC:  return MP_SPEAKER_ID_FLC;
    case OR_RSC:  return MP_SPEAKER_ID_FRC;
    case OR_LW:   return MP_SPEAKER_ID_WL;
    case OR_RW:   return MP_SPEAKER_ID_WR;
    case OR_LFE2: return MP_SPEAKER_ID_LFE2;
    case OR_TFL:  return MP_SPEAKER_ID_TFL;
    case OR_TFR:  return MP_SPEAKER_ID_TFR;
    case OR_TFC:  return MP_SPEAKER_ID_TFC;
    case OR_TBL:  return MP_SPEAKER_ID_TBL;
    case OR_TBR:  return MP_SPEAKER_ID_TBR;
    case OR_TC:   return MP_SPEAKER_ID_TC;
    default:      return MP_SPEAKER_ID_NA;  /* incl. TSL/TSR/LSD/RSD */
    }
}

/* Short display name for a liborender channel label, for the bed composition in
 * the track-info profile (e.g. "LFE+11 objects"). */
static const char *label_to_short_name(uint8_t lbl)
{
    switch (lbl) {
    case OR_L:    return "L";
    case OR_R:    return "R";
    case OR_C:    return "C";
    case OR_LFE:  return "LFE";
    case OR_LS:   return "Ls";
    case OR_RS:   return "Rs";
    case OR_TFL:  return "Tfl";
    case OR_TFR:  return "Tfr";
    case OR_TSL:  return "Tsl";
    case OR_TSR:  return "Tsr";
    case OR_TBL:  return "Tbl";
    case OR_TBR:  return "Tbr";
    case OR_LSC:  return "Lsc";
    case OR_RSC:  return "Rsc";
    case OR_LB:   return "Lb";
    case OR_RB:   return "Rb";
    case OR_CB:   return "Cb";
    case OR_TC:   return "Tc";
    case OR_LSD:  return "Lsd";
    case OR_RSD:  return "Rsd";
    case OR_LW:   return "Lw";
    case OR_RW:   return "Rw";
    case OR_TFC:  return "Tfc";
    case OR_LFE2: return "LFE2";
    default:      return "?";
    }
}

/* Human profile string for a codec, with/without object (Atmos/DTS:X) content —
 * mirrors what ffmpeg reports on the native path so shift+I reads the same.
 * `has_objects` reflects the actually-decoded object presence (object_count > 0),
 * not the bridge's pre-decode "may be spatial" flag — a plain multichannel
 * TrueHD/E-AC3 stream carries no objects and must not be labelled Atmos. */
static const char *profile_base(const char *codec, bool has_objects)
{
    if (strcmp(codec, "truehd") == 0)
        return has_objects ? "Dolby TrueHD + Dolby Atmos" : "Dolby TrueHD";
    if (strcmp(codec, "eac3") == 0)
        return has_objects ? "Dolby Digital Plus + Dolby Atmos" : "Dolby Digital Plus";
    if (strcmp(codec, "ac3") == 0)
        return "Dolby Digital";
    if (strcmp(codec, "dts") == 0)
        return has_objects ? "DTS:X" : "DTS";
    return codec;
}

/* Recompose codec_profile from the engine's live presentation info (Atmos flag,
 * bed composition, object count, DialNorm) and publish it for the track-info
 * display. Cheap and idempotent: returns immediately unless the value changed. */
static void refresh_codec_profile(struct priv *p)
{
    if (!p->renderer)
        return;

    int objs    = orender_object_count(p->renderer);  // >=0 / -1
    int dnorm   = orender_dialnorm_db(p->renderer);   // <=0 / INT32_MIN (unknown)

    uint8_t bed[MP_NUM_CHANNELS];
    uint32_t bedn = orender_bed_layout(p->renderer, bed, MP_NUM_CHANNELS);
    /* FNV-1a fingerprint of the bed labels, so a bed change (same object count)
     * still triggers a rebuild. */
    unsigned bed_sig = 2166136261u;
    for (uint32_t i = 0; i < bedn; i++)
        bed_sig = (bed_sig ^ bed[i]) * 16777619u;

    if (objs == p->last_objs && dnorm == p->last_dnorm &&
        bed_sig == p->last_bed_sig)
        return;

    /* Anchor the double-buffer to p->codec (demuxer lifetime), not our priv: the
     * core thread reads codec_profile long after a track switch has freed this
     * decoder (see the profile_buf note in struct priv). Allocated once, lazily,
     * on the first publish. talloc_zero_size aborts on OOM, so it is never NULL. */
    if (!p->profile_buf)
        p->profile_buf = talloc_zero_size(p->codec, 2 * sizeof(*p->profile_buf));

    int slot = p->profile_slot ^ 1;
    char *buf = p->profile_buf[slot];
    size_t cap = sizeof(p->profile_buf[slot]);

    int n = snprintf(buf, cap, "%s", profile_base(p->codec->codec, objs > 0));
    /* "· <bed labels>+<N> objects", e.g. "· LFE+11 objects" (no bed → "· N
     * objects"). Only when there are objects (plain multichannel reports 0). */
    if (objs > 0 && n > 0 && (size_t)n < cap) {
        n += snprintf(buf + n, cap - n, " · ");
        for (uint32_t i = 0; i < bedn && n > 0 && (size_t)n < cap; i++)
            n += snprintf(buf + n, cap - n, "%s%s",
                          i ? " " : "", label_to_short_name(bed[i]));
        if (n > 0 && (size_t)n < cap)
            n += snprintf(buf + n, cap - n, "%s%d objects", bedn ? "+" : "", objs);
    }
    if (dnorm != INT32_MIN && n > 0 && (size_t)n < cap)
        snprintf(buf + n, cap - n, " · DialNorm %d dB", dnorm);

    p->codec->codec_profile = buf;   // atomic publish of the new slot
    p->profile_slot = slot;
    p->last_objs = objs;
    p->last_dnorm = dnorm;
    p->last_bed_sig = bed_sig;
}

/* Build p->chmap from the renderer's output layout. Returns false if any
 * speaker had no mpv mapping (caller still proceeds; positions are NA). */
static bool build_chmap(struct priv *p)
{
    uint8_t labels[MP_NUM_CHANNELS];
    uint32_t n = orender_channel_layout(p->renderer, labels, MP_NUM_CHANNELS);
    if (n == 0 || n > MP_NUM_CHANNELS) {
        p->chmap = (struct mp_chmap){0};
        return false;
    }
    /* By-index mapping (the renderer default): a positionless chmap so mpv and
     * the AO pass channels straight through by index — output port N carries
     * layout speaker N, matching a custom rig wired in layout order. Only
     * by-name (1) builds a positional map so a position-aware sink routes by
     * speaker; <0 (error) also falls back to positionless. */
    if (orender_channel_mapping(p->renderer) != 1) {
        mp_chmap_set_unknown(&p->chmap, n);
        return true;
    }
    p->chmap = (struct mp_chmap){0};
    p->chmap.num = n;
    bool ok = true;
    for (uint32_t i = 0; i < n; i++) {
        int sp = label_to_mp_speaker(labels[i]);
        if (sp == MP_SPEAKER_ID_NA)
            ok = false;
        p->chmap.speaker[i] = sp;
    }
    return ok;
}

/* Try each entry in `sel` with `fns->create`, stopping at the first success. */
static bool try_create_child(struct mp_filter *da, struct priv *p,
                             const struct mp_decoder_fns *fns,
                             struct mp_decoder_list *sel)
{
    for (int i = 0; i < sel->num_entries; i++) {
        p->native = fns->create(da, p->codec, sel->entries[i].decoder);
        if (p->native) {
            MP_VERBOSE(da, "host-mode native decoder: %s\n", sel->entries[i].decoder);
            return true;
        }
    }
    return false;
}

/* Lazily create the native child decoder for host mode, picking the right driver
 * + decoder for the codec via mpv's normal selection (so e.g. dts → "dca"). With
 * host-decoder=spdif, request bitstream passthrough for this codec; if that is
 * not available, fall back to lavc rather than leaving the track undecodable. */
static bool ensure_native_child(struct mp_filter *da, struct priv *p)
{
    if (p->native)
        return true;

    if (p->host_decoder_idx == HOST_DEC_SPDIF) {
        /* select_spdif_codec only enables passthrough for codecs listed in its
         * `pref`; pass this codec so the explicit choice takes effect. */
        struct mp_decoder_list *sel = select_spdif_codec(p->codec->codec, p->codec->codec);
        bool ok = try_create_child(da, p, &ad_spdif, sel);
        talloc_free(sel);
        if (!ok)
            MP_WARN(da, "spdif passthrough unavailable for %s; using lavc\n",
                    p->codec->codec);
    }

    if (!p->native) {
        struct mp_decoder_list *all = talloc_zero(NULL, struct mp_decoder_list);
        ad_lavc.add_decoders(all);
        struct mp_decoder_list *sel = mp_select_decoders(p->log, all, p->codec->codec, NULL);
        talloc_free(all);
        try_create_child(da, p, &ad_lavc, sel);
        talloc_free(sel);
    }

    if (!p->native) {
        MP_ERR(da, "could not create a host-mode native decoder for %s\n",
               p->codec->codec);
        return false;
    }
    return true;
}

/* Host mode: pump the native child — forward packets in, decoded frames out. */
static void process_host(struct mp_filter *da, struct priv *p)
{
    if (!ensure_native_child(da, p)) {
        mp_filter_internal_mark_failed(da);
        return;
    }

    struct mp_pin *child_in = p->native->f->pins[0];
    struct mp_pin *child_out = p->native->f->pins[1];

    // Drain decoded frames to our output (and forward EOF transparently).
    if (mp_pin_can_transfer_data(da->ppins[1], child_out)) {
        struct mp_frame frame = mp_pin_out_read(child_out);
        mp_pin_in_write(da->ppins[1], frame);
    }
    // Feed input packets to the child.
    if (mp_pin_can_transfer_data(child_in, da->ppins[0])) {
        struct mp_frame frame = mp_pin_out_read(da->ppins[0]);
        mp_pin_in_write(child_in, frame);
    }
}

/* Spatial mode: decode + VBAP-render through the engine. */
static void process_spatial(struct mp_filter *da, struct priv *p)
{
    if (!mp_pin_can_transfer_data(da->ppins[1], da->ppins[0]))
        return;

    struct mp_frame inframe = mp_pin_out_read(da->ppins[0]);
    if (inframe.type == MP_FRAME_EOF) {
        mp_pin_in_write(da->ppins[1], inframe);
        return;
    } else if (inframe.type != MP_FRAME_PACKET) {
        if (inframe.type) {
            MP_ERR(da, "unknown frame type\n");
            mp_filter_internal_mark_failed(da);
        }
        return;
    }

    struct demux_packet *mpkt = inframe.data;
    struct mp_aframe *out = NULL;
    bool failed = false;
    double pts = mpkt->pts;   /* demuxer timestamp; drives A/V sync (see below) */

    /* The output channel count can change mid-stream (Studio toggling the
     * binaural ⇄ speaker output mode), so refresh it every packet and size
     * the scratch buffer for the current mode. */
    uint32_t cur_ch = orender_channel_count(p->renderer);
    if (cur_ch > 0 && cur_ch <= MP_NUM_CHANNELS && (int)cur_ch != p->channels)
        p->channels = (int)cur_ch;
    int ch = p->channels > 0 ? p->channels : 1;
    size_t capacity = (size_t)4096 * (size_t)ch;
    float *samples = talloc_array(NULL, float, capacity);

    size_t n_frames = 0;
    uint32_t n_ch = 0;
    int64_t out_pts_us = 0;
    int64_t pts_us = mpkt->pts == MP_NOPTS_VALUE ? 0 : (int64_t)(mpkt->pts * 1e6);

    int ret = orender_process(p->renderer, mpkt->buffer, mpkt->len, pts_us,
                              samples, capacity,
                              &n_frames, &n_ch, &out_pts_us);
    if (ret < 0) {
        MP_ERR(da, "orender_process error %d\n", ret);
        failed = true;
        goto done;
    }
    if (ret > 0) {
        MP_WARN(da, "orender output buffer too small; dropping packet\n");
        goto done;
    }

    if (n_frames == 0)
        goto done;   /* packet consumed; no output yet (need more data) */

    /* Resolve the output chmap on the first *decoded* frame. Deferred until
     * n_frames > 0: the layout is only meaningful once the bridge has decoded a
     * frame (AC-3/DTS need several packets to acquire sync). */
    if (!p->checked_spatial) {
        p->checked_spatial = true;
        p->last_mapping = orender_channel_mapping(p->renderer);
        if (!build_chmap(p)) {
            if (p->chmap.num == 0) {
                /* The renderer reported no output channels (e.g. the speaker
                 * layout could not be resolved). Spatial rendering is impossible,
                 * so route to the native host decoder for the rest of the track
                 * rather than dropping every frame (which would freeze audio). */
                MP_WARN(da, "renderer reported no output layout; decoding "
                            "natively instead (check the speaker layout in your "
                            "omniphony config)\n");
                p->force_host = true;
                goto done;
            }
            MP_WARN(da, "output layout has speakers with no mpv mapping\n");
        }
    }

    /* Live output-mode switches change the channel count mid-stream: rebuild
     * the chmap so the frame below is allocated for what we actually copy —
     * mpv's filter chain renegotiates downstream formats per frame. Without
     * this, switching binaural → speakers made the memcpy below write
     * n_frames × 12 floats into a 2-channel plane (heap corruption, SIGSEGV).
     */
    if (n_ch > 0 && n_ch != (uint32_t)p->chmap.num) {
        MP_VERBOSE(da, "renderer output changed to %u channels; renegotiating chmap\n",
                   n_ch);
        if (!build_chmap(p))
            MP_WARN(da, "output layout has speakers with no mpv mapping\n");
        if (n_ch != (uint32_t)p->chmap.num) {
            /* Safety net: still inconsistent → drop this frame instead of
             * overflowing the plane. */
            MP_ERR(da, "channel count %u does not match output layout (%d); "
                       "dropping frame\n", n_ch, p->chmap.num);
            goto done;
        }
    }

    /* Live by-index/by-name switch: same channel count, but the chmap flips
     * between positionless (by_index) and positional (by_name). The count check
     * above misses it, so poll the mapping and rebuild on change — the new chmap
     * set on the frame below makes mpv's filter chain reconfigure the output. */
    {
        int cur_mapping = orender_channel_mapping(p->renderer);
        if (cur_mapping != p->last_mapping) {
            MP_VERBOSE(da, "output channel mapping changed (%d -> %d); rebuilding chmap\n",
                       p->last_mapping, cur_mapping);
            build_chmap(p);
            p->last_mapping = cur_mapping;
        }
    }

    /* Now that a real frame has decoded, the engine knows the presentation's
     * Atmos flag, object count and DialNorm — surface them as the track's codec
     * profile so shift+I matches the native path (and adds objects + DialNorm). */
    refresh_codec_profile(p);

    out = mp_aframe_create();
    mp_aframe_set_format(out, AF_FORMAT_FLOAT);   /* interleaved float32 */
    mp_aframe_set_rate(out, p->sample_rate);
    mp_aframe_set_chmap(out, &p->chmap);
    /* Timestamp from the demuxer packet PTS (like ad_spdif), NOT the engine's
     * internal sample clock (out_pts_us): that clock resets to 0 on seek
     * (orender_reset), which puts the audio in the past so mpv drops every
     * frame after a seek — video keeps playing but audio goes silent while the
     * renderer is still producing samples. The packet PTS tracks seeks. */
    mp_aframe_set_pts(out, pts);

    /* format + rate + chmap must be set before allocating the data buffer. */
    if (!mp_aframe_alloc_data(out, n_frames)) {
        MP_ERR(da, "failed to allocate output frame (%zu frames, %u ch)\n",
               n_frames, n_ch);
        TA_FREEP(&out);
        failed = true;
        goto done;
    }

    uint8_t **data = mp_aframe_get_data_rw(out);
    if (!data || !data[0]) {
        MP_ERR(da, "no writable output plane\n");
        TA_FREEP(&out);
        failed = true;
        goto done;
    }
    size_t copy_elems = (size_t)n_frames * (size_t)n_ch;
    if (n_ch > 0 && copy_elems / (size_t)n_ch != (size_t)n_frames) {
        MP_ERR(da, "output frame size overflow (%zu frames, %u ch)\n", n_frames, n_ch);
        TA_FREEP(&out);
        failed = true;
        goto done;
    }
    memcpy(data[0], samples, copy_elems * sizeof(float));

done:
    talloc_free(samples);
    talloc_free(mpkt);
    if (out) {
        mp_pin_in_write(da->ppins[1], MAKE_FRAME(MP_FRAME_AUDIO, out));
    } else if (failed) {
        mp_filter_internal_mark_failed(da);
    } else {
        // No output frame this pass: re-run so the graph stays active. The bridge
        // needs several packets to acquire sync for some codecs (AC-3/DTS) before
        // the first decoded frame, so early packets legitimately yield zero
        // frames; re-running requests the next packet. Without this mpv never
        // gets a first frame, the audio output is never created, and playback
        // freezes on the first video frame with no sound. (Also covers the
        // re-sync after a host→spatial switch, where the bridge was just reset.)
        mp_filter_internal_mark_progress(da);
    }
}

static void ad_orender_process(struct mp_filter *da)
{
    struct priv *p = da->priv;

    /* Route on the engine's live channel_render_mode (0 host, 1 spatial), which
     * Studio flips over OSC. Reading it per packet is a cheap in-memory call, not
     * a poll. `force_host` (engine unusable) pins host. */
    int mode = p->renderer ? orender_channel_mode(p->renderer) : 0;
    bool host = p->force_host || mode != 1;
    int path = host ? PATH_HOST : PATH_SPATIAL;

    /* On a mode flip, flush stale state on the side we switch *to* so it starts
     * clean: the engine's bridge re-acquires sync (it wasn't fed during host),
     * and the native child drops any partial state from a previous host stint. */
    if (path != p->active_path) {
        if (path == PATH_SPATIAL) {
            if (p->renderer)
                orender_reset(p->renderer);
            p->checked_spatial = false;
            orender_overlay_set_rendering(1);  // show the spatial overlay again
            /* A host stint's child ad_lavc overwrote codec_desc/codec_profile
             * with its own strings; restore our desc and force the next frame to
             * republish our profile (reset the cache to impossible sentinels). */
            p->codec->codec_desc = p->orender_desc;
            p->last_objs = -1;
            p->last_dnorm = 1;
        } else {
            if (p->native && p->native->f)
                mp_filter_reset(p->native->f);
            /* Hide the whole spatial overlay (wireframe cube included) while we
             * decode natively — nothing is being spatialized — and drop the stale
             * scene so it does not linger. The user's overlay on/off preference is
             * preserved; spatial mode repopulates it. */
            orender_overlay_set_rendering(0);
            orender_overlay_clear();
        }
        p->active_path = path;
    }

    if (host)
        process_host(da, p);
    else
        process_spatial(da, p);
}

static void ad_orender_reset(struct mp_filter *da)
{
    struct priv *p = da->priv;
    if (p->renderer)
        orender_reset(p->renderer);
    if (p->native && p->native->f)
        mp_filter_reset(p->native->f);
    p->checked_spatial = false;
    p->active_path = PATH_NONE;
}

static void ad_orender_destroy(struct mp_filter *da)
{
    struct priv *p = da->priv;
    /* The native child is a talloc child of `da` and is freed with it; the
     * engine is an FFI handle we must release explicitly. The codec profile
     * buffer is a talloc child of p->codec (not of `da`), so it correctly
     * outlives this filter — see the profile_buf note in struct priv. */
    if (p->renderer) {
        orender_destroy(p->renderer);
        p->renderer = NULL;
    }
}

static const struct mp_filter_info ad_orender_filter = {
    .name = "ad_orender",
    .priv_size = sizeof(struct priv),
    .process = ad_orender_process,
    .reset = ad_orender_reset,
    .destroy = ad_orender_destroy,
};

static struct mp_decoder *create(struct mp_filter *parent,
                                 struct mp_codec_params *codec,
                                 const char *decoder)
{
    if (!codec->codec ||
        (strcmp(codec->codec, "truehd") != 0 && strcmp(codec->codec, "eac3") != 0 &&
         strcmp(codec->codec, "ac3") != 0 && strcmp(codec->codec, "dts") != 0))
        return NULL;

    struct mp_filter *da = mp_filter_create(parent, &ad_orender_filter);
    if (!da)
        return NULL;

    mp_filter_add_pin(da, MP_PIN_IN, "in");
    mp_filter_add_pin(da, MP_PIN_OUT, "out");

    da->log = mp_log_new(da, parent->log, NULL);

    struct priv *p = da->priv;
    p->log = da->log;
    p->codec = codec;
    p->sample_rate = codec->samplerate;
    p->active_path = PATH_NONE;
    p->public.f = da;

    struct ad_orender_params *opts =
        mp_get_config_group(da, da->global, &ad_orender_conf);
    p->host_decoder_idx = opts->host_decoder_idx;

    OrenderConfig cfg = {
        .sample_rate         = p->sample_rate,
        /* NULL → liborender resolves the shared omniphony config; these only
         * override it for this mpv invocation. OSC: --ad-orender-osc forces it
         * on, otherwise osc_enabled=0 lets liborender follow render.osc. Ports/
         * host/bind 0/NULL fall back to the config then the built-in defaults. */
        .config_yaml_path    = nz(opts->config_path),
        .speaker_layout_path = NULL,
        .bridge_path         = nz(opts->bridge_path),
        /* Tell the bridge which codec the raw access units carry: its raw
         * transport has no data-type byte to distinguish the supported
         * codecs from each other. */
        .codec               = codec->codec,
        .osc_enabled         = opts->osc ? 1 : 0,
        .osc_port_in         = (uint16_t)opts->osc_rx_port,
        .osc_port_out        = (uint16_t)opts->osc_port,
        .osc_bind            = nz(opts->osc_bind),
        .osc_host            = nz(opts->osc_monitor_target),
    };

    p->renderer = orender_create(&cfg);
    if (!p->renderer) {
        /* The engine could not start (e.g. a bad render.bridge_path). Rather than
         * leave the track with no decoder at all, stay selected and decode
         * natively for the whole session (host). Spatial is impossible until the
         * config is fixed and mpv restarted, but audio still plays. */
#ifdef _WIN32
        MP_ERR(da, "orender_create failed — decoding natively. Set "
                   "render.bridge_path in your omniphony config "
                   "(%%ProgramData%%\\omniphony\\config.yaml); see stderr.\n");
#else
        MP_ERR(da, "orender_create failed — decoding natively. Set "
                   "render.bridge_path in your omniphony config "
                   "(~/.config/omniphony/config.yaml); see stderr.\n");
#endif
        p->force_host = true;
    }

    /* Per-invocation override of the shared config's initial channel render mode.
     * Option values: 0=auto (follow config), 1=host, 2=spatial (direct/virtual
     * are legacy aliases of spatial). FFI mode codes: 0=host, 1=spatial — so
     * `value - 1` maps host(1)→0 and spatial(2)→1. The live mode is then driven
     * by Studio over OSC. */
    if (p->renderer && opts->channel_mode_idx > 0)
        orender_set_channel_mode(p->renderer, opts->channel_mode_idx - 1);

    if (p->renderer)
        p->channels = orender_channel_count(p->renderer);

    /* Match the overlay's initial visibility to the starting mode, so it does not
     * flash the wireframe cube before the first packet picks the path. */
    bool start_host = p->force_host ||
                      !p->renderer || orender_channel_mode(p->renderer) != 1;
    orender_overlay_set_rendering(start_host ? 0 : 1);

    /* Official-cased codec name. No "(orender)" suffix: the decoder already shows
     * up as the trailing "[orender]" bracket (codec != decoder). The Atmos /
     * DTS:X detail lands in the profile bracket built by refresh_codec_profile. */
    if (strcmp(codec->codec, "eac3") == 0)
        p->orender_desc = "E-AC-3";
    else if (strcmp(codec->codec, "ac3") == 0)
        p->orender_desc = "AC-3";
    else if (strcmp(codec->codec, "dts") == 0)
        p->orender_desc = "DTS";
    else
        p->orender_desc = "TrueHD";
    codec->codec_desc = p->orender_desc;

    /* Impossible sentinels (real: objs >=0, dnorm <=0 or INT32_MIN) so the first
     * decoded spatial frame always publishes a codec profile. */
    p->last_objs = -1;
    p->last_dnorm = 1;

    return &p->public;
}

static void add_decoders(struct mp_decoder_list *list)
{
    mp_add_decoder(list, "truehd", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
    mp_add_decoder(list, "eac3", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
    mp_add_decoder(list, "ac3", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
    mp_add_decoder(list, "dts", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
}

const struct mp_decoder_fns ad_orender = {
    .create = create,
    .add_decoders = add_decoders,
};
