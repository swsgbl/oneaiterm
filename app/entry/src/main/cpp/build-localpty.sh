#!/bin/bash
# build-localpty.sh — rebuild liblocalpty.so (x86_64 + arm64-v8a) from localpty.cpp
# using the DevEco OHOS NDK toolchain from WSL (same recipe as build-napi-*.sh).
#
# WHY THIS EXISTS (2026-10-07 rot incident): entry/CMakeLists.txt ships PREBUILT
# libs from entry/libs/<abi>/ and never recompiles them. The r6f PATH/HOME fix in
# localpty.cpp never reached the shipped 09-28 prebuilt, so every installed app
# ran a PTY with no PATH at all -> external commands (hmh etc.) "inaccessible or
# not found" in the app terminal while the system terminal (login shell, sources
# /data/local/home/.profile) worked. RULE: any localpty.cpp change MUST be
# followed by `bash build-localpty.sh` here, or it dies in source.
#
# Usage (from WSL):  bash /mnt/d/oneaiterm/app/entry/src/main/cpp/build-localpty.sh [x86_64|arm64-v8a|all]
set -e

SDK_NATIVE="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
SDK_NOLINK=/tmp/ohos-sdk-native
[ -e $SDK_NOLINK ] || ln -s "$SDK_NATIVE" $SDK_NOLINK
SRC="$(cd "$(dirname "$0")" && pwd)/localpty.cpp"
OUT_BASE="/mnt/d/oneaiterm/app/entry/libs"
WANT="${1:-all}"

build_one() {
  local ARCH="$1" TRIPLE="$2" LLVMLIB="$3"
  local SYSROOT="$SDK_NOLINK/sysroot"
  # resource-dir carries crtbeginS/crtendS + libclang_rt builtins per OHOS triple
  local RESOURCE_DIR
  RESOURCE_DIR="$(ls -d "$SDK_NOLINK"/llvm/lib/clang/* | head -1)"
  # libc++ headers must come from the libcxx-ohos tree (__n1 ABI namespace),
  # same as build-napi-*.sh — generic llvm headers produce __1 and fail dlopen.
  local FLAGS="--target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld \
    -resource-dir=$RESOURCE_DIR \
    -L$SDK_NOLINK/llvm/lib/$LLVMLIB -stdlib=libc++ -nostdinc++ \
    -isystem $SDK_NOLINK/llvm/include/libcxx-ohos/include/c++/v1 \
    -shared -fPIC -O2 -std=c++17 \
    -l:libace_napi.z.so -l:libhilog_ndk.z.so"
  mkdir -p "$OUT_BASE/$ARCH"
  clang++ $FLAGS "$SRC" -o "$OUT_BASE/$ARCH/liblocalpty.so"
  echo "== $ARCH =="
  file "$OUT_BASE/$ARCH/liblocalpty.so"
  # sanity: the env strings this build exists to carry must be present
  strings "$OUT_BASE/$ARCH/liblocalpty.so" | grep -q "data/local/home/.local/bin" \
    || { echo "SANITY FAIL: PATH string missing in $ARCH .so"; exit 1; }
  strings "$OUT_BASE/$ARCH/liblocalpty.so" | grep -q "xterm-256color" \
    || { echo "SANITY FAIL: TERM string missing in $ARCH .so"; exit 1; }
  echo "SANITY OK (PATH+TERM strings present)"
}

[ "$WANT" = "x86_64" ] || [ "$WANT" = "all" ] && \
  build_one x86_64 x86_64-unknown-linux-ohos x86_64-linux-ohos
[ "$WANT" = "arm64-v8a" ] || [ "$WANT" = "all" ] && \
  build_one arm64-v8a aarch64-linux-ohos aarch64-linux-ohos
echo "LOCALPTY BUILD DONE ($WANT)"
