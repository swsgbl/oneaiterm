@echo off
REM package-tools.cmd - build rawfile/tools.zip (the in-app terminal toolbox payload)
REM
REM Pulls files/tools from the VM app sandbox (provisioned by install-board-tools.cmd
REM or a previous run), repacks as a ZIP with top-level tools/ prefix, and writes it
REM to entry/src/main/resources/rawfile/tools.zip. The app auto-extracts this zip on
REM first local-terminal open (ToolsInstaller.ensure) - so ANY user installing the
REM built hap gets hmh/node zero-config. The zip is gitignored (38MB binary);
REM run this script whenever the board toolchain updates, then rebuild the hap.
REM ASCII-only comments per repo convention.

setlocal
set HDC=hdc -t 127.0.0.1:15566
set APPF=/data/app/el2/100/base/com.oneaiterm.terminal/haps/entry/files
set OUTDIR=D:\oneaiterm\app\entry\src\main\resources\rawfile
set WORK=D:\oneaiterm\.verify\tools-pkg

echo [pkg] 1/4 provision check (run install-board-tools.cmd first if this fails)
%HDC% shell "test -x %APPF%/tools/bin/hmh" || (echo FAILED: %APPF%/tools/bin/hmh missing & exit /b 1)

echo [pkg] 2/4 pack on device + pull
%HDC% shell "cd %APPF% && rm -f /data/local/tmp/tools-pkg.tgz && tar czf /data/local/tmp/tools-pkg.tgz tools"
if not exist "%WORK%" mkdir "%WORK%"
%HDC% file recv /data/local/tmp/tools-pkg.tgz "%WORK%\tools.tgz"
%HDC% shell "rm -f /data/local/tmp/tools-pkg.tgz"

echo [pkg] 3/4 rezip via WSL python (zip top-level prefix = tools/)
wsl -e bash -c "cd /tmp && rm -rf tools-repack && mkdir tools-repack && tar xzf /mnt/d/oneaiterm/.verify/tools-pkg/tools.tgz -C tools-repack 2>/dev/null; python3 /mnt/d/oneaiterm/.verify/m8r13/mkzip.py /tmp/tools-repack /mnt/d/oneaiterm/app/entry/src/main/resources/rawfile/tools.zip"
if not exist "%OUTDIR%\tools.zip" (echo FAILED: zip not produced & exit /b 1)

echo [pkg] 4/4 result
for %%F in ("%OUTDIR%\tools.zip") do echo tools.zip = %%~zF bytes
echo DONE_PACKAGE_TOOLS - rebuild the hap to embed (vm-deploy / build.cmd)
exit /b 0
