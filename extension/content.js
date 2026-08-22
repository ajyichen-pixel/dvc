'use strict';

const DVC_MAX_BYTES = 512 * 1024;
let dvcPending = 0;
const dvcBypassInputs = new WeakSet();
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
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
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
      position: 'fixed',
      right: '24px',
      bottom: '24px',
      zIndex: '2147483647',
      background: bg,
      color: '#fff',
      padding: '12px 16px',
      borderRadius: '14px',
      boxShadow: '0 12px 32px rgba(0,0,0,.24)',
      fontFamily: 'Segoe UI, Arial, sans-serif',
      fontSize: '14px',
      fontWeight: '600',
      maxWidth: '420px',
      lineHeight: '1.4'
    });
    el.textContent = 'DVC Upload Guard - ' + message;
    (document.documentElement || document.body).appendChild(el);
    setTimeout(() => {
      if (el.isConnected) el.remove();
    }, state === 'block' ? 7000 : 4500);
  } catch (_) {
    // UI failure must not affect enforcement.
  }
}

async function dvcProcessFile(file) {
  if (!file || typeof file.arrayBuffer !== 'function') {
    return { ok: false, action: 'block', reason: 'Invalid file object' };
  }
  if (file.size > DVC_MAX_BYTES) {
    return {
      ok: false,
      action: 'block',
      reason: 'V1 test limit is 512 KB. Large files are blocked fail-closed.'
    };
  }

  const buffer = await file.arrayBuffer();
  const response = await dvcSendMessage({
    op: 'sanitize',
    name: file.name,
    mime: file.type || 'application/octet-stream',
    data: dvcArrayBufferToBase64(buffer)
  });

  if (!response || response.action === 'block' || response.ok === false) {
    return response || { ok: false, action: 'block', reason: 'Unknown native host failure' };
  }

  if (response.action === 'rewrite') {
    if (!response.data) {
      return { ok: false, action: 'block', reason: 'Sanitized file data was missing' };
    }
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
  const output = [];
  let rewritten = 0;
  let matches = 0;
  for (const file of files) {
    const result = await dvcProcessFile(file);
    if (!result || !result.ok || result.action === 'block') {
      return { ok: false, reason: (result && result.reason) || 'Upload blocked by DVC' };
    }
    if (result.action === 'rewrite') rewritten++;
    matches += result.matches || 0;
    output.push(result.file);
  }
  return { ok: true, files: output, rewritten, matches };
}

function dvcDataTransferFromFiles(files) {
  const dt = new DataTransfer();
  for (const file of files) dt.items.add(file);
  return dt;
}

async function dvcHandleInputChange(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  if (dvcBypassInputs.has(input)) {
    dvcBypassInputs.delete(input);
    return;
  }
  if (!input.files || input.files.length === 0) return;

  event.preventDefault();
  event.stopImmediatePropagation();

  const originalFiles = Array.from(input.files);
  input.value = '';
  dvcPending++;
  dvcToast('Checking selected file before upload...');

  try {
    const result = await dvcProcessFileList(originalFiles);
    if (!result.ok) {
      input.value = '';
      dvcToast(result.reason || 'Upload blocked', 'block');
      return;
    }

    const dt = dvcDataTransferFromFiles(result.files);
    dvcBypassInputs.add(input);
    input.files = dt.files;
    input.dispatchEvent(new Event('input', { bubbles: true, cancelable: false }));
    input.dispatchEvent(new Event('change', { bubbles: true, cancelable: false }));

    if (result.rewritten > 0) {
      dvcToast('Safe copy ready. Sensitive content was de-identified before upload.', 'ok');
    } else {
      dvcToast('File checked. No sensitive content detected.', 'ok');
    }
  } catch (error) {
    input.value = '';
    dvcToast('Upload blocked because DVC inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

async function dvcHandleDrop(event) {
  if (!event.dataTransfer || !event.dataTransfer.files || event.dataTransfer.files.length === 0) return;
  const target = event.target;
  if (target && typeof target === 'object' && dvcBypassDropTargets.has(target)) {
    dvcBypassDropTargets.delete(target);
    return;
  }

  event.preventDefault();
  event.stopImmediatePropagation();

  const originalFiles = Array.from(event.dataTransfer.files);
  dvcPending++;
  dvcToast('Checking dropped file before upload...');

  try {
    const result = await dvcProcessFileList(originalFiles);
    if (!result.ok) {
      dvcToast(result.reason || 'Dropped file blocked', 'block');
      return;
    }

    const dt = dvcDataTransferFromFiles(result.files);
    const synthetic = new DragEvent('drop', {
      bubbles: true,
      cancelable: true,
      dataTransfer: dt
    });

    if (target && typeof target.dispatchEvent === 'function') {
      dvcBypassDropTargets.add(target);
      target.dispatchEvent(synthetic);
    }

    if (result.rewritten > 0) {
      dvcToast('Safe dropped copy ready. Sensitive content was de-identified.', 'ok');
    } else {
      dvcToast('Dropped file checked. No sensitive content detected.', 'ok');
    }
  } catch (_) {
    dvcToast('Dropped file blocked because DVC inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcGuardSubmit(event) {
  if (dvcPending <= 0) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  dvcToast('Upload is waiting for DVC inspection to finish.', 'block');
}

document.addEventListener('change', dvcHandleInputChange, true);
document.addEventListener('drop', dvcHandleDrop, true);
document.addEventListener('submit', dvcGuardSubmit, true);
