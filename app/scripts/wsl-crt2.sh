#!/bin/bash
SDK=/tmp/ohos-sdk-native
echo "--- x86_64-linux-ohos dir ---"
ls $SDK/llvm/lib/x86_64-linux-ohos/ 2>/dev/null
echo "--- x86_64-linux-ohos/usc ---"
ls $SDK/llvm/lib/x86_64-linux-ohos/usc 2>/dev/null | head -20
echo "--- sysroot usr/lib/x86_64 ---"
ls $SDK/sysroot/usr/lib/x86_64-unknown-linux-ohos/ 2>/dev/null | head -20
echo "--- clang resource dir in sysroot? ---"
find $SDK/sysroot -maxdepth 3 -name "crtbegin*" 2>/dev/null | head -5
