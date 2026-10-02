@echo off
REM gate-integration.cmd - 集成测试环节（补充任务 S2.3）
REM 执行六方法契约测试、HMH 事件映射、ACP JSON-RPC 编解码、回落流程等集成测试

setlocal enabledelayedexpansion
cd /d "%~dp0.."
set APP_DIR=%CD%
set FAILED=0

REM 检查 hdc 设备连接
hdc list targets 2>nul | findstr /C:"127.0.0.1" >nul
if !errorlevel! neq 0 (
    echo FAILED: integration - 设备未连接
    exit /b 1
)

REM 1. 六方法契约：AgentProvider 接口完整性
echo 检查: AgentProvider 六方法接口完整性...
findstr /C:"createSession" "%APP_DIR%\entry\src\main\ets\agent\AgentProvider.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - AgentProvider createSession 缺失
    set FAILED=1
)
findstr /C:"resumeSession" "%APP_DIR%\entry\src\main\ets\agent\AgentProvider.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - AgentProvider resumeSession 缺失
    set FAILED=1
)

REM 2. HMH 事件映射：12 种 SSE 事件类型
echo 检查: HMH 12 种 SSE 事件映射...
findstr /C:"approvalReq" "%APP_DIR%\entry\src\main\ets\agent\engine\HmhAdapter.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - HMH SSE 事件映射不完整
    set FAILED=1
)

REM 3. ACP JSON-RPC 编解码：七类方法
echo 检查: ACP 七类方法映射...
findstr /C:"session/new" "%APP_DIR%\entry\src\main\ets\agent\engine\AcpClient.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - ACP 七类方法映射不完整
    set FAILED=1
)

REM 4. 回落流程：引擎不可达时回落到本地
echo 检查: 引擎回落编排...
findstr /C:"AGENT_ENGINE_UNAVAILABLE" "%APP_DIR%\entry\src\main\ets\agent\AgentAdapter.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - 引擎回落编排缺失
    set FAILED=1
)

REM 5. 三引擎注册：local + hmh + acp
echo 检查: 三引擎注册...
findstr /C:"LocalAssistant" "%APP_DIR%\entry\src\main\ets\agent\AgentAdapter.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - 三引擎注册缺失（LocalAssistant）
    set FAILED=1
)
findstr /C:"HmhAdapter" "%APP_DIR%\entry\src\main\ets\agent\AgentAdapter.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - 三引擎注册缺失（HmhAdapter）
    set FAILED=1
)
findstr /C:"AcpClient" "%APP_DIR%\entry\src\main\ets\agent\AgentAdapter.ets" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: integration - 三引擎注册缺失（AcpClient）
    set FAILED=1
)

if !FAILED! equ 1 (
    echo FAILED: integration - 集成测试检查项未通过
    exit /b 1
)

echo PASSED: integration (六方法契约 + HMH 事件映射 + ACP 编解码 + 回落编排 + 三引擎注册)
exit /b 0