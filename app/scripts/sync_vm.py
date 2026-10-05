# sync_vm.py -- push the repo source tree to the VM build directory.
# Usage: python sync_vm.py [--push] [--prune]
#
# Transport: ONE tar.gz built on the host from the manifest, pushed with a
# single `hdc file send`, extracted on the VM into a freshly wiped tree.
# Rationale (M8-relay1 evidence, .verify/m8r1/sync-fix-test.log):
# back-to-back per-file `hdc file send` calls race on this transport -- the
# receiver creates the DEST FILENAME AS A DIRECTORY and nests the payload
# inside it (observed: /entry/src/main/ets/pages/Index.ets/src/main/ets/
# pages/Index.ets). 98 sends -> 95 misplaced files, repush makes it worse.
# A single-file send (the tarball) has none of that concurrency, and
# tar -C extraction creates every parent dir itself.
#
# Verification: one VM-side `find <root> -type f`, strip the root prefix,
# compare as POSIX-relative path sets against the local manifest. Also
# detects lineage pollution (a path segment repeating, e.g. .../Index.ets/
# src/main/ets/pages/Index.ets) which is the signature of the send bug
# above -- that is a hard FAIL, not a warning.
import os
import subprocess
import sys
import tarfile
import tempfile
import time

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
APP = os.path.join(REPO, "app")
VM_DST = "/data/local/home/tmp/app"
VM_TARBALL = "/data/local/tmp/m8r1-sync.tar.gz"
HDC = r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
TARGET = "127.0.0.1:15566"
HAR_KEEP = (".ets", ".json5", ".ts")  # extensions synced from the HAR tree
# (.ts is hvigorfile.ts -- hard-required by VM hvigor, 00303148 without it;
#  the vm_find filter MUST mirror the manifest rules or files that DID land
#  get reported missing, the same class of bug as the 95-missing false alarm)
# build residue / installed package dirs are never synced (VM has its own)
EXCLUDE_SEGMENTS = ("oh_modules", "build", ".hvigor", ".cxx", "node_modules", ".preview", "placeholder-icon")

# (relative dir under app/, filename patterns to include)
INCLUDE = [
    ("entry/src/main/ets", [".ets"]),
    ("entry/src/main/resources", None),   # all files
    ("entry/src/main/cpp", None),         # CMakeLists + cpp + d.ts + oh-package
    # ohosTest module tree (M8-relay8): full tree -- module.json5, ets sources
    # (testrunner/testability/pages + 10 test files), resources, oh-package
    ("entry/src/ohosTest", None),
    # AppScope resources: app.json5 alone is NOT enough -- module label refs
    # like $string:app_name live in AppScope/resources/base/element/string.json
    # and CompileResource fails ("ref don't be defined") without them
    ("AppScope/resources", None),
    ("thirdparty/libssh-x86_64-har", [".ets", ".json5"]),
]


def hdc(*args):
    r = subprocess.run([HDC, "-t", TARGET] + list(args), capture_output=True, text=True)
    time.sleep(0.05)  # pacing: back-to-back hdc calls occasionally cross-talk on this transport
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def hdc_shell(cmd):
    return hdc("shell", cmd)


def build_manifest():
    files = []
    # fixed set of config files (sync targets from M8-relay0)
    fixed = [
        "entry/build-profile.json5",
        "entry/oh-package.json5",
        "entry/hvigorfile.ts",
        "entry/src/main/module.json5",
        "build-profile.json5",
        "oh-package.json5",
        "hvigorfile.ts",
        "AppScope/app.json5",
        # hvigor wrapper config: VM hvigor hard-fails (00304004 Not Found)
        # without app/hvigor/hvigor-config.json5 in the project tree
        "hvigor/hvigor-config.json5",
        # HAR module build script: hvigor 00303148 "Hvigorfile not found"
        # for thirdparty/libssh-x86_64-har without it (M8-relay1 run3);
        # HAR_KEEP patterns (.ets/.json5) do not cover the .ts extension
        "thirdparty/libssh-x86_64-har/hvigorfile.ts",
        # referenced by entry/build-profile.json5 ruleOptions; CompileArkTS
        # 00304036 without it
        "entry/obfuscation-rules.txt",
    ]
    for f in fixed:
        if os.path.isfile(os.path.join(APP, f)):
            files.append(f)
    for rel, pats in INCLUDE:
        base = os.path.join(APP, rel)
        for root, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if d not in EXCLUDE_SEGMENTS]
            for n in sorted(names):
                if pats is None or os.path.splitext(n)[1] in pats:
                    files.append(os.path.relpath(os.path.join(root, n), APP).replace("\\", "/"))
    return sorted(set(files))


def make_tarball(manifest, tar_path):
    # deterministic tarball: manifest order, POSIX arcnames, no host paths
    with tarfile.open(tar_path, "w:gz") as tf:
        for f in manifest:
            tf.add(os.path.join(APP, f), arcname=f)
    return os.path.getsize(tar_path)


def push_tarball(manifest):
    # one tarball, one send, VM-side wipe + extract. The tree is rebuilt
    # from scratch every deploy so no polluted state (orphan files,
    # filename-as-directory residue) can survive into this sync.
    tmp = os.path.join(tempfile.gettempdir(), "m8r1-sync.tar.gz")
    size = make_tarball(manifest, tmp)
    print("TARBALL=%d bytes from %d files" % (size, len(manifest)))
    rc, out = hdc("file", "send", tmp, VM_TARBALL)
    if rc != 0 or "fail" in (out or "").lower() or "error" in (out or "").lower():
        print("FAIL: tarball send rc=%d out=%s" % (rc, out.strip()))
        return False
    # verify the tarball landed with the right size before extracting:
    # single-file sends are reliable but the errorlevel still lies
    # (no awk on this VM; `wc -c <file` prints the bare number)
    rc, out = hdc_shell("wc -c < " + VM_TARBALL)
    got_size = out.strip().splitlines()[-1] if out.strip() else ""
    if got_size != str(size):
        print("FAIL: tarball size on VM=%s expected=%d (send silently dropped)" % (got_size, size))
        return False
    rc, out = hdc_shell(
        "rm -rf " + VM_DST + " && mkdir -p " + VM_DST
        + " && tar -xzf " + VM_TARBALL + " -C " + VM_DST
        + " && echo EXTRACT_OK"
    )
    if rc != 0 or "EXTRACT_OK" not in out:
        print("FAIL: vm extract rc=%d out=%s" % (rc, out.strip()[:500]))
        return False
    return True


def vm_find():
    # ONE find over the whole synced tree (single shell round-trip; the old
    # multi-find concat was another cross-talk victim). Returns a set of
    # POSIX-relative paths, or None on transport failure.
    rc, out = hdc_shell("find " + VM_DST + " -type f")
    if rc != 0:
        print("FAIL: vm find rc=%d out=%s" % (rc, out.strip()))
        return None
    got = set()
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith(VM_DST + "/"):
            continue
        rel = line[len(VM_DST) + 1:]
        if not rel or rel.endswith("/"):
            continue  # never happens for -type f; belt and braces
        got.add(rel)
    # har tree: keep only ets/json5 (libs/*.so are injected at repack stage)
    got = set(g for g in got if not g.startswith("thirdparty/") or g.endswith(HAR_KEEP))
    return got


def detect_pollution(got):
    # a legit synced path never repeats a segment (entry/src/main/ets/...);
    # a repeated segment (.../Index.ets/src/main/ets/pages/Index.ets) is the
    # signature of the filename-as-directory hdc send bug -- hard FAIL
    bad = []
    for g in got:
        segs = g.split("/")
        if len(segs) != len(set(segs)):
            bad.append(g)
    return bad


def verify_counts(manifest):
    got = vm_find()
    if got is None:
        return "findfail", []
    pollution = detect_pollution(got)
    if pollution:
        print("FAIL: %d polluted paths on VM (hdc send nested payloads):" % len(pollution))
        for p in pollution[:10]:
            print("  polluted " + p)
        return "polluted", pollution
    want = set(manifest)
    missing = sorted(want - got)
    extra = sorted(got - want)
    print("VM_FIND_COUNT=%d LOCAL_MANIFEST=%d" % (len(got), len(want)))
    if missing:
        print("WARN: %d missing on VM after push:" % len(missing))
        for m in missing[:20]:
            print("  missing " + m)
        return "missing", missing
    if extra:
        print("WARN: %d orphan files on VM (not in local manifest):" % len(extra))
        for e in extra[:20]:
            print("  orphan " + e)
        return "orphans", extra
    return "ok", []


def main():
    do_push = "--push" in sys.argv
    do_prune = "--prune" in sys.argv
    manifest = build_manifest()
    ets_cnt = sum(1 for f in manifest if f.startswith("entry/src/main/ets/") and f.endswith(".ets"))
    print("MANIFEST=%d files (ets=%d)" % (len(manifest), ets_cnt))
    if not do_push and not do_prune:
        # dry mode: print manifest only
        for f in manifest:
            print("  " + f)
        return 0
    if do_push:
        # tar transport replaces per-file sends entirely; --prune is a no-op
        # now (the tree is wiped and re-extracted), kept for CLI compat
        if not push_tarball(manifest):
            return 1
        res, detail = verify_counts(manifest)
        if res == "missing":
            # one full retry of the transport (tarball may have been sent
            # while the VM was mid-something); a second miss is a real FAIL
            print("RETRY: one more full tar push")
            if not push_tarball(manifest):
                return 1
            res, detail = verify_counts(manifest)
        if res != "ok":
            print("FAIL: verify after push -> %s" % res)
            return 1
    else:
        res, detail = verify_counts(manifest)
        if res != "ok":
            print("FAIL: VM tree does not match manifest -> %s (run with --push)" % res)
            return 1
    print("SYNC_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
