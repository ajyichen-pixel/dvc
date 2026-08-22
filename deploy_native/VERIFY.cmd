@echo off
setlocal EnableExtensions
title DVC Upload Guard Native V1 - Verify
set "ROOT=C:\Program Files\DVC\UploadGuard"
set "LOG=%ProgramData%\DVC\UploadGuard\logs\dvc_upload_guard.log"
set "FAIL=0"

echo ============================================================
echo DVC UPLOAD GUARD NATIVE V1 - VERIFY
echo ============================================================

if exist "%ROOT%\DVCUploadGuardHost.exe" (echo [PASS] Native host EXE present.) else (echo [FAIL] Native host EXE missing.& set "FAIL=1")
if exist "%ROOT%\native_host_manifest.json" (echo [PASS] Native host manifest present.) else (echo [FAIL] Native host manifest missing.& set "FAIL=1")
if exist "%ROOT%\extension\manifest.json" (echo [PASS] Browser extension present.) else (echo [FAIL] Browser extension missing.& set "FAIL=1")

reg query "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [WARN] Chrome HKLM 64-bit registration missing.) else (echo [PASS] Chrome native host registered.)
reg query "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [WARN] Edge HKLM 64-bit registration missing.) else (echo [PASS] Edge native host registered.)

echo.
echo ===== HOST HEALTH =====
if exist "%ROOT%\DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" --health
if errorlevel 1 set "FAIL=1"

echo.
echo ===== HOST SELFTEST =====
if exist "%ROOT%\DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" --selftest
if errorlevel 1 set "FAIL=1"

echo.
echo Extension ID: cdmogelilldmfcioieahdnaocmillhcl
echo Native host: com.trcore.dvc_upload_guard
echo Test Chrome: "%ROOT%\START_TEST_CHROME.cmd"
echo Test Edge:   "%ROOT%\START_TEST_EDGE.cmd"

echo.
echo ===== RECENT LOG =====
if exist "%LOG%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%LOG%' -Tail 30"
) else (
  echo No native host log yet. This is normal before the first browser request.
)

if "%FAIL%"=="0" (echo.&echo VERIFY_PASS) else (echo.&echo VERIFY_FAIL)
pause
exit /b %FAIL%
