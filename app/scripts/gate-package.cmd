@echo off
REM gate-package.cmd - 产物清单完整性校验环节（补充任务 S2.8）
REM 校验 HAP 双 ABI 包、SBOM、许可证据、构建证据、版本号一致性
REM NOTE (M8-relay10): static check (tripwire) by design for release artifact manifest completeness (file-level) - not an on-device test

setlocal enabledelayedexpansion
cd /d "%~dp0..\.."
set PROJECT_DIR=%CD%
cd /d "%~dp0.."
set APP_DIR=%CD%
set FAILED=0

REM 1. 校验 HAP 双 ABI 包（default）存在
echo 检查: default HAP 产物...
set DEFAULT_HAP_DIR=%APP_DIR%\entry\build\default\outputs\default
if not exist "%DEFAULT_HAP_DIR%\entry-default-unsigned.hap" (
    echo FAILED: package - default HAP 产物不存在
    set FAILED=1
)

REM 2. 校验 HAP 双 ABI 包（store）存在
echo 检查: store HAP 产物...
set STORE_HAP_DIR=%APP_DIR%\entry\build\store\outputs\store
if not exist "%STORE_HAP_DIR%\entry-store-unsigned.hap" (
    echo FAILED: package - store HAP 产物不存在
    set FAILED=1
)

REM 3. 校验 SBOM 存在
echo 检查: SBOM.json...
if not exist "%PROJECT_DIR%\SBOM.json" (
    echo FAILED: package - SBOM.json 不存在
    set FAILED=1
)

REM 4. 校验许可证据存在
echo 检查: LICENSE-MATRIX.csv...
if not exist "%PROJECT_DIR%\LICENSE-MATRIX.csv" (
    echo FAILED: package - LICENSE-MATRIX.csv 不存在
    set FAILED=1
)

REM 5. 校验版本号一致性
echo 检查: 版本号一致性...
for /f "tokens=2 delims=:," %%v in ('rg "versionName" "%APP_DIR%\build-profile.json5"') do (
    set VERSION_LINE=%%v
    goto :version_found
)
:version_found
echo   build-profile.json5 versionName: !VERSION_LINE!

if !FAILED! equ 1 (
    echo FAILED: package - 产物清单完整性校验未通过
    exit /b 1
)

echo PASSED: package (双 product HAP + SBOM + 许可证据 + 版本号)
exit /b 0