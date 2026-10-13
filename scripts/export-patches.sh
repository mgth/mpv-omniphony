#!/usr/bin/env bash
# Write the fork's delta as patch series, for whoever wants upstream mpv plus
# patches rather than the fork: a distribution package, a review, a rebase.
# The builds do not use them, they compile the fork tag itself
# (scripts/mpv-source.sh). The releases attach them.
#
#   scripts/export-patches.sh stable | master [OUTDIR]
#       OUTDIR defaults to build/patches-<track>.
#
# Two series, to apply in this order on the track's upstream base (MPV_TAG for
# stable, MPV_MASTER_BASE for master), with `git am` or `patch -p1`:
#
#   OUTDIR/asio/      the ASIO audio output (ao_asio), which is not orender's
#   OUTDIR/orender/   the orender integration
#
# The fork's branches interleave the two. The script replays the ASIO commits
# first and the others after, and fails unless the result is the pinned tag's
# tree, or when a commit touches both: the ASIO output has to stay a series
# that stands on its own, so the orender delta stays easy to rebase.
set -euo pipefail

# shellcheck source=fork-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fork-lib.sh"

TRACK="${1:?usage: export-patches.sh stable | master [OUTDIR]}"
OUT="${2:-$WORKDIR/patches-$TRACK}"

GIT_DIR_FORK="$WORKDIR/mpv-fork.git"
[ -d "$GIT_DIR_FORK" ] || git init --quiet --bare "$GIT_DIR_FORK"
g() { git -C "$GIT_DIR_FORK" "$@"; }
set_remote "$GIT_DIR_FORK" upstream "$MPV_UPSTREAM_URL"

case "$TRACK" in
stable)
    tip="$(fetch_pinned "$GIT_DIR_FORK" "$MPV_FORK_STABLE_TAG" "$MPV_FORK_STABLE_SHA")"
    g fetch --quiet --no-tags upstream "refs/tags/$MPV_TAG"
    base="$(g rev-parse 'FETCH_HEAD^{commit}')"
    ;;
master)
    tip="$(fetch_pinned "$GIT_DIR_FORK" "$MPV_FORK_MASTER_TAG" "$MPV_FORK_MASTER_SHA")"
    base="$MPV_MASTER_BASE"
    ;;
*)
    echo "usage: export-patches.sh stable | master [OUTDIR]" >&2
    exit 2
    ;;
esac

if ! g merge-base --is-ancestor "$base" "$tip"; then
    echo "!! the base $base is not an ancestor of the fork tag ($tip):" >&2
    echo "   mpv-fork.env names a base the fork is not built on." >&2
    exit 1
fi

# Files an ASIO commit may touch besides its own: where an output driver is
# registered and built, and the licence note of its SDK headers.
asio_shared='^(meson\.build|meson\.options|audio/out/ao\.c|Copyright)$'

asio=()
other=()
for c in $(g rev-list --no-merges --reverse --topo-order "$base..$tip"); do
    files="$(g show --format= --name-only "$c")"
    if echo "$files" | grep -qi asio; then
        mixed="$(echo "$files" | grep -vi asio | grep -Ev "$asio_shared" || true)"
        if [ -n "$mixed" ]; then
            echo "!! $(g log -1 --format='%h %s' "$c")" >&2
            echo "   touches the ASIO output and something else:" >&2
            echo "$mixed" | sed 's/^/     /' >&2
            echo "   Split it in the fork: the ASIO output is a series of its own." >&2
            exit 1
        fi
        asio+=("$c")
    else
        other+=("$c")
    fi
done

# Replay in the exported order, so each patch applies on the one before it
# without a three-way merge.
REPLAY="$WORKDIR/replay-$TRACK"
if [ -d "$REPLAY" ]; then
    g worktree remove --force "$REPLAY"
fi
g worktree prune
g worktree add --quiet --detach "$REPLAY" "$base"
pick() {
    GIT_COMMITTER_NAME=mpv-omniphony GIT_COMMITTER_EMAIL=mpv-omniphony@invalid \
        git -C "$REPLAY" cherry-pick --allow-empty "$1" >/dev/null 2>&1 || {
        echo "!! $(g log -1 --format='%h %s' "$1")" >&2
        echo "   does not replay with the ASIO commits moved first: it depends on" >&2
        echo "   a commit of the other series. Untangle the two in the fork." >&2
        exit 1
    }
}
for c in ${asio[@]+"${asio[@]}"}; do pick "$c"; done
asio_tip="$(git -C "$REPLAY" rev-parse HEAD)"
for c in ${other[@]+"${other[@]}"}; do pick "$c"; done

if [ "$(git -C "$REPLAY" rev-parse 'HEAD^{tree}')" != "$(g rev-parse "$tip^{tree}")" ]; then
    echo "!! replaying ASIO first, then the rest, does not give the tree of the" >&2
    echo "   fork tag: a merge commit of the fork carries a change of its own." >&2
    exit 1
fi

mkdir -p "$OUT/asio" "$OUT/orender"
find "$OUT/asio" "$OUT/orender" -maxdepth 1 -name '*.patch' -delete
git -C "$REPLAY" format-patch --quiet --zero-commit --no-signature \
    -o "$OUT/asio" "$base..$asio_tip"
git -C "$REPLAY" format-patch --quiet --zero-commit --no-signature \
    -o "$OUT/orender" "$asio_tip..HEAD"
g worktree remove --force "$REPLAY"

echo ">> ${#asio[@]} ASIO and ${#other[@]} orender patches in $OUT," >&2
echo "   to apply in that order on mpv $(g rev-parse --short=10 "$base")" >&2
echo "$OUT"
