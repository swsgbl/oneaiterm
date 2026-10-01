#!/bin/bash
echo "sudo -n test: $(sudo -n true 2>&1; echo rc=$?)"
echo "user: $(whoami)"
echo "apt policy check:"
apt-cache policy clang 2>/dev/null | sed -n '1,5p'
echo "ldd target check: clang available versions:"
apt-cache search --names-only '^clang-[0-9]+$' 2>/dev/null | sort | tail -5
