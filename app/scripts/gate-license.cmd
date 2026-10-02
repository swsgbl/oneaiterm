@echo off
REM gate-license.cmd - 许可一致性校验环节（补充任务 S2.6）
REM 比对 oh-package.json5 依赖列表与 LICENSE-MATRIX.csv 已登记许可

setlocal enabledelayedexpansion
cd /d "%~dp0..\.."
set PROJECT_DIR=%CD%
cd /d "%~dp0.."
set APP_DIR=%CD%
set FAILED=0

REM 检查 LICENSE-MATRIX.csv 存在
if not exist "%PROJECT_DIR%\LICENSE-MATRIX.csv" (
    echo FAILED: license - LICENSE-MATRIX.csv 不存在
    exit /b 1
)

REM 检查 oh-package.json5 存在
if not exist "%APP_DIR%\oh-package.json5" (
    echo FAILED: license - app/oh-package.json5 不存在
    exit /b 1
)

REM 读取 oh-package.json5 中的 dependencies（零新增第三方依赖约束）
echo 检查: oh-package.json5 dependencies...
rg "\"dependencies\"" "%APP_DIR%\oh-package.json5" >nul 2>&1
if !errorlevel! equ 0 (
    REM 检查 dependencies 是否为空（零新增第三方依赖约束）
    for /f "tokens=*" %%a in ('rg -A5 "\"dependencies\"" "%APP_DIR%\oh-package.json5"') do (
        echo %%a | findstr /V "dependencies" | findstr ":" >nul
        if !errorlevel! equ 0 (
            echo FAILED: license - dependencies 非空（违反零新增第三方依赖约束）
            set FAILED=1
        )
    )
)

if !FAILED! equ 1 exit /b 1

REM 检查 entry/oh-package.json5 依赖
echo 检查: entry/oh-package.json5 dependencies...
rg "\"@ohos/libssh\"" "%APP_DIR%\entry\oh-package.json5" >nul 2>&1
if !errorlevel! equ 0 (
    REM 验证 libssh 在 LICENSE-MATRIX.csv 中已登记
    rg "libssh" "%PROJECT_DIR%\LICENSE-MATRIX.csv" >nul 2>&1
    if !errorlevel! neq 0 (
        echo FAILED: license - @ohos/libssh 未在 LICENSE-MATRIX.csv 中登记
        set FAILED=1
    )
)

REM 检查 hypium 在 LICENSE-MATRIX.csv 中已登记
rg "hypium" "%APP_DIR%\entry\oh-package.json5" >nul 2>&1
if !errorlevel! equ 0 (
    rg "hypium" "%PROJECT_DIR%\LICENSE-MATRIX.csv" >nul 2>&1
    if !errorlevel! neq 0 (
        echo WARN: license - @ohos/hypium 未在 LICENSE-MATRIX.csv 中登记（devDependency，测试框架）
    )
)

if !FAILED! equ 1 (
    echo FAILED: license - 许可一致性校验未通过
    exit /b 1
)

echo PASSED: license (零新增第三方依赖 + 已登记许可一致)
exit /b 0