@echo off
rem ============================================================
rem upstream KaihongOS M4-relay4 - sign newest unsigned HAP from
rem entry\build\store (store flavor: apiCompatibleVersion 14)
rem Same keychain as sign.cmd (app.p12 + ca.p12 under thirdparty\signing),
rem but -compatibleVersion 14 so KaihongOS 5.0.2.57 (API14) accepts the HAP.
rem Usage: scripts\sign-store.cmd
rem ============================================================
setlocal
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "SIGNJAR=%DEVECO%\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
set "JAVA=%DEVECO%\jbr\bin\java.exe"
if not exist "%JAVA%" set "JAVA=java"

set "OUT=%ROOT%\thirdparty\signing"
if not exist "%OUT%" mkdir "%OUT%"
set "APPKS=%OUT%\app.p12"
set "CAKS=%OUT%\ca.p12"
set "ROOT_CER=%OUT%\rootCA.cer"
set "SUBAPP_CER=%OUT%\subAppCA.cer"
set "SUBPROF_CER=%OUT%\subProfileCA.cer"
set "APP_CER=%OUT%\upstream-app-cert.cer"
set "PROF_CER=%OUT%\upstream-profile-cert.cer"
set "PROFILE_JSON=%OUT%\upstream-debug-profile.json"
set "PROFILE_P7B=%OUT%\upstream-debug-profile.p7b"
set "SUBJ_ROOT=C=CN,O=upstream,OU=upstream,CN=upstream Root CA"
set "SUBJ_SUBAPP=C=CN,O=upstream,OU=upstream,CN=upstream App Sign CA"
set "SUBJ_SUBPROF=C=CN,O=upstream,OU=upstream,CN=upstream Profile Sign CA"

if not exist "%APPKS%" (
  echo [sign-store] ERROR: %APPKS% missing - run scripts\sign.cmd once first to build the keychain
  exit /b 1
)
if not exist "%APP_CER%" (
  echo [sign-store] ERROR: %APP_CER% missing - run scripts\sign.cmd once first to build the keychain
  exit /b 1
)

rem ---- locate newest unsigned HAP under entry\build\store ----
set "HAP="
for /f "delims=" %%F in ('dir /b /s /o-d "%ROOT%\entry\build\store\*.hap" 2^>nul ^| findstr /v /i /c:"-signed"') do (
  if not defined HAP set "HAP=%%F"
)
if not defined HAP (
  echo [sign-store] ERROR: no unsigned .hap under entry\build\store - run scripts\build-store.cmd build step first
  exit /b 1
)
echo [sign-store] target HAP: %HAP%
for %%I in ("%HAP%") do set "HAPDIR=%%~dpI"
set "SIGNED_HAP=%HAPDIR%entry-store-signed.hap"
if exist "%SIGNED_HAP%" del "%SIGNED_HAP%"

echo [sign-store] sign-app (compatibleVersion 14)
"%JAVA%" -jar "%SIGNJAR%" sign-app -mode localSign -keyAlias "upstreamkey" -keyPwd 123456 -appCertFile "%APP_CER%" -profileFile "%PROFILE_P7B%" -inFile "%HAP%" -signAlg SHA256withECDSA -keystoreFile "%APPKS%" -keystorePwd 123456 -outFile "%SIGNED_HAP%" -compatibleVersion 14 || goto :fail

echo [sign-store] verify-app
"%JAVA%" -jar "%SIGNJAR%" verify-app -inFile "%SIGNED_HAP%" -outCertChain "%OUT%\verify-cert-chain.cer" -outProfile "%OUT%\verify-profile.p7b" || goto :fail

echo [sign-store] OK: %SIGNED_HAP%
for %%I in ("%SIGNED_HAP%") do echo [sign-store] size=%%~zI
endlocal & exit /b 0

:fail
echo [sign-store] FAILED
endlocal & exit /b 1
