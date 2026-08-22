@echo off
setlocal EnableExtensions
title DVC Upload Guard Native V1 - Verify
set "ROOT=C:\Program Files\DVC\UploadGuard"
set "LOG=%ProgramData%\DVC\UploadGuard\logs\dvc_upload_guard.log"
set "EXTID=cdmogelilldmfcioieahdnaocmillhcl"
set "FAIL=0"

echo ============================================================
echo DVC UPLOAD GUARD NATIVE V1 - VERIFY
echo ============================================================

if exist "%ROOT%\DVCUploadGuardHost.exe" (echo [PASS] Native host EXE present.) else (echo [FAIL] Native host EXE missing.& set "FAIL=1")
if exist "%ROOT%\native_host_manifest.json" (echo [PASS] Native host manifest present.) else (echo [FAIL] Native host manifest missing.& set "FAIL=1")
if exist "%ROOT%\extension\manifest.json" (echo [PASS] Browser extension present.) else (echo [FAIL] Browser extension missing.& set "FAIL=1")
if exist "%ROOT%\extension\policy_schema.json" (echo [PASS] Managed policy schema present.) else (echo [FAIL] Managed policy schema missing.& set "FAIL=1")

reg query "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [WARN] Chrome native host registration missing.) else (echo [PASS] Chrome native host registered.)
reg query "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [WARN] Edge native host registration missing.) else (echo [PASS] Edge native host registered.)

echo.
echo ===== CHROME MANAGED POLICY =====
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\3rdparty\extensions\%EXTID%\policy" /v Enabled >nul 2>&1
if errorlevel 1 (echo [FAIL] Chrome managed DVC policy missing.& set "FAIL=1") else (echo [PASS] Chrome managed DVC policy present.)
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\3rdparty\extensions\%EXTID%\policy" /v RedactionTermsJson
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\3rdparty\extensions\%EXTID%\policy" /v ReplacementText

echo.
echo ===== EDGE MANAGED POLICY =====
reg query "HKLM\SOFTWARE\Policies\Microsoft\Edge\3rdparty\extensions\%EXTID%\policy" /v Enabled >nul 2>&1
if errorlevel 1 (echo [WARN] Edge managed DVC policy missing.) else (echo [PASS] Edge managed DVC policy present.)

echo.
echo ===== HOST HEALTH =====
if exist "%ROOT%\DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" --health
if errorlevel 1 set "FAIL=1"

echo.
echo ===== HOST SELFTEST =====
if exist "%ROOT%\DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" --selftest
if errorlevel 1 set "FAIL=1"

echo.
echo Extension ID: %EXTID%
echo Native host: com.trcore.dvc_upload_guard
echo Test Chrome: "%ROOT%\START_TEST_CHROME.cmd"
echo Test Edge:   "%ROOT%\START_TEST_EDGE.cmd"
echo In the DVC test Chrome, open chrome://policy and click Reload policies.

echo.
echo ===== RECENT LOG =====
if exist "%LOG%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%LOG%' -Tail 40"
) else (
  echo No native host log yet. This is normal before the first browser request.
)

if "%FAIL%"=="0" (echo.&echo VERIFY_PASS) else (echo.&echo VERIFY_FAIL)
pause
exit /b %FAIL%
