'use strict';

const HOST_NAME = 'com.trcore.dvc_upload_guard';

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== 'DVC_SANITIZE') {
    return false;
  }

  chrome.runtime.sendNativeMessage(HOST_NAME, message.payload, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({
        ok: false,
        action: 'block',
        reason: 'Native host error: ' + chrome.runtime.lastError.message
      });
      return;
    }

    if (!response) {
      sendResponse({
        ok: false,
        action: 'block',
        reason: 'Native host returned no response'
      });
      return;
    }

    sendResponse(response);
  });

  return true;
});
