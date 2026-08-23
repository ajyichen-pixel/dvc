$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$repo = (Get-Location).Path
$hostExe = Join-Path $repo 'build\host\DVCUploadGuardHost.exe'
if (-not (Test-Path -LiteralPath $hostExe)) { throw 'Native host build output missing.' }
$baseManifest = Get-Content (Join-Path $repo 'extension\manifest.json') -Raw | ConvertFrom-Json
$key = [string]$baseManifest.key
if (-not $key) { throw 'Base extension key missing.' }
$browserDownloader = Get-Content (Join-Path $repo 'deploy_native\GET_TEST_BROWSER.ps1') -Raw

$out = Join-Path $repo 'dist_test_b\DVC_TEST_B_WEBPILOT_MAINWORLD'
$ext = Join-Path $out 'extension'
if (Test-Path -LiteralPath (Split-Path $out -Parent)) { Remove-Item -LiteralPath (Split-Path $out -Parent) -Recurse -Force }
New-Item -ItemType Directory -Path $ext -Force | Out-Null
Copy-Item -LiteralPath $hostExe -Destination (Join-Path $out 'DVCUploadGuardHost.exe') -Force
Write-Utf8NoBom (Join-Path $out 'GET_TEST_BROWSER.ps1') $browserDownloader

$manifest = [ordered]@{
  manifest_version = 3
  name = 'DVC Upload Guard TEST-B MainWorld'
  version = '1.1.0'
  description = 'DVC Webpilot-style framework and main-world upload interception test.'
  key = $key
  permissions = @('nativeMessaging')
  host_permissions = @('http://*/*','https://*/*')
  background = [ordered]@{ service_worker='background.js' }
  content_scripts = @(
    [ordered]@{
      matches=@('http://*/*','https://*/*')
      js=@('page_hook.js')
      run_at='document_start'
      all_frames=$true
      world='MAIN'
    },
    [ordered]@{
      matches=@('http://*/*','https://*/*')
      js=@('content.js')
      run_at='document_start'
      all_frames=$true
      world='ISOLATED'
    }
  )
  action = [ordered]@{ default_title='DVC Upload Guard TEST-B MainWorld' }
}
Write-Utf8NoBom (Join-Path $ext 'manifest.json') ($manifest | ConvertTo-Json -Depth 10)

$background = @'
'use strict';
const HOST_NAME = 'com.trcore.dvc_upload_guard_test_b_mainworld';
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
'@
Write-Utf8NoBom (Join-Path $ext 'background.js') $background

$pageHook = @'
'use strict';
/* DVC_ENGINE_B_MAINWORLD_UPLOAD_GUARD */
(() => {
  const safeByKey = new Map();
  const keyOf = (f) => {
    try { return [f.name || '', f.size || 0, f.lastModified || 0, f.type || ''].join('|'); }
    catch (_) { return ''; }
  };
  const mapped = (v) => {
    try { return (v instanceof File) ? (safeByKey.get(keyOf(v)) || null) : null; }
    catch (_) { return null; }
  };

  window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    const d = event.data;
    if (!d || d.source !== 'DVC_TEST_B_SAFE_MAP' || !d.original || !(d.safe instanceof File)) return;
    const k = [d.original.name || '', d.original.size || 0, d.original.lastModified || 0, d.original.type || ''].join('|');
    safeByKey.set(k, d.safe);
    try { document.documentElement.setAttribute('data-dvc-b-safe-map-count', String(safeByKey.size)); } catch (_) {}
  }, true);

  const nativeAppend = FormData.prototype.append;
  FormData.prototype.append = function(name, value, filename) {
    const safe = mapped(value);
    if (safe) {
      return arguments.length >= 3 ? nativeAppend.call(this, name, safe, safe.name) : nativeAppend.call(this, name, safe, safe.name);
    }
    return nativeAppend.apply(this, arguments);
  };

  const nativeSet = FormData.prototype.set;
  if (nativeSet) {
    FormData.prototype.set = function(name, value, filename) {
      const safe = mapped(value);
      if (safe) return nativeSet.call(this, name, safe, safe.name);
      return nativeSet.apply(this, arguments);
    };
  }

  const nativeFetch = window.fetch;
  window.fetch = function(input, init) {
    if (init && init.body) {
      const safe = mapped(init.body);
      if (safe) init = Object.assign({}, init, { body: safe });
    }
    return nativeFetch.call(this, input, init);
  };

  const nativeXhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    return nativeXhrSend.call(this, mapped(body) || body);
  };

  const patchFileReader = (name) => {
    const native = FileReader.prototype[name];
    if (typeof native !== 'function') return;
    FileReader.prototype[name] = function(blob, ...rest) {
      return native.call(this, mapped(blob) || blob, ...rest);
    };
  };
  ['readAsArrayBuffer','readAsText','readAsDataURL','readAsBinaryString'].forEach(patchFileReader);

  const patchBlobRead = (name) => {
    const native = Blob.prototype[name];
    if (typeof native !== 'function') return;
    Blob.prototype[name] = function(...args) {
      const safe = mapped(this);
      return native.apply(safe || this, args);
    };
  };
  ['arrayBuffer','text','stream','slice'].forEach(patchBlobRead);

  try {
    document.documentElement.setAttribute('data-dvc-b-mainworld-hook', 'ready');
  } catch (_) {}
})();
'@
Write-Utf8NoBom (Join-Path $ext 'page_hook.js') $pageHook

$content = @'
'use strict';
/* DVC_ENGINE_B_FRAMEWORK_SETTER_V2 */
const DVC_MAX_BYTES = 512 * 1024;
let dvcPending = 0;
const dvcState = new WeakMap();
const dvcDropBypass = new WeakSet();

function sendNative(payload) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type:'DVC_SANITIZE', payload }, (response) => {
      if (chrome.runtime.lastError) return resolve({ ok:false, action:'block', reason:chrome.runtime.lastError.message });
      resolve(response || { ok:false, action:'block', reason:'No extension response' });
    });
  });
}
function toBase64(buffer) {
  const bytes = new Uint8Array(buffer); let binary=''; const step=0x8000;
  for (let i=0;i<bytes.length;i+=step) binary += String.fromCharCode(...bytes.subarray(i, Math.min(i+step, bytes.length)));
  return btoa(binary);
}
function fromBase64(base64) {
  const binary=atob(base64), bytes=new Uint8Array(binary.length);
  for (let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i);
  return bytes;
}
function toast(message, state='info') {
  try {
    const old=document.getElementById('__dvc_b_toast'); if(old) old.remove();
    const el=document.createElement('div'); el.id='__dvc_b_toast';
    Object.assign(el.style,{position:'fixed',right:'24px',bottom:'24px',zIndex:'2147483647',background:state==='ok'?'#176b41':state==='block'?'#9f2d20':'#f48418',color:'#fff',padding:'12px 16px',borderRadius:'14px',fontFamily:'Segoe UI,Arial,sans-serif',fontSize:'14px',fontWeight:'600',maxWidth:'520px',boxShadow:'0 12px 32px rgba(0,0,0,.24)'});
    el.textContent='DVC TEST-B - '+message; (document.documentElement||document.body).appendChild(el);
    setTimeout(()=>{if(el.isConnected)el.remove();}, state==='block'?8000:5500);
  } catch(_) {}
}
function stop(e){ e.preventDefault(); e.stopImmediatePropagation(); e.stopPropagation(); }
function dataTransfer(files){ const dt=new DataTransfer(); for(const f of files)dt.items.add(f); return dt; }
function setFilesNative(input, files){
  const dt=dataTransfer(files); const desc=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');
  if(desc&&typeof desc.set==='function') desc.set.call(input,dt.files); else input.files=dt.files;
}
function dispatchSafe(input){
  try{input.dispatchEvent(new InputEvent('input',{bubbles:true,cancelable:false,inputType:'insertReplacementText'}));}
  catch(_){input.dispatchEvent(new Event('input',{bubbles:true,cancelable:false}));}
  input.dispatchEvent(new Event('change',{bubbles:true,cancelable:false}));
}
function originalMeta(file){ return {name:file.name,size:file.size,lastModified:file.lastModified,type:file.type||''}; }
function publishSafeMap(original, safe){
  try { window.postMessage({source:'DVC_TEST_B_SAFE_MAP', original:originalMeta(original), safe}, '*'); } catch(_) {}
}
async function processFile(file){
  if(!file||typeof file.arrayBuffer!=='function') return {ok:false,action:'block',reason:'Invalid file'};
  if(file.size>DVC_MAX_BYTES) return {ok:false,action:'block',reason:'Test limit is 512 KB'};
  const response=await sendNative({op:'sanitize',name:file.name,mime:file.type||'application/octet-stream',data:toBase64(await file.arrayBuffer())});
  if(!response||!response.ok||response.action==='block') return response||{ok:false,action:'block',reason:'Native host failed'};
  if(response.action==='rewrite'){
    if(!response.data) return {ok:false,action:'block',reason:'Safe file payload missing'};
    const safe=new File([fromBase64(response.data)],response.name||('DVC_SAFE_'+file.name),{type:response.mime||file.type||'application/octet-stream',lastModified:Date.now()});
    return {ok:true,action:'rewrite',original:file,file:safe,matches:response.matches||0};
  }
  return {ok:true,action:'allow',original:file,file,matches:0};
}
async function processFiles(files){
  const output=[]; const pairs=[]; let rewritten=0,matches=0;
  for(const file of files){ const r=await processFile(file); if(!r||!r.ok||r.action==='block')return{ok:false,reason:(r&&r.reason)||'Blocked'}; output.push(r.file); pairs.push(r); if(r.action==='rewrite')rewritten++; matches+=r.matches||0; }
  return {ok:true,files:output,pairs,rewritten,matches};
}
async function inspectInput(input, rawFiles){
  const existing=dvcState.get(input); if(existing&&existing.processing)return;
  dvcState.set(input,{processing:true,bypass:0}); input.value=''; dvcPending++; toast('framework + MAIN world inspection running...');
  try{
    const result=await processFiles(rawFiles);
    if(!result.ok){ input.value=''; dvcState.delete(input); toast('blocked: '+(result.reason||'inspection failed'),'block'); return; }
    for(const p of result.pairs) if(p.action==='rewrite') publishSafeMap(p.original,p.file);
    setFilesNative(input,result.files); dvcState.set(input,{processing:false,bypass:2}); dispatchSafe(input);
    toast(result.rewritten>0?'SAFE FileList + MAIN world map ready, matches='+result.matches:'checked, no match','ok');
  }catch(_){input.value='';dvcState.delete(input);toast('blocked because inspection failed','block');}
  finally{dvcPending=Math.max(0,dvcPending-1);}
}
function onFileEvent(event){
  const input=event.target; if(!(input instanceof HTMLInputElement)||input.type!=='file')return;
  const state=dvcState.get(input);
  if(state&&state.bypass>0){state.bypass--;if(state.bypass<=0)dvcState.delete(input);return;}
  if(input.files&&input.files.length>0){stop(event);const raw=Array.from(input.files);void inspectInput(input,raw);}
  else if(state&&state.processing) stop(event);
}
async function onDrop(event){
  if(!event.dataTransfer||!event.dataTransfer.files||event.dataTransfer.files.length===0)return;
  const target=event.target;if(target&&dvcDropBypass.has(target)){dvcDropBypass.delete(target);return;}
  stop(event);dvcPending++;
  try{
    const result=await processFiles(Array.from(event.dataTransfer.files));
    if(!result.ok){toast('drop blocked: '+(result.reason||'inspection failed'),'block');return;}
    for(const p of result.pairs) if(p.action==='rewrite') publishSafeMap(p.original,p.file);
    const synthetic=new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dataTransfer(result.files)});
    if(target&&typeof target.dispatchEvent==='function'){dvcDropBypass.add(target);target.dispatchEvent(synthetic);}
    toast('SAFE drop + MAIN world map ready, matches='+result.matches,'ok');
  }finally{dvcPending=Math.max(0,dvcPending-1);}
}
window.addEventListener('input',onFileEvent,true);
window.addEventListener('change',onFileEvent,true);
window.addEventListener('drop',onDrop,true);
window.addEventListener('submit',(event)=>{if(dvcPending<=0)return;stop(event);toast('inspection still running','block');},true);
try{document.documentElement.setAttribute('data-dvc-b-isolated-hook','ready');}catch(_){}
'@
Write-Utf8NoBom (Join-Path $ext 'content.js') $content

$nativeManifest = [ordered]@{
  name='com.trcore.dvc_upload_guard_test_b_mainworld'
  description='DVC Upload Guard TEST-B MainWorld'
  path='C:\Program Files\DVC\UploadGuardTestBMainWorld\DVCUploadGuardHost.exe'
  type='stdio'
  allowed_origins=@('chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/')
}
Write-Utf8NoBom (Join-Path $out 'native_host_manifest.json') ($nativeManifest | ConvertTo-Json -Depth 6)

$install = @'
@echo off
setlocal EnableExtensions
title DVC Upload Guard TEST-B MainWorld - Install
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)
set "ROOT=C:\Program Files\DVC\UploadGuardTestBMainWorld"
set "HOST=com.trcore.dvc_upload_guard_test_b_mainworld"
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
reg add "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /t REG_SZ /d "%ROOT%\native_host_manifest.json" /f >nul
"%ROOT%\DVCUploadGuardHost.exe" --health || goto :fail
"%ROOT%\DVCUploadGuardHost.exe" --selftest || goto :fail
echo INSTALL_OK
call "%ROOT%\START_TEST.cmd"
exit /b 0
:fail
echo INSTALL_FAILED
pause
exit /b 1
'@
Write-Utf8NoBom (Join-Path $out 'INSTALL.cmd') $install

$start = @'
@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\UploadGuardTestBMainWorld"
set "EXT=%ROOT%\extension"
set "PROFILE=%LOCALAPPDATA%\DVC\UploadGuardTestBMainWorldProfile"
set "CHROME=%ProgramData%\DVC\UploadGuard\Browser\chrome-win64\chrome.exe"
if not exist "%CHROME%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\GET_TEST_BROWSER.ps1"
  if errorlevel 1 exit /b 2
)
if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "DVC TEST-B MainWorld" "%CHROME%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "https://chatgpt.com/"
echo START_TEST_OK
exit /b 0
'@
Write-Utf8NoBom (Join-Path $out 'START_TEST.cmd') $start

$verify = @'
@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\UploadGuardTestBMainWorld"
set "HOST=com.trcore.dvc_upload_guard_test_b_mainworld"
set "FAIL=0"
echo ============================================================
echo DVC Upload Guard TEST-B MainWorld - VERIFY
echo ============================================================
if exist "%ROOT%\DVCUploadGuardHost.exe" (echo [PASS] Host EXE) else (echo [FAIL] Host EXE&set FAIL=1)
if exist "%ROOT%\extension\manifest.json" (echo [PASS] Extension manifest) else (echo [FAIL] Extension manifest&set FAIL=1)
if exist "%ROOT%\extension\page_hook.js" (echo [PASS] MAIN world hook) else (echo [FAIL] MAIN world hook&set FAIL=1)
reg query "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [FAIL] Chrome native host registry&set FAIL=1) else echo [PASS] Chrome native host registry
"%ROOT%\DVCUploadGuardHost.exe" --selftest
if errorlevel 1 set FAIL=1
if "%FAIL%"=="0" (echo VERIFY_PASS) else (echo VERIFY_FAIL)
pause
exit /b %FAIL%
'@
Write-Utf8NoBom (Join-Path $out 'VERIFY.cmd') $verify

$uninstall = @'
@echo off
setlocal EnableExtensions
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)
set "ROOT=C:\Program Files\DVC\UploadGuardTestBMainWorld"
set "HOST=com.trcore.dvc_upload_guard_test_b_mainworld"
reg delete "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f /reg:64 >nul 2>&1
reg delete "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f >nul 2>&1
if exist "%ROOT%" rmdir /S /Q "%ROOT%"
echo UNINSTALL_OK
pause
exit /b 0
'@
Write-Utf8NoBom (Join-Path $out 'UNINSTALL.cmd') $uninstall

$readme = @'
DVC Upload Guard TEST-B MainWorld

This version adds a MAIN-world safety net in addition to framework-aware file input replay.
It maps each original File to the DVC sanitized File and intercepts FormData append/set, FileReader, Blob/File reads, fetch body, and XHR body.

TEST:
1. Run INSTALL.cmd as Administrator.
2. Use only the isolated Chrome window it opens.
3. Upload the same small DOCX containing passport / national ID test terms.
4. Download or inspect the file the website actually received.
5. PASS only if the received DOCX contains [DVC-REDACTED] and no original sensitive terms.
'@
Write-Utf8NoBom (Join-Path $out 'README_FIRST.txt') $readme
Write-Utf8NoBom (Join-Path $out 'ENGINE_MARKER.txt') "DVC_ENGINE_B_MAINWORLD_UPLOAD_GUARD`r`n"
Write-Host 'TEST_B_MAINWORLD_PACKAGE_GENERATED'
