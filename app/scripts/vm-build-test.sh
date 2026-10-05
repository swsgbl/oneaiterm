#!/system/bin/sh
# vm-build-test.sh -- build the ohosTest (entry_test) module on the VM,
# M8-relay8. Two-axis sed over the stock pack_hap.sh. LAYOUT FACT (proven
# this relay): hvigor lays out build/{product}/intermediates/{target}/...
# so for product=store + target=ohosTest:
#   product axis: build/default/ -> build/store/        (INTER + OUT head)
#   target  axis: inner /default/ -> /ohosTest/         (loader_out res
#                 syscap loader source_map stripped_native_libs libs +
#                 outputs tail) and module=entry@ohosTest.
# NOT a /store/->/ohosTest/ global pass (that would clobber the product
# dir too -- first attempt failed exactly that way).
# The test module has no native libs: the stripped_native_libs branch in
# pack_hap.sh is -f guarded and stays off.
# Runs under timeout 280. Output: /data/local/home/tmp/app/out_test-unsigned.hap
set -e
SRC=/data/local/home/.local/bin/pack_hap.sh
DST=/data/local/home/.local/bin/pack_hap_test.sh
PROJ=/data/local/home/tmp/app
LOG=/data/local/tmp/m8r8-test-build.log
OUT=/data/local/home/tmp/app/out_test-unsigned.hap

echo "[tbuild] regenerate $DST from stock pack_hap.sh"
cp -f "$SRC" "$DST"
chmod +x "$DST"
# ---- product axis ----
sed -i 's/-p product=default/-p product=store/' "$DST"
sed -i 's|INTER="$PROJ/entry/build/default/intermediates"|INTER="$PROJ/entry/build/store/intermediates"|' "$DST"
sed -i 's|OUT="$PROJ/entry/build/default/outputs/default"|OUT="$PROJ/entry/build/store/outputs/ohosTest"|' "$DST"
# ---- target axis ----
sed -i 's/-p module=entry@default/-p module=entry@ohosTest/' "$DST"
sed -i 's|UNSIGNED="$OUT/entry-default-unsigned.hap"|UNSIGNED="$OUT/entry-ohosTest-unsigned.hap"|' "$DST"
# every remaining inner /default/ segment is TARGET level (loader_out res
# syscap loader source_map stripped_native_libs libs + debug cache paths);
# a cache miss there is only a rebuild cost, never a correctness issue.
sed -i 's|/default/|/ohosTest/|g' "$DST"
sed -i 's/libentry\.so/liblocalpty.so/' "$DST"
if ! grep -q 'entry@ohosTest' "$DST" || ! grep -q 'product=store' "$DST" \
   || ! grep -q 'build/store/intermediates' "$DST"; then
  echo "FAIL: sed regeneration incomplete"; exit 1
fi
echo "[tbuild] sed ok (entry@ohosTest, product=store, build/store/intermediates)"

cd "$PROJ"
export HOME=/data/local/home
. /data/local/home/env.sh >/dev/null 2>&1 || true
if [ ! -d "$PROJ/entry/oh_modules/@ohos/hypium" ]; then
  echo "[tbuild] ohpm install (hypium missing)"
  set +e
  ohpm install --all
  OHPM_RC=$?
  set -e
  if [ $OHPM_RC -ne 0 ] || [ ! -d "$PROJ/entry/oh_modules/@ohos/hypium" ]; then
    echo "FAIL: ohpm install rc=$OHPM_RC or hypium link missing"
    exit 1
  fi
fi
echo "[tbuild] timeout 280 pack_hap_test.sh (log: $LOG)"
# Targeted abc refresh: incremental builds can desync ets/TestRunner/*.abc
# entry records from modules.abc (measured live: ReferenceError "Cannot
# find module &entry/.../ListTest&" -> App died). Clearing loader_out
# forces a full OhosTestCompileArkTS rerun which rewrites every abc in
# sync. Do NOT rm -rf build/store: a cold tree triggers hvigor's full
# SDK component enumeration (toolchains,ets,js,native,previewer) and
# this VM ships a reduced SDK without native/previewer -> 00303168.
rm -rf "$PROJ/entry/build/store/intermediates/loader_out"
# stale-abc hard reset: incremental OhosTestCompileArkTS can leave ets abc
# entry records desynced from modules.abc. loader_out + loader + the old
# output hap must ALL go, else a failed build silently re-ships the stale
# hap (measured live: 10s BUILD FAILED with rc=0 + DONE false-positive).
rm -rf "$PROJ/entry/build/store/intermediates/loader"
rm -f "$PROJ/entry/build/store/outputs/ohosTest/entry-ohosTest-unsigned.hap" "$OUT"
rm -f "$LOG"
set +e
timeout 280 "$DST" "$PROJ" > "$LOG" 2>&1
RC=$?
set -e
echo "[tbuild] rc=$RC"
tail -n 25 "$LOG"
# pack_hap.sh's DESIGNED recovery path: this VM ships no JDK, so hvigor
# PackageHap ALWAYS fails with "spawn java ENOENT" and pack_hap.sh falls
# back to its own C++ pack (ohos_packing_tool) + hap-sign-tool -- which
# is how every successful build on this VM was produced (12:07/12:51
# evidence runs included). hvigor's own "BUILD FAILED in Ns" line
# therefore does NOT mean the build failed; the FATAL marker is
# pack_hap.sh's dump_compile_errors header "===== BUILD FAILED (rc=)"
# (compile errors / abc missing / non-java hvigor failures all exit
# nonzero there and print it). Guarding on the bare marker misfires on
# the legitimate java fallback (measured live: 17:53 U2 build produced
# a fresh signed hap yet tripped this guard).
if grep -aq '===== BUILD FAILED' "$LOG"; then
  echo "FAIL: pack_hap declared fatal BUILD FAILED (rc=$RC)"
  grep -aE 'ERROR|Error' "$LOG" | tail -n 20 || true
  exit 1
fi
if [ $RC -ne 0 ] || [ ! -f "$PROJ/entry/build/store/outputs/ohosTest/entry-ohosTest-unsigned.hap" ]; then
  echo "FAIL: build rc=$RC (test hap missing)"
  grep -aE 'ERROR|Error|error' "$LOG" | tail -n 20 || true
  exit 1
fi
cp -f "$PROJ/entry/build/store/outputs/ohosTest/entry-ohosTest-unsigned.hap" "$OUT"
ls -l "$OUT"
echo "DONE_VM_BUILD_TEST"
