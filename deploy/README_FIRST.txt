DVC CONTENT ANALYSIS AGENT V1

PURPOSE
Chrome file upload -> official Content Analysis SDK -> DVC fail-closed verdict.

INSTALL
1. Extract this package.
2. Right-click INSTALL.cmd and run as Administrator.
3. Restart Chrome.
4. Open chrome://policy and click Reload policies.
5. Run VERIFY.cmd.

V1 ACCEPTANCE TEST
Use a DOCX containing the target identity keywords used by the DVC V1 scanner.
Attempt to attach it in managed Chrome.

EXPECTED LOG FLOW
REQUEST_RECEIVED
SCAN_RESULT
RESPONSE_SENT action=BLOCK
ACK_RECEIVED status=SUCCESS final_action=BLOCK
ENFORCEMENT_CONFIRMED

LOG
%ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log

IMPORTANT
V1 is intentionally narrow. PDF, OCR, Presidio and safe-copy replacement are not enabled yet.
Unsupported content and scanner errors are blocked by design.
