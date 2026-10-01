#!/bin/bash
# find ssh_options_apply failure point: dump options.c around getaddrinfo/hostname handling
set -e
B=/tmp/libssh-src-probe/libssh-0.11.1
grep -n "ssh_options_apply" $B/src/options.c > /mnt/d/upstream/evidence/M1a/opt-apply-line.txt
# dump function body (heuristic: from definition to next function at col 0)
awk '/^int ssh_options_apply/,/^}/' $B/src/options.c > /mnt/d/upstream/evidence/M1a/opt-apply-body.txt
echo APPLY_DONE
