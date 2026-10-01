#!/bin/bash
echo "--- last 15 lines of build log ---"
tail -15 /tmp/upstream-build.log
echo "--- out/x86_64/lib ---"
ls /mnt/d/oneaiterm/app/thirdparty/out/x86_64/lib/ 2>/dev/null || echo "(not yet)"
echo "--- build processes ---"
pgrep -a make | head -3
pgrep -a ninja | head -3
echo "--- done marker ---"
grep -E "OPENSSL DONE|LIBSSH DONE|ALL DONE|Error|error:" /tmp/upstream-build.log | tail -10 || true
