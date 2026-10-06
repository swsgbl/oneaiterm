#!/bin/bash
# M8 relay12: compile-face gold verification for arm64 libssh_ohos_napi.so
# Usage (from Windows): wsl -e bash /mnt/d/oneaiterm/app/thirdparty/verify-arm64.sh [old|new]
MODE="${1:-old}"
LIBS=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs
OUT=/mnt/d/oneaiterm/.verify/m8r12
SO="$LIBS/arm64-v8a/libssh_ohos_napi.so"
X86="$LIBS/x86_64/libssh_ohos_napi.so"

flt() { grep -iE 'Tunnel|zm[A-Z]|SONAME|NEEDED|Machine'; }

sym() { nm -D --defined-only "$1" | awk '{print $NF}' | sort; }

echo "== MODE: $MODE =="
echo "== [A3] readelf -h =="
readelf -h "$SO" | flt
echo "== [A1/A4] readelf -d =="
readelf -d "$SO" | flt
echo "== [A2] tunnel/zm exported symbols =="
nm -D --defined-only "$SO" | flt | sort

echo "== [A2-diff] x86 vs arm64 full defined-symbol diff =="
sym "$X86" > /tmp/sym-x86.txt
sym "$SO"  > /tmp/sym-arm64.txt
echo "-- only in x86 (missing from arm64):"
comm -23 /tmp/sym-x86.txt /tmp/sym-arm64.txt
echo "-- only in arm64 (extra):"
comm -13 /tmp/sym-x86.txt /tmp/sym-arm64.txt
echo "-- counts: x86=$(wc -l < /tmp/sym-x86.txt) arm64=$(wc -l < /tmp/sym-arm64.txt)"

echo "== [A4] arm64 prebuilt deps present =="
ls -la /mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/src/main/cpp/thirdparty/libssh/arm64-v8a/lib/
ls -la /mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/src/main/cpp/thirdparty/openssl/arm64-v8a/lib/

echo "== file =="
file "$SO"
