'use strict';

const resultEl = document.getElementById('result');
const fileEl = document.getElementById('file');
const downloadEl = document.getElementById('download');

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + step, bytes.length)));
  }
  return btoa(binary);
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function send(payload) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: 'DVC_SANITIZE', payload }, (response) => {
      if (chrome.runtime.lastError) {
        resolve({ ok: false, action: 'block', reason: chrome.runtime.lastError.message });
        return;
      }
      resolve(response || { ok: false, action: 'block', reason: 'No response' });
    });
  });
}

document.getElementById('health').addEventListener('click', async () => {
  downloadEl.textContent = '';
  resultEl.textContent = 'Checking native host...';
  const response = await send({ op: 'health' });
  resultEl.textContent = JSON.stringify(response, null, 2);
});

fileEl.addEventListener('change', async () => {
  downloadEl.textContent = '';
  const file = fileEl.files && fileEl.files[0];
  if (!file) return;
  if (file.size > 512 * 1024) {
    resultEl.textContent = 'BLOCK: V1 test limit is 512 KB.';
    return;
  }
  resultEl.textContent = 'Inspecting ' + file.name + '...';
  const buffer = await file.arrayBuffer();
  const response = await send({
    op: 'sanitize',
    name: file.name,
    mime: file.type || 'application/octet-stream',
    data: arrayBufferToBase64(buffer)
  });
  resultEl.textContent = JSON.stringify({
    ok: response.ok,
    action: response.action,
    name: response.name,
    matches: response.matches,
    reason: response.reason,
    version: response.version
  }, null, 2);

  if (response.action === 'rewrite' && response.data) {
    const bytes = base64ToBytes(response.data);
    const blob = new Blob([bytes], { type: response.mime || file.type || 'application/octet-stream' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = response.name || ('DVC_SAFE_' + file.name);
    a.textContent = 'Download sanitized safe copy';
    downloadEl.appendChild(a);
  }
});
