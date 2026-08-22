@echo off
setlocal EnableExtensions
net session >nul 2>nul
if errorlevel 1 (
  echo [FAIL] Run INSTALL.cmd as Administrator.
  pause
  exit /b 1
)

set "DST=%ProgramFiles%\DVC\ContentAnalysis"
if not exist "%DST%" mkdir "%DST%"
copy /y "%~dp0DVCContentAnalysisAgent.exe" "%DST%\DVCContentAnalysisAgent.exe" >nul
copy /y "%~dp0DVC_DOCX_SCAN.ps1" "%DST%\DVC_DOCX_SCAN.ps1" >nul
copy /y "%~dp0START_AGENT.cmd" "%DST%\START_AGENT.cmd" >nul

schtasks /Delete /TN "DVC Content Analysis Agent" /F >nul 2>nul
schtasks /Create /TN "DVC Content Analysis Agent" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"%DST%\START_AGENT.cmd\"" /F
if errorlevel 1 (
  echo [FAIL] Unable to create startup task.
  pause
  exit /b 1
)

reg import "%~dp0chrome_policy.reg"
if errorlevel 1 (
  echo [FAIL] Unable to import Chrome policy.
  pause
  exit /b 1
)

schtasks /Run /TN "DVC Content Analysis Agent" >nul
echo.
echo [PASS] DVC Content Analysis Agent V1 installed.
echo Restart Chrome, then open chrome://policy and click Reload policies.
echo Log: %ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log
pause
