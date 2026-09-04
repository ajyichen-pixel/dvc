@echo off
setlocal EnableExtensions
echo ============================================================
echo DVC CONTENT ANALYSIS AGENT V1 - VERIFY
echo ============================================================

powershell.exe -NoProfile -Command "$p=Get-Process -Name 'DVCContentAnalysisAgent' -ErrorAction SilentlyContinue; if($p){ exit 0 } else { exit 1 }"
if errorlevel 1 (echo [FAIL] Agent process not running.) else (echo [PASS] Agent process running.)

schtasks /Query /TN "DVC Content Analysis Agent" >nul 2>nul
if errorlevel 1 (echo [FAIL] Startup task missing.) else (echo [PASS] Startup task present.)

reg query "HKLM\SOFTWARE\Policies\Google\Chrome" /v CloudManagementEnrollmentToken >nul 2>nul
if errorlevel 1 (
  echo [INFO] CloudManagementEnrollmentToken is not present on this machine.
  echo [INFO] Token presence is not required after every enrollment scenario, so confirm chrome://management.
) else (
  echo [PASS] Chrome Enterprise Core enrollment token is present.
)

reg query "HKLM\SOFTWARE\Policies\Google\Chrome" /v OnFileAttachedEnterpriseConnector >nul 2>nul
if errorlevel 1 (
  echo [PASS] No legacy platform OnFileAttachedEnterpriseConnector value detected.
) else (
  echo [WARN] Legacy platform OnFileAttachedEnterpriseConnector value detected.
  echo [WARN] This policy is cloud-only. A local HKLM/GPO value is not a valid production activation method.
)

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
schtasks /Query /TN "DVC Content Analysis Agent" /V /FO LIST 2>nul

echo.
echo ===== REQUIRED CHROME CHECKS =====
echo 1. chrome://management must show the browser is managed.
echo 2. Google Admin Console must have Chrome Enterprise Connectors enabled.
echo 3. Upload content analysis must have a Local Content Analysis DLP vendor selected.
echo 4. chrome://policy must show OnFileAttachedEnterpriseConnector from cloud management.
echo 5. Expand the policy and confirm service_provider is local_system_agent or the vendor value delivered by Google.
echo.
echo Final success marker after a blocked upload: ENFORCEMENT_CONFIRMED
pause
