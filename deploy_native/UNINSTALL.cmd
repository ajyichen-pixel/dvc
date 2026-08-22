@echo off
setlocal EnableExtensions
title DVC Upload Guard Native V1 - Uninstall

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator permission...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)

set "ROOT=C:\Program Files\DVC\UploadGuard"

reg delete "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f /reg:64 >nul 2>&1
reg delete "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f /reg:32 >nul 2>&1
reg delete "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f /reg:64 >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f /reg:32 >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.trcore.dvc_upload_guard" /f >nul 2>&1

if exist "%ROOT%" rmdir /S /Q "%ROOT%"

echo UNINSTALL_OK
echo Test browser profiles and ProgramData logs are intentionally kept for diagnostics.
pause
exit /b 0
