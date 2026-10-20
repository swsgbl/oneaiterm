#!/system/bin/sh
# vm-sign-install.sh -- device-side sign + install of the repacked main hap
# (com.oneaiterm.terminal). Pushed fresh by vm-deploy.cmd every run because
# /data/local/tmp is tmpfs (VM reboot wipes it).
. /data/local/home/env.sh >/dev/null 2>&1
SIG="$OHOS_HOME/signature"
IN=/data/local/tmp/m7r1-unsigned.hap
OUT=/data/local/tmp/m7r1-signed.hap
BUNDLE=com.oneaiterm.terminal
echo "SIG dir: $SIG"
hap-sign-tool sign-app -keyAlias "OpenHarmony Application Release" -signAlg SHA256withECDSA -mode localSign -appCertFile "$SIG/OpenHarmonyApplication.pem" -profileFile "$SIG/app1-profile-release.p7b" -inFile "$IN" -keystoreFile "$SIG/OpenHarmony.p12" -outFile "$OUT" -keyPwd 123456 -keystorePwd 123456 2>&1 | tail -2
ls -l "$OUT" || exit 1
bm uninstall -n "$BUNDLE" 2>/dev/null
bm install -p "$OUT" || exit 1
echo DONE_M7R1_SIGN_INSTALL
