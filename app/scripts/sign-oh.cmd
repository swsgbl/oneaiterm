@echo off
rem ============================================================
rem upstream M5 relay1 - sign-oh.cmd
rem Signs newest unsigned HAP with OH community chain (key 123456).
rem Profile: oh-community\app1-profile-release.p7b (release type,
rem system_core APL - matches what the 15566 VM trusts).
rem Usage: scripts\sign-oh.cmd [HAP_PATH]
rem   default: newest unsigned .hap under entry\build\default\outputs
rem ============================================================
setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "SIGNJAR=%DEVECO%\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
set "JAVA=%DEVECO%\jbr\bin\java.exe"
if not exist "%JAVA%" set "JAVA=java"

set "SIGNING=%ROOT%\thirdparty\signing"
set "OHDIR=%SIGNING%\oh-community"
set "OHKS=%OHDIR%\OpenHarmony.p12"
set "OHCERT=%SIGNING%\oh-verify-chain.cer"
if not exist "%OHCERT%" set "OHCERT=%OHDIR%\OpenHarmonyApplication.pem"
set "PROF=%OHDIR%\app1-profile-release.p7b"

for %%F in ("%OHKS%" "%OHCERT%" "%PROF%") do if not exist %%F (
  echo [sign-oh] MISSING %%~F
  exit /b 1
)

rem locate newest unsigned HAP under entry\build\default\outputs
set "HAP=%~1"
if "%HAP%"=="" (
  set "HAP="
  for /f "delims=" %%F in ('dir /b /s /o-d "%ROOT%\entry\build\default\outputs\default\*.hap" 2^>nul ^| findstr /v /i /c:"signed"') do (
    if not defined HAP set "HAP=%%F"
  )
)
if not defined HAP (
  echo [sign-oh] no unsigned .hap under entry\build\default\outputs\default
  echo [sign-oh] run: scripts\build.cmd first
  exit /b 1
)
echo [sign-oh] target HAP: %HAP%
for %%I in ("%HAP%") do set "HAPDIR=%%~dpI"
set "SIGNED_HAP=%HAPDIR%entry-default-oh-signed.hap"
if exist "%SIGNED_HAP%" del "%SIGNED_HAP%"

echo [sign-oh] sign-app (OH community chain, SHA384withECDSA, compatibleVersion 14)
"%JAVA%" -jar "%SIGNJAR%" sign-app -mode localSign -keyAlias "OpenHarmony Application Release" -keyPwd 123456 -appCertFile "%OHCERT%" -profileFile "%PROF%" -inFile "%HAP%" -signAlg SHA384withECDSA -keystoreFile "%OHKS%" -keystorePwd 123456 -outFile "%SIGNED_HAP%" -compatibleVersion 14
if not exist "%SIGNED_HAP%" (
  echo [sign-oh] FAILED: signed hap not produced
  exit /b 1
)

echo [sign-oh] verify-app
"%JAVA%" -jar "%SIGNJAR%" verify-app -inFile "%SIGNED_HAP%" || goto :fail

echo [sign-oh] OK: %SIGNED_HAP%
for %%I in ("%SIGNED_HAP%") do echo [sign-oh] size=%%~zI
endlocal & exit /b 0

:fail
echo [sign-oh] FAILED at verify step
endlocal & exit /b 1
