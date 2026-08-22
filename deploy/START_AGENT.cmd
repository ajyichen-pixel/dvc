@echo off
setlocal
cd /d "%~dp0"
if not exist "%ProgramData%\DVC\ContentAnalysis\logs" mkdir "%ProgramData%\DVC\ContentAnalysis\logs" >nul 2>nul
echo AGENT_START_REQUEST >> "%ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log"
"%~dp0DVCContentAnalysisAgent.exe"
