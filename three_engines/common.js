'use strict';

const DVC = (() => {
  const MAX_BYTES = 512 * 1024;
  const DEFAULT_TERMS = [
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
  const DEFAULT_REPLACEMENT = '[DVC-REDACTED]';
  let pending = 0;

  function sendNative(payload) {
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

  function managedGet() {
    return new Promise((resolve) => {
      try {
        chrome.storage.managed.get(null, (items) => {
          if (chrome.runtime.lastError) { resolve({}); return; }
          resolve(items || {});
        });
      } catch (_) { resolve({}); }
    });
  }

  async function loadPolicy() {
    const managed = await managedGet();
    let terms = DEFAULT_TERMS.slice();
    let source = 'builtin-fallback';
    if (typeof managed.RedactionTermsJson === 'string' && managed.RedactionTermsJson.trim()) {
      try {
        const parsed = JSON.parse(managed.RedactionTermsJson);
        if (Array.isArray(parsed) && parsed.length && parsed.every((x) => typeof x === 'string')) {
          terms = parsed.filter(Boolean).slice(0, 500);
          source = 'browser-managed-policy';
        }
      } catch (_) {}
    }
    return {
      enabled: managed.Enabled !== false,
      terms,
      replacement: (typeof managed.ReplacementText === 'string' && managed.ReplacementText) ? managed.ReplacementText : DEFAULT_REPLACEMENT,
      source
    };
  }

  function toBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
      binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + step, bytes.length)));
    }
    return btoa(binary);
  }

  function fromBase64(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  async function processFile(file, policy) {
    if (!file || typeof file.arrayBuffer !== 'function') return { ok: false, action: 'block', reason: 'Invalid file object' };
    if (file.size > MAX_BYTES) return { ok: false, action: 'block', reason: 'V1 test limit is 512 KB. Large files are blocked fail-closed.' };
    if (!policy.enabled) return { ok: false, action: 'block', reason: 'DVC browser policy is disabled.' };
    const response = await sendNative({
      op: 'sanitize',
      name: file.name,
      mime: file.type || 'application/octet-stream',
      data: toBase64(await file.arrayBuffer()),
      terms: policy.terms,
      replacement: policy.replacement,
      policySource: policy.source
    });
    if (!response || response.ok === false || response.action === 'block') return response || { ok: false, action: 'block', reason: 'Unknown native host failure' };
    if (response.action === 'rewrite') {
      if (!response.data) return { ok: false, action: 'block', reason: 'Sanitized data missing' };
      const safeFile = new File([fromBase64(response.data)], response.name || ('DVC_SAFE_' + file.name), {
        type: response.mime || file.type || 'application/octet-stream',
        lastModified: Date.now()
      });
      return { ok: true, action: 'rewrite', file: safeFile, matches: response.matches || 0 };
    }
    return { ok: true, action: 'allow', file, matches: 0 };
  }

  async function processFiles(files) {
    const policy = await loadPolicy();
    const output = [];
    let rewritten = 0;
    let matches = 0;
    for (const file of files) {
      const result = await processFile(file, policy);
      if (!result || !result.ok || result.action === 'block') return { ok: false, reason: (result && result.reason) || 'Upload blocked by DVC', policy };
      if (result.action === 'rewrite') rewritten++;
      matches += result.matches || 0;
      output.push(result.file);
    }
    return { ok: true, files: output, rewritten, matches, policy };
  }

  function dataTransfer(files) {
    const dt = new DataTransfer();
    for (const file of files) dt.items.add(file);
    return dt;
  }

  function stop(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
    event.stopPropagation();
  }

  function toast(message, state = 'info') {
    try {
      const id = '__dvc_three_engine_toast';
      const old = document.getElementById(id);
      if (old) old.remove();
      const el = document.createElement('div');
      el.id = id;
      const bg = state === 'ok' ? '#176b41' : state === 'block' ? '#9f2d20' : '#f48418';
      Object.assign(el.style, {
        position: 'fixed', right: '24px', bottom: '24px', zIndex: '2147483647', background: bg,
        color: '#fff', padding: '12px 16px', borderRadius: '14px', boxShadow: '0 12px 32px rgba(0,0,0,.24)',
        fontFamily: 'Segoe UI, Arial, sans-serif', fontSize: '14px', fontWeight: '600', maxWidth: '480px', lineHeight: '1.4'
      });
      el.textContent = 'DVC ' + (globalThis.DVC_ENGINE_LABEL || 'Upload Engine') + ' - ' + message;
      (document.documentElement || document.body).appendChild(el);
      setTimeout(() => { if (el.isConnected) el.remove(); }, state === 'block' ? 7000 : 5000);
    } catch (_) {}
  }

  function incPending() { pending++; }
  function decPending() { pending = Math.max(0, pending - 1); }
  function hasPending() { return pending > 0; }

  return { processFiles, dataTransfer, stop, toast, incPending, decPending, hasPending };
})();

globalThis.DVC = DVC;
