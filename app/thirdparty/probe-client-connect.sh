#!/bin/bash
# dump client.c ssh_connect context around the "Couldn't apply options" error
set -e
sed -n '540,620p' /tmp/libssh-src-probe/libssh-0.11.1/src/client.c > /mnt/d/upstream/evidence/M1a/libssh-client-connect.txt
echo DUMP_DONE
