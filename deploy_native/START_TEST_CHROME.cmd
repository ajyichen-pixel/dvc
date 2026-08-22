@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\UploadGuard"
set "EXT=%ROOT%\extension"
set "PROFILE=%LOCALAPPDATA%\DVC\UploadGuardChromeProfile"
set "CHROME=%ProgramData%\DVC\UploadGuard\Browser\chrome-win64\chrome.exe"

if not exist "%CHROME%" (
  echo Chrome for Testing is required because current branded Chrome blocks --load-extension.
  echo Downloading the official Google test browser now...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\GET_TEST_BROWSER.ps1"
  if errorlevel 1 (
    echo CHROME_FOR_TESTING_DOWNLOAD_FAILED
    exit /b 2
  )
)

if not exist "%CHROME%" (
  echo CHROME_FOR_TESTING_NOT_FOUND
  exit /b 3
)

if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "DVC Upload Guard Test" "%CHROME%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/test.html"
echo CHROME_FOR_TESTING_STARTED
exit /b 0
