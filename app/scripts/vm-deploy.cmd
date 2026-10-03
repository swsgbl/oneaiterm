@echo off
setlocal enabledelayedexpansion
rem vm-deploy.cmd -- ONE-COMMAND deploy of D:\oneaiterm\app to the KaihongOS VM
rem (127.0.0.1:15566): sync -> adapt -> build(+ohpm) -> repack -> install
rem [+ /smoke]. Evidence dir: .verify\m8r1\ . Stage logs land there too.
rem Idempotent: safe to re-run; every stage verifies its own result before
rem moving on. BUILD runs ohpm install first when entry/oh_modules is
rem missing (the tar sync wipes the tree, so @ohos/libssh file: deps
rem never resolve without it -- 13 CompileArkTS cascade errors otherwise).
rem Usage: app\scripts\vm-deploy.cmd [/smoke]

set "REPO=%~dp0..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
set "APP=%REPO%\app"
set "SCR=%APP%\scripts"
set "EV=%REPO%\.verify\m8r1"
set "PY=C:\Users\hongfu\AppData\Local\mise\shims\python.exe"
set "HDC=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
set "T=-t 127.0.0.1:15566"
set "VMROOT=/data/local/home/tmp/app"

if not exist "%EV%" mkdir "%EV%"

echo ===== VM-DEPLOY START %date% %time% =====
echo repo=%REPO%

rem ---- stage 0: device online ----
"%HDC%" %T% shell "echo online" >"%EV%\stage0-online.txt" 2>&1
findstr /C:"online" "%EV%\stage0-online.txt" >nul || goto :fail_online
echo [0/6] device online

rem ---- stage 1: SYNC ----
echo [1/6] SYNC repo to %VMROOT%
"%PY%" "%SCR%\sync_vm.py" --push --prune >"%EV%\stage1-sync.log" 2>&1
if errorlevel 1 goto :fail_sync
findstr /C:"VM_FIND_COUNT" "%EV%\stage1-sync.log"
echo [1/6] SYNC ok

rem ---- stage 2: ADAPT ----
echo [2/6] ADAPT apply VM-side adaptations
"%HDC%" %T% file send "%SCR%\vm-adapt.sh" /data/local/tmp/vm-adapt.sh >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-adapt.sh" >"%EV%\stage2-adapt.log" 2>&1
findstr /C:"DONE_VM_ADAPT" "%EV%\stage2-adapt.log" >nul || goto :fail_adapt
type "%EV%\stage2-adapt.log"
echo [2/6] ADAPT ok

rem ---- stage 3: BUILD ----
echo [3/6] BUILD store product on VM (timeout 280, may take minutes)
"%HDC%" %T% file send "%SCR%\vm-build-store.sh" /data/local/tmp/vm-build-store.sh >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-build-store.sh" >"%EV%\stage3-build.log" 2>&1
findstr /C:"DONE_VM_BUILD_STORE" "%EV%\stage3-build.log" >nul || goto :fail_build
for /f "tokens=*" %%L in ('findstr /C:"out_release.hap" "%EV%\stage3-build.log"') do echo %%L
echo [3/6] BUILD ok

rem ---- stage 4: REPACK ----
echo [4/6] REPACK pull raw hap + inject libssh HAR so files
"%HDC%" %T% file recv %VMROOT%/out_release.hap "%EV%\vm-raw.hap" >nul 2>&1
if not exist "%EV%\vm-raw.hap" goto :fail_repack
"%PY%" "%SCR%\repack_vm.py" "%EV%\vm-raw.hap" "%EV%\vm-repacked.hap" >"%EV%\stage4-repack.log" 2>&1
if errorlevel 1 goto :fail_repack
findstr /C:"injected" "%EV%\stage4-repack.log"
findstr /C:"OK " "%EV%\stage4-repack.log"
echo [4/6] REPACK ok

rem ---- stage 5: INSTALL ----
echo [5/6] INSTALL sign + bm install on device
"%HDC%" %T% file send "%EV%\vm-repacked.hap" /data/local/tmp/m7r1-unsigned.hap >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-sign-install.sh" >"%EV%\stage5-install.log" 2>&1
findstr /C:"successfully" "%EV%\stage5-install.log" >nul || goto :fail_install
findstr /C:"DONE_M7R1_SIGN_INSTALL" "%EV%\stage5-install.log" >nul || goto :failinstall_marker
type "%EV%\stage5-install.log"
echo [5/6] INSTALL ok

if /i "%~1"=="/smoke" goto :smoke
echo ===== VM-DEPLOY DONE (no /smoke) =====
endlocal & exit /b 0

:smoke
echo [6/6] SMOKE launch + main UI check
"%PY%" "%SCR%\smoke_vm.py" >"%EV%\stage6-smoke.log" 2>&1
if errorlevel 1 goto :fail_smoke
type "%EV%\stage6-smoke.log"
echo ===== VM-DEPLOY DONE + SMOKE PASS =====
endlocal & exit /b 0

:fail_online
echo FAIL stage 0: device offline. Check hdc target 127.0.0.1:15566.
type "%EV%\stage0-online.txt"
endlocal & exit /b 1
:fail_sync
echo FAIL stage 1 SYNC. Tail:
powershell -NoProfile -Command "Get-Content -Tail 30 '%EV%\stage1-sync.log'"
endlocal & exit /b 1
:fail_adapt
echo FAIL stage 2 ADAPT. Tail:
powershell -NoProfile -Command "Get-Content -Tail 30 '%EV%\stage2-adapt.log'"
endlocal & exit /b 1
:fail_build
echo FAIL stage 3 BUILD. Tail:
powershell -NoProfile -Command "Get-Content -Tail 40 '%EV%\stage3-build.log'"
endlocal & exit /b 1
:fail_repack
echo FAIL stage 4 REPACK. Tail:
powershell -NoProfile -Command "Get-Content -Tail 20 '%EV%\stage4-repack.log'"
endlocal & exit /b 1
:fail_install
echo FAIL stage 5 INSTALL. Tail:
powershell -NoProfile -Command "Get-Content -Tail 30 '%EV%\stage5-install.log'"
endlocal & exit /b 1
:failinstall_marker
echo FAIL stage 5 INSTALL: installed but DONE marker missing. Tail:
powershell -NoProfile -Command "Get-Content -Tail 30 '%EV%\stage5-install.log'"
endlocal & exit /b 1
:fail_smoke
echo FAIL stage 6 SMOKE. Tail:
powershell -NoProfile -Command "Get-Content -Tail 30 '%EV%\stage6-smoke.log'"
endlocal & exit /b 1
