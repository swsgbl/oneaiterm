@echo off
REM gate-integration.cmd -- integration gate: REAL on-device integration
REM checks (M8-relay10). Replaces the old source-grep shell (which only
REM grepped method names in Agent*.ets). Now delegates to the
REM gate_integration_run.cjs driver, which proves the integration
REM surface on the device itself (127.0.0.1:15566):
REM   I1  module coexistence: `bm dump -a` lists com.oneaiterm.terminal
REM       (entry_test too when installed) - no ghost-overwrite.
REM   I2  full app lifecycle: force-stop + aa start, hilog 15s window
REM       shows EntryAbility onCreate -> onWindowStageCreate ->
REM       onForeground, with NO jscrash/cppcrash/appfreeze keywords.
REM   I3  bundle-dump size sentinel: `bm dump -n com.oneaiterm.terminal`
REM       output > 5KB (relay6/7 ghost-overwrite auto-sentinel).
REM Prereq: com.oneaiterm.terminal installed (vm-deploy).
REM Device absent -> "FAILED: integration - device absent (honest fail)"
REM exit 1. Override target for fail-closed drills: set HM_GATE_TARGET.
REM Evidence: %EV%\integration-last.txt (+ integration-bma/hilog/bmn.txt)
REM Red lines: no git ops; 15566 target only in real runs; no host-built
REM artifacts; main bundle is never uninstalled.

setlocal enabledelayedexpansion
set "SCR=%~dp0"
set "APP=%SCR%.."
for %%I in ("%APP%") do set "APP=%%~fI"
set "REPO=%APP%\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
set "EV=%REPO%\.verify\m8r10"
set "HDC=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if not exist "%HDC%" set "HDC=hdc"
if not defined HM_GATE_TARGET set "HM_GATE_TARGET=127.0.0.1:15566"
set "T=-t %HM_GATE_TARGET%"
if not exist "%EV%" mkdir "%EV%"

REM ---- device online (honest fail-closed) ----
"%HDC%" %T% shell "echo online" >"%EV%\integration-online.txt" 2>&1
findstr /C:"online" "%EV%\integration-online.txt" >nul || goto :fail_nodevice
echo [integration] device online (%HM_GATE_TARGET%)

REM ---- app installed prereq (I1 pre-flight; driver re-proves) ----
"%HDC%" %T% shell "bm dump -a" >"%EV%\integration-bma-preflight.txt" 2>&1
findstr /C:"com.oneaiterm.terminal" "%EV%\integration-bma-preflight.txt" >nul || goto :fail_notinstalled
echo [integration] com.oneaiterm.terminal installed

REM ---- real run via driver (~2 min: lifecycle window dominates) ----
echo [integration] running on-device integration driver (I1 coexist + I2 lifecycle + I3 dump-size)...
node "%SCR%gate_integration_run.cjs" "%EV%"
if errorlevel 1 goto :fail_run

echo PASSED: integration ^(on-device: I1 module coexist + I2 full lifecycle no-crash + I3 bundle dump ^> 5KB^)
echo evidence: %EV%\integration-last.txt
exit /b 0

:fail_nodevice
echo FAILED: integration - device absent (honest fail)
echo evidence: %EV%\integration-online.txt
exit /b 1

:fail_notinstalled
echo FAILED: integration - com.oneaiterm.terminal not installed (run app\scripts\vm-deploy.cmd first; honest fail)
echo evidence: %EV%\integration-bma-preflight.txt
exit /b 1

:fail_run
echo FAILED: integration - on-device criteria not met, see %EV%\integration-last.txt
powershell -NoProfile -Command "Get-Content -Tail 12 '%EV%\integration-last.txt'"
exit /b 1
