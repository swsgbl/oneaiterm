#!/system/bin/sh
# vm-ohpm.sh -- VM-side ohpm install for the synced tree (M8-relay1).
# The tar sync deliberately wipes the whole tree (no oh_modules survive),
# and pack_hap.sh does NOT run ohpm install -- so file: deps like
# @ohos/libssh never resolve and CompileArkTS fails with "Cannot find
# module '@ohos/libssh'" (13 cascade errors, run4b). This script sources
# env.sh (PATH for ohpm/node), installs all deps, and verifies the
# @ohos/libssh link exists under entry/oh_modules.
set -e
export HOME=/data/local/home
. /data/local/home/env.sh >/dev/null 2>&1 || true
cd /data/local/home/tmp/app
echo "[ohpm] installing all deps (offline file: deps)"
set +e
ohpm install --all
RC=$?
set -e
echo "[ohpm] rc=$RC"
if [ -d entry/oh_modules/@ohos/libssh ] || [ -d oh_modules/@ohos/libssh ]; then
  echo "[ohpm] @ohos/libssh link present"
else
  echo "FAIL: @ohos/libssh still missing after install"
  exit 1
fi
if [ $RC -ne 0 ]; then
  echo "FAIL: ohpm install rc=$RC"
  exit 1
fi
echo DONE_VM_OHPM
