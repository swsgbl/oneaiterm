#!/bin/bash
set -e
if ! command -v clang >/dev/null 2>&1; then
  sudo -n apt-get install -y clang >/dev/null 2>&1 || sudo -n apt-get install -y clang
fi
clang --version | sed -n 1p
echo "triple test:"
echo 'int main(){return 0;}' > /tmp/t.c
clang --target=x86_64-unknown-linux-ohos --sysroot="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot" -c /tmp/t.c -o /tmp/t.o && echo "OHOS x86_64 target OK" || echo "OHOS target FAIL"
