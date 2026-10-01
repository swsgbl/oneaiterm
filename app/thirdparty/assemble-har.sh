#!/bin/bash
# 将 x86_64 交叉编译产物组装成本地 HAR (与官方 @ohos/libssh 1.0.4 同构,仅 ABI 不同)
set -e
SRC=/mnt/d/oneaiterm/app/thirdparty
HAR_LOCAL=$SRC/libssh-x86_64-har
OUT=$SRC/out/x86_64
UP=$SRC/ohos_ssh-src/library

# 1) 以官方库源码为骨架
rm -rf $HAR_LOCAL
mkdir -p $HAR_LOCAL
cp -a $UP/. $HAR_LOCAL/

# 2) 塞入 x86_64 预编译产物 (对齐 HAR 内 libs/<abi>/ 布局)
LIBDIR=$HAR_LOCAL/libs/x86_64
mkdir -p $LIBDIR
cp $OUT/lib64/libcrypto.so.3 $LIBDIR/
cp $OUT/lib64/libssl.so.3    $LIBDIR/
cp $OUT/libssh/lib/libssh.so.4 $LIBDIR/
# libc++_shared: 从 SDK 拷贝 (napi wrapper 会链 libc++_shared)
cp "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/lib/x86_64-linux-ohos/libc++_shared.so" $LIBDIR/

# 3) thirdparty 布局: library/src/main/cpp/thirdparty/{libssh,openssl}/x86_64/{include,lib}
TP=$HAR_LOCAL/src/main/cpp/thirdparty
mkdir -p $TP/libssh/x86_64/lib $TP/openssl/x86_64/lib
cp -a $OUT/include $TP/openssl/x86_64/
cp $OUT/lib64/libcrypto.so.3 $OUT/lib64/libssl.so.3 $TP/openssl/x86_64/lib/
cp -a $OUT/libssh/include $TP/libssh/x86_64/
cp $OUT/libssh/lib/libssh.so.4 $TP/libssh/x86_64/lib/

echo "HAR skeleton at $HAR_LOCAL"
ls $LIBDIR
ls $TP/libssh/x86_64/lib
ls $TP/openssl/x86_64/lib
