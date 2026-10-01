@echo off
rem ============================================================
rem upstream KaihongOS M1a - build HAP via hvigorw
rem Usage: scripts\build.cmd [output log note]
rem ============================================================
setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node;%PATH%"
set "JAVA_HOME=%DEVECO%\jbr"
set "HVIGOR_USER_HOME=%ROOT%\.hvigor"
cd /d "%ROOT%"

echo [build] root=%ROOT%
echo [build] running: hvigorw assembleHap --no-daemon
call hvigorw.bat assembleHap --no-daemon
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo [build] FAILED rc=%RC%
  exit /b %RC%
)

rem locate produced HAP(s)
set "FOUND="
for /r "%ROOT%\entry\build" %%F in (default\*.hap) do (
  echo [build] HAP: %%F  size=%%~zF
  set "FOUND=1"
)
if not defined FOUND echo [build] WARN: no .hap found under entry\build
endlocal & exit /b 0
