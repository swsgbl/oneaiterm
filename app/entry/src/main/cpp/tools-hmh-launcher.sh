#!/system/bin/sh
# OneAITerm in-sandbox hmh launcher (app-namespace paths only).
# NOTE: ctx.filesDir = /data/storage/el2/base/haps/entry/files (haps/entry segment!)
# Forced jitless: app sandbox uids forbid RWX; V8 JIT would SIGTRAP
# (same reason the board's .ohos node wrapper defaults to --jitless).
T=/data/storage/el2/base/haps/entry/files/tools
export HOME="$T/home"
[ -z "${HMH_HOME:-}" ] && export HMH_HOME="$HOME/hmh-home"
# node.bin NEEDS libc++_shared.so - absent from sandbox /lib; bundled beside
export LD_LIBRARY_PATH="$T/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
case " ${NODE_OPTIONS:-} " in
  *" --jitless "*) ;;
  *) export NODE_OPTIONS="--jitless${NODE_OPTIONS:+ $NODE_OPTIONS}" ;;
esac
exec "$T/bin/node" "$T/hmharness/node_modules/@hmharness/cli/dist/main.js" "$@"
