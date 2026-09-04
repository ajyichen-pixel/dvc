DVC CONTENT ANALYSIS AGENT V1

PURPOSE
Chrome file upload -> Chromium Content Analysis SDK -> DVC fail-closed verdict.

IMPORTANT CHROME REQUIREMENT
OnFileAttachedEnterpriseConnector is a Chrome cloud-only policy.
Do NOT deploy this connector policy through HKLM, REG, GPO, ADMX, or another platform policy mechanism.
The browser must be enrolled in Chrome Enterprise Core and the connector must be enabled from Google Admin Console.

GOOGLE ADMIN PREREQUISITES
1. Sign up for or use Chrome Enterprise Core.
2. Enroll the Windows Chrome system installation with a Chrome Enterprise Core enrollment token.
3. Confirm the browser appears under Managed browsers in Google Admin Console.
4. Go to Chrome settings -> Chrome Enterprise Connectors.
5. Enable Chrome Enterprise Connectors.
6. Configure Upload content analysis and select the supported Local Content Analysis DLP vendor path used for this integration test.
7. Restart Chrome or reload cloud policy.

CLIENT VERIFICATION
1. Open chrome://management and confirm Chrome is managed.
2. Open chrome://policy.
3. Confirm OnFileAttachedEnterpriseConnector is present from cloud management.
4. Expand it and confirm the service provider value delivered by Google.
5. Do not treat a locally-created HKLM OnFileAttachedEnterpriseConnector value as proof that the connector is active.

DVC AGENT INSTALL
1. Extract this package.
2. Right-click INSTALL.cmd and run as Administrator.
3. Run VERIFY.cmd.
4. Restart Chrome after the Enterprise Core connector policy is confirmed.

V1 ACCEPTANCE TEST
Use a DOCX containing the target identity keywords used by the DVC V1 scanner.
Attempt to attach it in managed Chrome on a URL covered by the cloud connector rule.

EXPECTED LOG FLOW
BROWSER_CONNECTED
REQUEST_RECEIVED
SCAN_RESULT
RESPONSE_SENT action=BLOCK
ACK_RECEIVED status=SUCCESS final_action=BLOCK
ENFORCEMENT_CONFIRMED

LOG
%ProgramData%\DVC\ContentAnalysis\logs\dvc_content_analysis.log

IMPLEMENTATION NOTE
Current Chromium source contains only a fixed set of service provider identifiers. local_system_agent is a legacy/temporary alias that maps to the Broadcom system-agent local path brcm_chrm_cas; it is not a generic vendor-registration API. Production provider onboarding therefore cannot be assumed from the local SDK alone.

BUILD
The Windows executable is built by GitHub Actions on windows-2022 using the pinned Chromium Content Analysis SDK commit.

V1 SCOPE
V1 is intentionally narrow. PDF, OCR, Presidio and safe-copy replacement are not enabled yet.
Unsupported content and scanner errors are blocked by design.
