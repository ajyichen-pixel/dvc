'use strict';

globalThis.DVC_ENGINE_LABEL = 'TEST-C Browser Bridge Proxy Picker';

const nativeFilesSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files')?.set;
const armed = new WeakSet();
const bypass = new WeakSet();
const dropBypass = new WeakSet();

function setFiles(input, files) {
  const dt = DVC.dataTransfer(files);
  if (typeof nativeFilesSetter === 'function') nativeFilesSetter.call(input, dt.files);
  else input.files = dt.files;
}

function copyPickerAttributes(source, proxy) {
  const attrs = ['accept', 'capture'];
  for (const name of attrs) {
    if (source.hasAttribute(name)) proxy.setAttribute(name, source.getAttribute(name) || '');
  }
  proxy.multiple = !!source.multiple;
  if (source.hasAttribute('webkitdirectory')) proxy.setAttribute('webkitdirectory', '');
}

async function proxyPick(original) {
  const proxy = document.createElement('input');
  proxy.type = 'file';
  copyPickerAttributes(original, proxy);
  Object.assign(proxy.style, { position: 'fixed', left: '-10000px', top: '-10000px', width: '1px', height: '1px', opacity: '0' });
  proxy.setAttribute('data-dvc-proxy-picker', '1');
  (document.documentElement || document.body).appendChild(proxy);

  proxy.addEventListener('change', async () => {
    const originals = proxy.files ? Array.from(proxy.files) : [];
    if (!originals.length) { proxy.remove(); return; }
    DVC.incPending();
    DVC.toast('Raw file selected only in DVC proxy picker. Inspecting...');
    try {
      const result = await DVC.processFiles(originals);
      if (!result.ok) {
        DVC.toast(result.reason || 'Upload blocked', 'block');
        return;
      }
      bypass.add(original);
      setFiles(original, result.files);
      original.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      original.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      queueMicrotask(() => bypass.delete(original));
      DVC.toast(result.rewritten > 0
        ? 'Only sanitized file was placed into the website input.'
        : 'Inspected file was placed into the website input.', 'ok');
    } catch (_) {
      DVC.toast('Inspection failed; upload blocked.', 'block');
    } finally {
      proxy.remove();
      DVC.decPending();
    }
  }, { once: true });

  proxy.click();
}

function interceptPickerClick(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  if (input.hasAttribute('data-dvc-proxy-picker')) return;
  if (bypass.has(input)) return;
  if (armed.has(input)) return;

  DVC.stop(event);
  armed.add(input);
  try {
    void proxyPick(input);
  } finally {
    queueMicrotask(() => armed.delete(input));
  }
}

async function fallbackOriginalEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  if (input.hasAttribute('data-dvc-proxy-picker')) return;
  if (bypass.has(input)) return;
  if (!input.files || input.files.length === 0) return;

  DVC.stop(event);
  const originals = Array.from(input.files);
  input.value = '';
  DVC.incPending();
  DVC.toast('Fallback capture used. Inspecting original input before page listeners...');
  try {
    const result = await DVC.processFiles(originals);
    if (!result.ok) {
      DVC.toast(result.reason || 'Upload blocked', 'block');
      return;
    }
    bypass.add(input);
    setFiles(input, result.files);
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    queueMicrotask(() => bypass.delete(input));
    DVC.toast(result.rewritten > 0 ? 'Fallback path injected safe file.' : 'Fallback path inspected file.', 'ok');
  } catch (_) {
    input.value = '';
    DVC.toast('Inspection failed; upload blocked.', 'block');
  } finally {
    DVC.decPending();
  }
}

async function captureDrop(event) {
  const transfer = event.dataTransfer;
  if (!transfer || !transfer.files || transfer.files.length === 0) return;
  const target = event.target;
  if (target && dropBypass.has(target)) {
    dropBypass.delete(target);
    return;
  }
  DVC.stop(event);
  DVC.incPending();
  try {
    const result = await DVC.processFiles(Array.from(transfer.files));
    if (!result.ok) {
      DVC.toast(result.reason || 'Drop blocked', 'block');
      return;
    }
    const safe = DVC.dataTransfer(result.files);
    const synthetic = new DragEvent('drop', { bubbles: true, cancelable: true, composed: true, dataTransfer: safe });
    if (target && typeof target.dispatchEvent === 'function') {
      dropBypass.add(target);
      target.dispatchEvent(synthetic);
    }
    DVC.toast(result.rewritten > 0 ? 'Safe dropped file bridged to the page.' : 'Drop inspected and bridged.', 'ok');
  } catch (_) {
    DVC.toast('Drop inspection failed; blocked.', 'block');
  } finally {
    DVC.decPending();
  }
}

function guardSubmit(event) {
  if (!DVC.hasPending()) return;
  DVC.stop(event);
  DVC.toast('Upload is waiting for DVC inspection.', 'block');
}

window.addEventListener('click', interceptPickerClick, true);
window.addEventListener('input', fallbackOriginalEvent, true);
window.addEventListener('change', fallbackOriginalEvent, true);
window.addEventListener('drop', captureDrop, true);
window.addEventListener('submit', guardSubmit, true);
