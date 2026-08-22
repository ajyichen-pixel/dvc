$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$repo = (Get-Location).Path
$hostExe = Join-Path $repo 'build\host\DVCUploadGuardHost.exe'
if (-not (Test-Path -LiteralPath $hostExe)) { throw 'Native host build output missing.' }
$baseManifest = Get-Content (Join-Path $repo 'extension\manifest.json') -Raw | ConvertFrom-Json
$key = [string]$baseManifest.key
if (-not $key) { throw 'Base extension key missing.' }
$browserDownloader = Get-Content (Join-Path $repo 'deploy_native\GET_TEST_BROWSER.ps1') -Raw

$common = @'
'use strict';

const DVC_MAX_BYTES = 512 * 1024;
let dvcPending = 0;

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
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function dvcToast(message, state = 'info') {
  try {
    const old = document.getElementById('__dvc_upload_guard_engine_toast');
    if (old) old.remove();
    const el = document.createElement('div');
    el.id = '__dvc_upload_guard_engine_toast';
    Object.assign(el.style, {
      position: 'fixed', right: '24px', bottom: '24px', zIndex: '2147483647',
      background: state === 'ok' ? '#176b41' : state === 'block' ? '#9f2d20' : '#f48418',
      color: '#fff', padding: '12px 16px', borderRadius: '14px',
      boxShadow: '0 12px 32px rgba(0,0,0,.24)', fontFamily: 'Segoe UI,Arial,sans-serif',
      fontSize: '14px', fontWeight: '600', maxWidth: '500px'
    });
    el.textContent = message;
    (document.documentElement || document.body).appendChild(el);
    setTimeout(() => { if (el.isConnected) el.remove(); }, state === 'block' ? 7000 : 5000);
  } catch (_) {}
}

async function dvcProcessFile(file) {
  if (!file || typeof file.arrayBuffer !== 'function') {
    return { ok: false, action: 'block', reason: 'Invalid file object' };
  }
  if (file.size > DVC_MAX_BYTES) {
    return { ok: false, action: 'block', reason: 'Test limit is 512 KB.' };
  }
  const data = dvcArrayBufferToBase64(await file.arrayBuffer());
  const response = await dvcSendMessage({
    op: 'sanitize',
    name: file.name,
    mime: file.type || 'application/octet-stream',
    data
  });
  if (!response || !response.ok || response.action === 'block') {
    return response || { ok: false, action: 'block', reason: 'Native host failed' };
  }
  if (response.action === 'rewrite') {
    if (!response.data) return { ok: false, action: 'block', reason: 'Safe file payload missing' };
    const bytes = dvcBase64ToBytes(response.data);
    return {
      ok: true,
      action: 'rewrite',
      file: new File([bytes], response.name || ('DVC_SAFE_' + file.name), {
        type: response.mime || file.type || 'application/octet-stream',
        lastModified: Date.now()
      }),
      matches: response.matches || 0
    };
  }
  return { ok: true, action: 'allow', file, matches: 0 };
}

async function dvcProcessFiles(files) {
  const output = [];
  let rewritten = 0;
  let matches = 0;
  for (const file of files) {
    const r = await dvcProcessFile(file);
    if (!r || !r.ok || r.action === 'block') {
      return { ok: false, reason: (r && r.reason) || 'DVC blocked upload' };
    }
    output.push(r.file);
    if (r.action === 'rewrite') rewritten++;
    matches += r.matches || 0;
  }
  return { ok: true, files: output, rewritten, matches };
}

function dvcDataTransfer(files) {
  const dt = new DataTransfer();
  for (const file of files) dt.items.add(file);
  return dt;
}

function dvcStop(event) {
  event.preventDefault();
  event.stopImmediatePropagation();
  event.stopPropagation();
}

function dvcSetFilesNative(input, files) {
  const dt = dvcDataTransfer(files);
  const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files');
  if (desc && typeof desc.set === 'function') desc.set.call(input, dt.files);
  else input.files = dt.files;
}

function dvcDispatchSafe(input) {
  try {
    input.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: false, inputType: 'insertReplacementText' }));
  } catch (_) {
    input.dispatchEvent(new Event('input', { bubbles: true, cancelable: false }));
  }
  input.dispatchEvent(new Event('change', { bubbles: true, cancelable: false }));
}
'@

$engineA = @'
/* DVC_ENGINE_A_PROXY_PICKER
   Interceptor-style strategy: the website's real file input never receives the
   raw OS selection. DVC opens its own proxy picker, sanitizes there, then injects
   only the safe File objects into the original website input.
*/
const dvcABypass = new WeakMap();
const dvcADropBypass = new WeakSet();

function dvcACopyPickerAttrs(source, proxy) {
  if (source.accept) proxy.accept = source.accept;
  proxy.multiple = !!source.multiple;
  if (source.hasAttribute('capture')) proxy.setAttribute('capture', source.getAttribute('capture') || '');
}

async function dvcAInspectInto(original, rawFiles) {
  dvcPending++;
  dvcToast('TEST-A: sanitizing before website file selection...');
  try {
    const result = await dvcProcessFiles(rawFiles);
    if (!result.ok) {
      original.value = '';
      dvcToast('TEST-A blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }
    dvcABypass.set(original, 2);
    dvcSetFilesNative(original, result.files);
    dvcDispatchSafe(original);
    dvcToast(
      result.rewritten > 0
        ? 'TEST-A: SAFE file injected, matches=' + result.matches
        : 'TEST-A: file checked, no match',
      'ok'
    );
  } catch (_) {
    original.value = '';
    dvcToast('TEST-A blocked because inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcAFileClick(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  if (input.dataset.dvcProxyPicker === '1') return;

  dvcStop(event);

  const proxy = document.createElement('input');
  proxy.type = 'file';
  proxy.dataset.dvcProxyPicker = '1';
  dvcACopyPickerAttrs(input, proxy);
  Object.assign(proxy.style, { position: 'fixed', left: '-10000px', top: '-10000px', width: '1px', height: '1px' });
  (document.body || document.documentElement).appendChild(proxy);

  proxy.addEventListener('change', () => {
    const files = proxy.files ? Array.from(proxy.files) : [];
    proxy.remove();
    if (files.length > 0) void dvcAInspectInto(input, files);
  }, { once: true });

  proxy.click();
}

function dvcAFallbackFileEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;
  if (input.dataset.dvcProxyPicker === '1') return;

  const bypass = dvcABypass.get(input) || 0;
  if (bypass > 0) {
    if (bypass === 1) dvcABypass.delete(input); else dvcABypass.set(input, bypass - 1);
    return;
  }

  if (input.files && input.files.length > 0) {
    dvcStop(event);
    const raw = Array.from(input.files);
    input.value = '';
    void dvcAInspectInto(input, raw);
  }
}

async function dvcADrop(event) {
  if (!event.dataTransfer || !event.dataTransfer.files || event.dataTransfer.files.length === 0) return;
  const target = event.target;
  if (target && dvcADropBypass.has(target)) {
    dvcADropBypass.delete(target);
    return;
  }

  dvcStop(event);
  dvcPending++;
  try {
    const result = await dvcProcessFiles(Array.from(event.dataTransfer.files));
    if (!result.ok) {
      dvcToast('TEST-A drop blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }
    const dt = dvcDataTransfer(result.files);
    const synthetic = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt });
    if (target && typeof target.dispatchEvent === 'function') {
      dvcADropBypass.add(target);
      target.dispatchEvent(synthetic);
    }
    dvcToast('TEST-A: SAFE drop injected, matches=' + result.matches, 'ok');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

window.addEventListener('click', dvcAFileClick, true);
window.addEventListener('input', dvcAFallbackFileEvent, true);
window.addEventListener('change', dvcAFallbackFileEvent, true);
window.addEventListener('drop', dvcADrop, true);
'@

$engineB = @'
/* DVC_ENGINE_B_FRAMEWORK_SETTER
   Webpilot-style strategy: capture input/change before page frameworks, sanitize,
   set FileList through the native HTMLInputElement setter, then replay framework-
   friendly input and change events with only safe File objects.
*/
const dvcBState = new WeakMap();
const dvcBDropBypass = new WeakSet();

async function dvcBInspect(input, rawFiles) {
  const existing = dvcBState.get(input);
  if (existing && existing.processing) return;

  dvcBState.set(input, { processing: true, bypass: 0 });
  input.value = '';
  dvcPending++;
  dvcToast('TEST-B: framework-safe inspection running...');
  try {
    const result = await dvcProcessFiles(rawFiles);
    if (!result.ok) {
      input.value = '';
      dvcBState.delete(input);
      dvcToast('TEST-B blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }

    dvcSetFilesNative(input, result.files);
    dvcBState.set(input, { processing: false, bypass: 2 });
    dvcDispatchSafe(input);
    dvcToast(
      result.rewritten > 0
        ? 'TEST-B: SAFE FileList replayed, matches=' + result.matches
        : 'TEST-B: file checked, no match',
      'ok'
    );
  } catch (_) {
    input.value = '';
    dvcBState.delete(input);
    dvcToast('TEST-B blocked because inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcBFileEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;

  const state = dvcBState.get(input);
  if (state && state.bypass > 0) {
    state.bypass--;
    if (state.bypass <= 0) dvcBState.delete(input);
    return;
  }

  if (input.files && input.files.length > 0) {
    dvcStop(event);
    const raw = Array.from(input.files);
    void dvcBInspect(input, raw);
  } else if (state && state.processing) {
    dvcStop(event);
  }
}

async function dvcBDrop(event) {
  if (!event.dataTransfer || !event.dataTransfer.files || event.dataTransfer.files.length === 0) return;
  const target = event.target;
  if (target && dvcBDropBypass.has(target)) {
    dvcBDropBypass.delete(target);
    return;
  }

  dvcStop(event);
  dvcPending++;
  try {
    const result = await dvcProcessFiles(Array.from(event.dataTransfer.files));
    if (!result.ok) {
      dvcToast('TEST-B drop blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }
    const synthetic = new DragEvent('drop', {
      bubbles: true,
      cancelable: true,
      dataTransfer: dvcDataTransfer(result.files)
    });
    if (target && typeof target.dispatchEvent === 'function') {
      dvcBDropBypass.add(target);
      target.dispatchEvent(synthetic);
    }
    dvcToast('TEST-B: SAFE drop replayed, matches=' + result.matches, 'ok');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

window.addEventListener('input', dvcBFileEvent, true);
window.addEventListener('change', dvcBFileEvent, true);
window.addEventListener('drop', dvcBDrop, true);
'@

$engineC = @'
/* DVC_ENGINE_C_NATIVE_BRIDGE
   Browser-Bridge-style control strategy: keep the native messaging architecture
   minimal and deterministic. Capture the website file event, sanitize through
   the isolated native host, then inject a DataTransfer FileList.
*/
const dvcCState = new WeakMap();
const dvcCDropBypass = new WeakSet();

async function dvcCInspect(input, rawFiles) {
  const state = dvcCState.get(input);
  if (state && state.processing) return;

  dvcCState.set(input, { processing: true, bypass: 0 });
  input.value = '';
  dvcPending++;
  dvcToast('TEST-C: native bridge inspection running...');
  try {
    const result = await dvcProcessFiles(rawFiles);
    if (!result.ok) {
      input.value = '';
      dvcCState.delete(input);
      dvcToast('TEST-C blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }
    const dt = dvcDataTransfer(result.files);
    input.files = dt.files;
    dvcCState.set(input, { processing: false, bypass: 2 });
    input.dispatchEvent(new Event('input', { bubbles: true, cancelable: false }));
    input.dispatchEvent(new Event('change', { bubbles: true, cancelable: false }));
    dvcToast(
      result.rewritten > 0
        ? 'TEST-C: SAFE native-bridge file injected, matches=' + result.matches
        : 'TEST-C: file checked, no match',
      'ok'
    );
  } catch (_) {
    input.value = '';
    dvcCState.delete(input);
    dvcToast('TEST-C blocked because inspection failed.', 'block');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

function dvcCFileEvent(event) {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || input.type !== 'file') return;

  const state = dvcCState.get(input);
  if (state && state.bypass > 0) {
    state.bypass--;
    if (state.bypass <= 0) dvcCState.delete(input);
    return;
  }

  if (input.files && input.files.length > 0) {
    dvcStop(event);
    void dvcCInspect(input, Array.from(input.files));
  } else if (state && state.processing) {
    dvcStop(event);
  }
}

async function dvcCDrop(event) {
  if (!event.dataTransfer || !event.dataTransfer.files || event.dataTransfer.files.length === 0) return;
  const target = event.target;
  if (target && dvcCDropBypass.has(target)) {
    dvcCDropBypass.delete(target);
    return;
  }
  dvcStop(event);
  dvcPending++;
  try {
    const result = await dvcProcessFiles(Array.from(event.dataTransfer.files));
    if (!result.ok) {
      dvcToast('TEST-C drop blocked: ' + (result.reason || 'inspection failed'), 'block');
      return;
    }
    const synthetic = new DragEvent('drop', {
      bubbles: true, cancelable: true, dataTransfer: dvcDataTransfer(result.files)
    });
    if (target && typeof target.dispatchEvent === 'function') {
      dvcCDropBypass.add(target);
      target.dispatchEvent(synthetic);
    }
    dvcToast('TEST-C: SAFE native-bridge drop injected, matches=' + result.matches, 'ok');
  } finally {
    dvcPending = Math.max(0, dvcPending - 1);
  }
}

window.addEventListener('input', dvcCFileEvent, true);
window.addEventListener('change', dvcCFileEvent, true);
window.addEventListener('drop', dvcCDrop, true);
'@

$submitGuard = @'
window.addEventListener('submit', (event) => {
  if (dvcPending <= 0) return;
  dvcStop(event);
  dvcToast('DVC inspection is still running.', 'block');
}, true);

try {
  document.documentElement && document.documentElement.setAttribute('data-dvc-upload-engine', 'active');
} catch (_) {}
'@

$variants = @(
  [pscustomobject]@{
    Code='A'; Folder='DVC_TEST_A_INTERCEPTOR'; Root='C:\Program Files\DVC\UploadGuardTestA';
    Profile='%LOCALAPPDATA%\DVC\UploadGuardTestAProfile'; Host='com.trcore.dvc_upload_guard_test_a';
    Name='DVC Upload Guard TEST-A Interceptor'; Marker='DVC_ENGINE_A_PROXY_PICKER'; Body=$engineA;
    Source='Independent DVC test implementation inspired by Interceptor-style proxy picker and drop injection.'
  },
  [pscustomobject]@{
    Code='B'; Folder='DVC_TEST_B_WEBPILOT'; Root='C:\Program Files\DVC\UploadGuardTestB';
    Profile='%LOCALAPPDATA%\DVC\UploadGuardTestBProfile'; Host='com.trcore.dvc_upload_guard_test_b';
    Name='DVC Upload Guard TEST-B Webpilot'; Marker='DVC_ENGINE_B_FRAMEWORK_SETTER'; Body=$engineB;
    Source='Independent DVC test implementation inspired by DataTransfer/native-setter framework replay patterns.'
  },
  [pscustomobject]@{
    Code='C'; Folder='DVC_TEST_C_BROWSER_BRIDGE'; Root='C:\Program Files\DVC\UploadGuardTestC';
    Profile='%LOCALAPPDATA%\DVC\UploadGuardTestCProfile'; Host='com.trcore.dvc_upload_guard_test_c';
    Name='DVC Upload Guard TEST-C Browser Bridge'; Marker='DVC_ENGINE_C_NATIVE_BRIDGE'; Body=$engineC;
    Source='Independent DVC control implementation using isolated Chrome profile plus Native Messaging bridge.'
  }
)

$dist = Join-Path $repo 'dist_three'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

foreach ($v in $variants) {
  $out = Join-Path $dist $v.Folder
  $ext = Join-Path $out 'extension'
  New-Item -ItemType Directory -Path $ext -Force | Out-Null

  Copy-Item -LiteralPath $hostExe -Destination (Join-Path $out 'DVCUploadGuardHost.exe') -Force
  Write-Utf8NoBom (Join-Path $out 'GET_TEST_BROWSER.ps1') $browserDownloader

  $manifest = [ordered]@{
    manifest_version = 3
    name = $v.Name
    version = '1.0.0'
    description = 'DVC isolated upload engine comparison test.'
    key = $key
    permissions = @('nativeMessaging')
    host_permissions = @('http://*/*','https://*/*')
    background = [ordered]@{ service_worker='background.js' }
    content_scripts = @([ordered]@{
      matches=@('http://*/*','https://*/*')
      js=@('content.js')
      run_at='document_start'
      all_frames=$true
    })
    action = [ordered]@{ default_title=$v.Name }
  }
  Write-Utf8NoBom (Join-Path $ext 'manifest.json') ($manifest | ConvertTo-Json -Depth 8)

  $background = @"
'use strict';
const HOST_NAME = '$($v.Host)';
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== 'DVC_SANITIZE') return false;
  chrome.runtime.sendNativeMessage(HOST_NAME, message.payload, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({ ok:false, action:'block', reason:'Native host error: ' + chrome.runtime.lastError.message });
      return;
    }
    sendResponse(response || { ok:false, action:'block', reason:'Native host returned no response' });
  });
  return true;
});
"@
  Write-Utf8NoBom (Join-Path $ext 'background.js') $background
  Write-Utf8NoBom (Join-Path $ext 'content.js') ($common + "`r`n" + $v.Body + "`r`n" + $submitGuard)

  $nativeManifest = [ordered]@{
    name = $v.Host
    description = $v.Name
    path = ($v.Root + '\DVCUploadGuardHost.exe')
    type = 'stdio'
    allowed_origins = @('chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/')
  }
  Write-Utf8NoBom (Join-Path $out 'native_host_manifest.json') ($nativeManifest | ConvertTo-Json -Depth 6)

  $install = @"
@echo off
setlocal EnableExtensions
title $($v.Name) - Install
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath `$env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)
set "ROOT=$($v.Root)"
set "HOST=$($v.Host)"
if not exist "%ROOT%" mkdir "%ROOT%"
if not exist "%ROOT%\extension" mkdir "%ROOT%\extension"
copy /Y "%~dp0DVCUploadGuardHost.exe" "%ROOT%\DVCUploadGuardHost.exe" >nul || goto :fail
copy /Y "%~dp0native_host_manifest.json" "%ROOT%\native_host_manifest.json" >nul || goto :fail
copy /Y "%~dp0GET_TEST_BROWSER.ps1" "%ROOT%\GET_TEST_BROWSER.ps1" >nul || goto :fail
copy /Y "%~dp0START_TEST.cmd" "%ROOT%\START_TEST.cmd" >nul || goto :fail
copy /Y "%~dp0VERIFY.cmd" "%ROOT%\VERIFY.cmd" >nul || goto :fail
copy /Y "%~dp0UNINSTALL.cmd" "%ROOT%\UNINSTALL.cmd" >nul || goto :fail
robocopy "%~dp0extension" "%ROOT%\extension" /E /NFL /NDL /NJH /NJS /NP >nul
reg add "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:64 >nul
reg add "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\%HOST%" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f /reg:64 >nul
reg add "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f >nul
reg add "HKCU\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\%HOST%" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f >nul
"%ROOT%\DVCUploadGuardHost.exe" --health || goto :fail
"%ROOT%\DVCUploadGuardHost.exe" --selftest || goto :fail
echo INSTALL_OK
call "%ROOT%\START_TEST.cmd"
exit /b 0
:fail
echo INSTALL_FAILED
pause
exit /b 1
"@
  Write-Utf8NoBom (Join-Path $out 'INSTALL.cmd') $install

  $start = @"
@echo off
setlocal EnableExtensions
set "ROOT=$($v.Root)"
set "EXT=%ROOT%\extension"
set "PROFILE=$($v.Profile)"
set "CHROME=%ProgramData%\DVC\UploadGuard\Browser\chrome-win64\chrome.exe"
if not exist "%CHROME%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\GET_TEST_BROWSER.ps1"
  if errorlevel 1 exit /b 2
)
if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "$($v.Name)" "%CHROME%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "https://chatgpt.com/"
echo START_TEST_OK
exit /b 0
"@
  Write-Utf8NoBom (Join-Path $out 'START_TEST.cmd') $start

  $verify = @"
@echo off
setlocal EnableExtensions
set "ROOT=$($v.Root)"
set "HOST=$($v.Host)"
set "FAIL=0"
echo ============================================================
echo $($v.Name) - VERIFY
echo ============================================================
if exist "%ROOT%\DVCUploadGuardHost.exe" (echo [PASS] Host EXE) else (echo [FAIL] Host EXE&set FAIL=1)
if exist "%ROOT%\extension\manifest.json" (echo [PASS] Extension) else (echo [FAIL] Extension&set FAIL=1)
reg query "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [FAIL] Chrome native host registry&set FAIL=1) else echo [PASS] Chrome native host registry
"%ROOT%\DVCUploadGuardHost.exe" --selftest
if errorlevel 1 set FAIL=1
if "%FAIL%"=="0" (echo VERIFY_PASS) else (echo VERIFY_FAIL)
pause
exit /b %FAIL%
"@
  Write-Utf8NoBom (Join-Path $out 'VERIFY.cmd') $verify

  $uninstall = @"
@echo off
setlocal EnableExtensions
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath `$env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)
set "ROOT=$($v.Root)"
set "HOST=$($v.Host)"
reg delete "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f /reg:64 >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\%HOST%" /f /reg:64 >nul 2>&1
reg delete "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\%HOST%" /f >nul 2>&1
if exist "%ROOT%" rmdir /S /Q "%ROOT%"
echo UNINSTALL_OK
pause
exit /b 0
"@
  Write-Utf8NoBom (Join-Path $out 'UNINSTALL.cmd') $uninstall

  $readme = @"
$($v.Name)

ENGINE:
$($v.Source)

ISOLATION:
Install folder: $($v.Root)
Chrome profile: $($v.Profile)
Native host: $($v.Host)
Extension ID: cdmogelilldmfcioieahdnaocmillhcl (same signed test extension key; profile is isolated)

TEST:
1. Run INSTALL.cmd as Administrator.
2. The isolated Chrome for Testing profile opens.
3. Upload the same small DOCX that contains the passport / national ID test terms.
4. Download or inspect the file that the website actually received.
5. PASS only if the received DOCX contains [DVC-REDACTED] and no original sensitive terms.
6. Run UNINSTALL.cmd before moving to the next engine if you want a completely clean machine state.

The native host preserves the existing DVC DOCX sanitization self-test.
Upstream projects are not redistributed in this package; this is an independent DVC test implementation of the compared integration pattern.
"@
  Write-Utf8NoBom (Join-Path $out 'README_FIRST.txt') $readme
  Write-Utf8NoBom (Join-Path $out 'ENGINE_MARKER.txt') ($v.Marker + "`r`n")
}

Write-Host 'THREE_ENGINE_PACKAGES_GENERATED'
