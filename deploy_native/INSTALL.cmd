@echo off
setlocal EnableExtensions
title DVC Upload Guard Native V1 - Install

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator permission...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)

set "ROOT=C:\Program Files\DVC\UploadGuard"
set "LOGROOT=%ProgramData%\DVC\UploadGuard"
set "EXTID=cdmogelilldmfcioieahdnaocmillhcl"

echo ============================================================
echo DVC UPLOAD GUARD NATIVE V1 - INSTALL
echo ============================================================

if not exist "%ROOT%" mkdir "%ROOT%"
if not exist "%ROOT%\extension" mkdir "%ROOT%\extension"
if not exist "%LOGROOT%\logs" mkdir "%LOGROOT%\logs"

copy /Y "%~dp0DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" >nul
if errorlevel 1 goto :fail
copy /Y "%~dp0native_host_manifest.json" "%ROOT%\native_host_manifest.json" >nul
if errorlevel 1 goto :fail
copy /Y "%~dp0START_TEST_CHROME.cmd" "%ROOT%\START_TEST_CHROME.cmd" >nul
copy /Y "%~dp0START_TEST_EDGE.cmd" "%ROOT%\START_TEST_EDGE.cmd" >nul
copy /Y "%~dp0GET_TEST_BROWSER.ps1" "%ROOT%\GET_TEST_BROWSER.ps1" >nul
copy /Y "%~dp0VERIFY.cmd" "%ROOT%\VERIFY.cmd" >nul
copy /Y "%~dp0DVC_BROWSER_POLICY.reg" "%ROOT%\DVC_BROWSER_POLICY.reg" >nul
robocopy "%~dp0extension" "%ROOT%\extension" /E /NFL /NDL /NJH /NJS /NP >nul

icacls "%LOGROOT%" /grant *S-1-5-32-545:(OI)(CI)M /T /C >nul 2>&1

echo [1/4] Register Chrome and Edge native messaging host...
reg add "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:64 >nul 2>&1
reg add "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:32 >nul 2>&1
reg add "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:64 >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:32 >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f >nul 2>&1

echo [2/4] Import Chrome and Edge managed DVC redaction policy...
reg import "%ROOT%\DVC_BROWSER_POLICY.reg" >nul 2>&1
if errorlevel 1 goto :fail

echo [3/4] Run native host self-test...
"%ROOT%\DVCUploadGuardHost.exe" --health
if errorlevel 1 goto :fail
"%ROOT%\DVCUploadGuardHost.exe" --selftest
if errorlevel 1 goto :fail

echo [4/4] Launch isolated Chrome for Testing profile...
call "%ROOT%\START_TEST_CHROME.cmd"
if errorlevel 1 goto :fail

echo.
echo INSTALL_OK
echo Extension ID: %EXTID%
echo Native host: com.trcore.dvc_upload_guard
echo Managed redaction policy: WRITTEN
echo The DVC test page should be open in Chrome for Testing.
echo.
pause
exit /b 0

:fail
echo.
echo INSTALL_FAILED
echo Run VERIFY.cmd and keep the console output.
pause
exit /b 1
