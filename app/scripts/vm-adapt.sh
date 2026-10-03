#!/system/bin/sh
# vm-adapt.sh -- apply the three VM-side adaptations proven in M8-relay0
# to the synced tree. Deterministic sed edits; no manual steps.
#   A1) build-profile.json5: runtimeOS HarmonyOS -> OpenHarmony,
#       version strings "5.0.2(14)"/"6.1.1(24)" -> plain number 14,
#       ensure compileSdkVersion: 14 exists on BOTH products
#       (the default product lacks the key; VM hvigor API14 fails
#       with "SDK component missing"/compileSdkVersion errors without it).
#   A2) module.json5: deviceTypes -> ["default"] only (the OH SDK ships
#       no phone/2in1 syscap sets; mixed list makes the syscap
#       intersection empty -> rpcid check fails).
# (The pack_hap_store.sh marker fix libentry.so->liblocalpty.so belongs to
#  the BUILD stage, which regenerates pack_hap_store.sh from scratch each
#  run -- see vm-build-store.sh.)
# All edits are idempotent (match-then-skip). Usage: vm-adapt.sh
set -e
APP=/data/local/home/tmp/app
BP=$APP/build-profile.json5
MOD=$APP/entry/src/main/module.json5

echo "[adapt] A1 build-profile runtimeOS + sdk versions -> OpenHarmony/14"
sed -i 's/"runtimeOS": *"HarmonyOS"/"runtimeOS": "OpenHarmony"/g' "$BP"
sed -i 's/"\(compatible\|target\)SdkVersion": *"5\.0\.2(14)"/"\1SdkVersion": 14/g' "$BP"
sed -i 's/"\(compatible\|target\)SdkVersion": *"6\.1\.1(24)"/"\1SdkVersion": 14/g' "$BP"
# ensure compileSdkVersion on both products. ANCHOR MATTERS: targets[]
# objects also carry "name": "default"/"store" lines -- anchoring the
# insert on "name" polluted modules[1].targets[1] (schema error 00303038,
# propertyNames compileSdkVersion, M8-relay1 run2). compatibleSdkVersion
# exists ONLY inside product objects, so: strip every compileSdkVersion
# line (also cleans any pollution from older runs), then re-insert after
# each normalized compatibleSdkVersion line. Idempotent by construction.
sed -i '/"compileSdkVersion"/d' "$BP"
sed -i '/"compatibleSdkVersion": 14,/a\        "compileSdkVersion": 14,' "$BP"
N=$(grep -c '"compileSdkVersion"' "$BP")
echo "[adapt] compileSdkVersion count (must be exactly 2, products only): $N"
if [ "$N" -ne 2 ]; then
  echo "FAIL: compileSdkVersion count=$N (expected 2)"; exit 1
fi

echo "[adapt] A2 module.json5 deviceTypes -> [\"default\"]"
sed -i 's/"deviceTypes": *\[[^]]*\]/"deviceTypes": [ "default" ]/' "$MOD"
echo "[adapt] DONE_VM_ADAPT"
