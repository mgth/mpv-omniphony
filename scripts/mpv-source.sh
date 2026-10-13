#!/usr/bin/env bash
# Assemble the mpv tree a build compiles, from the fork tags pinned in
# mpv-fork.env. Nothing is patched here: the fork is the source.
#
#   scripts/mpv-source.sh stable
#       The fork's stable tag, as it is.          -> build/mpv-<MPV_TAG>
#   scripts/mpv-source.sh master
#       Upstream mpv master HEAD with the fork's master tag merged in (live
#       tracker: fails when master has moved under the fork's commits).
#                                                  -> build/mpv-master-<sha>
#   scripts/mpv-source.sh master --pinned
#       The fork's master tag, as it is (reproducible).
#                                                  -> build/mpv-master-<sha>
#
# The last line of stdout is the tree's directory.
#
# To build a fork checkout that is not tagged yet, point the script at it:
#   MPV_FORK_URL=/path/to/fork MPV_SOURCE_REF=orender scripts/mpv-source.sh stable
# MPV_SOURCE_REF replaces the pinned tag and skips the commit check.
set -euo pipefail

# shellcheck source=fork-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fork-lib.sh"

TRACK="${1:?usage: mpv-source.sh stable | master [--pinned]}"
PINNED="${2:-}"

case "$TRACK" in
stable)
    SRC="$WORKDIR/mpv-$MPV_TAG"
    if [ ! -d "$SRC/.git" ]; then
        git init --quiet "$SRC"
    else
        echo ">> reusing existing tree at $SRC" >&2
    fi
    # Without blobs the history is small, and `git describe` still finds the
    # upstream release tag the fork is based on (mpv's version string).
    sha="$(fetch_pinned "$SRC" "$MPV_FORK_STABLE_TAG" "$MPV_FORK_STABLE_SHA" --filter=blob:none)"
    set_remote "$SRC" upstream "$MPV_UPSTREAM_URL"
    git -C "$SRC" fetch --quiet --no-tags --filter=blob:none upstream \
        "refs/tags/$MPV_TAG:refs/tags/$MPV_TAG"
    git -C "$SRC" checkout --quiet --force --detach "$sha"
    git -C "$SRC" clean -fdxq
    echo ">> mpv $MPV_TAG + fork ${MPV_SOURCE_REF:-$MPV_FORK_STABLE_TAG} (${sha:0:10})" >&2
    ;;
master)
    CLONE_DIR="$WORKDIR/mpv-master-clone"
    if [ ! -d "$CLONE_DIR/.git" ]; then
        echo ">> cloning mpv master" >&2
        git clone --quiet --branch master "$MPV_UPSTREAM_URL" "$CLONE_DIR"
    else
        echo ">> refreshing existing clone at $CLONE_DIR" >&2
        git -C "$CLONE_DIR" fetch --quiet origin master
        git -C "$CLONE_DIR" checkout --quiet --force --detach origin/master
        git -C "$CLONE_DIR" clean -fdxq
    fi
    sha="$(fetch_pinned "$CLONE_DIR" "$MPV_FORK_MASTER_TAG" "$MPV_FORK_MASTER_SHA")"
    if [ "$PINNED" = "--pinned" ]; then
        git -C "$CLONE_DIR" checkout --quiet --force --detach "$sha"
        head="${sha:0:10}"
    else
        git -C "$CLONE_DIR" checkout --quiet --force --detach origin/master
        head="$(git -C "$CLONE_DIR" rev-parse --short=10 HEAD)"
        if ! git -C "$CLONE_DIR" -c user.name=mpv-omniphony -c user.email=mpv-omniphony@invalid \
                merge --quiet --no-edit "$sha" >&2; then
            git -C "$CLONE_DIR" merge --abort || true
            echo "!! mpv master ($head) has moved under the fork's master track" >&2
            echo "   (${MPV_SOURCE_REF:-$MPV_FORK_MASTER_TAG}). Rebase the fork's orender-master onto" >&2
            echo "   upstream master, tag it and update mpv-fork.env (README, Tracking mpv master)." >&2
            exit 1
        fi
    fi
    # Named after the upstream commit built on (the fork's own with --pinned).
    SRC="$WORKDIR/mpv-master-$head"
    if [ -d "$SRC" ]; then
        echo ">> replacing stale $SRC" >&2
        rm -rf "${SRC:?}"
    fi
    cp -a "$CLONE_DIR" "$SRC"
    # cp -a keeps the index's stat data while the files get new inodes:
    # refresh it so the snapshot is a clean tree for git and for meson.
    git -C "$SRC" update-index --refresh >/dev/null 2>&1 || true
    echo ">> mpv master + fork ${MPV_SOURCE_REF:-$MPV_FORK_MASTER_TAG} (${sha:0:10})" >&2
    ;;
*)
    echo "usage: mpv-source.sh stable | master [--pinned]" >&2
    exit 2
    ;;
esac

echo ">> build with: cd $SRC && meson setup _b -Dorender=enabled && meson compile -C _b" >&2
echo "$SRC"
