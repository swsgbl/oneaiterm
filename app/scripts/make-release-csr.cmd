@echo off
rem ============================================================
rem upstream KaihongOS - RELEASE track key material generator
rem Produces (in thirdparty\signing\release\):
rem   upstream-release.p12  - app release signing key (ECC NIST-P-256)
rem   upstream-release.csr  - Certificate Signing Request to submit
rem                          on developer.kaihong.com for release cert
rem Usage:
rem   scripts\make-release-csr.cmd                          (placeholder subject)
rem   scripts\make-release-csr.cmd "C=CN,O=REALNAME,CN=REALNAME"
rem NOTE: regenerate with your REAL verified subject before applying
rem       the certificate on the Kaihong developer platform.
rem ============================================================
setlocal
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "SIGNJAR=%DEVECO%\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
set "JAVA=%DEVECO%\jbr\bin\java.exe"
if not exist "%JAVA%" set "JAVA=java"

set "OUT=%ROOT%\thirdparty\signing\release"
if not exist "%OUT%" mkdir "%OUT%"
set "KS=%OUT%\upstream-release.p12"
set "CSR=%OUT%\upstream-release.csr"
set "ALIAS=upstream-release-key"
set "SUBJ=%~1"
if "%SUBJ%"=="" set "SUBJ=C=CN,O=upstream-dev,CN=upstream release key (PLACEHOLDER - regenerate with real subject)"

if exist "%KS%" (
  echo [csr] WARNING: %KS% already exists. Delete it first to regenerate.
  echo [csr] Keeping existing keystore to avoid invalidating an issued certificate.
  exit /b 0
)

echo [csr] 1/2 generate keypair (ECC NIST-P-256) ...
"%JAVA%" -jar "%SIGNJAR%" generate-keypair -keyAlias "%ALIAS%" -keyPwd upstream-rel-2026 -keyAlg ECC -keySize NIST-P-256 -keystoreFile "%KS%" -keystorePwd upstream-rel-2026
if errorlevel 1 ( echo [csr] keypair FAILED & exit /b 1 )

echo [csr] 2/2 generate CSR ...
"%JAVA%" -jar "%SIGNJAR%" generate-csr -keyAlias "%ALIAS%" -keyPwd upstream-rel-2026 -subject "%SUBJ%" -signAlg SHA256withECDSA -keystoreFile "%KS%" -keystorePwd upstream-rel-2026 -outFile "%CSR%"
if errorlevel 1 ( echo [csr] CSR FAILED & exit /b 1 )

echo [csr] DONE:
dir /b "%OUT%"
echo [csr] Submit upstream-release.csr on developer.kaihong.com to obtain:
echo [csr]   - release certificate (.cer/.p7b)  -^> save as upstream-release-cert.cer
echo [csr]   - release Profile (.p7b)           -^> save as upstream-release-profile.p7b
echo [csr] then run scripts\sign-release.cmd
endlocal
