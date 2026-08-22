DVC UPLOAD GUARD NATIVE V1
==========================

GOAL
----
This test build replaces Chrome Enterprise Core with a local browser extension
plus Native Messaging Host design.

NO DEVELOPMENT TOOLS ARE REQUIRED.
No Visual Studio, CMake, Node.js, Python, or .NET runtime installation is needed.
The native host is a self-contained Windows x64 executable.

IMPORTANT BROWSER NOTE
----------------------
Current branded Google Chrome no longer accepts the --load-extension switch.
For a zero-manual-step test, INSTALL.cmd automatically downloads Google's official
Chrome for Testing Stable build on first use and starts an isolated DVC profile.
This does not replace or modify the user's normal Chrome installation.

QUICK TEST
----------
1. Extract the ZIP.
2. Run INSTALL.cmd.
3. Accept the Windows administrator prompt.
4. On first use, allow the official Chrome for Testing download to complete.
5. The DVC Upload Guard test page opens automatically.
6. Click "Check native host".
7. Select a DOCX test file.
8. For a document containing sensitive keywords, expected result:
      action = rewrite
      matches >= 1
      output name begins with DVC_SAFE_
9. Download the safe copy and verify sensitive values are replaced by:
      [DVC-REDACTED]

BROWSER UPLOAD TEST
-------------------
Keep the DVC Chrome for Testing window open and browse to a normal upload page.
For a standard <input type=file>, DVC clears the original selection before the
page handles it, sends the file to the Native Messaging Host, and re-attaches only
the checked or sanitized File. Drag/drop is also intercepted and replayed when
the website accepts synthetic drop events.

V1 TEST LIMITS
--------------
- Maximum file size: 512 KB. Larger files are blocked fail-closed.
- Supported sanitization: DOCX and common text formats.
- Unsupported formats are blocked in this V1 build.
- PDF/image/OCR and production large-file streaming are future stages.
- Some sites require trusted drag/drop events; standard file selection is the
  primary V1 validation path.

FILES
-----
INSTALL.cmd              One-click installer and test-browser launcher
UNINSTALL.cmd            Removes native host registrations and installed files
START_TEST_CHROME.cmd     Starts isolated Chrome for Testing with DVC extension
GET_TEST_BROWSER.ps1     Downloads official Chrome for Testing when needed
START_TEST_EDGE.cmd       Experimental Edge launcher
VERIFY.cmd               Validates host, registration, self-test, and logs
DVCUploadGuardHost.exe    Self-contained Windows Native Messaging Host
native_host_manifest.json Native Messaging registration manifest
extension\                Manifest V3 browser extension

FIXED DEVELOPMENT EXTENSION ID
------------------------------
cdmogelilldmfcioieahdnaocmillhcl

NATIVE HOST NAME
----------------
com.trcore.dvc_upload_guard

LOG
---
C:\ProgramData\DVC\UploadGuard\logs\dvc_upload_guard.log

EXPECTED LOG EXAMPLES
---------------------
ALLOW name=sample.docx type=docx ... matches=0
REWRITE name=sample.docx safe=DVC_SAFE_sample.docx ... matches=2
BLOCK name=sample.pdf ... reason=unsupported_type

SECURITY MODEL OF THIS TEST
---------------------------
The content script intercepts file selection before the page receives the normal
change event, clears the raw file, asks the native host to inspect it, and only
re-attaches a checked or sanitized File. Host errors, unsupported formats, and
oversized files fail closed.

This is a test architecture, not yet the production large-file DLP release.
