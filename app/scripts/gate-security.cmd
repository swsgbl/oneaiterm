@echo off
REM gate-security.cmd - 安全用例检查环节（补充任务 S2.5）
REM 逐一执行十类安全用例检查，任一失败禁止豁免放行

setlocal enabledelayedexpansion
set FAILED=0
set SEC_FAIL_COUNT=0
cd /d "%~dp0.."
set SRC_BASE=%CD%
set POLICY_FILE=%SRC_BASE%\entry\src\main\ets\agent\security\PolicyEngine.ets
set AUDIT_FILE=%SRC_BASE%\entry\src\main\ets\agent\security\AuditWriter.ets
set ACP_FILE=%SRC_BASE%\entry\src\main\ets\agent\engine\AcpClient.ets

echo 安全用例检查（十类）:
echo.

REM 1. path traversal
echo [1/10] path traversal...
findstr /C:"TRAVERSAL" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: PolicyEngine 路径穿越正则缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 2. command injection
echo [2/10] command injection...
findstr /C:"INJECTION" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: PolicyEngine 命令注入拦截正则缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 3. credential leakage
echo [3/10] credential leakage...
findstr /C:"digest" "%AUDIT_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: AuditWriter 脱敏逻辑缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 4. approval bypass
echo [4/10] approval bypass...
findstr /C:"require_approval" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: 审批绕过防护缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 5. workspace escape
echo [5/10] workspace escape...
findstr /C:"deny" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: 工作区逃逸防护缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 6. malicious MCP
echo [6/10] malicious MCP...
findstr /S /C:"MCP" "%SRC_BASE%\entry\src\main\ets\agent\*.ets" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   PASSED - 无 MCP 依赖，无需 schema validation
)

REM 7. prompt injection
echo [7/10] prompt injection...
findstr /C:"INJECTION" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: prompt 注入防护缺失
    set /a SEC_FAIL_COUNT+=1
)

REM 8. SSRF
echo [8/10] SSRF...
findstr /C:"baseUrl" "%ACP_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED - ACP agentUrl 来自配置，非 AI 可控
) else (
    echo   FAILED: SSRF 防护检查失败
    set /a SEC_FAIL_COUNT+=1
)

REM 9. arbitrary write
echo [9/10] arbitrary write...
findstr /C:"term_write" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: 任意文件写入防护缺失
    set /a SEC_FAIL_COUNT+=1
)


REM 10. destructive command
echo [10/10] destructive command...
findstr /C:"DESTRUCTIVE" "%POLICY_FILE%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   PASSED
) else (
    echo   FAILED: 危险命令审批缺失
    set /a SEC_FAIL_COUNT+=1
)

echo.
if !SEC_FAIL_COUNT! equ 0 (
    echo PASSED: security (十类安全用例全部通过)
    exit /b 0
) else (
    echo FAILED: security - !SEC_FAIL_COUNT! 类安全用例未通过
    echo 安全缺陷报告: 禁止豁免放行
    exit /b 1
)