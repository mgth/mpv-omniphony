#!/usr/bin/env bash
# Check that an unpacked Linux zip (`mpv` plus the libraries bundled in `lib/`)
# starts with nothing but its own files and the system's libraries.
#
# Run it on the distribution the zip is built for (the CI runner is Ubuntu
# 24.04), in the unpacked zip, not in the build tree. It runs everything with
# an empty environment, so nothing a build step exported (LD_LIBRARY_PATH on
# the dependency prefix) can hide a missing library. It fails when:
#  - a run path names a directory outside the bundle: the build prefix exists
#    on the build host and would resolve there, and nowhere else;
#  - `ldd` cannot resolve a library of `mpv` or of a bundled library. Each
#    bundled library is checked on its own because the loader does not apply
#    mpv's RUNPATH to the dependencies of its dependencies;
#  - a bundled library is passed over for a copy from elsewhere;
#  - `mpv --version` does not start with every symbol bound (LD_BIND_NOW): a
#    system library older than the one mpv was linked against resolves by
#    name and only fails on the missing symbol.
#
# It cannot see a library the build host has installed and a user's machine
# has not: the zip relies on distribution packages for those.
#
# Usage: scripts/check-linux-bundle.sh <unpacked-zip-dir>
set -euo pipefail

[ $# -eq 1 ] || { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//;$d' >&2; exit 2; }
DIR="$(cd "$1" && pwd)"
[ -x "$DIR/mpv" ] || { echo "!! no mpv binary in $DIR" >&2; exit 1; }

# LC_ALL=C: the messages matched below are translated otherwise.
clean=(env -i PATH=/usr/bin:/bin LC_ALL=C)

objects=("$DIR/mpv")
while IFS= read -r -d '' f; do objects+=("$f"); done \
    < <(find "$DIR/lib" -type f -name '*.so*' -print0 2>/dev/null | sort -z)

fail=0
for obj in "${objects[@]}"; do
    name=${obj#"$DIR/"}

    runpath=$("${clean[@]}" objdump -p "$obj" | awk '$1 == "RUNPATH" || $1 == "RPATH" {print $2}')
    for entry in ${runpath//:/ }; do
        case "$entry" in
            '$ORIGIN'|'$ORIGIN/'*) ;;
            *) echo "!! $name: run path entry outside the bundle: $entry" >&2; fail=1 ;;
        esac
    done

    # "libfoo.so.1 => /path/libfoo.so.1 (0x…)" or "libfoo.so.1 => not found".
    while read -r soname arrow path _; do
        [ "$arrow" = "=>" ] || continue
        if [ "$path" = "not" ]; then
            echo "!! $name: $soname not found" >&2; fail=1
        elif [ -e "$DIR/lib/$soname" ] && [ ! "$path" -ef "$DIR/lib/$soname" ]; then
            echo "!! $name: loads $path instead of the bundled lib/$soname" >&2; fail=1
        fi
    done < <("${clean[@]}" ldd "$obj")
done
[ "$fail" -eq 0 ] || exit 1

# From another directory: nothing may depend on the working directory.
version=$(cd / && "${clean[@]}" LD_BIND_NOW=1 "$DIR/mpv" --version) \
    || { echo "!! mpv --version failed" >&2; exit 1; }
grep -m1 '^mpv ' <<<"$version"
echo ">> ${#objects[@]} objects resolve, mpv starts"
