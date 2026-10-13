# Shared by scripts/mpv-source.sh and scripts/export-patches.sh: read
# mpv-fork.env and fetch a pinned tag of the fork. Sourced, not run.

# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FORK_URL="${MPV_FORK_URL:-}"
ENV_MPV_TAG="${MPV_TAG:-}"
# shellcheck source=../mpv-fork.env
. "$REPO_ROOT/mpv-fork.env"
[ -n "$ENV_FORK_URL" ] && MPV_FORK_URL="$ENV_FORK_URL"
# The workflows name the stable tree's directory after their own MPV_TAG.
if [ -n "$ENV_MPV_TAG" ] && [ "$ENV_MPV_TAG" != "$MPV_TAG" ]; then
    echo "!! MPV_TAG is $ENV_MPV_TAG in the environment and $MPV_TAG in mpv-fork.env" >&2
    exit 1
fi
WORKDIR="$REPO_ROOT/build"
mkdir -p "$WORKDIR"

# Point the remote $2 of the repository at $1 to the URL $3.
set_remote() {
    if git -C "$1" remote get-url "$2" >/dev/null 2>&1; then
        git -C "$1" remote set-url "$2" "$3"
    else
        git -C "$1" remote add "$2" "$3"
    fi
}

# fetch_pinned DIR TAG COMMIT [fetch options]
# Fetch the tag TAG of the fork (remote `fork`) into the repository at DIR and
# print the commit it resolves to, after checking it is COMMIT. With
# MPV_SOURCE_REF set, that ref is taken instead and nothing is checked.
fetch_pinned() {
    local dir="$1" tag="$2" want="$3" ref got
    shift 3
    if [ -n "${MPV_SOURCE_REF:-}" ]; then
        ref="$MPV_SOURCE_REF"
        echo ">> MPV_SOURCE_REF set: taking $ref from $MPV_FORK_URL, commit not checked" >&2
    else
        ref="refs/tags/$tag"
    fi
    set_remote "$dir" fork "$MPV_FORK_URL"
    git -C "$dir" fetch --quiet --no-tags "$@" fork "$ref"
    got="$(git -C "$dir" rev-parse 'FETCH_HEAD^{commit}')"
    if [ -z "${MPV_SOURCE_REF:-}" ] && [ "$got" != "$want" ]; then
        echo "!! $tag resolves to $got in $MPV_FORK_URL," >&2
        echo "   mpv-fork.env records $want. A fork tag is never moved:" >&2
        echo "   tag the new head under a new name and update mpv-fork.env." >&2
        exit 1
    fi
    echo "$got"
}
