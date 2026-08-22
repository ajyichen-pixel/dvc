'use strict';

globalThis.DVC_ENGINE_LABEL = 'TEST-B Framework Setter';

const states = new WeakMap();
const dropBypass = new WeakSet();
const nativeFilesSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files')?.set;

function setFilesFrameworkAware(input, files) {
  const dt = DVC.dataTransfer(files);
  if (typeof nativeFilesSetter === 'function') nativeFilesSetter.call(input, dt.files);
  else input.files = dt.files;

  try {
    input.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText' }));
  } catch (_) {
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  }
  input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));

  queueMicrotask(() => {
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  });
}

async function inspectInput(input) {
  const state = states.get(input);
  if (state && state.processing) return;
  if (!input.files || input.files.length === 0) return;

  const originals = Array.from(input.files);
  states.set(input, { processing: true, bypass: false });
  input.value = '';
  DVC.incPending();
  DVC.toast('Framework upload event captured. Inspecting before state update...');

  try {
    const result = await DVC.processFiles(originals);
    if (!result.ok) {
      input.value = '';
      states.delete(input);
      DVC.toast(result.reason || 'Upload blocked', 'block');
      return;
    }

    states.set(input, { processing: false, bypass: true });
    setFilesFrameworkAware(input, result.files);
    setTimeout(() => {
      const s = states.get(input);
      if (s) s.bypass = false;
    }, 0);

    DVC.toast(result.rewritten > 0
      ? 'Native files setter injected safe file; framework events replayed.'
      : 'File inspected; framework events replayed.', 'ok');
  } catch (_) {
    input.value = '';
    states.delete(input);
    DVC.toast('Inspection failed; upload blocked.', 'block');
  } finally {
    DVC.decPending();
  }
}

function captureFileEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  const state = states.get(input);
  if (state && state.bypass) return;
  if (input.files && input.files.length > 0) {
    DVC.stop(event);
    if (!state || !state.processing) void inspectInput(input);
  } else if (state && state.processing) {
    DVC.stop(event);
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
    DVC.toast(result.rewritten > 0 ? 'Framework drop replayed with safe file.' : 'Drop inspected and replayed.', 'ok');
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

window.addEventListener('input', captureFileEvent, true);
window.addEventListener('change', captureFileEvent, true);
window.addEventListener('drop', captureDrop, true);
window.addEventListener('submit', guardSubmit, true);
