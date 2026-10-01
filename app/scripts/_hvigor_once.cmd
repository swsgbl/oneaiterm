@echo off
rem internal: one-shot hvigor run with tag, full log to evidence\M1a\run-<tag>.log
setlocal
set "TAG=%1"
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node;%PATH%"
set "HVIGOR_USER_HOME=%ROOT%\.hvigor"
cd /d "%ROOT%"
call hvigorw.bat assembleHap --no-daemon > "%ROOT%\..\evidence\M1a\run-%TAG%.log" 2>&1
set "RC=%ERRORLEVEL%"
echo HVIGOR_RC=%RC%
powershell -NoProfile -Command "Get-Content 'D:\upstream\evidence\M1a\run-%TAG%.log' -Tail 25"
exit /b %RC%
