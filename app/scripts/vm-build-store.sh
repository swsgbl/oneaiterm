#!/system/bin/sh
# vm-build-store.sh -- build the store product on the VM, self-healing the
# pack_hap_store.sh wrapper from the stock /data/local/home/.local/bin/pack_hap.sh
# on every run (7 seds proven in M8-relay0):
#   1. product=default -> store           (2. module=entry@default -> entry@store)
#   3. intermediates inner default/ -> store/   (INTER line)
#   4. outputs default/ -> store/ + entry-default-unsigned.hap -> entry-store-unsigned.hap
#   5. loader_out/res/syscap/loader/source_map/stripped_native_libs/libs default->store
#   6. hvigor -p product=store
#   7. libentry.so -> liblocalpty.so   (this repo's cmake product name;
#      the stock marker never matches -> hap silently packs 0 .so)
# Runs the build under timeout 280, prints the hvigor tail on failure.
# Output hap: /data/local/home/tmp/app/out_release.hap
set -e
SRC=/data/local/home/.local/bin/pack_hap.sh
DST=/data/local/home/.local/bin/pack_hap_store.sh
PROJ=/data/local/home/tmp/app
LOG=/data/local/tmp/vmchain-build.log

echo "[build] regenerate $DST from stock pack_hap.sh (self-heal)"
cp -f "$SRC" "$DST"
chmod +x "$DST"
sed -i 's/-p product=default/-p product=store/' "$DST"
sed -i 's/-p module=entry@default/-p module=entry@store/' "$DST"
sed -i 's|INTER="$PROJ/entry/build/default/intermediates"|INTER="$PROJ/entry/build/store/intermediates"|' "$DST"
sed -i 's|OUT="$PROJ/entry/build/default/outputs/default"|OUT="$PROJ/entry/build/store/outputs/store"|' "$DST"
sed -i 's|UNSIGNED="$OUT/entry-default-unsigned.hap"|UNSIGNED="$OUT/entry-store-unsigned.hap"|' "$DST"
# catch every remaining inner path segment (loader_out/res/syscap/loader/
# source_map/stripped_native_libs/libs + debug cache paths): product=store
# lays these out under the "store" target dir. "product=default" and
# "entry@default" carry no slashes and are handled above; the unsigned hap
# name has no flanking slash either -- all safe for this global form.
sed -i 's|/default/|/store/|g' "$DST"
sed -i 's/libentry\.so/liblocalpty.so/' "$DST"
N=$(grep -c 'store' "$DST")
echo "[build] store-marker count in $DST: $N"
if ! grep -q 'entry@store' "$DST" || ! grep -q 'product=store' "$DST"; then
  echo "FAIL: sed regeneration incomplete"; exit 1
fi

cd "$PROJ"
# ohpm deps: the tar sync wipes the tree so no oh_modules survive, and
# pack_hap.sh never runs ohpm install -- without this, file: deps like
# @ohos/libssh never resolve (13 CompileArkTS "Cannot find module"
# cascade errors, M8-relay1 run4b). env.sh gives ohpm/node PATH.
export HOME=/data/local/home
. /data/local/home/env.sh >/dev/null 2>&1 || true
if [ ! -d "$PROJ/entry/oh_modules/@ohos/libssh" ]; then
  echo "[build] ohpm install (entry oh_modules missing)"
  set +e
  ohpm install --all
  OHPM_RC=$?
  set -e
  if [ $OHPM_RC -ne 0 ] || [ ! -d "$PROJ/entry/oh_modules/@ohos/libssh" ]; then
    echo "FAIL: ohpm install rc=$OHPM_RC or libssh link missing"
    exit 1
  fi
fi
echo "[build] timeout 280 pack_hap_store.sh $PROJ (log: $LOG)"
rm -f "$LOG"
set +e
timeout 280 "$DST" "$PROJ" > "$LOG" 2>&1
RC=$?
set -e
echo "[build] rc=$RC"
tail -n 25 "$LOG"
if [ $RC -ne 0 ] || [ ! -f "$PROJ/out_release.hap" ]; then
  echo "FAIL: build rc=$RC (hap missing? $( [ -f "$PROJ/out_release.hap" ] && echo no || echo yes ))"
  echo "FAIL: full log at $LOG on VM; error tail follows:"
  grep -aE 'ERROR|Error|error' "$LOG" | tail -n 20 || true
  exit 1
fi
ls -l "$PROJ/out_release.hap"
echo "DONE_VM_BUILD_STORE"
