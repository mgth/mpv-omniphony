#!/usr/bin/env python3
"""Emit an MSVC-style .def file listing a DLL's exported symbols.

The Windows libmpv bundle ships MinGW's import library (libmpv.dll.a), which
MSVC toolchains cannot link against. With this .def they generate their own:

    lib /def:mpv.def /name:libmpv-2.dll /out:mpv.lib /MACHINE:X64

objdump's export table layout differs between binutils versions (the symbol
either follows a `+base[N] hint` prefix or stands alone after the ordinal), so
match both and take the union. A plausibility floor turns a future layout
change into a failed build instead of a silently truncated .def.

A prefix filter keeps the .def down to the API the DLL is meant to expose. Our
libmpv-2.dll also exports the Lua interpreter it links statically; an import
library carrying `luaL_*` would collide with a consumer's own Lua for no reason.

Usage: make-import-def.py [--prefix PREFIX] <dll> <out.def>
Env:   OBJDUMP  objdump binary to use (default: x86_64-w64-mingw32-objdump)
"""

import os
import re
import subprocess
import sys

# libmpv exports 54 mpv_* symbols; a handful means the parse broke, not a small
# API. Kept well under that so a few client-API additions/removals don't trip it.
MIN_EXPORTS = 40

# "[   0] +base[   1]  0000 mpv_client_api_version"
BASE_HINT_RE = re.compile(r"^\s*\[\s*\d+\]\s+\+base\[\s*\d+\]\s+\S+\s+(\S+)\s*$", re.M)
# "[   0] mpv_client_api_version"
PLAIN_RE = re.compile(r"^\s*\[\s*\d+\]\s+([A-Za-z_][\w@?$.]*)\s*$", re.M)
IDENT_RE = re.compile(r"[A-Za-z_?][\w@?$.]*")
# Placeholder token printed instead of a name when only the address is known.
NOT_A_SYMBOL = {"RVA"}


def main() -> int:
    argv = sys.argv[1:]
    prefix = ""
    if len(argv) > 1 and argv[0] == "--prefix":
        prefix = argv[1]
        argv = argv[2:]
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    dll, out_path = argv

    tool = os.environ.get("OBJDUMP", "x86_64-w64-mingw32-objdump")
    dump = subprocess.run(
        [tool, "-p", dll], capture_output=True, text=True, check=True
    ).stdout

    names = set(BASE_HINT_RE.findall(dump)) | set(PLAIN_RE.findall(dump))
    names = {n for n in names if n not in NOT_A_SYMBOL and IDENT_RE.fullmatch(n)}
    names = {n for n in names if n.startswith(prefix)}

    if len(names) < MIN_EXPORTS:
        print(
            f"error: parsed only {len(names)} exports from {dll} "
            f"(prefix {prefix!r}, expected >= {MIN_EXPORTS}) — "
            "objdump export layout changed?",
            file=sys.stderr,
        )
        return 1

    with open(out_path, "w") as fh:
        fh.write("EXPORTS\n")
        for name in sorted(names):
            fh.write(f"{name}\n")

    print(f"wrote {out_path} ({len(names)} exports)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
