#!/bin/bash
echo "--- official arm64 napi so deps ---"
readelf -d /mnt/d/oneaiterm/app/entry/oh_modules/@ohos/libssh/libs/arm64-v8a/libssh_ohos_napi.so | grep -E "SONAME|NEEDED"
echo "--- official napi module name (test import path) ---"
strings /mnt/d/oneaiterm/app/entry/oh_modules/@ohos/libssh/libs/arm64-v8a/libssh_ohos_napi.so | grep -E "^libssh_ohos_napi" | head -3
