@echo off
rem ============================================================
rem upstream KaihongOS - RELEASE signing (store track)
rem Requires platform-issued files in thirdparty\signing\release\:
rem   upstream-release.p12             (from make-release-csr.cmd)
rem   upstream-release-cert.cer/.p7b   (issued by developer.kaihong.com)
rem   upstream-release-profile.p7b     (issued by developer.kaihong.com)
rem Signs the newest unsigned HAP -> *-release-signed.hap
rem ============================================================
setlocal
set "ROOT=%~dp0.."
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "SIGNJAR=%DEVECO%\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
set "JAVA=%DEVECO%\jbr\bin\java.exe"
if not exist "%JAVA%" set "JAVA=java"
set "OUT=%ROOT%\thirdparty\signing\release"
set "KS=%OUT%\upstream-release.p12"
set "CERT=%OUT%\upstream-release-cert.cer"
if not exist "%CERT%" set "CERT=%OUT%\upstream-release-cert.p7b"
set "PROFILE=%OUT%\upstream-release-profile.p7b"

for %%F in ("%KS%" "%CERT%" "%PROFILE%") do if not exist %%F (
  echo [sign-release] MISSING: %%~F
  echo [sign-release] Obtain cert+profile via developer.kaihong.com with upstream-release.csr first.
  exit /b 1
)

set "HAP="
for /f "delims=" %%F in ('dir /b /s /o-d "%ROOT%\entry\build\default\*.hap" 2^>nul ^| findstr /v /i /c:"signed"') do (
  if not defined HAP set "HAP=%%F"
)
if not defined HAP ( echo [sign-release] no unsigned hap - run build.cmd first & exit /b 1 )

set "SIGNED=%ROOT%\entry\build\default\outputs\default\entry-release-signed.hap"
echo [sign-release] signing "%HAP%" ...
"%JAVA%" -jar "%SIGNJAR%" sign-app -keyAlias "upstream-release-key" -signAlg SHA256withECDSA -mode "localSignature" -appCertFile "%CERT%" -profileFile "%PROFILE%" -inFile "%HAP%" -keystoreFile "%KS%" -keyPwd upstream-rel-2026 -signAlg SHA256withECDSA -outFile "%SIGNED%" 2>&1 | findstr /i "error success"
if not exist "%SIGNED%" ( echo [sign-release] FAILED & exit /b 1 )
"%JAVA%" -jar "%SIGNJAR%" verify-app -inFile "%SIGNED%" 2>&1 | findstr /i "error digest cert"
echo [sign-release] DONE: %SIGNED%
endlocal
