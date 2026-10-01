#!/bin/bash
S=/mnt/d/oneaiterm/app/thirdparty/libssh-x86_64-har/libs/x86_64/libssh_ohos_napi.so
echo "== NEEDED:"; readelf -d $S | grep -E 'NEEDED|SONAME'
echo "== banner symbols:"; nm -D $S | grep -iE 'banner' || echo "(none dynamic)"
nm $S 2>/dev/null | grep -iE 'FetchServerBanner|GetServerBanner' | head -5
