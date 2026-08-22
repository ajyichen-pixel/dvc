@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if not exist "%ProgramData%\DVC\ContentAnalysis\logs" mkdir "%ProgramData%\DVC\ContentAnalysis\logs" >nul 2>nul
set "BOOTLOG=%ProgramData%\DVC\ContentAnalysis\logs\agent_boot.log"
echo ============================================================>>"%BOOTLOG%"
echo START %DATE% %TIME%>>"%BOOTLOG%"
echo CWD=%CD%>>"%BOOTLOG%"
echo EXE=%~dp0DVCContentAnalysisAgent.exe>>"%BOOTLOG%"
echo AGENT_START_REQUEST >> "%ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log"
"%~dp0DVCContentAnalysisAgent.exe" >>"%BOOTLOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo EXIT_CODE=%RC%>>"%BOOTLOG%"
exit /b %RC%
