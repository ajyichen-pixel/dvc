@echo off
setlocal EnableExtensions
net session >nul 2>nul
if errorlevel 1 (
  echo [FAIL] Run UNINSTALL.cmd as Administrator.
  pause
  exit /b 1
)

schtasks /End /TN "DVC Content Analysis Agent" >nul 2>nul
schtasks /Delete /TN "DVC Content Analysis Agent" /F >nul 2>nul
taskkill /IM DVCContentAnalysisAgent.exe /F >nul 2>nul
reg delete "HKLM\SOFTWARE\Policies\Google\Chrome" /v OnFileAttachedEnterpriseConnector /f >nul 2>nul
rmdir /s /q "%ProgramFiles%\DVC\ContentAnalysis" >nul 2>nul
echo [PASS] DVC Content Analysis Agent V1 removed.
pause
