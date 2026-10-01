#!/bin/bash
# dump SSH_OPTIONS_USER / SSH_OPTIONS_SSH_DIR NULL handling in options.c
set -e
B=/tmp/libssh-src-probe/libssh-0.11.1
grep -n "case SSH_OPTIONS_USER:" $B/src/options.c > /mnt/d/oatuser/evidence/M1a/user-case.txt
grep -n "case SSH_OPTIONS_SSH_DIR:" $B/src/options.c >> /mnt/d/upstream/evidence/M1a/user-case.txt
# dump lines around each hit
awk 'NR>=1 && /case SSH_OPTIONS_USER:/{print NR": "$0}' $B/src/options.c >> /mnt/d/oatuser/evidence/M1a/user-case.txt
echo CASE_DONE
