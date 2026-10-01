#!/bin/bash
# M4 relay-1: cross-compile openssl-3.5.4 + libssh-0.11.1 + libssh_ohos_napi for arm64-v8a OHOS
# (aarch64-linux-ohos), staging into the HAR:
#   libs/arm64-v8a/                      (runtime .so set, next to libs/x86_64/)
#   src/main/cpp/thirdparty/*/arm64-v8a/ (headers + link libs for the napi build)
# Same toolchain/recipe as build-x86_64.sh + build-napi-x86_64.sh, target switched to aarch64.
# Idempotent: each phase guarded by its output file, safe to rerun on timeout.
set -e

SDK_NATIVE="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
SDK_NOLINK=/tmp/ohos-sdk-native
[ -e $SDK_NOLINK ] || ln -s "$SDK_NATIVE" $SDK_NOLINK
SYSROOT="$SDK_NOLINK/sysroot"
RESOURCE_DIR="$SDK_NOLINK/llvm/lib/clang/15.0.4"
OHOS_LLVM_LIB="$SDK_NOLINK/llvm/lib/aarch64-linux-ohos"
TRIPLE=aarch64-linux-ohos

SRC=/mnt/d/oneaiterm/app/thirdparty
WORK=/tmp/upstream-xbuild-arm64
OUT=$SRC/out/arm64-v8a
HAR=$SRC/libssh-x86_64-har
mkdir -p $WORK $OUT

CC="clang --target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"
CXX="clang++ --target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"
XFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"

cd $WORK

# ---------- openssl 3.5.4 (arm64) ----------
if [ ! -f $OUT/lib/libcrypto.so.3 ]; then
  if [ ! -d openssl-3.5.4 ]; then
    tar xf $SRC/downloads/openssl-3.5.4.tar.gz
  fi
  if [ ! -f $WORK/openssl-3.5.4/.ohos_patched ]; then
    cd openssl-3.5.4
    patch -p1 --forward < $SRC/ohos_ssh-src/doc/openssl-3.5.4/armcap-ohos-support.patch || true
    touch .ohos_patched
    cd ..
  fi
  mkdir -p ossl-build && cd ossl-build
  CC="$CC" CXX="$CXX" \
  perl ../openssl-3.5.4/Configure linux-aarch64 shared no-tests no-threads \
    --prefix=$OUT \
    -DNDEBUG -O2 > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
  make -j8 > build.log 2>&1 || { tail -30 build.log; exit 1; }
  make install_sw >> build.log 2>&1 || { tail -20 build.log; exit 1; }
  cd $WORK
fi
echo "OPENSSL DONE"
ls -la $OUT/lib/

# ---------- libssh 0.11.1 (arm64) ----------
if [ ! -f $OUT/libssh/lib/libssh.so.4 ]; then
  if [ ! -d libssh-0.11.1 ]; then
    tar xf $SRC/downloads/libssh-0.11.1.tar.xz
  fi
  if [ ! -f $WORK/libssh-0.11.1/.ohos_patched ]; then
    cd libssh-0.11.1
    patch -p1 --forward < $SRC/ohos_ssh-src/doc/libssh/libssh_oh_pkg.patch || true
    touch .ohos_patched
    cd ..
  fi
  mkdir -p libssh-build && cd libssh-build
  cmake ../libssh-0.11.1 \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_C_COMPILER="clang" \
    -DCMAKE_C_FLAGS="$XFLAGS" \
    -DCMAKE_CXX_COMPILER="clang++" \
    -DCMAKE_CXX_FLAGS="$XFLAGS" \
    -DCMAKE_FIND_ROOT_PATH="$SYSROOT;$OUT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_INSTALL_PREFIX=$OUT/libssh \
    -DOPENSSL_ROOT_DIR=$OUT \
    -DOPENSSL_INCLUDE_DIR=$OUT/include \
    -DOPENSSL_CRYPTO_LIBRARY=$OUT/lib/libcrypto.so.3 \
    -DOPENSSL_SSL_LIBRARY=$OUT/lib/libssl.so.3 \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_EXAMPLES=OFF -DWITH_SERVER=ON -DWITH_STATIC_LIB=OFF \
    -DUNIT_TESTING=OFF -DCLIENT_TESTING=OFF -DSERVER_TESTING=OFF -DWITH_PCAP=OFF \
    -DWITH_DEBUG_CALLTRACE=OFF -DWITH_DEBUG_CRYPTO=OFF \
    -G Ninja > cmake.log 2>&1 || { tail -30 cmake.log; exit 1; }
  ninja > build.log 2>&1 || { tail -40 build.log; exit 1; }
  ninja install >> build.log 2>&1 || { tail -20 build.log; exit 1; }
  # 对齐官方 HAR 命名: libssh.so.4
  rm -f $OUT/libssh/lib/libssh.so $OUT/libssh/lib/libssh.so.4
  mv $OUT/libssh/lib/libssh.so.4.10.1 $OUT/libssh/lib/libssh.so.4
  cd $WORK
fi
echo "LIBSSH DONE"
ls -la $OUT/libssh/lib/

# ---------- stage headers + link libs into HAR cpp/thirdparty (mirrors x86_64 layout) ----------
OSS=$HAR/src/main/cpp/thirdparty/openssl/arm64-v8a
LSH=$HAR/src/main/cpp/thirdparty/libssh/arm64-v8a
mkdir -p $OSS/include $OSS/lib $LSH/include $LSH/lib
rm -rf $OSS/include/openssl $LSH/include/libssh
cp -rf $OUT/include/openssl $OSS/include/
cp -f $OUT/lib/libcrypto.so.3 $OUT/lib/libssl.so.3 $OSS/lib/
cp -rf $OUT/libssh/include/libssh $LSH/include/
cp -f $OUT/libssh/lib/libssh.so.4 $LSH/lib/
echo "STAGED cpp/thirdparty/*/arm64-v8a"

# ---------- napi module (delegates to build-napi-arm64.sh) ----------
bash $SRC/build-napi-arm64.sh

# ---------- runtime .so set into HAR libs/arm64-v8a ----------
mkdir -p $HAR/libs/arm64-v8a
cp -f $OUT/libssh/lib/libssh.so.4 $HAR/libs/arm64-v8a/
cp -f $OUT/lib/libcrypto.so.3 $OUT/lib/libssl.so.3 $HAR/libs/arm64-v8a/
# libc++_shared.so: SDK aarch64 build (matches the __n1 headers we compile against)
cp -f "$SDK_NOLINK/llvm/lib/aarch64-linux-ohos/libc++_shared.so" $HAR/libs/arm64-v8a/
echo "HAR libs/arm64-v8a DONE"
ls -la $HAR/libs/arm64-v8a/
echo "ALL DONE -> $OUT"
