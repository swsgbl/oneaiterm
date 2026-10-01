#!/bin/bash
# evidence probe: compare libc++ symbol namespaces (SDK vs HAR-bundled) and napi so imports
set -e
SDK_SO="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/lib/x86_64-linux-ohos/libc++_shared.so"
HAR_SO="/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs/x86_64/libc++_shared.so"
NAPI_SO="/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs/x86_64/libssh_ohos_napi.so"
D=/mnt/d/upstream/evidence/M1a
nm -D "$SDK_SO" | c++filt | sort -u > $D/libcpp-sdk-syms.txt
nm -D "$HAR_SO" | c++filt | sort -u > $D/libcpp-har-syms.txt
nm -D --undefined-only "$NAPI_SO" | c++filt | sort -u > $D/napi-undef-syms.txt
echo PROBE_DONE
