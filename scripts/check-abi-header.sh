#!/usr/bin/env bash
# Fail when the liborender header vendored in the fork is not the header of
# the engine a build ships with. mpv compiles against the vendored copy
# (common/orender_abi.h) and loads the engine at runtime, so nothing else
# notices a copy that has drifted until a playback goes wrong.
#
#   scripts/check-abi-header.sh VENDORED_H ORENDER_H [--warn]
#
# VENDORED_H  common/orender_abi.h of the fork
# ORENDER_H   omniphony-renderer/orender_ffi/include/orender.h of Omniphony
# --warn      report a difference as a GitHub Actions warning and succeed
#             (builds that follow Omniphony's main, where the header moves
#             before the fork follows)
set -euo pipefail

vendored="${1:?usage: check-abi-header.sh VENDORED_H ORENDER_H [--warn]}"
reference="${2:?usage: check-abi-header.sh VENDORED_H ORENDER_H [--warn]}"
mode="${3:-}"

# The vendored file is a leading comment, one blank line, then the generated
# header byte for byte.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
awk 'copy { print; next } /^ \*\/$/ { getline; copy = 1 }' "$vendored" > "$body"
if [ ! -s "$body" ]; then
    echo "!! $vendored: no header found below a leading comment" >&2
    exit 1
fi

if diff -u --label "Omniphony orender.h" --label "fork common/orender_abi.h" \
        "$reference" "$body"; then
    echo ">> the vendored liborender header is the engine's"
    exit 0
fi

msg="the fork's common/orender_abi.h is not Omniphony's orender.h (diff above): copy the generated header over it on both fork branches, tag them, update mpv-fork.env"
if [ "$mode" = "--warn" ]; then
    echo "::warning::$msg"
    exit 0
fi
echo "!! $msg" >&2
exit 1
