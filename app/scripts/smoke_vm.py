# smoke_vm.py -- /smoke stage of vm-deploy.cmd.
# Sequence: aa start -> sleep 5 -> dumpLayout -> assert launch marker
# ("一站AI终端" visible) -> click the guide overlay "跳过" button by its
# dumped origBounds -> re-dump -> assert main UI renders (>50 visible text
# nodes) -> screenshot. Evidence lands in .verify/m8r1/.
# NOTE: uitest click coords are origBounds centers (window == screen);
# the guide overlay re-appears after every reinstall, blocking all clicks.
import glob
import json
import os
import re
import subprocess
import sys
import time

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EV = os.path.join(REPO, ".verify", "m8r1")
HDC = r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
TARGET = "127.0.0.1:15566"
BUNDLE = "com.oneaiterm.terminal"
MARKER = "\u4e00\u7ad9AI\u7ec8\u7aef"          # 一站AI终端
SKIP = "\u8df3\u8fc7"                          # 跳过


def hdc(*args):
    r = subprocess.run([HDC, "-t", TARGET] + list(args), capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def shell(cmd):
    return hdc("shell", cmd)


def dump_layout(name):
    shell("rm -f /data/local/tmp/layout_*.json")
    rc, out = shell("uitest dumpLayout")
    time.sleep(1.0)
    rc, out = shell("find /data/local/tmp -maxdepth 1 -name 'layout_*.json' -type f")
    files = sorted(l.strip() for l in out.splitlines() if "layout_" in l)
    if not files:
        print("FAIL: no layout_*.json after dumpLayout")
        return None
    vmf = files[-1]
    local = os.path.join(EV, name)
    rc2, _ = hdc("file", "recv", vmf, local)
    if rc2 != 0 or not os.path.isfile(local):
        print("FAIL: recv %s" % vmf)
        return None
    with open(local, "r", encoding="utf-8") as f:
        return json.load(f)


def walk_texts(root):
    hits = []
    def w(n):
        if not n or not isinstance(n, dict):
            return
        a = n.get("attributes") or {}
        t = a.get("text")
        if isinstance(t, str) and t:
            hits.append({"text": t, "visible": str(a.get("visible")), "bounds": a.get("origBounds") or a.get("bounds")})
        for c in n.get("children") or []:
            w(c)
    w(root)
    return hits


def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def main():
    os.makedirs(EV, exist_ok=True)
    rc, out = shell("aa start -a EntryAbility -b %s" % BUNDLE)
    print("aa start:", out.strip()[:120])
    time.sleep(5)

    layout = dump_layout("smoke-launch.json")
    if layout is None:
        return 1
    texts = walk_texts(layout)
    vis = [t for t in texts if t["visible"] == "true"]
    print("launch: %d text nodes (%d visible)" % (len(texts), len(vis)))
    if not any(MARKER in t["text"] for t in vis):
        print("FAIL: launch marker not visible: " + MARKER)
        return 1
    print("PASS1: launch marker visible")

    skip = next((t for t in vis if t["text"].strip() == SKIP), None)
    if skip and skip["bounds"]:
        c = center(skip["bounds"])
        print("click skip at %s (bounds %s)" % (c, skip["bounds"]))
        shell("uitest uiInput click %d %d" % c)
        time.sleep(2)
    else:
        print("no guide overlay skip button found (may already be dismissed)")

    layout2 = dump_layout("smoke-main.json")
    if layout2 is None:
        return 1
    vis2 = [t for t in walk_texts(layout2) if t["visible"] == "true"]
    print("main UI: %d visible text nodes" % len(vis2))
    if len(vis2) <= 50:
        print("FAIL: main UI visible text nodes = %d (need > 50)" % len(vis2))
        return 1
    print("PASS2: main UI > 50 visible text nodes (%d)" % len(vis2))

    shell("snapshot_display -f /data/local/tmp/vmchain-smoke.jpeg")
    time.sleep(1)
    hdc("file", "recv", "/data/local/tmp/vmchain-smoke.jpeg", os.path.join(EV, "vmchain-smoke.jpeg"))
    print("DONE_VM_SMOKE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
