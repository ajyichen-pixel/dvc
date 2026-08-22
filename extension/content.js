'use strict';

const DVC_MAX_BYTES = 512 * 1024;
const DVC_DEFAULT_TERMS = [
  '\u570B\u6C11\u8EAB\u5206\u8B49',
  '\u5C45\u6C11\u8EAB\u4EFD\u8BC1',
  '\u8EAB\u5206\u8B49',
  '\u8EAB\u4EFD\u8BC1',
  '\u8B77\u7167',
  'passport',
  'national identification',
  'national id',
  'id number'
];
const DVC_DEFAULT_REPLACEMENT = '[DVC-REDACTED]';

let dvcPending = 0;
const dvcInputStates = new WeakMap();
const dvcBypassDropTargets = new WeakSet();

function dvcSendMessage(payload) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: 'DVC_SANITIZE', payload }, (response) => {
      if (chrome.runtime.lastError) {
        resolve({ ok: false, action: 'block', reason: chrome.runtime.lastError.message });
        return;
      }
      resolve(response || { ok: false, action: 'block', reason: 'No extension response' });
    });
  });
}

function dvcManagedGet() {
  return new Promise((resolve) => {
    try {
      chrome.storage.managed.get(null, (items) => {
        if (chrome.runtime.lastError) {
          resolve({});
          return;
        }
        resolve(items || {});
      });
    } catch (_) {
      resolve({});
    }
  });
}

async function dvcLoadPolicy() {
  const managed = await dvcManagedGet();
  let terms = DVC_DEFAULT_TERMS.slice();
  let source = 'builtin-fallback';
  if (typeof managed.RedactionTermsJson === 'string' && managed.RedactionTermsJson.trim()) {
    try {
      const parsed = JSON.parse(managed.RedactionTermsJson);
      if (Array.isArray(parsed) && parsed.length > 0 && parsed.every((x) => typeof x === 'string')) {
        terms = parsed.filter(Boolean).slice(0, 500);
        source = 'browser-managed-policy';
      }
    } catch (_) {
      // Invalid managed policy fails back to the built-in safe baseline.
    }
  }
  const replacement = typeof managed.ReplacementText === 'string' && managed.ReplacementText
    ? managed.ReplacementText
    : DVC_DEFAULT_REPLACEMENT;
  const enabled = managed.Enabled !== false;
  return { enabled, terms, replacement, source };
}

function dvcArrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + step, bytes.length)));
  }
  return btoa(binary);
}

function dvcBase64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function dvcToast(message, state = 'info') {
  try {
    const old = document.getElementById('__dvc_upload_guard_toast');
    if (old) old.remove();
    const el = document.createElement('div');
    el.id = '__dvc_upload_guard_toast';
    const bg = state === 'ok' ? '#176b41' : state === 'block' ? '#9f2d20' : '#f48418';
    Object.assign(el.style, {
      position: 'fixed', right: '24px', bottom: '24px', zIndex: '2147483647',
      background: bg, color: '#fff', padding: '12px 16px', borderRadius: '14px',
      boxShadow: '0 12px 32px rgba(0,0,0,.24)', fontFamily: 'Segoe UI, Arial, sans-serif',
      fontSize: '14px', fontWeight: '600', maxWidth: '460px', lineHeight: '1.4'
    });
    el.textContent = 'DVC Upload Guard - ' + message;
    (document.documentElement || document.body).appendChild(el);
    setTimeout(() => { if (el.isConnected) el.remove(); }, state === 'block' ? 7000 : 5000);
  } catch (_) {}
}

async function dvcProcessFile(file, policy) {
  if (!file || typeof file.arrayBuffer !== 'function') {
    return { ok: false, action: 'block', reason: 'Invalid file object' };
  }
  if (file.size > DVC_MAX_BYTES) {
    return { ok: false, action: 'block', reason: 'V1 test limit is 512 KB. Large files are blocked fail-closed.' };
  }
  if (!policy.enabled) {
    return { ok: false, action: 'block', reason: 'DVC browser policy is disabled.' };
  }

  const buffer = await file.arrayBuffer();
  const response = await dvcSendMessage({
    op: 'sanitize',
    name: file.name,
    mime: file.type || 'application/octet-stream',
    data: dvcArrayBufferToBase64(buffer),
    terms: policy.terms,
    replacement: policy.replacement,
    policySource: policy.source
  });

  if (!response || response.action === 'block' || response.ok === false) {
    return response || { ok: false, action: 'block', reason: 'Unknown native host failure' };
  }

  if (response.action === 'rewrite') {
    if (!response.data) return { ok: false, action: 'block', reason: 'Sanitized file data was missing' };
    const bytes = dvcBase64ToBytes(response.data);
    const safeFile = new File([bytes], response.name || ('DVC_SAFE_' + file.name), {
      type: response.mime || file.type || 'application/octet-stream',
      lastModified: Date.now()
    });
    return { ok: true, action: 'rewrite', file: safeFile, matches: response.matches || 0, reason: response.reason || '' };
  }

  return { ok: true, action: 'allow', file, matches: 0, reason: response.reason || '' };
}

async function dvcProcessFileList(files) {
  const policy = await dvcLoadPolicy();
  const output = [];
  let rewritten = 0;
  let matches = 0;
  for (const file of files) {
    const result = await dvcProcessFile(file, policy);
    if (!result || !result.ok || result.action === 'block') {
      return { ok: false, reason: (result && result.reason) || 'Upload blocked by DVC', policy };
    }
    if (result.action === 'rewrite') rewritten++;
    matches += result.matches || 0;
    output.push(result.file);
  }
  return { ok: true, files: output, rewritten, matches, policy };
}

function dvcDataTransferFromFiles(files) {
  const dt = new DataTransfer();
  for (const file of files) dt.items.add(file);
  return dt;
}

function dvcStopOriginal(event) {
  event.preventDefault();
  event.stopImmediatePropagation();
  event.stopPropagation();
}

async function dvcStartInputInspection(input) {
  const existing = dvcInputStates.get(input);
  if (existing && existing.processing) return;
  if (!input.files || input.files.length === 0) return;

  const originalFiles = Array.from(input.files);
  dvcInputStates.set(input, { processing: true, bypass: false });
  input.value = '';
  dvcPending++;
  dvcToast('Checking selected file before the website can receive it...');

  try {
    const result = await dvcProcessFileList(originalFiles);
    if (!result.ok) {
      input.value = '';
      dvcToast(result.reason || 'Upload blocked', 'block');
      dvcInputStates.delete(input);
      return;
    }

    const dt = dvcDataTransferFromFiles(result.files);
    input.files = dt.files;
    dvcInputStates.set(input, { processing: false, bypass: true });

    input.dispatchEvent(new Event('input', { bubbles: true, cancelable: false }));
    input.dispatchEvent(new Event('change', { bubbles: true, cancelable: false }));

    const state = dvcInputStates.get(input);
    if (state) state.bypass = false;

    const policyText = result.policy.source === 'browser-managed-policy' ? 'managed policy' : 'built-in fallback';
    if (result.rewritten > 0) {
      dvcToast('Safe file injected before upload. ' + result.matches + ' match(es), ' + policyText + '.', 'ok');
    } else {
      dvcToast('File checked before upload. No sensitive content detected, ' + policyText + '.', 'ok');
    }
  } catch (_) {
    input.value = '';
    dvcInputStates.delete(input);
    dvcToast('Upload blocked because DVC inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcHandleFileEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;

  const state = dvcInputStates.get(input);
  if (state && state.bypass) return;

  // The browser normally fires input before change. The old V1 intercepted only
  // change, allowing upload libraries to cache the original File during input.
  // Stop BOTH original events before page code can enqueue the raw file.
  if (input.files && input.files.length > 0) {
    dvcStopOriginal(event);
    if (!state || !state.processing) void dvcStartInputInspection(input);
    return;
  }

  if (state && state.processing) dvcStopOriginal(event);
}

async function dvcHandleDrop(event) {
  if (!event.dataTransfer || !event.dataTransfer.files || event.dataTransfer.files.length === 0) return;
  const target = event.target;
  if (target && typeof target === 'object' && dvcBypassDropTargets.has(target)) {
    dvcBypassDropTargets.delete(target);
    return;
  }

  dvcStopOriginal(event);
  const originalFiles = Array.from(event.dataTransfer.files);
  dvcPending++;
  dvcToast('Checking dropped file before the website can receive it...');

  try {
    const result = await dvcProcessFileList(originalFiles);
    if (!result.ok) {
      dvcToast(result.reason || 'Dropped file blocked', 'block');
      return;
    }
    const dt = dvcDataTransferFromFiles(result.files);
    const synthetic = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt });
    if (target && typeof target.dispatchEvent === 'function') {
      dvcBypassDropTargets.add(target);
      target.dispatchEvent(synthetic);
    }
    const policyText = result.policy.source === 'browser-managed-policy' ? 'managed policy' : 'built-in fallback';
    dvcToast(result.rewritten > 0
      ? 'Safe dropped file injected. ' + result.matches + ' match(es), ' + policyText + '.'
      : 'Dropped file checked, ' + policyText + '.', 'ok');
  } catch (_) {
    dvcToast('Dropped file blocked because DVC inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcGuardSubmit(event) {
  if (dvcPending <= 0) return;
  dvcStopOriginal(event);
  dvcToast('Upload is waiting for DVC inspection to finish.', 'block');
}

// Window capture is the earliest normal DOM event phase. Intercept both input
// and change so page frameworks never receive the raw selected File first.
window.addEventListener('input', dvcHandleFileEvent, true);
window.addEventListener('change', dvcHandleFileEvent, true);
window.addEventListener('drop', dvcHandleDrop, true);
window.addEventListener('submit', dvcGuardSubmit, true);

try {
  document.documentElement && document.documentElement.setAttribute('data-dvc-upload-guard', 'active');
} catch (_) {}
