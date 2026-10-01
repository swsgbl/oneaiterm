#!/bin/bash
command -v ld.lld >/dev/null 2>&1 && echo "lld OK: $(ld.lld --version | head -1)" || { echo "installing lld..."; sudo -n apt-get install -y lld >/dev/null 2>&1; command -v ld.lld >/dev/null 2>&1 && echo "lld installed: $(ld.lld --version | head -1)" || echo "lld MISSING"; }
ls /usr/bin/*lld* 2>/dev/null | head -5
