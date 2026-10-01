#!/bin/bash
SDK=/tmp/ohos-sdk-native
echo "--- sysroot layout ---"
ls $SDK/sysroot/ 2>/dev/null
ls $SDK/sysroot/usr/ 2>/dev/null
echo "--- sysroot/usr/lib ---"
ls $SDK/sysroot/usr/lib/ 2>/dev/null | head
echo "--- find crt in whole native sdk (maxdepth 6) ---"
find -L $SDK -maxdepth 6 \( -name "crtbeginS.o" -o -name "Scrt1.o" -o -name "crti.o" \) 2>/dev/null | head -10
echo "--- clang version dirs in llvm/lib/clang ---"
ls $SDK/llvm/lib/clang/ 2>/dev/null
ls $SDK/llvm/lib/clang/*/lib/ 2>/dev/null
ls $SDK/llvm/lib/clang/*/lib/x86_64-unknown-linux-ohos/ 2>/dev/null | head
