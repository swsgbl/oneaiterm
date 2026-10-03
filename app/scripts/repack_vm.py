# repack_vm.py -- inject libssh HAR so files into a VM-built (device-raw) HAP.
# Usage: python repack_vm.py <in.hap> <out.hap>
#
# The VM toolchain packs the hap before host-side HAR libs land in libs/,
# so we rebuild the zip here: keep every entry from the VM build, drop the
# stale libssh-family .so copies, and (re)add the five authoritative so
# files from the repo HAR (including versioned names like libssh.so.4 --
# the suffix check is ".so" in name, NOT endswith(".so")).
import os
import shutil
import sys
import zipfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SO_DIR = os.path.join(REPO, "app", "thirdparty", "libssh-x86_64-har", "libs", "x86_64")
PREFIX = "libs/x86_64/"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: python repack_vm.py <in.hap> <out.hap>")
        return 2
    src, out = sys.argv[1], sys.argv[2]
    sos = sorted(f for f in os.listdir(SO_DIR) if ".so" in f)
    if not sos:
        print("FAIL: no .so under", SO_DIR)
        return 1
    tmp = out + ".tmp"
    with zipfile.ZipFile(src, "r") as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if item.filename.startswith(PREFIX) and item.filename[len(PREFIX):] in sos:
                continue  # drop stale copies; re-add from repo HAR below
            zout.writestr(item, zin.read(item.filename))
        for s in sos:
            tgt = PREFIX + s
            with open(os.path.join(SO_DIR, s), "rb") as f:
                data = f.read()
            zout.writestr(tgt, data)
            print("injected %s (%d bytes)" % (tgt, len(data)))
    shutil.move(tmp, out)
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
    missing = [s for s in sos if PREFIX + s not in names]
    if missing:
        print("FAIL: missing after repack:", missing)
        return 1
    kept_libs = sorted(n for n in names if n.startswith(PREFIX))
    print("libs/x86_64 final:", kept_libs)
    print("OK", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
