DVC UPLOAD GUARD NATIVE V1
==========================

GOAL
----
This test build replaces the Chrome Enterprise Core dependency with a local
Chrome/Edge Extension + Native Messaging Host design.

NO DEVELOPMENT TOOLS ARE REQUIRED ON THE TEST PC.
No Visual Studio, CMake, Node.js, Python, or .NET runtime installation is needed.
The native host is published as a self-contained Windows x64 executable.

QUICK TEST
----------
1. Extract the ZIP.
2. Run INSTALL.cmd.
3. Accept the Windows administrator prompt.
4. An isolated Chrome test profile should open automatically.
5. On the DVC Upload Guard test page, click "Check native host".
6. Select a DOCX test file.
7. For a document containing sensitive keywords, expected result:
      action = rewrite
      matches >= 1
      output name begins with DVC_SAFE_
8. Download the safe copy and verify the sensitive value is replaced by:
      [DVC-REDACTED]

BROWSER UPLOAD TEST
-------------------
Keep the isolated test Chrome window open and browse to a normal web upload page.
For regular <input type=file> selection, DVC clears the original file immediately,
scans it through Native Messaging, then places only the checked/sanitized File
back into the upload control. Normal drag/drop is also intercepted and replayed
with the checked file when the target accepts synthetic drop events.

V1 TEST LIMITS
--------------
- Maximum file size: 512 KB. Larger files are blocked fail-closed.
- Supported sanitization: DOCX and common UTF-8 text formats.
- Unsupported formats are blocked in this V1 build.
- PDF/image/OCR and production large-file chunk streaming are future stages.
- Some web apps that require trusted drag/drop events may reject synthetic drop.
  Standard file-input selection is the primary V1 validation path.

FILES
-----
INSTALL.cmd              One-click installer and Chrome test launcher
UNINSTALL.cmd            Removes native host registrations and installed files
START_TEST_CHROME.cmd     Starts isolated Chrome profile with unpacked extension
START_TEST_EDGE.cmd       Starts isolated Edge profile with unpacked extension
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
The browser content script intercepts file selection before the page receives the
change event, clears the raw file selection, asks the native host to inspect it,
and only re-attaches a checked or sanitized File. Native host errors, unsupported
formats, and oversized files fail closed.

This is a test architecture, not yet the production large-file DLP release.
