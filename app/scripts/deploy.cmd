@echo off
rem ============================================================
rem upstream KaihongOS M1a - deploy signed HAP to emulator
rem Device: 127.0.0.1:5555 (KaihongOS emulator, hdc -t)
rem Usage: scripts\deploy.cmd
rem ============================================================
setlocal
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "HDC=%DEVECO%\sdk\default\openharmony\toolchains\hdc.exe"
if not exist "%HDC%" set "HDC=hdc"

set "TARGET=127.0.0.1:5555"

set "HAP="
for /f "delims=" %%F in ('dir /b /s /o-d "%ROOT%\entry\build\default\*-signed.hap" 2^>nul') do (
  if not defined HAP set "HAP=%%F"
)
if not defined HAP (
  echo [deploy] ERROR: no *-signed.hap under entry\build\default - run build.cmd + sign.cmd first
  exit /b 1
)
echo [deploy] HAP: %HAP%

echo [deploy] hdc target: %TARGET%
"%HDC%" -t %TARGET% shell echo device-ok
if errorlevel 1 (
  echo [deploy] ERROR: device not reachable - start emulator and/or hdc tmode port
  exit /b 1
)

echo [deploy] installing...
"%HDC%" -t %TARGET% install -r "%HAP%"
if errorlevel 1 (
  echo [deploy] retry with 'app install'...
  "%HDC%" -t %TARGET% app install -p "%HAP%"
  if errorlevel 1 goto :fail
)

echo [deploy] launching EntryAbility...
"%HDC%" -t %TARGET% shell aa start -a EntryAbility -b com.oneaiterm.terminal
if errorlevel 1 goto :fail

echo [deploy] OK - app installed and launched
endlocal & exit /b 0

:fail
echo [deploy] FAILED
endlocal & exit /b 1
