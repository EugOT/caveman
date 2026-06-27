"""``python3 -m scripts`` entry point (pure-Zig runtime).

The Python compress CLI was retired in the R6.4 pure-Zig cutover. Compression
now runs through the ``caveman-compress`` Zig binary. If it is on PATH (or in a
local ``zig/zig-out/bin``), forward to it; otherwise tell the user where it went.
"""

import os
import shutil
import sys
from pathlib import Path


def _find_binary() -> str | None:
    found = shutil.which("caveman-compress")
    if found:
        return found
    # Local clone fallback: <repo_root>/zig/zig-out/bin/caveman-compress
    # __file__ → scripts → caveman-compress → skills → repo_root
    local = Path(__file__).resolve().parents[3] / "zig" / "zig-out" / "bin" / "caveman-compress"
    return str(local) if local.exists() else None


def main() -> int:
    binary = _find_binary()
    if binary is None:
        sys.stderr.write(
            "caveman-compress: the Python compress CLI was retired in the "
            "pure-Zig cutover.\n"
            "Install the caveman binaries (see install.sh) or build from a "
            "clone with `zig build -Dtool=caveman`, then re-run.\n"
        )
        return 1
    os.execv(binary, [binary, *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())
