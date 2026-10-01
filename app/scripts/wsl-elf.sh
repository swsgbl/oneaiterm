#!/bin/bash
OUT=/mnt/d/oneaiterm/app/thirdparty/out/x86_64
echo "--- ELF headers ---"
for f in $OUT/lib64/libcrypto.so.3 $OUT/lib64/libssl.so.3 $OUT/libssh/lib/libssh.so.4; do
  file "$f" 2>/dev/null || readelf -h "$f" | head -3
done
echo "--- SONAME / NEEDED ---"
readelf -d $OUT/libssh/lib/libssh.so.4 2>/dev/null | grep -E "SONAME|NEEDED"
echo "---"
readelf -d $OUT/lib64/libcrypto.so.3 2>/dev/null | grep -E "SONAME|NEEDED"
