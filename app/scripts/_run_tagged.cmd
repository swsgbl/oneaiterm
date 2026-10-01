@echo off
rem internal: run a project script with tag, capture output to evidence\M1a\run-<tag>.log
setlocal
set "TAG=%~1"
set "SCRIPT=%~2"
set "ROOT=%~dp0.."
if "%TAG%"=="" set "TAG=x"
call "%ROOT%\scripts\%SCRIPT%" > "D:\upstream\evidence\M1a\run-%TAG%.log" 2>&1
set "RC=%ERRORLEVEL%"
echo RUN_RC=%RC%
powershell -NoProfile -Command "Get-Content 'D:\upstream\evidence\M1a\run-%TAG%.log' -Tail 30"
exit /b %RC%
