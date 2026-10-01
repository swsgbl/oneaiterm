#!/bin/bash
# M1a todo2: build libssh_ohos_napi.so (x86_64 OHOS) from HAR skeleton napi sources (WSL Ubuntu, clang21+lld)
set -e

SDK_NATIVE="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
SDK_NOLINK=/tmp/ohos-sdk-native
[ -e $SDK_NOLINK ] || ln -s "$SDK_NATIVE" $SDK_NOLINK
SYSROOT="$SDK_NOLINK/sysroot"
RESOURCE_DIR="$SDK_NOLINK/llvm/lib/clang/15.0.4"
OHOS_LLVM_LIB="$SDK_NOLINK/llvm/lib/x86_64-linux-ohos"
TRIPLE=x86_64-unknown-linux-ohos
# M1a relay-4 ABI fix: OHOS libc++ exports std::__n1::* symbols (see
# llvm/include/libcxx-ohos/include/c++/v1/__config_site: _LIBCPP_ABI_NAMESPACE __n1).
# The generic llvm/include/c++/v1 headers use __1 -> relocation failure at dlopen:
#   "_ZNSt3__112basic_string...aSERKS5_: symbol not found" (evidence/M1a/bms-diag.txt)
# So C++ headers MUST come from the libcxx-ohos tree, matching the shipped libc++_shared.so.
XFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB -stdlib=libc++ -nostdinc++ -isystem $SDK_NOLINK/llvm/include/libcxx-ohos/include/c++/v1"

SRC=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/src/main/cpp
BUILD=/tmp/upstream-napi-build
OUTLIB=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs/x86_64
rm -rf $BUILD && mkdir -p $BUILD
cd $BUILD

cmake $SRC \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_C_COMPILER="clang" \
  -DCMAKE_C_FLAGS="$XFLAGS" \
  -DCMAKE_CXX_COMPILER="clang++" \
  -DCMAKE_CXX_FLAGS="$XFLAGS" \
  -DCMAKE_FIND_ROOT_PATH="$SYSROOT" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DOHOS_ARCH=x86_64 \
  -DCMAKE_EXE_LINKER_FLAGS="$XFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$XFLAGS" \
  -DCMAKE_BUILD_TYPE=Release \
  -G Ninja > cmake.log 2>&1 || { echo "== cmake FAIL =="; tail -40 cmake.log; exit 1; }
ninja > build.log 2>&1 || { echo "== ninja FAIL =="; tail -60 build.log; exit 1; }
cp -f $BUILD/libssh_ohos_napi.so $OUTLIB/
echo "NAPI BUILD DONE"
ls -la $OUTLIB/
file $OUTLIB/libssh_ohos_napi.so
