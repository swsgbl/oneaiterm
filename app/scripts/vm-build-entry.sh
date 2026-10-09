#!/system/bin/sh
# vm-build-entry.sh -- build the MAIN entry module (product=store, target=
# default) on the KaihongOS VM, for tty7-M2a device acceptance.
# Derived from pack_hap.sh with ONLY the product axis sed'd (default->store);
# the target stays @default (unlike vm-build-test.sh which also swaps target).
# Output: /data/local/home/tmp/app/out_entry-signed.hap (script signs itself).
set -e
SRC=/data/local/home/.local/bin/pack_hap.sh
DST=/data/local/home/.local/bin/pack_hap_entry.sh
PROJ=/data/local/home/tmp/app
LOG=/data/local/tmp/m2a-entry-build.log
OUT=/data/local/home/tmp/app/out_entry-signed.hap

echo "[ebuild] regenerate $DST from stock pack_hap.sh"
cp -f "$SRC" "$DST"
chmod +x "$DST"
# ---- product axis ONLY: module target default->store (store product's
# entry targets list ONLY 'store'; entry@default is not executable ->
# "No output will be generated" + modules.abc never produced). Inner
# /default/ segments are TARGET-level paths in hvigor layout
# (build/store/intermediates/store/...), same double-axis as vm-build-test.
sed -i 's/-p product=default/-p product=store/' "$DST"
sed -i 's/-p module=entry@default/-p module=entry@store/' "$DST"
sed -i 's|INTER="$PROJ/entry/build/default/intermediates"|INTER="$PROJ/entry/build/store/intermediates"|' "$DST"
sed -i 's|OUT="$PROJ/entry/build/default/outputs/default"|OUT="$PROJ/entry/build/store/outputs/store"|' "$DST"
sed -i 's|UNSIGNED="$OUT/entry-default-unsigned.hap"|UNSIGNED="$OUT/entry-store-unsigned.hap"|' "$DST"
sed -i 's|/default/|/store/|g' "$DST"
sed -i 's/libentry\.so/liblocalpty.so/' "$DST"
if ! grep -q 'product=store' "$DST" || ! grep -q 'build/store/intermediates' "$DST" || ! grep -q 'entry@store' "$DST"; then
  echo "FAIL: sed regeneration incomplete"; exit 1
fi
echo "[ebuild] sed ok (entry@store, product=store)"

cd "$PROJ"
export HOME=/data/local/home
. /data/local/home/env.sh >/dev/null 2>&1 || true
if [ ! -d "$PROJ/entry/oh_modules/@ohos/hypium" ]; then
  echo "[ebuild] ohpm install (hypium missing)"
  set +e
  ohpm install --all
  OHPM_RC=$?
  set -e
  if [ $OHPM_RC -ne 0 ]; then
    echo "FAIL: ohpm install rc=$OHPM_RC"
    exit 1
  fi
fi
echo "[ebuild] timeout 280 pack_hap_entry.sh (log: $LOG)"
rm -f "$LOG"
set +e
timeout 280 "$DST" -o "$OUT" "$PROJ" > "$LOG" 2>&1
RC=$?
set -e
echo "[ebuild] rc=$RC"
tail -n 15 "$LOG"
if grep -aq '===== BUILD FAILED' "$LOG"; then
  echo "FAIL: pack_hap declared fatal BUILD FAILED (rc=$RC)"
  grep -aE 'ERROR|Error' "$LOG" | tail -n 20 || true
  exit 1
fi
if [ ! -f "$OUT" ]; then
  echo "FAIL: build rc=$RC (signed hap missing)"
  grep -aE 'ERROR|Error|error' "$LOG" | tail -n 20 || true
  exit 1
fi
ls -l "$OUT"
echo "DONE_VM_BUILD_ENTRY"
