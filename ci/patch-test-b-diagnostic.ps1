$ErrorActionPreference = 'Stop'

$root = Join-Path (Get-Location).Path 'dist_test_b\DVC_TEST_B_WEBPILOT_MAINWORLD'
$ext = Join-Path $root 'extension'
if (-not (Test-Path -LiteralPath $ext)) { throw 'TEST-B package must be generated before diagnostic patching.' }

function Append-Utf8NoBom([string]$Path, [string]$Text) {
  $old = [System.IO.File]::ReadAllText($Path)
  [System.IO.File]::WriteAllText($Path, $old + "`r`n" + $Text, [System.Text.UTF8Encoding]::new($false))
}

$manifestPath = Join-Path $ext 'manifest.json'
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$m.version = '1.2.0'
$m.name = 'DVC Upload Guard TEST-B Diagnostic'
$m.description = 'DVC TEST-B diagnostic build with page lifecycle and upload-path tracing.'
[System.IO.File]::WriteAllText($manifestPath, ($m | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))

$backgroundDiag = @'

/* DVC_TEST_B_DIAG_BACKGROUND */
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== 'DVC_HEALTH') return false;
  chrome.runtime.sendNativeMessage('com.trcore.dvc_upload_guard_test_b_mainworld', { op:'health' }, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({ ok:false, reason:chrome.runtime.lastError.message });
      return;
    }
    sendResponse(response || { ok:false, reason:'No native health response' });
  });
  return true;
});
'@
Append-Utf8NoBom (Join-Path $ext 'background.js') $backgroundDiag

$pageDiag = @'

/* DVC_TEST_B_DIAG_MAINWORLD */
(() => {
  const diag = (kind, detail='') => {
    try {
      window.postMessage({ source:'DVC_TEST_B_DIAG', world:'MAIN', kind, detail:String(detail || ''), ts:Date.now() }, '*');
    } catch (_) {}
  };
  diag('MAIN_WORLD_READY');

  try {
    const nativeAppend = FormData.prototype.append;
    FormData.prototype.append = function(...args) {
      diag('FORMDATA_APPEND', args[1] instanceof File ? (args[1].name || 'File') : typeof args[1]);
      return nativeAppend.apply(this, args);
    };
  } catch (_) { diag('FORMDATA_APPEND_PATCH_FAIL'); }

  try {
    const nativeSet = FormData.prototype.set;
    if (nativeSet) {
      FormData.prototype.set = function(...args) {
        diag('FORMDATA_SET', args[1] instanceof File ? (args[1].name || 'File') : typeof args[1]);
        return nativeSet.apply(this, args);
      };
    }
  } catch (_) { diag('FORMDATA_SET_PATCH_FAIL'); }

  try {
    const nativeFetch = window.fetch;
    window.fetch = function(input, init) {
      let d = '';
      try { d = init && init.body ? (init.body.constructor && init.body.constructor.name || typeof init.body) : 'none'; } catch (_) {}
      diag('FETCH', d);
      return nativeFetch.apply(this, arguments);
    };
  } catch (_) { diag('FETCH_PATCH_FAIL'); }

  try {
    const nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(body) {
      let d = '';
      try { d = body ? (body.constructor && body.constructor.name || typeof body) : 'none'; } catch (_) {}
      diag('XHR_SEND', d);
      return nativeSend.apply(this, arguments);
    };
  } catch (_) { diag('XHR_PATCH_FAIL'); }

  try {
    const nativeAttachShadow = Element.prototype.attachShadow;
    Element.prototype.attachShadow = function(init) {
      const shadow = nativeAttachShadow.apply(this, arguments);
      diag('SHADOW_ROOT_CREATED', this.tagName || 'element');
      return shadow;
    };
  } catch (_) { diag('ATTACH_SHADOW_PATCH_FAIL'); }

  try {
    if (typeof window.showOpenFilePicker === 'function') {
      const nativePicker = window.showOpenFilePicker;
      window.showOpenFilePicker = async function(...args) {
        diag('SHOW_OPEN_FILE_PICKER');
        return nativePicker.apply(this, args);
      };
    } else {
      diag('SHOW_OPEN_FILE_PICKER_UNAVAILABLE');
    }
  } catch (_) { diag('SHOW_OPEN_FILE_PICKER_PATCH_FAIL'); }
})();
'@
Append-Utf8NoBom (Join-Path $ext 'page_hook.js') $pageDiag

$contentDiag = @'

/* DVC_TEST_B_DIAG_ISOLATED */
(() => {
  const lines = [];
  let panel;
  function ensurePanel() {
    try {
      if (panel && panel.isConnected) return panel;
      panel = document.createElement('div');
      panel.id = '__dvc_test_b_diag_panel';
      Object.assign(panel.style, {
        position:'fixed', right:'14px', top:'14px', zIndex:'2147483647', width:'430px', maxHeight:'52vh', overflow:'auto',
        background:'rgba(17,24,39,.96)', color:'#fff', padding:'12px 14px', borderRadius:'12px', border:'1px solid rgba(255,255,255,.2)',
        boxShadow:'0 12px 38px rgba(0,0,0,.35)', fontFamily:'Consolas,Segoe UI,monospace', fontSize:'12px', lineHeight:'1.45', whiteSpace:'pre-wrap'
      });
      (document.documentElement || document.body).appendChild(panel);
      return panel;
    } catch (_) { return null; }
  }
  function log(kind, detail='') {
    const text = new Date().toLocaleTimeString() + '  ' + kind + (detail ? '  ' + detail : '');
    lines.push(text);
    if (lines.length > 30) lines.shift();
    const p = ensurePanel();
    if (p) p.textContent = 'DVC TEST-B DIAG ACTIVE\n' + lines.join('\n');
    try { console.log('[DVC TEST-B DIAG]', kind, detail); } catch (_) {}
  }

  log('ISOLATED_WORLD_READY', location.href);
  window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    const d = event.data;
    if (!d || d.source !== 'DVC_TEST_B_DIAG') return;
    log(d.kind || 'MAIN_EVENT', d.detail || '');
  }, true);

  chrome.runtime.sendMessage({ type:'DVC_HEALTH' }, (response) => {
    if (chrome.runtime.lastError) {
      log('NATIVE_HOST_FAIL', chrome.runtime.lastError.message);
      return;
    }
    if (response && response.ok) log('NATIVE_HOST_READY', response.version || 'ok');
    else log('NATIVE_HOST_FAIL', response && response.reason || 'unknown');
  });

  function resolveFileInput(event) {
    try {
      if (event.target instanceof HTMLInputElement && event.target.type === 'file') return event.target;
      const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
      for (const node of path) {
        if (node instanceof HTMLInputElement && node.type === 'file') return node;
      }
    } catch (_) {}
    return null;
  }

  ['click','pointerdown','input','change'].forEach((type) => {
    window.addEventListener(type, (event) => {
      const input = resolveFileInput(event);
      if (!input) return;
      let detail = 'file-input';
      try { detail += ' files=' + (input.files ? input.files.length : 0) + ' hidden=' + String(!!input.hidden || input.offsetParent === null); } catch (_) {}
      log(type.toUpperCase() + '_FILE_INPUT', detail);
      if ((type === 'input' || type === 'change') && input.files && input.files.length > 0) {
        const state = dvcState.get(input);
        if (!state || (!state.processing && !(state.bypass > 0))) {
          try {
            stop(event);
            const raw = Array.from(input.files);
            log('COMPOSED_PATH_CAPTURE', raw.map(f => f.name).join(','));
            void inspectInput(input, raw);
          } catch (e) { log('COMPOSED_PATH_CAPTURE_FAIL', e && e.message || 'error'); }
        }
      }
    }, true);
  });

  window.addEventListener('drop', (event) => {
    try { log('DROP_EVENT', event.dataTransfer && event.dataTransfer.files ? 'files=' + event.dataTransfer.files.length : 'no-files'); } catch (_) {}
  }, true);
  window.addEventListener('submit', () => log('SUBMIT_EVENT'), true);

  try {
    const observer = new MutationObserver((records) => {
      let fileInputs = 0;
      for (const r of records) {
        for (const n of r.addedNodes || []) {
          if (!(n instanceof Element)) continue;
          if (n.matches && n.matches('input[type="file"]')) fileInputs++;
          if (n.querySelectorAll) fileInputs += n.querySelectorAll('input[type="file"]').length;
        }
      }
      if (fileInputs) log('DYNAMIC_FILE_INPUT_ADDED', String(fileInputs));
    });
    observer.observe(document.documentElement || document, {subtree:true, childList:true});
  } catch (e) { log('MUTATION_OBSERVER_FAIL', e && e.message || 'error'); }
})();
'@
Append-Utf8NoBom (Join-Path $ext 'content.js') $contentDiag

$readmePath = Join-Path $root 'README_FIRST.txt'
$readme = @'

TEST-B DIAGNOSTIC 1.2 ADDITIONS
- A persistent diagnostic panel appears at the top-right as soon as the isolated content script loads.
- Expected initial lines: ISOLATED_WORLD_READY, MAIN_WORLD_READY, NATIVE_HOST_READY.
- File input click/input/change are logged, including hidden inputs discovered through composedPath().
- Dynamic file inputs, Shadow DOM creation, showOpenFilePicker, FormData, fetch, XHR and submit activity are logged.
- For this diagnostic run, take a screenshot of the panel immediately after selecting the DOCX, whether upload succeeds or fails.
'@
Append-Utf8NoBom $readmePath $readme

[System.IO.File]::WriteAllText((Join-Path $root 'ENGINE_MARKER.txt'), "DVC_ENGINE_B_DIAGNOSTIC_V1_2`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host 'TEST_B_DIAGNOSTIC_PATCH_APPLIED'
exit 0
