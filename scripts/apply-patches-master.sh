#!/usr/bin/env bash
# Clone mpv master HEAD (latest commit on mpv-player/mpv) and apply
# patches-master/. Produces a buildable tree at ./build/mpv-master-<short-sha>.
#
# Variante "HEAD vivant" de apply-patches.sh : pas de pin SHA, chaque exécution
# prend le dernier commit master. Voir aussi apply-patches.sh pour la cible
# v0.41.0 reproductible.
#
# Usage: scripts/apply-patches-master.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MPV_URL="https://github.com/mpv-player/mpv.git"
WORKDIR="$REPO_ROOT/build"
CLONE_DIR="$WORKDIR/mpv-master-clone"

mkdir -p "$WORKDIR"

# MPV_MASTER_REF pins which master commit we build:
#   unset / "master"  -> latest master HEAD (default; used by build-master.yml)
#   a commit SHA       -> that exact commit (used by the FEL flow, whose vendored
#                         patch targets dv-fel's rebase base — ~100 commits behind
#                         HEAD. Cloning HEAD rots the FEL patch in vo_gpu_next.c.)
# The SHA must be an ancestor of master; a full clone always contains it.
MPV_REF="${MPV_MASTER_REF:-master}"
if [ ! -d "$CLONE_DIR/.git" ]; then
    echo ">> cloning mpv master (full history, --3way needs blobs)"
    git clone --branch master "$MPV_URL" "$CLONE_DIR"
else
    echo ">> refreshing existing clone at $CLONE_DIR"
    git -C "$CLONE_DIR" fetch origin master
fi
if [ "$MPV_REF" = master ]; then RESET_TO="origin/master"; else RESET_TO="$MPV_REF"; fi
echo ">> pinning mpv tree to: $MPV_REF"
git -C "$CLONE_DIR" reset --hard "$RESET_TO"
git -C "$CLONE_DIR" clean -fdx

SHORT_SHA="$(git -C "$CLONE_DIR" rev-parse --short HEAD)"
SRC="$WORKDIR/mpv-master-${SHORT_SHA}"

if [ -d "$SRC" ]; then
    echo ">> removing stale $SRC"
    rm -rf "$SRC"
fi

echo ">> snapshotting clone to $SRC (HEAD=$SHORT_SHA)"
cp -a "$CLONE_DIR" "$SRC"
# cp -a copies the index file with the source's stat data, but the working-tree
# files have new inode/mtime. Refresh the snapshot's index so `git apply --3way`
# sees a clean tree (without this, --3way rejects every modified file).
git -C "$SRC" update-index --refresh >/dev/null 2>&1 || true

shopt -s nullglob
patches=("$REPO_ROOT"/patches-master/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! no patches in patches-master/ — generate them first"
    echo "   scripts/regenerate-patches-master.sh /path/to/mpv-fork"
    exit 1
fi

echo ">> applying ${#patches[@]} patch(es)"
for p in "${patches[@]}"; do
    echo "   - $(basename "$p")"
    git -C "$SRC" apply --3way "$p"
done

echo ">> done. Build with:"
echo "   cd $SRC && meson setup build -Dorender=enabled && meson compile -C build"
