@echo off
rem internal: ohpm install --all with project-local ohpm on PATH
setlocal
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\node;%PATH%"
cd /d "%ROOT%"
call ohpm install --all 2>&1
exit /b %ERRORLEVEL%
