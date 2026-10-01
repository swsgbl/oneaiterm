#!/bin/bash
# 同步执行构建,日志同时落到 /mnt/d (宿主可见)
set -o pipefail
tr -d '\r' < /mnt/d/oneaiterm/app/thirdparty/build-x86_64.sh > /tmp/b.sh
bash /tmp/b.sh 2>&1 | tee /mnt/d/upstream/evidence/M1a/xbuild.log
echo "BUILD_RC=$?"
