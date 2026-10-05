#!/system/bin/sh
# vm-sign-install-test.sh -- device-side sign + CO-EXIST install of the
# entry_test module hap (M8-relay8). RED LINE: never uninstalls the main
# bundle -- entry_test is a feature module that lives in the SAME bundle
# (com.oneaiterm.terminal); `bm install -p` upgrades/adds the module
# alongside the installed entry hap.
. /data/local/home/env.sh >/dev/null 2>&1
SIG="$OHOS_HOME/signature"
IN=/data/local/tmp/m8r8-test-unsigned.hap
OUT=/data/local/tmp/m8r8-test-signed.hap
BUNDLE=com.oneaiterm.terminal
echo "SIG dir: $SIG"
hap-sign-tool sign-app -keyAlias "OpenHarmony Application Release" -signAlg SHA256withECDSA -mode localSign -appCertFile "$SIG/OpenHarmonyApplication.pem" -profileFile "$SIG/app1-profile-release.p7b" -inFile "$IN" -keystoreFile "$SIG/OpenHarmony.p12" -outFile "$OUT" -keyPwd 123456 -keystorePwd 123456 2>&1 | tail -2
ls -l "$OUT" || exit 1
bm install -p "$OUT"
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL: bm install rc=$RC"
  exit 1
fi
echo "DONE_M8R8_TEST_INSTALL"
