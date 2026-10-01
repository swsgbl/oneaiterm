#!/bin/bash
SDK=/tmp/ohos-sdk-native
echo "--- sysroot/usr/lib/x86_64-linux-ohos full ---"
ls $SDK/sysroot/usr/lib/x86_64-linux-ohos/ | head -30
echo "--- clang/15.0.4/lib ---"
ls $SDK/llvm/lib/clang/15.0.4/lib/ 2>/dev/null
echo "--- clang/15.0.4/lib/x86_64-linux-ohos ---"
ls $SDK/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos/ 2>/dev/null
