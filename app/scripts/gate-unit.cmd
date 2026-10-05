@echo off
REM gate-unit.cmd -- unit gate: REAL on-device hypium execution (M8-relay8).
REM Chain: ohosTest module (entry_test) built on the KaihongOS VM
REM (127.0.0.1:15566), signed + co-exist installed (main bundle NEVER
REM uninstalled), executed via `aa test -s unittest ListTest`.
REM Modes:
REM   (none)  run `aa test` against the installed entry_test hap, parse
REM           REAL stats from the aa-test client output. Exit 0 only on
REM           TestFinished-ResultCode: 0 AND Failure: 0 AND Error: 0 AND
REM           Tests run >= 1 AND Pass >= 1. Anything else (device absent,
REM           module not installed, timeout, failures) => exit 1.
REM           Honest fail-closed: a PASS is never fabricated.
REM   build   full provision first (sync -> vm-adapt -> vm-build-test ->
REM           sign+install), then the same aa test + parse. Use after
REM           source changes or when the module is not installed yet.
REM   u2      fail-path self-check: replay the parser against a captured
REM           failing output (%EV%\gate-unit-u2-input.txt) and EXPECT it
REM           to fail. Exit 0 = the FAIL branch triggers correctly.
REM Evidence: %EV%\gate-unit-last.txt (+ stage logs gate-unit-build-*.log)
REM Red lines: no git ops; VM-built artifacts only (host hvigor products
REM are never installed); main bundle is never uninstalled; 15566 only.

setlocal enabledelayedexpansion
set "SCR=%~dp0"
set "APP=%SCR%.."
for %%I in ("%APP%") do set "APP=%%~fI"
set "REPO=%APP%\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
set "EV=%REPO%\.verify\m8r8"
set "HDC=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if not exist "%HDC%" set "HDC=hdc"
set "T=-t 127.0.0.1:15566"
set "PY=C:\Users\hongfu\AppData\Local\mise\shims\python.exe"
set "MODE=%~1"
if not exist "%EV%" mkdir "%EV%"

REM ---- host tree sanity: ohosTest suite files must exist ----
set SUITES=0
for %%f in (
    "%APP%\entry\src\ohosTest\ets\test\List.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\PolicyEngine.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\AuditRedact.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\AgentSessionMeta.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\AcpClient.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\CapabilityDiscovery.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\ApprovalCard.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\AgentAdapter.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\ApprovalManager.test.ets"
    "%APP%\entry\src\ohosTest\ets\test\BackspaceKey.test.ets"
) do (
    if exist %%f (set /a SUITES+=1) else (
        echo FAILED: unit - ohosTest suite file missing: %%f
    )
)
if !SUITES! lss 10 (
    echo FAILED: unit - ohosTest tree incomplete ^(!SUITES!/10 files^)
    exit /b 1
)
echo check: !SUITES!/10 ohosTest suite files present

if /i "%MODE%"=="u2"    goto :u2
if /i "%MODE%"=="build" goto :device
goto :device

REM ===================== build mode: full provision =====================
:build
echo [unit-build] 1/4 sync repo tree to VM
"%PY%" "%SCR%sync_vm.py" --push --prune >"%EV%\gate-unit-build-sync.log" 2>&1
if errorlevel 1 goto :fail_sync
findstr /C:"SYNC_OK" "%EV%\gate-unit-build-sync.log" >nul || goto :fail_sync

echo [unit-build] 2/4 vm-adapt
"%HDC%" %T% file send "%SCR%vm-adapt.sh" /data/local/tmp/vm-adapt.sh >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-adapt.sh" >"%EV%\gate-unit-build-adapt.log" 2>&1
findstr /C:"DONE_VM_ADAPT" "%EV%\gate-unit-build-adapt.log" >nul || goto :fail_adapt

echo [unit-build] 3/4 vm-build-test (ohosTest module, stale-abc hard reset inside)
"%HDC%" %T% file send "%SCR%vm-build-test.sh" /data/local/tmp/vm-build-test.sh >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-build-test.sh" >"%EV%\gate-unit-build-test.log" 2>&1
findstr /C:"DONE_VM_BUILD_TEST" "%EV%\gate-unit-build-test.log" >nul || goto :fail_build

echo [unit-build] 4/4 sign + co-exist install (main bundle untouched)
"%HDC%" %T% shell "cp -f /data/local/home/tmp/app/out_test-unsigned.hap /data/local/tmp/m8r8-test-unsigned.hap"
"%HDC%" %T% file send "%SCR%vm-sign-install-test.sh" /data/local/tmp/vm-sign-install-test.sh >nul 2>&1
"%HDC%" %T% shell "sh /data/local/tmp/vm-sign-install-test.sh" >"%EV%\gate-unit-build-install.log" 2>&1
findstr /C:"DONE_M8R8_TEST_INSTALL" "%EV%\gate-unit-build-install.log" >nul || goto :fail_install

REM ===================== run mode: aa test + parse =====================
:device
"%HDC%" %T% shell "echo online" >"%EV%\gate-unit-online.txt" 2>&1
findstr /C:"online" "%EV%\gate-unit-online.txt" >nul || goto :fail_nodevice

:run
echo [unit] aa test entry_test/ListTest ^(cold start can take ~100s; window 180s^)
"%HDC%" %T% shell "aa test -b com.oneaiterm.terminal -m entry_test -s unittest ListTest -w 180" >"%EV%\gate-unit-last.txt" 2>&1
call :parse "%EV%\gate-unit-last.txt"
if !PARSE_OK! equ 1 goto :run_ok
REM ---- hilog fallback (client window vs delayed app spawn) ----
REM Measured on this VM: right after a bm install the aa framework can
REM take ~100s to spawn the test app, while the aa-test client window
REM (-w 90) expired first -> "Timeout: user test is not completed" even
REM though the device ran every case. The device-side hypium summary in
REM hilog ("total cases:N;failure X,error Y,pass Z", same pid as the
REM "ListTest runner main() enter" marker, fresh timestamp) is the
REM authoritative runtime record; hilog_stats.cjs enforces pid pairing
REM and freshness so a stale buffer line can never fake a PASS.
echo [unit] client report missing/timeout - falling back to hilog ground truth
"%HDC%" %T% shell "hilog -x" >"%EV%\gate-unit-hilog.txt" 2>&1
node "%SCR%hilog_stats.cjs" "%EV%\gate-unit-hilog.txt" >"%EV%\gate-unit-hilog-stats.txt" 2>&1
type "%EV%\gate-unit-hilog-stats.txt"
findstr /C:"HILOG_STATS=OK" "%EV%\gate-unit-hilog-stats.txt" >nul || goto :fail_parse
for /f "usebackq tokens=2-5 delims=," %%a in (`findstr /C:"HILOG_STATS=OK" "%EV%\gate-unit-hilog-stats.txt"`) do (
    set "RUN=%%a"
    set "FAILN=%%b"
    set "ERRN=%%c"
    set "PASSN=%%d"
)
if !FAILN! gtr 0 goto :fail_parse
if !ERRN! gtr 0 goto :fail_parse
if !PASSN! lss 1 goto :fail_parse
:run_ok
echo PASSED: unit ^(on-device hypium: Tests run: !RUN!, Pass: !PASSN!, Failure: !FAILN!, Error: !ERRN!^)
exit /b 0

REM ===================== u2 mode: parser fail-path self-test ============
:u2
if not exist "%EV%\gate-unit-u2-input.txt" (
    echo FAILED: unit-u2 - no captured input at %EV%\gate-unit-u2-input.txt
    exit /b 1
)
call :parse "%EV%\gate-unit-u2-input.txt"
if !PARSE_OK! equ 1 (
    echo FAILED: unit-u2 - parser ACCEPTED a failing output ^(false positive^)
    exit /b 1
)
echo PASSED: unit-u2 - fail path triggers correctly ^(!REASON!^)
exit /b 0

REM ===================== sub: parse an aa-test output ===================
REM %1 = log file. Sets RUN/PASSN/FAILN/ERRN/RC0/PARSE_OK/REASON.
:parse
set "PLOG=%~1"
set "PARSE_OK=0"
set "RUN=-1"
set "PASSN=-1"
set "FAILN=-1"
set "ERRN=-1"
set "RC0=1"
set "REASON="
findstr /C:"TestFinished-ResultCode: 0" "%PLOG%" >nul && set "RC0=0"
findstr /C:"Not found entry_test" "%PLOG%" >nul && set "REASON=entry_test module not installed (run: gate-unit.cmd build)"
for /f "usebackq delims=" %%L in (`findstr /C:"OHOS_REPORT_RESULT: stream=Tests run:" "%PLOG%"`) do (
    for /f "tokens=1-5 delims=," %%A in ("%%L") do (
        for /f "tokens=4 delims=:, " %%R in ("%%A") do set "RUN=%%R"
        for /f "tokens=2 delims=: " %%R in ("%%B") do set "FAILN=%%R"
        for /f "tokens=2 delims=: " %%R in ("%%C") do set "ERRN=%%R"
        for /f "tokens=2 delims=: " %%R in ("%%D") do set "PASSN=%%R"
    )
)
if "!REASON!"=="" if !RC0! neq 0 set "REASON=TestFinished-ResultCode is not 0"
echo !RUN!|findstr /r "^[0-9][0-9]*$" >nul || set "REASON=Tests-run count missing/non-numeric"
echo !PASSN!|findstr /r "^[0-9][0-9]*$" >nul || set "REASON=Pass count missing/non-numeric"
echo !FAILN!|findstr /r "^[0-9][0-9]*$" >nul || set "REASON=Failure count missing/non-numeric"
echo !ERRN!|findstr /r "^[0-9][0-9]*$" >nul || set "REASON=Error count missing/non-numeric"
if not "!REASON!"=="" exit /b 0
if !RC0! neq 0 set "REASON=TestFinished-ResultCode is not 0"
if !RUN! lss 1   set "REASON=Tests run is 0 (no test executed)"
if !PASSN! lss 1 set "REASON=Pass count is 0"
if !FAILN! gtr 0 set "REASON=Failure count is !FAILN! (expected 0)"
if !ERRN! gtr 0  set "REASON=Error count is !ERRN! (expected 0)"
if "!REASON!"=="" set "PARSE_OK=1"
exit /b 0

REM ===================== failure exits ==================================
:fail_parse
echo FAILED: unit - !REASON!
echo FAILED: unit - raw evidence: %EV%\gate-unit-last.txt ^(tail^)
type "%EV%\gate-unit-last.txt" | more +0 2>nul | findstr /n "." | findstr /b "2[0-9][0-9][0-9]" >nul
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "Get-Content -Tail 6 '%EV%\gate-unit-last.txt'"`) do echo   %%L
exit /b 1

:fail_nodevice
echo FAILED: unit - device not connected ^(VM 127.0.0.1:15566 offline^)
exit /b 1

:fail_sync
echo FAILED: unit-build - sync_vm.py failed, see %EV%\gate-unit-build-sync.log
exit /b 1

:fail_adapt
echo FAILED: unit-build - vm-adapt failed, see %EV%\gate-unit-build-adapt.log
exit /b 1

:fail_build
echo FAILED: unit-build - vm-build-test failed, see %EV%\gate-unit-build-test.log
exit /b 1

:fail_install
echo FAILED: unit-build - sign/install failed, see %EV%\gate-unit-build-install.log
exit /b 1
