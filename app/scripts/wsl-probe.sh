#!/bin/bash
echo "=== toolchain probe ==="
for c in clang clang++ make perl cmake ninja patch xz curl wget tar git; do
  if command -v $c >/dev/null 2>&1; then
    v=$($c --version 2>/dev/null | sed -n 1p)
    echo "OK  $c : $v"
  else
    echo "NO  $c"
  fi
done
echo "=== windows sdk mount check ==="
ls "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin/" 2>/dev/null | grep -E "x86_64|aarch64" | head -5
