#!/bin/bash
# M4 relay-1 todo A: build libssh_ohos_napi.so (arm64-v8a OHOS) from HAR skeleton napi sources (WSL Ubuntu, clang21+lld)
# Same toolchain/recipe as build-napi-x86_64.sh, target switched to aarch64-linux-ohos:
#   - llvm lib dir       x86_64-linux-ohos -> aarch64-linux-ohos
#   - C++ headers still from libcxx-ohos tree (std::__n1 ABI, see build-napi-x86_64.sh header comment)
# Output goes to libs/arm64-v8a/ next to libs/x86_64/ (OHOS multi-ABI HAR convention), HAR dir name unchanged.
set -e

SDK_NATIVE="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
SDK_NOLINK=/tmp/ohos-sdk-native
[ -e $SDK_NOLINK ] || ln -s "$SDK_NATIVE" $SDK_NOLINK
SYSROOT="$SDK_NOLINK/sysroot"
RESOURCE_DIR="$SDK_NOLINK/llvm/lib/clang/15.0.4"
OHOS_LLVM_LIB="$SDK_NOLINK/llvm/lib/aarch64-linux-ohos"
TRIPLE=aarch64-linux-ohos
XFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB -stdlib=libc++ -nostdinc++ -isystem $SDK_NOLINK/llvm/include/libcxx-ohos/include/c++/v1"

SRC=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/src/main/cpp
BUILD=/tmp/upstream-napi-build-arm64
OUTLIB=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs/arm64-v8a
mkdir -p $OUTLIB
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
  -DOHOS_ARCH=arm64-v8a \
  -DCMAKE_EXE_LINKER_FLAGS="$XFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$XFLAGS" \
  -DCMAKE_BUILD_TYPE=Release \
  -G Ninja > cmake.log 2>&1 || { echo "== cmake FAIL =="; tail -40 cmake.log; exit 1; }
ninja > build.log 2>&1 || { echo "== ninja FAIL =="; tail -60 build.log; exit 1; }
cp -f $BUILD/libssh_ohos_napi.so $OUTLIB/
echo "NAPI BUILD DONE"
ls -la $OUTLIB/
file $OUTLIB/libssh_ohos_napi.so
