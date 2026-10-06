@echo off
REM gate-e2e.cmd -- e2e gate: REAL on-device execution (M8-relay10).
REM Replaces the old source-grep shell (which grepped "220" in AIDock.ets
REM and called it a day). Now drives the actual app on the KaihongOS VM
REM (127.0.0.1:15566) via the gate_e2e_run.cjs driver:
REM   step 1  force-stop + aa start -> dumpLayout -> dismiss onboarding
REM           "skip" if present -> main UI text nodes > 50 (E1)
REM   step 2  SSH gold path: WantParams auto-connect uterm@10.0.2.2:2222
REM           (pw uterm-pw-735) + postLogin `echo M8-E2E-GATE-OK`,
REM           marker must be visible on screen (dumpLayout text nodes, E2)
REM   step 3  hilog connect lines (corroborating detail, non-blocking)
REM Modes:
REM   (none)  full run (~4 min: both steps + marker poll window)
REM   /quick  step 1 only (fast lane: launch + guide-dismiss + node count)
REM Prereq: com.oneaiterm.terminal installed (vm-deploy). Not installed
REM         -> honest fail-closed with a "run vm-deploy first" hint.
REM Device absent -> "FAILED: e2e - device absent (honest fail)" exit 1.
REM Evidence: %EV%\e2e-last.txt (+ e2e-*.json/.txt dumps, e2e-hilog.txt)
REM Red lines: no git ops; 15566 target only; no host-built artifacts.

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
set "MODE=full"
if /i "%~1"=="/quick" set "MODE=quick"
if not exist "%EV%" mkdir "%EV%"

REM ---- device online (honest fail-closed) ----
"%HDC%" %T% shell "echo online" >"%EV%\e2e-online.txt" 2>&1
findstr /C:"online" "%EV%\e2e-online.txt" >nul || goto :fail_nodevice
echo [e2e] device online (127.0.0.1:15566), mode=%MODE%

REM ---- app installed prereq ----
"%HDC%" %T% shell "bm dump -a" >"%EV%\e2e-bma.txt" 2>&1
findstr /C:"com.oneaiterm.terminal" "%EV%\e2e-bma.txt" >nul || goto :fail_notinstalled
echo [e2e] com.oneaiterm.terminal installed

REM ---- real run via driver ----
echo [e2e] running on-device E2E driver (full ~4 min / quick ~1 min)...
node "%SCR%gate_e2e_run.cjs" %MODE% "%EV%"
if errorlevel 1 goto :fail_run

echo PASSED: e2e ^(on-device: cold start + onboarding dismiss + main UI nodes ^> 50^)
if /i "%MODE%"=="full" echo PASSED: e2e ^(SSH gold marker M8-E2E-GATE-OK visible on screen^)
echo evidence: %EV%\e2e-last.txt
exit /b 0

:fail_nodevice
echo FAILED: e2e - device absent (honest fail)
echo evidence: %EV%\e2e-online.txt
exit /b 1

:fail_notinstalled
echo FAILED: e2e - com.oneaiterm.terminal not installed (run app\scripts\vm-deploy.cmd first; honest fail)
echo evidence: %EV%\e2e-bma.txt
exit /b 1

:fail_run
echo FAILED: e2e - on-device criteria not met, see %EV%\e2e-last.txt
powershell -NoProfile -Command "Get-Content -Tail 12 '%EV%\e2e-last.txt'"
exit /b 1
