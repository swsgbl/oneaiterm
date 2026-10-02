@echo off
REM OneAITerm Release Gate Pipeline (Phase 6 + 补充任务 S2.1)
REM 九环节顺序执行：typecheck → unit → integration → E2E → security → license → SBOM → build → package
REM 任一环节失败即阻断发布，输出失败环节/用例/原因清单
REM 支持单环节调用：gate.cmd <环节名>

setlocal enabledelayedexpansion
set GATE_DIR=%~dp0
set PROJECT_DIR=%GATE_DIR%..\..
set APP_DIR=%PROJECT_DIR%\app
set FAILED=0
set FAILED_STAGE=
set FAILED_DETAIL=
set RUN_STAGE=%1

REM 环境变量设置
set JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr
set HVIGOR_USER_HOME=%USERPROFILE%\.hvigor
set PATH=C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;%PATH%

if "%RUN_STAGE%"=="" (
    echo ========================================
    echo OneAITerm Release Gate Pipeline (全流程)
    echo ========================================
) else (
    echo ========================================
    echo OneAITerm Gate: %RUN_STAGE% (单环节)
    echo ========================================
)

REM ===== 1. typecheck =====
if "%RUN_STAGE%"=="" goto :stage_typecheck
if /I "%RUN_STAGE%"=="typecheck" goto :stage_typecheck
goto :stage_unit

:stage_typecheck
echo.
echo [1/9] typecheck...
cd /d %APP_DIR%
call hvigorw.bat assembleHap --no-daemon -p product=default 2>&1 | findstr /C:"BUILD SUCCESSFUL" >nul
if !errorlevel! neq 0 (
    echo FAILED: typecheck - ArkTS 编译失败
    set FAILED=1
    set FAILED_STAGE=typecheck
    set FAILED_DETAIL=ArkTS 编译失败，请检查构建日志
    goto :gate_end
)
REM 静态收口检查：AgentKernel 残留引用（排除注释行）
rg -n "AgentKernel" entry\src\main\ets\ 2>nul | findstr /V "//\|\\*\|comment" >nul 2>&1
if !errorlevel! equ 0 (
    echo FAILED: typecheck - AgentKernel 残留引用（非注释）
    set FAILED=1
    set FAILED_STAGE=typecheck
    set FAILED_DETAIL=AgentKernel 残留引用（非注释），请检查 entry\src\main\ets\ 目录
    goto :gate_end
)
echo PASSED: typecheck
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 2. unit =====
:stage_unit
if "%RUN_STAGE%"=="" goto :stage_unit_run
if /I "%RUN_STAGE%"=="unit" goto :stage_unit_run
goto :stage_integration

:stage_unit_run
echo.
echo [2/9] unit...
call "%GATE_DIR%gate-unit.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=unit
    goto :gate_end
)
echo PASSED: unit
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 3. integration =====
:stage_integration
if "%RUN_STAGE%"=="" goto :stage_integration_run
if /I "%RUN_STAGE%"=="integration" goto :stage_integration_run
goto :stage_e2e

:stage_integration_run
echo.
echo [3/9] integration...
call "%GATE_DIR%gate-integration.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=integration
    goto :gate_end
)
echo PASSED: integration
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 4. E2E =====
:stage_e2e
if "%RUN_STAGE%"=="" goto :stage_e2e_run
if /I "%RUN_STAGE%"=="E2E" goto :stage_e2e_run
goto :stage_security

:stage_e2e_run
echo.
echo [4/9] E2E...
call "%GATE_DIR%gate-e2e.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=E2E
    goto :gate_end
)
echo PASSED: E2E
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 5. security =====
:stage_security
if "%RUN_STAGE%"=="" goto :stage_security_run
if /I "%RUN_STAGE%"=="security" goto :stage_security_run
goto :stage_license

:stage_security_run
echo.
echo [5/9] security...
call "%GATE_DIR%gate-security.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=security
    goto :gate_end
)
echo PASSED: security
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 6. license =====
:stage_license
if "%RUN_STAGE%"=="" goto :stage_license_run
if /I "%RUN_STAGE%"=="license" goto :stage_license_run
goto :stage_sbom

:stage_license_run
echo.
echo [6/9] license...
call "%GATE_DIR%gate-license.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=license
    goto :gate_end
)
echo PASSED: license
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 7. SBOM =====
:stage_sbom
if "%RUN_STAGE%"=="" goto :stage_sbom_run
if /I "%RUN_STAGE%"=="SBOM" goto :stage_sbom_run
goto :stage_build

:stage_sbom_run
echo.
echo [7/9] SBOM...
call "%GATE_DIR%gate-sbom.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=SBOM
    goto :gate_end
)
echo PASSED: SBOM
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 8. build =====
:stage_build
if "%RUN_STAGE%"=="" goto :stage_build_run
if /I "%RUN_STAGE%"=="build" goto :stage_build_run
goto :stage_package

:stage_build_run
echo.
echo [8/9] build - default product (API24)...
cd /d %APP_DIR%
call hvigorw.bat assembleHap --no-daemon -p product=default >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: build - default product
    set FAILED=1
    set FAILED_STAGE=build
    set FAILED_DETAIL=default product API24 build failed
    goto :gate_end
)
echo [8/9] build - store product (API14)...
call hvigorw.bat assembleHap --no-daemon -p product=store >nul 2>&1
if !errorlevel! neq 0 (
    echo FAILED: build - store product
    set FAILED=1
    set FAILED_STAGE=build
    set FAILED_DETAIL=store product API14 build failed
    goto :gate_end
)
echo PASSED: build - dual product
if not "%RUN_STAGE%"=="" goto :gate_end

REM ===== 9. package =====
:stage_package
if "%RUN_STAGE%"=="" goto :stage_package_run
if /I "%RUN_STAGE%"=="package" goto :stage_package_run
goto :gate_end

:stage_package_run
echo.
echo [9/9] package...
call "%GATE_DIR%gate-package.cmd"
if !errorlevel! neq 0 (
    set FAILED=1
    set FAILED_STAGE=package
    goto :gate_end
)
echo PASSED: package
if not "%RUN_STAGE%"=="" goto :gate_end

:gate_end
echo.
echo ========================================
if !FAILED! equ 0 (
    echo ALL GATES PASSED - 发布就绪
    exit /b 0
) else (
    echo GATE FAILED at: !FAILED_STAGE!
    if not "!FAILED_DETAIL!"=="" echo 原因: !FAILED_DETAIL!
    echo 不产出发布包
    exit /b 1
)