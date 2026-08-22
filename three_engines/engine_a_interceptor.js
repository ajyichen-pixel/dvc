'use strict';

globalThis.DVC_ENGINE_LABEL = 'TEST-A Interceptor';

const states = new WeakMap();
const dropBypass = new WeakSet();

async function inspectInput(input) {
  const state = states.get(input);
  if (state && state.processing) return;
  if (!input.files || input.files.length === 0) return;

  const originals = Array.from(input.files);
  states.set(input, { processing: true, bypass: false });
  input.value = '';
  DVC.incPending();
  DVC.toast('Raw selection captured before page listeners. Inspecting...');

  try {
    const result = await DVC.processFiles(originals);
    if (!result.ok) {
      input.value = '';
      states.delete(input);
      DVC.toast(result.reason || 'Upload blocked', 'block');
      return;
    }

    const dt = DVC.dataTransfer(result.files);
    input.files = dt.files;
    states.set(input, { processing: false, bypass: true });
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    const s = states.get(input);
    if (s) s.bypass = false;

    DVC.toast(result.rewritten > 0
      ? 'Safe file injected. ' + result.matches + ' sensitive match(es) rewritten.'
      : 'File inspected. No sensitive content detected.', 'ok');
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
  const dt = event.dataTransfer;
  if (!dt || !dt.files || dt.files.length === 0) return;
  const target = event.target;
  if (target && dropBypass.has(target)) {
    dropBypass.delete(target);
    return;
  }

  DVC.stop(event);
  DVC.incPending();
  DVC.toast('Dropped raw file captured before page listeners. Inspecting...');
  try {
    const result = await DVC.processFiles(Array.from(dt.files));
    if (!result.ok) {
      DVC.toast(result.reason || 'Drop blocked', 'block');
      return;
    }
    const safe = DVC.dataTransfer(result.files);
    const synthetic = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: safe });
    if (target && typeof target.dispatchEvent === 'function') {
      dropBypass.add(target);
      target.dispatchEvent(synthetic);
    }
    DVC.toast(result.rewritten > 0 ? 'Safe dropped file injected.' : 'Dropped file inspected.', 'ok');
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
