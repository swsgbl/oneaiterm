#!/bin/bash
SDK=/tmp/ohos-sdk-native
echo "--- crt*.o ---"
find $SDK -name "crt*.o" 2>/dev/null | head -10
echo "--- libunwind ---"
find $SDK -name "libunwind*" 2>/dev/null | head -5
echo "--- clang_rt builtins ---"
find $SDK -name "libclang_rt.builtins*" 2>/dev/null | head -5
echo "--- llvm lib dir guesses ---"
ls $SDK/llvm/lib/ 2>/dev/null | head -10
ls $SDK/llvm/lib/x86_64-unknown-linux-ohos 2>/dev/null | head -20
