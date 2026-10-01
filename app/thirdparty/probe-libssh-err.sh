#!/bin/bash
# locate the "Couldn't apply options" error string inside libssh source tarball
set -e
D=/tmp/libssh-src-probe
rm -rf $D && mkdir -p $D
tar -xf /mnt/d/oneaiterm/app/thirdparty/downloads/libssh-0.11.1.tar.xz -C $D
cd $D/libssh-0.11.1
grep -rn "Couldn't apply options" src/ include/ 2>/dev/null > /mnt/d/upstream/evidence/M1a/libssh-err-search.txt || echo "NOT FOUND in libssh" >> /mnt/d/upstream/evidence/M1a/libssh-err-search.txt
echo SEARCH_DONE
