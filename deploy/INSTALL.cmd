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
for %%F in ("%~dp0*.dll") do if exist "%%~fF" copy /y "%%~fF" "%DST%\%%~nxF" >nul

schtasks /End /TN "DVC Content Analysis Agent" >nul 2>nul
schtasks /Delete /TN "DVC Content Analysis Agent" /F >nul 2>nul
schtasks /Create /TN "DVC Content Analysis Agent" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"%DST%\START_AGENT.cmd\"" /F
if errorlevel 1 (
  echo [FAIL] Unable to create startup task.
  pause
  exit /b 1
)

REM IMPORTANT: OnFileAttachedEnterpriseConnector is cloud-only in Chrome.
REM Do NOT install it through HKLM/GPO. It must arrive from Chrome Enterprise Core.
reg query "HKLM\SOFTWARE\Policies\Google\Chrome" /v OnFileAttachedEnterpriseConnector >nul 2>nul
if not errorlevel 1 (
  echo [WARN] Legacy platform OnFileAttachedEnterpriseConnector value detected.
  echo [WARN] This connector policy is cloud-only and this local value must not be used as proof of activation.
)

schtasks /Run /TN "DVC Content Analysis Agent" >nul
timeout /t 2 /nobreak >nul
powershell.exe -NoProfile -Command "$p=Get-Process -Name 'DVCContentAnalysisAgent' -ErrorAction SilentlyContinue; if($p){exit 0}else{exit 1}"
if errorlevel 1 (
  echo [WARN] Agent did not remain running. Run VERIFY.cmd and send the AGENT BOOT LOG.
) else (
  echo [PASS] Agent process is running.
)

echo.
echo [PASS] DVC Content Analysis Agent V1 installed.
echo [REQUIRED] Enroll Chrome in Chrome Enterprise Core and enable Local Content Analysis in Google Admin Console.
echo [REQUIRED] chrome://policy must show OnFileAttachedEnterpriseConnector delivered by cloud management.
echo Log: %ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log
pause
