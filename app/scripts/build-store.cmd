@echo off
rem ============================================================
rem upstream KaihongOS M4-relay4 - store flavor one-click build
rem
rem What it does:
rem   1. Build product=store (compatibleSdkVersion=5.0.2(14)) via hvigorw
rem      compileSdkVersion stays 26 (Deveco Studio SDK) - verified OK,
rem      hvigor does NOT require the companion API14 SDK to exist.
rem   2. Sign the unsigned store HAP with -compatibleVersion 14
rem      (same keychain as sign.cmd: app.p12/ca.p12, passwords 123456)
rem   3. Optionally install+launch on the 5555 emulator (pass "deploy" as %1)
rem
rem After the API14 companion SDK lands in D:\upstream\sdk-kaihongos
rem (if you want to compile *against* API14 instead of 26), set:
rem   set "HOS_SDK_HOME=D:\upstream\sdk-kaihongos"
rem   (or add sdk.dir to kaihongos\local.properties) and set
rem   COMPILE_14=1 before calling this script.
rem
rem Usage: scripts\build-store.cmd [deploy]
rem ============================================================
setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "HDC=%DEVECO%\sdk\default\openharmony\toolchains\hdc.exe"
if not exist "%HDC%" set "HDC=hdc"
set "TARGET=127.0.0.1:5555"

if defined COMPILE_14 (
  set "SDK14=D:\upstream\sdk-kaihongos"
  if exist "!SDK14!" (
    set "HOS_SDK_HOME=!SDK14!"
    echo [build-store] compiling against API14 SDK: !HOS_SDK_HOME!
  ) else (
    echo [build-store] WARN: D:\upstream\sdk-kaihongos missing - falling back to DevEco API26 SDK
  )
)

set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node;%PATH%"
set "JAVA_HOME=%DEVECO%\jbr"
set "HVIGOR_USER_HOME=%ROOT%\.hvigor"
cd /d "%ROOT%"

echo [build-store] 1/2 hvigorw assembleHap -p product=store
call hvigorw.bat assembleHap --no-daemon -p product=store
if errorlevel 1 (
  echo [build-store] BUILD FAILED
  exit /b 1
)

echo [build-store] 2/2 sign (-compatibleVersion 14)
call "%ROOT%\scripts\sign-store.cmd"
if errorlevel 1 (
  echo [build-store] SIGN FAILED
  exit /b 1
)

if /i "%~1"=="deploy" (
  echo [build-store] 3/3 deploy to %TARGET%
  set "SIGNED=%ROOT%\entry\build\store\outputs\store\entry-store-signed.hap"
  "%HDC%" -t %TARGET% install -r "%SIGNED%"
  if errorlevel 1 (
    "%HDC%" -t %TARGET% app install -p "%SIGNED%"
    if errorlevel 1 (
      echo [build-store] INSTALL FAILED
      exit /b 1
    )
  )
  "%HDC%" -t %TARGET% shell aa start -a EntryAbility -b com.oneaiterm.terminal
  if errorlevel 1 (
    echo [build-store] LAUNCH FAILED
    exit /b 1
  )
  echo [build-store] DEPLOY OK - installed and launched on %TARGET%
)

endlocal & exit /b 0
