#!/bin/bash
# M1a: 交叉编译 openssl-3.5.4 + libssh-0.11.1 (x86_64 OHOS)
# 用法: bash build-x86_64.sh  (在 WSL Ubuntu 内运行)
set -e

SDK_NATIVE="/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
# 空格路径会破坏 openssl Makefile 的变量展开,做无空格软链
SDK_NOLINK=/tmp/ohos-sdk-native
[ -e $SDK_NOLINK ] || ln -s "$SDK_NATIVE" $SDK_NOLINK
SYSROOT="$SDK_NOLINK/sysroot"
# Ubuntu clang 21 需显式指向 SDK clang15 资源目录(crtbegin/crtend/builtins/libunwind 都在那里)
RESOURCE_DIR="$SDK_NOLINK/llvm/lib/clang/15.0.4"
OHOS_LLVM_LIB="$SDK_NOLINK/llvm/lib/x86_64-linux-ohos"
TRIPLE=x86_64-unknown-linux-ohos
CC="clang --target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"
CXX="clang++ --target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"

SRC=/mnt/d/oneaiterm/app/thirdparty
WORK=/tmp/upstream-xbuild
OUT=$SRC/out/x86_64
mkdir -p $WORK $OUT

cd $WORK

# ---------- openssl 3.5.4 ----------
if [ ! -f $OUT/lib64/libcrypto.so.3 ]; then
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
  perl ../openssl-3.5.4/Configure linux-x86_64 shared no-tests no-threads \
    --prefix=$OUT \
    -DNDEBUG -O2 > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
  make -j8 > build.log 2>&1 || { tail -30 build.log; exit 1; }
  make install_sw >> build.log 2>&1 || { tail -20 build.log; exit 1; }
  cd $WORK
fi
echo "OPENSSL DONE"
ls -la $OUT/lib64/

# ---------- libssh 0.11.1 ----------
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
XFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -fuse-ld=lld -resource-dir=$RESOURCE_DIR -L$OHOS_LLVM_LIB"
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
    -DOPENSSL_CRYPTO_LIBRARY=$OUT/lib64/libcrypto.so.3 \
    -DOPENSSL_SSL_LIBRARY=$OUT/lib64/libssl.so.3 \
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
echo "ALL DONE -> $OUT"
