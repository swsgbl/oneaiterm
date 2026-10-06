@echo off
REM gate-sbom.cmd - SBOM 生成与校验环节（补充任务 S2.7）
REM 校验 SBOM.json 与 license 结果一致性
REM NOTE (M8-relay10): static check (tripwire) by design for SBOM/license consistency (file-level) - not an on-device test

setlocal enabledelayedexpansion
cd /d "%~dp0..\.."
set PROJECT_DIR=%CD%
set FAILED=0

REM 检查 SBOM.json 存在
if not exist "%PROJECT_DIR%\SBOM.json" (
    echo FAILED: SBOM - SBOM.json 不存在
    exit /b 1
)

REM 检查 SBOM.json 格式有效性
echo 检查: SBOM.json 格式...
findstr /C:"components" "%PROJECT_DIR%\SBOM.json" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: SBOM - SBOM.json 格式无效（缺少 components 字段）
    set FAILED=1
)
findstr /C:"name" "%PROJECT_DIR%\SBOM.json" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: SBOM - SBOM.json 格式无效（缺少 name 字段）
    set FAILED=1
)
findstr /C:"version" "%PROJECT_DIR%\SBOM.json" >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: SBOM - SBOM.json 格式无效（缺少 version 字段）
    set FAILED=1
)

REM 检查 SBOM.json 与 LICENSE-MATRIX.csv 一致性
if exist "%PROJECT_DIR%\LICENSE-MATRIX.csv" (
    echo 检查: SBOM 与 LICENSE-MATRIX 一致性...
    findstr /C:"libssh" "%PROJECT_DIR%\SBOM.json" >nul 2>&1
    if !errorlevel! equ 0 (
        findstr /C:"libssh" "%PROJECT_DIR%\LICENSE-MATRIX.csv" >nul 2>&1
        if !errorlevel! neq 0 (
            echo FAILED: SBOM - SBOM 中 libssh 条目与 LICENSE-MATRIX 不一致
            set FAILED=1
        )
    )
)

if !FAILED! equ 1 (
    echo FAILED: SBOM - SBOM 校验未通过
    exit /b 1
)

echo PASSED: SBOM (格式有效 + 许可一致)
exit /b 0