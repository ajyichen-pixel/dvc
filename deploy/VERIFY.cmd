@echo off
setlocal EnableExtensions
echo ============================================================
echo DVC CONTENT ANALYSIS AGENT V1 - VERIFY
echo ============================================================

tasklist /FI "IMAGENAME eq DVCContentAnalysisAgent.exe" | find /I "DVCContentAnalysisAgent.exe" >nul
if errorlevel 1 (echo [FAIL] Agent process not running.) else (echo [PASS] Agent process running.)

schtasks /Query /TN "DVC Content Analysis Agent" >nul 2>nul
if errorlevel 1 (echo [FAIL] Startup task missing.) else (echo [PASS] Startup task present.)

reg query "HKLM\SOFTWARE\Policies\Google\Chrome" /v OnFileAttachedEnterpriseConnector >nul 2>nul
if errorlevel 1 (echo [FAIL] Chrome connector policy missing.) else (echo [PASS] Chrome connector policy present.)

set "LOG=%ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log"
set "BOOTLOG=%ProgramData%\DVC\ContentAnalysis\logs\agent_boot.log"
if exist "%LOG%" (
  echo [PASS] Log file present.
  echo.
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath $env:ProgramData\DVC\ContentAnalysis\logs\dvc_content_analysis.log -Tail 30"
) else (
  echo [INFO] Log file not created yet.
)

if exist "%BOOTLOG%" (
  echo.
  echo ===== AGENT BOOT LOG =====
  type "%BOOTLOG%"
)

echo.
echo ===== TASK STATUS =====
schtasks /Query /TN "DVC Content Analysis Agent" /V /FO LIST 2>nul | findstr /I /C:"Status:" /C:"Last Run Time:" /C:"Last Result:"

echo.
echo Chrome check: chrome://policy
echo Expected policy: OnFileAttachedEnterpriseConnector
echo Final success marker after a blocked upload: ENFORCEMENT_CONFIRMED
pause
