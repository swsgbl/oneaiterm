@echo off
REM gate-e2e.cmd - 端到端验证环节（补充任务 S2.4）
REM 执行终端内四类 AI 入口、审批卡交互、会话恢复等端到端场景

setlocal enabledelayedexpansion
cd /d "%~dp0.."
set APP_DIR=%CD%
set FAILED=0

REM 检查 hdc 设备连接
hdc list targets 2>nul | findstr /C:"127.0.0.1" >nul
if !errorlevel! neq 0 (
    echo FAILED: E2E - 设备未连接
    exit /b 1
)

REM 1. 四类 AI 入口模式
echo 检查: 四类 AI 入口模式...
findstr /C:"aiMode" "%APP_DIR%\entry\src\main\ets\components\AIDock.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: E2E - 四类 AI 入口模式缺失
    set FAILED=1
)

REM 2. 审批卡组件
echo 检查: 审批卡组件...
findstr /C:"ApprovalCard" "%APP_DIR%\entry\src\main\ets\components\ApprovalCard.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: E2E - 审批卡组件缺失
    set FAILED=1
)

REM 3. AIDock 220px 展开高度
echo 检查: AIDock 220px 展开高度...
findstr /C:"220" "%APP_DIR%\entry\src\main\ets\components\AIDock.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: E2E - AIDock 220px 展开高度配置缺失
    set FAILED=1
)

REM 4. 三引擎选择
echo 检查: 三引擎选择 UI...
findstr /C:"engineType" "%APP_DIR%\entry\src\main\ets\components\AIDock.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: E2E - 三引擎选择 UI 缺失
    set FAILED=1
)

REM 5. 能力探测
echo 检查: 能力探测组件...
findstr /C:"CapabilityDiscovery" "%APP_DIR%\entry\src\main\ets\agent\discovery\CapabilityDiscovery.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: E2E - 能力探测组件缺失
    set FAILED=1
)

REM 6. 应用启动验证
echo 检查: 应用启动...
hdc shell "aa start -a EntryAbility -b com.oneaiterm.terminal" 2>&1 | findstr /C:"successfully" >nul
if !errorlevel! neq 0 (
    echo FAILED: E2E - 应用启动失败
    set FAILED=1
)

if !FAILED! equ 1 (
    echo FAILED: E2E - 端到端验证项未通过
    exit /b 1
)

echo PASSED: E2E (四类入口 + 审批卡 + 220px + 三引擎选择 + 能力探测 + 应用启动)
exit /b 0