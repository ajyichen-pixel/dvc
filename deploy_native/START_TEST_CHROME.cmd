@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\UploadGuard"
set "EXT=%ROOT%\extension"
set "PROFILE=%LOCALAPPDATA%\DVC\UploadGuardChromeProfile"
set "CHROME="

if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"

if not defined CHROME (
  echo CHROME_NOT_FOUND
  exit /b 2
)

if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "DVC Upload Guard Test" "%CHROME%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/test.html"
echo CHROME_TEST_PROFILE_STARTED
exit /b 0
