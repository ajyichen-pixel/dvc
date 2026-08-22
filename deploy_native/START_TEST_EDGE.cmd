@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\UploadGuard"
set "EXT=%ROOT%\extension"
set "PROFILE=%LOCALAPPDATA%\DVC\UploadGuardEdgeProfile"
set "EDGE="

if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined EDGE if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"

if not defined EDGE (
  echo EDGE_NOT_FOUND
  exit /b 2
)

if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "DVC Upload Guard Test" "%EDGE%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/test.html"
echo EDGE_TEST_PROFILE_STARTED
exit /b 0
