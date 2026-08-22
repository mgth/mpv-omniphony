#!/usr/bin/env bash
# Build a STUB liborender for loader tests: all public symbols as no-ops, with
# a parameterizable ABI version so CI can exercise mpv's runtime handshake
# (accept a matching major, reject a mismatched one, fall through candidates).
#
# mpv no longer needs any liborender at build time (it dlopens the library
# against its vendored ABI header), so unlike the old mock-liborender.sh this
# installs no header and no pkg-config file — it only compiles a .so.
#
# Usage: stub-liborender.sh OUT_PATH [MAJOR [MINOR]]
#   OUT_PATH  where to write the stub (e.g. /tmp/stub/liborender.so)
#   MAJOR     value returned by orender_version_major() (default 0)
#   MINOR     value returned by orender_version_minor() (default 99)
set -euo pipefail

OUT="${1:?usage: stub-liborender.sh OUT_PATH [MAJOR [MINOR]]}"
MAJOR="${2:-0}"
MINOR="${3:-99}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keep signatures in sync with the vendored header (patches add it to the mpv
# tree as common/orender_abi.h). The stub decodes nothing: orender_create
# returns a dummy handle and orender_process yields zero frames forever.
cat > "$WORK/stub.c" <<EOF
#include <stddef.h>
#include <stdint.h>
typedef struct OrenderRenderer { int _; } OrenderRenderer;
typedef struct OrenderConfig OrenderConfig;
static OrenderRenderer g;
OrenderRenderer *orender_create(const OrenderConfig *c){(void)c;return &g;}
void orender_destroy(OrenderRenderer *r){(void)r;}
int orender_is_spatial(const OrenderRenderer *r){(void)r;return 0;}
int orender_has_objects(const OrenderRenderer *r){(void)r;return 0;}
uint64_t orender_output_latency_samples(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_channel_count(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_channel_layout(const OrenderRenderer *r,uint8_t *o,uint32_t c){(void)r;(void)o;(void)c;return 0;}
int orender_channel_mode(const OrenderRenderer *r){(void)r;return 0;}
void orender_set_channel_mode(OrenderRenderer *r,int m){(void)r;(void)m;}
int orender_channel_mapping(const OrenderRenderer *r){(void)r;return 0;}
void orender_set_channel_mapping(OrenderRenderer *r,int m){(void)r;(void)m;}
int orender_object_count(const OrenderRenderer *r){(void)r;return 0;}
int orender_dialnorm_db(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_bed_layout(const OrenderRenderer *r,uint8_t *o,uint32_t c){(void)r;(void)o;(void)c;return 0;}
void orender_reset(OrenderRenderer *r){(void)r;}
int orender_process(OrenderRenderer *r,const uint8_t *p,size_t pl,int64_t t,
                    float *o,size_t oc,size_t *nf,uint32_t *nc,int64_t *op){
    (void)r;(void)p;(void)pl;(void)t;(void)o;(void)oc;
    if(nf)*nf=0; if(nc)*nc=0; if(op)*op=t; return 0;}
uint32_t orender_version_major(void){return ${MAJOR}u;}
uint32_t orender_version_minor(void){return ${MINOR}u;}
const char *orender_build_id(void){return "stub-liborender ${MAJOR}.${MINOR} (CI fixture)";}
int orender_set_option(OrenderRenderer *r,const char *k,const char *v){(void)r;(void)k;(void)v;return -1;}
uintptr_t orender_overlay_ass(uint32_t x,uint32_t y,uint8_t *o,uintptr_t c){(void)x;(void)y;(void)o;(void)c;return 0;}
void orender_overlay_set_enabled(int e){(void)e;}
void orender_overlay_set_rendering(int x){(void)x;}
void orender_overlay_clear(void){}
int orender_overlay_toggle(void){return 0;}
int orender_overlay_toggle_labels(void){return 0;}
int orender_overlay_toggle_objects(void){return 0;}
int orender_overlay_toggle_trails(void){return 0;}
int orender_overlay_toggle_heatmap(void){return 0;}
uint32_t orender_overlay_cycle_heatmap_colormap(void){return 0;}
uint32_t orender_overlay_adjust_heatmap_bands(int32_t d){(void)d;return 0;}
uintptr_t orender_overlay_heatmap_bgra(uint32_t x,uint32_t y,uint8_t *o,uintptr_t c,int32_t *g){(void)x;(void)y;(void)o;(void)c;(void)g;return 0;}
EOF

mkdir -p "$(dirname "$OUT")"
cc -shared -fPIC -Wl,-soname,"liborender.so.$MAJOR" "$WORK/stub.c" -o "$OUT"
echo ">> stub liborender (ABI $MAJOR.$MINOR) written to $OUT"
