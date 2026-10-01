#!/usr/bin/env bash
# Regenerate patches-master/ from the mpv fork's `orender-master` branch.
#
# `orender-master` is the parallel branch in the fork that carries the same
# orender/asio integration commits as `orender`, but rebased onto upstream
# master (instead of the v0.41.0 tag). See README "Tracking mpv master".
#
# Run this after rebasing `orender-master` onto `upstream/master` in the fork.
#
# Usage:
#   scripts/regenerate-patches-master.sh /path/to/mpv-fork [BASE_REF]
#
# BASE_REF defaults to `upstream/master`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK="${1:?usage: regenerate-patches-master.sh /path/to/mpv-fork [BASE_REF]}"
BASE_REF="${2:-upstream/master}"
SRC_BRANCH="${SRC_BRANCH:-orender-master}"

if [ ! -d "$FORK/.git" ]; then
    echo "!! $FORK is not a git repo" >&2
    exit 1
fi

if ! git -C "$FORK" rev-parse --verify "$SRC_BRANCH" >/dev/null 2>&1; then
    echo "!! branch '$SRC_BRANCH' not found in $FORK" >&2
    echo "   Create it: git checkout -b $SRC_BRANCH $BASE_REF && git cherry-pick v0.41.0..orender" >&2
    exit 1
fi

if ! git -C "$FORK" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "!! ref '$BASE_REF' not found in $FORK" >&2
    echo "   Add the upstream remote: git remote add upstream https://github.com/mpv-player/mpv.git && git fetch upstream" >&2
    exit 1
fi

mkdir -p "$REPO_ROOT/patches-master"
echo ">> generating patches from ${BASE_REF}..${SRC_BRANCH} in $FORK"
# 9xxx-*.patch are MANUAL patches with no fork-commit counterpart (they target
# upstream code the fork base predates). Drop one once upstream master has made
# it obsolete, or it stops applying and breaks the live-master build.
# They apply last (lexicographic glob in apply-patches-master.sh) and must
# survive regeneration — only the format-patch-generated series is wiped.
find "$REPO_ROOT/patches-master" -maxdepth 1 -name '*.patch' \
    ! -name '9[0-9][0-9][0-9]-*.patch' -delete
git -C "$FORK" format-patch "${BASE_REF}..${SRC_BRANCH}" \
    --no-numbered-files --zero-commit --no-signature \
    -o "$REPO_ROOT/patches-master"

echo ">> wrote:"
ls -1 "$REPO_ROOT"/patches-master/*.patch

echo ">> reminder: keep src/ad_orender.c in sync with the fork's copy."
echo "   cp \"$FORK/audio/decode/ad_orender.c\" \"$REPO_ROOT/src/ad_orender.c\""
