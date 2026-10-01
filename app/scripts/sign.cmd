@echo off
rem ============================================================
rem upstream KaihongOS M1a - full self-built debug signing chain
rem Keys:  app.p12 (upstreamkey)        - app signing key
rem         ca.p12  (upstreamroot/subapp/subprofile/profile) - CA keys
rem Chain: root CA -> subAppCA  -> app cert (certChain)
rem         root CA -> subProfCA -> profile cert (certChain) -> p7b -> sign HAP
rem All passwords 123456. bundleName=com.oneaiterm.terminal, compatibleVersion 24
rem Params verified against `hap-sign-tool.jar -h` (API26 toolchain).
rem Usage: scripts\sign.cmd  (signs newest unsigned HAP from build.cmd)
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

rem ---- locate newest unsigned HAP ----
set "HAP="
for /f "delims=" %%F in ('dir /b /s /o-d "%ROOT%\entry\build\default\*.hap" 2^>nul ^| findstr /v /i /c:"-signed"') do (
  if not defined HAP set "HAP=%%F"
)
if not defined HAP (
  echo [sign] ERROR: no unsigned .hap under entry\build\default - run build.cmd first
  exit /b 1
)
echo [sign] target HAP: %HAP%
for %%I in ("%HAP%") do set "HAPDIR=%%~dpI"
set "SIGNED_HAP=%HAPDIR%entry-default-signed.hap"
if exist "%SIGNED_HAP%" del "%SIGNED_HAP%"

echo [sign] 1/9 app keypair (app.p12 / upstreamkey)
if exist "%APPKS%" del "%APPKS%"
"%JAVA%" -jar "%SIGNJAR%" generate-keypair -keyAlias "upstreamkey" -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -keystoreFile "%APPKS%" -keystorePwd 123456 || goto :fail

echo [sign] 2/9 root CA (ca.p12 / upstreamroot)
if exist "%CAKS%" del "%CAKS%"
"%JAVA%" -jar "%SIGNJAR%" generate-ca -keyAlias "upstreamroot" -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -subject "%SUBJ_ROOT%" -validity 3650 -signAlg SHA256withECDSA -basicConstraintsPathLen 2 -keystoreFile "%CAKS%" -keystorePwd 123456 -outFile "%ROOT_CER%" || goto :fail

echo [sign] 3/9 sub CA for app certs (issued by root)
"%JAVA%" -jar "%SIGNJAR%" generate-ca -keyAlias "upstreamsubapp" -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -issuer "%SUBJ_ROOT%" -issuerKeyAlias "upstreamroot" -issuerKeyPwd 123456 -subject "%SUBJ_SUBAPP%" -validity 3650 -signAlg SHA256withECDSA -basicConstraintsPathLen 0 -keystoreFile "%CAKS%" -keystorePwd 123456 -outFile "%SUBAPP_CER%" || goto :fail

echo [sign] 4/9 sub CA for profile certs (issued by root)
"%JAVA%" -jar "%SIGNJAR%" generate-ca -keyAlias "upstreamsubprof" -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -issuer "%SUBJ_ROOT%" -issuerKeyAlias "upstreamroot" -issuerKeyPwd 123456 -subject "%SUBJ_SUBPROF%" -validity 3650 -signAlg SHA256withECDSA -basicConstraintsPathLen 0 -keystoreFile "%CAKS%" -keystorePwd 123456 -outFile "%SUBPROF_CER%" || goto :fail

echo [sign] 5/9 profile signing keypair (ca.p12 / upstreamprofile)
"%JAVA%" -jar "%SIGNJAR%" generate-keypair -keyAlias "upstreamprofile" -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -keystoreFile "%CAKS%" -keystorePwd 123456 || goto :fail

echo [sign] 6/9 app cert chain (key=upstreamkey@app.p12, issuer=subAppCA)
"%JAVA%" -jar "%SIGNJAR%" generate-app-cert -keyAlias "upstreamkey" -keyPwd 123456 -issuer "%SUBJ_SUBAPP%" -issuerKeyAlias "upstreamsubapp" -issuerKeyPwd 123456 -subject "C=CN,O=upstream,OU=upstream,CN=com.oneaiterm.terminal" -validity 3650 -signAlg SHA256withECDSA -rootCaCertFile "%ROOT_CER%" -subCaCertFile "%SUBAPP_CER%" -keystoreFile "%APPKS%" -keystorePwd 123456 -issuerKeystoreFile "%CAKS%" -issuerKeystorePwd 123456 -outForm certChain -outFile "%APP_CER%" || goto :fail

echo [sign] 7/9 profile cert chain + profile json + sign-profile (p7b)
"%JAVA%" -jar "%SIGNJAR%" generate-profile-cert -keyAlias "upstreamprofile" -keyPwd 123456 -issuer "%SUBJ_SUBPROF%" -issuerKeyAlias "upstreamsubprof" -issuerKeyPwd 123456 -subject "C=CN,O=upstream,OU=upstream,CN=upstream Provision Profile" -validity 3650 -signAlg SHA256withECDSA -rootCaCertFile "%ROOT_CER%" -subCaCertFile "%SUBPROF_CER%" -keystoreFile "%CAKS%" -keystorePwd 123456 -outForm certChain -outFile "%PROF_CER%" || goto :fail
if exist "%PROFILE_JSON%" del "%PROFILE_JSON%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\_make_profile.ps1" -AppCert "%APP_CER%" -OutJson "%PROFILE_JSON%" || goto :fail
"%JAVA%" -jar "%SIGNJAR%" sign-profile -mode localSign -keyAlias "upstreamprofile" -keyPwd 123456 -profileCertFile "%PROF_CER%" -inFile "%PROFILE_JSON%" -signAlg SHA256withECDSA -keystoreFile "%CAKS%" -keystorePwd 123456 -outFile "%PROFILE_P7B%" || goto :fail

echo [sign] 8/9 sign-app (compatibleVersion 24)
"%JAVA%" -jar "%SIGNJAR%" sign-app -mode localSign -keyAlias "upstreamkey" -keyPwd 123456 -appCertFile "%APP_CER%" -profileFile "%PROFILE_P7B%" -inFile "%HAP%" -signAlg SHA256withECDSA -keystoreFile "%APPKS%" -keystorePwd 123456 -outFile "%SIGNED_HAP%" -compatibleVersion 24 || goto :fail

echo [sign] 9/9 verify-app
"%JAVA%" -jar "%SIGNJAR%" verify-app -inFile "%SIGNED_HAP%" -outCertChain "%OUT%\verify-cert-chain.cer" -outProfile "%OUT%\verify-profile.p7b" || goto :fail

echo [sign] OK: %SIGNED_HAP%
for %%I in ("%SIGNED_HAP%") do echo [sign] size=%%~zI
endlocal & exit /b 0

:fail
echo [sign] FAILED (see steps above)
endlocal & exit /b 1
