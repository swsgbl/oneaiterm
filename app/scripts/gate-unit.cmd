@echo off
REM gate-unit.cmd - unit test gate (supplementary task S2.2)
REM M8-relay2: FAIL-CLOSED. On-device hypium is NOT wired on the VM build
REM chain (VM tree has no entry_test module, no ohosTest dir, and
REM pack_hap_store.sh has no test variant; probed 2026-10-03). When device
REM execution fails, this gate exits 1 instead of faking PASSED. Real wiring
REM needs a DevEco-configured ohosTest module; until then a PASS here would
REM be a lie. The Agent E2E approval-loop evidence in .verify/m8r2/ is a
REM smoke layer above unit tests, not a substitute for them.

setlocal enabledelayedexpansion
cd /d "%~dp0.."
set APP_DIR=%CD%
set FAILED=0

REM 检查 hdc 设备连接
hdc list targets 2>nul | findstr /C:"127.0.0.1" >nul
if !errorlevel! neq 0 (
    echo FAILED: unit - 设备未连接（hdc list targets 无输出）
    exit /b 1
)

REM 检查测试入口文件存在
if not exist "%APP_DIR%\entry\src\test\List.test.ets" (
    echo FAILED: unit - 测试入口 List.test.ets 不存在
    exit /b 1
)

REM 检查测试文件完整性
set TEST_COUNT=0
for %%f in (
    "%APP_DIR%\entry\src\test\PolicyEngine.test.ets"
    "%APP_DIR%\entry\src\test\AuditRedact.test.ets"
    "%APP_DIR%\entry\src\test\AgentSessionMeta.test.ets"
    "%APP_DIR%\entry\src\test\AcpClient.test.ets"
    "%APP_DIR%\entry\src\test\CapabilityDiscovery.test.ets"
    "%APP_DIR%\entry\src\test\ApprovalCard.test.ets"
) do (
    if exist %%f (
        set /a TEST_COUNT+=1
    ) else (
        echo FAILED: unit - 测试文件缺失: %%f
        set FAILED=1
    )
)

if !FAILED! equ 1 exit /b 1

echo 检查: !TEST_COUNT! 个测试文件就绪

REM 尝试在设备上执行 hypium 测试
REM 注意：需要 DevEco Studio 配置 ohosTest module 才能在设备上执行
hdc shell "aa test -b com.oneaiterm.terminal -m entry_test -s unittest ListTest -w 60" 2>&1 | findstr "TestFinished-ResultCode: 0" >nul
if !errorlevel! neq 0 (
    echo FAILED: unit - on-device hypium not wired on VM chain (honest fail, do not fake PASS)
    echo FAILED: unit - test files present (!TEST_COUNT!) but device execution failed
    echo FAILED: unit - wire a DevEco ohosTest module (entry_test) or run tests on a real chain
    exit /b 1
)

echo PASSED: unit (设备测试全部通过)
exit /b 0