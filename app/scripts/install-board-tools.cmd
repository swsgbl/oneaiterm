@echo off
REM install-board-tools.cmd - provision the in-app terminal toolbox (M8 toolbox design)
REM
REM WHY: 3rd-party app sandbox mount namespace does NOT contain /data/local
REM (board hmh/node/NDK home - mountinfo-audited 2026-10-07), so board tools can
REM never run from the app terminal by PATH/profile tricks. But exec INSIDE the
REM app sandbox is proven viable, so we copy the toolchain into the app's own
REM files/tools dir; localpty PATH puts files/tools/bin FIRST => hmh etc. work
REM zero-config in the app terminal (jitless node + bundled libc++_shared.so).
REM
REM Run AFTER every vm-deploy (reinstall wipes app files/). Requires the board
REM toolchain at /data/local/home (dsh-pack node + hmh board install).
REM ASCII-only comments per repo convention.

setlocal
set HDC=hdc -t 127.0.0.1:15566
set APPF=/data/app/el2/100/base/com.oneaiterm.terminal/haps/entry/files

echo [tools] 1/4 create dirs
%HDC% shell "mkdir -p %APPF%/tools/bin %APPF%/tools/lib %APPF%/tools/home" || goto :fail

echo [tools] 2/4 copy node + libc++ + hmharness + hmh home config
%HDC% shell "cp /data/local/home/dsh-pack/node/bin/node.bin %APPF%/tools/bin/node" || goto :fail
%HDC% shell "cp /data/app/el1/bundle/public/com.oneaiterm.terminal/libs/x86_64/libc++_shared.so %APPF%/tools/lib/" || goto :fail
%HDC% shell "rm -rf %APPF%/tools/hmharness && cp -r /data/local/home/.local/hmharness %APPF%/tools/hmharness" || goto :fail
%HDC% shell "rm -rf %APPF%/tools/home/hmh-home && cp -r /data/local/home/.hmharness %APPF%/tools/home/hmh-home" || goto :fail

echo [tools] 3/4 hmh launcher (jitless + bundled lib path + sandbox HMH_HOME)
%HDC% file send "%~dp0..\entry\src\main\cpp\tools-hmh-launcher.sh" %APPF%/tools/bin/hmh
%HDC% shell "test -s %APPF%/tools/bin/hmh" || goto :fail
%HDC% shell "chmod 755 %APPF%/tools/bin/hmh %APPF%/tools/bin/node" || goto :fail

echo [tools] 4/4 ownership (hdc writes as root; app uid is 20010060)
%HDC% shell "chown -R 20010060:20010060 %APPF%/tools" || goto :fail
%HDC% shell "ls -la %APPF%/tools/bin/" || goto :fail

echo DONE_BOARD_TOOLS (hmh now on the app terminal PATH)
exit /b 0
:fail
echo FAILED_BOARD_TOOLS
exit /b 1
