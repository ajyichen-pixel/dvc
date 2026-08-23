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

$out = Join-Path $repo 'dist_diag\DVC_BROWSER_UPLOAD_DIAGNOSTIC_V1'
$ext = Join-Path $out 'extension'
if (Test-Path -LiteralPath (Split-Path $out -Parent)) { Remove-Item -LiteralPath (Split-Path $out -Parent) -Recurse -Force }
New-Item -ItemType Directory -Path $ext -Force | Out-Null
Copy-Item -LiteralPath $hostExe -Destination (Join-Path $out 'DVCUploadGuardHost.exe') -Force
Write-Utf8NoBom (Join-Path $out 'GET_TEST_BROWSER.ps1') $browserDownloader

$manifest = [ordered]@{
  manifest_version = 3
  name = 'DVC Browser Upload Diagnostic'
  version = '1.0.0'
  description = 'DVC browser upload path diagnostic console.'
  key = $key
  permissions = @('nativeMessaging','downloads')
  host_permissions = @('http://*/*','https://*/*')
  background = [ordered]@{ service_worker='background.js' }
  content_scripts = @(
    [ordered]@{ matches=@('http://*/*','https://*/*'); js=@('page_hook.js'); run_at='document_start'; all_frames=$true; world='MAIN' },
    [ordered]@{ matches=@('http://*/*','https://*/*'); js=@('content.js'); run_at='document_start'; all_frames=$true; world='ISOLATED' }
  )
  action = [ordered]@{ default_title='DVC Browser Upload Diagnostic' }
}
Write-Utf8NoBom (Join-Path $ext 'manifest.json') ($manifest | ConvertTo-Json -Depth 10)

$background = @'
'use strict';
const HOST_NAME = 'com.trcore.dvc_browser_upload_diagnostic';
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== 'DVC_NATIVE') return false;
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
/* DVC_BROWSER_UPLOAD_DIAGNOSTIC_MAIN_V1 */
(() => {
  const exactMap = new Map();
  const looseMap = new Map();
  const now = () => new Date().toISOString();
  const exactKey = f => { try { return [f.name||'',f.size||0,f.lastModified||0,f.type||''].join('|'); } catch(_) { return ''; } };
  const looseKey = f => { try { return [f.name||'',f.size||0,f.type||''].join('|'); } catch(_) { return ''; } };
  const emit = (type, detail={}) => window.postMessage({source:'DVC_DIAG_MAIN_EVENT', time:now(), type, detail}, '*');
  const safeFor = v => {
    try {
      if (!(v instanceof File)) return null;
      return exactMap.get(exactKey(v)) || looseMap.get(looseKey(v)) || null;
    } catch(_) { return null; }
  };
  const describe = v => {
    try { return v instanceof File ? {name:v.name,size:v.size,type:v.type,lastModified:v.lastModified} : {kind:Object.prototype.toString.call(v)}; }
    catch(_) { return {kind:'unknown'}; }
  };
  const mapOrLog = (v, path) => {
    const safe = safeFor(v);
    if (safe) {
      emit(path, {mapped:true, original:describe(v), safe:describe(safe)});
      return safe;
    }
    if (v instanceof File) emit(path, {mapped:false, file:describe(v), knownMappings:exactMap.size});
    else emit(path, {mapped:false, nonFile:true});
    return v;
  };

  window.addEventListener('message', e => {
    if (e.source !== window || !e.data) return;
    if (e.data.source === 'DVC_DIAG_SAFE_MAP' && e.data.original && e.data.safe instanceof File) {
      const o = e.data.original;
      const ek = [o.name||'',o.size||0,o.lastModified||0,o.type||''].join('|');
      const lk = [o.name||'',o.size||0,o.type||''].join('|');
      exactMap.set(ek, e.data.safe);
      looseMap.set(lk, e.data.safe);
      emit('SAFE_MAP_ADDED', {original:o, safe:describe(e.data.safe), count:exactMap.size});
    }
    if (e.data.source === 'DVC_DIAG_FORCE_MAIN_TEST' && e.data.original instanceof File) {
      try {
        const fd = new FormData();
        fd.append('dvc_force_test', e.data.original, e.data.original.name);
        const seen = fd.get('dvc_force_test');
        emit('FORCE_TEST_RESULT', {input:describe(e.data.original), result:describe(seen), safeName:seen instanceof File ? seen.name : null});
      } catch (err) { emit('FORCE_TEST_ERROR', {message:String(err)}); }
    }
  }, true);

  const nativeAppend = FormData.prototype.append;
  FormData.prototype.append = function(name, value, filename) {
    const out = mapOrLog(value, 'FORMDATA_APPEND');
    if (out instanceof File) return nativeAppend.call(this, name, out, out.name);
    return nativeAppend.apply(this, arguments);
  };
  const nativeSet = FormData.prototype.set;
  if (nativeSet) FormData.prototype.set = function(name, value, filename) {
    const out = mapOrLog(value, 'FORMDATA_SET');
    if (out instanceof File) return nativeSet.call(this, name, out, out.name);
    return nativeSet.apply(this, arguments);
  };

  const nativeFetch = window.fetch;
  window.fetch = function(input, init) {
    emit('FETCH_CALL', {hasBody:!!(init&&init.body), bodyType:init&&init.body?Object.prototype.toString.call(init.body):null});
    if (init && init.body instanceof File) init = Object.assign({}, init, {body:mapOrLog(init.body,'FETCH_FILE_BODY')});
    return nativeFetch.call(this, input, init);
  };

  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    emit('XHR_SEND', {hasBody:!!body, bodyType:body?Object.prototype.toString.call(body):null});
    if (body instanceof File) body = mapOrLog(body,'XHR_FILE_BODY');
    return nativeSend.call(this, body);
  };

  ['readAsArrayBuffer','readAsText','readAsDataURL','readAsBinaryString'].forEach(name => {
    const native = FileReader.prototype[name];
    if (typeof native !== 'function') return;
    FileReader.prototype[name] = function(blob, ...rest) {
      if (blob instanceof File) blob = mapOrLog(blob, 'FILEREADER_' + name.toUpperCase());
      return native.call(this, blob, ...rest);
    };
  });

  ['arrayBuffer','text','stream','slice'].forEach(name => {
    const native = Blob.prototype[name];
    if (typeof native !== 'function') return;
    Blob.prototype[name] = function(...args) {
      let self = this;
      if (this instanceof File) self = mapOrLog(this, 'BLOB_' + name.toUpperCase());
      return native.apply(self, args);
    };
  });

  if (typeof window.showOpenFilePicker === 'function') {
    const nativePicker = window.showOpenFilePicker.bind(window);
    window.showOpenFilePicker = async function(...args) {
      emit('SHOW_OPEN_FILE_PICKER', {phase:'called'});
      const handles = await nativePicker(...args);
      emit('SHOW_OPEN_FILE_PICKER', {phase:'returned', count:handles&&handles.length||0});
      return handles;
    };
  }

  emit('MAIN_WORLD_READY', {url:location.href});
})();
'@
Write-Utf8NoBom (Join-Path $ext 'page_hook.js') $pageHook

$content = @'
'use strict';
/* DVC_BROWSER_UPLOAD_DIAGNOSTIC_ISOLATED_V1 */
const MAX_BYTES = 512 * 1024;
const timeline = [];
const state = {
  version:'1.0.0', isolated:'READY', main:'WAITING', native:'WAITING', hostVersion:'',
  selected:'', selectedSize:0, sanitize:'IDLE', action:'', matches:0, safeName:'',
  inputSetter:'NO', changeReplay:'NO', uploadPath:'UNKNOWN', verdict:'YELLOW',
  lastEvent:'', lastDetail:'', events:0
};
let bypass = new WeakMap();
let panel;

function record(type, detail={}) {
  const item = {time:new Date().toISOString(), type, detail};
  timeline.push(item); if (timeline.length > 500) timeline.shift();
  state.lastEvent = type; state.lastDetail = JSON.stringify(detail); state.events = timeline.length;
  if (['FORMDATA_APPEND','FORMDATA_SET','FETCH_FILE_BODY','XHR_FILE_BODY','FILEREADER_READASARRAYBUFFER','FILEREADER_READASTEXT','FILEREADER_READASDATAURL','FILEREADER_READASBINARYSTRING'].includes(type)) {
    state.uploadPath = type;
    if (detail && detail.mapped === true) state.verdict = 'GREEN';
    else if (detail && detail.mapped === false && detail.knownMappings > 0) state.verdict = 'RED';
  }
  render();
}

function native(payload) {
  return new Promise(resolve => chrome.runtime.sendMessage({type:'DVC_NATIVE',payload}, r => {
    if (chrome.runtime.lastError) return resolve({ok:false,action:'block',reason:chrome.runtime.lastError.message});
    resolve(r || {ok:false,action:'block',reason:'No response'});
  }));
}
function b64(buf){const bytes=new Uint8Array(buf);let s='';for(let i=0;i<bytes.length;i+=0x8000)s+=String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)));return btoa(s);}
function bytes(s){const x=atob(s),o=new Uint8Array(x.length);for(let i=0;i<x.length;i++)o[i]=x.charCodeAt(i);return o;}
function meta(f){return {name:f.name,size:f.size,lastModified:f.lastModified,type:f.type||''};}
function dt(files){const d=new DataTransfer();for(const f of files)d.items.add(f);return d;}
function findFileInput(e){
  const path = typeof e.composedPath === 'function' ? e.composedPath() : [e.target];
  for (const n of path) if (n instanceof HTMLInputElement && n.type === 'file') return n;
  return e.target instanceof HTMLInputElement && e.target.type === 'file' ? e.target : null;
}

async function sanitize(file) {
  state.selected=file.name; state.selectedSize=file.size; state.sanitize='RUNNING'; state.action=''; state.matches=0; state.safeName=''; state.verdict='YELLOW'; render();
  record('FILE_CAPTURED', meta(file));
  if (file.size > MAX_BYTES) return {ok:false,reason:'File exceeds 512 KB diagnostic limit'};
  record('HOST_REQUEST_SENT', meta(file));
  const r = await native({op:'sanitize',name:file.name,mime:file.type||'application/octet-stream',data:b64(await file.arrayBuffer())});
  record('HOST_RESPONSE', {ok:r&&r.ok, action:r&&r.action, matches:r&&r.matches, reason:r&&r.reason, version:r&&r.version});
  if (!r || !r.ok || r.action === 'block') { state.sanitize='FAILED'; state.action='BLOCK'; render(); return {ok:false,reason:r&&r.reason||'Host failed'}; }
  state.sanitize='DONE'; state.action=r.action||'allow'; state.matches=r.matches||0;
  if (r.action === 'rewrite') {
    const safe = new File([bytes(r.data)], r.name || ('DVC_SAFE_'+file.name), {type:r.mime||file.type||'application/octet-stream',lastModified:Date.now()});
    state.safeName=safe.name;
    window.postMessage({source:'DVC_DIAG_SAFE_MAP', original:meta(file), safe}, '*');
    record('SAFE_FILE_CREATED', {original:meta(file),safe:meta(safe),matches:state.matches});
    render(); return {ok:true,original:file,file:safe,action:'rewrite'};
  }
  state.safeName=file.name; render(); return {ok:true,original:file,file,action:'allow'};
}

async function processInput(input) {
  const n = bypass.get(input)||0;
  if (n>0) { bypass.set(input,n-1); record('BYPASS_REPLAY_EVENT',{remaining:n-1}); return; }
  if (!input.files || !input.files.length) return;
  const raw = Array.from(input.files); input.value='';
  const output=[];
  for (const f of raw) { const r=await sanitize(f); if(!r.ok){record('SANITIZE_BLOCK',{reason:r.reason});return;} output.push(r.file); }
  const desc=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');
  const list=dt(output).files;
  if(desc&&typeof desc.set==='function') desc.set.call(input,list); else input.files=list;
  state.inputSetter='YES'; record('INPUT_SETTER',{names:Array.from(input.files||[]).map(f=>f.name)});
  bypass.set(input,2);
  input.dispatchEvent(new Event('input',{bubbles:true}));
  input.dispatchEvent(new Event('change',{bubbles:true}));
  state.changeReplay='YES'; record('CHANGE_REPLAY',{names:Array.from(input.files||[]).map(f=>f.name)});
}

['pointerdown','click','input','change','drop','submit'].forEach(type => {
  window.addEventListener(type, e => {
    const input=findFileInput(e);
    record(type.toUpperCase(), {target:e.target&&e.target.tagName||'', fileInput:!!input, inputName:input&&input.name||'', files:input&&input.files?Array.from(input.files).map(meta):[]});
    if ((type==='input'||type==='change') && input) void processInput(input);
    if (type==='drop' && e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) record('DROP_FILES',{files:Array.from(e.dataTransfer.files).map(meta)});
  }, true);
});

const mo = new MutationObserver(ms => { for(const m of ms) for(const n of m.addedNodes||[]) { if(!(n instanceof Element)) continue; const found=[]; if(n.matches&&n.matches('input[type=file]')) found.push(n); found.push(...(n.querySelectorAll?n.querySelectorAll('input[type=file]'):[])); for(const x of found) record('DYNAMIC_FILE_INPUT_ADDED',{name:x.name||'',id:x.id||'',hidden:x.hidden||getComputedStyle(x).display==='none'}); } });
try { mo.observe(document.documentElement,{childList:true,subtree:true}); } catch(_) {}

window.addEventListener('message', e => {
  if (e.source!==window || !e.data || e.data.source!=='DVC_DIAG_MAIN_EVENT') return;
  if (e.data.type==='MAIN_WORLD_READY') state.main='READY';
  record(e.data.type,e.data.detail||{});
}, true);

function statusColor(v){return v==='GREEN'?'#16a34a':v==='RED'?'#dc2626':'#d97706';}
function render(){
  if(!panel||!panel.isConnected)return;
  const v=panel.querySelector('[data-dvc-body]'); if(!v)return;
  v.innerHTML = `
  <div><b>VERDICT</b> <span style="color:${statusColor(state.verdict)};font-weight:800">${state.verdict}</span></div>
  <div>ISOLATED_WORLD&nbsp;&nbsp;${state.isolated}</div>
  <div>MAIN_WORLD&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;${state.main}</div>
  <div>NATIVE_HOST&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;${state.native} ${state.hostVersion}</div>
  <hr style="border:0;border-top:1px solid #374151;margin:7px 0">
  <div>FILE&nbsp;&nbsp;${escapeHtml(state.selected||'-')}</div>
  <div>SIZE&nbsp;&nbsp;${state.selectedSize||0}</div>
  <div>SANITIZE&nbsp;&nbsp;${state.sanitize}</div>
  <div>ACTION&nbsp;&nbsp;${state.action||'-'}</div>
  <div>MATCHES&nbsp;&nbsp;${state.matches}</div>
  <div>SAFE_FILE&nbsp;&nbsp;${escapeHtml(state.safeName||'-')}</div>
  <div>INPUT_SETTER&nbsp;&nbsp;${state.inputSetter}</div>
  <div>CHANGE_REPLAY&nbsp;&nbsp;${state.changeReplay}</div>
  <div>UPLOAD_PATH&nbsp;&nbsp;${state.uploadPath}</div>
  <hr style="border:0;border-top:1px solid #374151;margin:7px 0">
  <div>EVENTS&nbsp;&nbsp;${state.events}</div>
  <div>LAST&nbsp;&nbsp;${escapeHtml(state.lastEvent||'-')}</div>
  <div style="font-size:10px;opacity:.8;max-width:330px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${escapeHtml(state.lastDetail||'')}</div>`;
}
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function exportLog(){
  const payload={generatedAt:new Date().toISOString(),url:location.href,state:{...state},timeline:[...timeline],userAgent:navigator.userAgent};
  const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'});
  const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='DVC_UPLOAD_DIAG_'+new Date().toISOString().replace(/[:.]/g,'-')+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);
  record('EXPORT_DIAGNOSTIC_LOG',{});
}
async function forceTest(){
  record('FORCE_TEST_START',{});
  const picker=document.createElement('input');picker.type='file';picker.accept='.docx,.txt,.csv,.json,.xml,.html,.htm,.log,.md';picker.style.display='none';document.documentElement.appendChild(picker);
  picker.addEventListener('change',async()=>{const f=picker.files&&picker.files[0];picker.remove();if(!f){record('FORCE_TEST_CANCEL',{});return;}const r=await sanitize(f);if(!r.ok){record('FORCE_TEST_SANITIZE_FAIL',{reason:r.reason});return;}window.postMessage({source:'DVC_DIAG_FORCE_MAIN_TEST',original:f},'*');},{once:true});picker.click();
}
function makePanel(){
  panel=document.createElement('div');panel.id='__dvc_upload_diag_panel';
  Object.assign(panel.style,{position:'fixed',right:'12px',top:'12px',zIndex:'2147483647',width:'380px',background:'#111827',color:'#f9fafb',border:'1px solid #4b5563',borderRadius:'12px',boxShadow:'0 12px 36px rgba(0,0,0,.35)',padding:'12px',font:'12px/1.45 Consolas,monospace'});
  panel.innerHTML='<div style="font:700 14px Segoe UI;margin-bottom:8px">DVC Browser Upload Diagnostic V1</div><div data-dvc-body></div><div style="display:flex;gap:8px;margin-top:10px"><button data-dvc-export>Export Diagnostic Log</button><button data-dvc-force>Force Test Mode</button></div>';
  for(const b of panel.querySelectorAll('button'))Object.assign(b.style,{cursor:'pointer',padding:'6px 8px',borderRadius:'8px',border:'1px solid #6b7280',background:'#1f2937',color:'#fff',font:'11px Segoe UI'});
  panel.querySelector('[data-dvc-export]').onclick=exportLog;panel.querySelector('[data-dvc-force]').onclick=forceTest;
  (document.documentElement||document.body).appendChild(panel);render();
}

record('ISOLATED_WORLD_READY',{url:location.href});
const start=()=>{if(!panel)makePanel();}; if(document.documentElement)start(); else document.addEventListener('DOMContentLoaded',start,{once:true});
void (async()=>{const r=await native({op:'health'});state.native=r&&r.ok?'READY':'FAILED';state.hostVersion=r&&r.version||'';record('NATIVE_HOST_READY',{ok:r&&r.ok,version:r&&r.version,reason:r&&r.reason});})();
'@
Write-Utf8NoBom (Join-Path $ext 'content.js') $content

$nativeManifest = [ordered]@{
  name='com.trcore.dvc_browser_upload_diagnostic'
  description='DVC Browser Upload Diagnostic V1'
  path='C:\Program Files\DVC\BrowserUploadDiagnostic\DVCUploadGuardHost.exe'
  type='stdio'
  allowed_origins=@('chrome-extension://cdmogelilldmfcioieahdnaocmillhcl/')
}
Write-Utf8NoBom (Join-Path $out 'native_host_manifest.json') ($nativeManifest | ConvertTo-Json -Depth 6)

$install = @'
@echo off
setlocal EnableExtensions
title DVC Browser Upload Diagnostic V1 - Install
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList '/c','""%~f0""'"
  exit /b
)
set "ROOT=C:\Program Files\DVC\BrowserUploadDiagnostic"
set "HOST=com.trcore.dvc_browser_upload_diagnostic"
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
set "ROOT=C:\Program Files\DVC\BrowserUploadDiagnostic"
set "EXT=%ROOT%\extension"
set "PROFILE=%LOCALAPPDATA%\DVC\BrowserUploadDiagnosticProfile"
set "CHROME=%ProgramData%\DVC\UploadGuard\Browser\chrome-win64\chrome.exe"
if not exist "%CHROME%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\GET_TEST_BROWSER.ps1"
  if errorlevel 1 exit /b 2
)
if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1
start "DVC Browser Upload Diagnostic V1" "%CHROME%" --user-data-dir="%PROFILE%" --no-first-run --no-default-browser-check --disable-extensions-except="%EXT%" --load-extension="%EXT%" "https://chatgpt.com/"
echo START_TEST_OK
exit /b 0
'@
Write-Utf8NoBom (Join-Path $out 'START_TEST.cmd') $start

$verify = @'
@echo off
setlocal EnableExtensions
set "ROOT=C:\Program Files\DVC\BrowserUploadDiagnostic"
set "HOST=com.trcore.dvc_browser_upload_diagnostic"
set "FAIL=0"
echo ============================================================
echo DVC Browser Upload Diagnostic V1 - VERIFY
echo ============================================================
if exist "%ROOT%\DVCUploadGuardHost.exe" (echo [PASS] Host EXE) else (echo [FAIL] Host EXE&set FAIL=1)
if exist "%ROOT%\extension\manifest.json" (echo [PASS] Extension manifest) else (echo [FAIL] Extension manifest&set FAIL=1)
if exist "%ROOT%\extension\page_hook.js" (echo [PASS] MAIN world hook) else (echo [FAIL] MAIN world hook&set FAIL=1)
if exist "%ROOT%\extension\content.js" (echo [PASS] Diagnostic console) else (echo [FAIL] Diagnostic console&set FAIL=1)
reg query "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /ve /reg:64 >nul 2>&1
if errorlevel 1 (echo [FAIL] Chrome native host registry&set FAIL=1) else echo [PASS] Chrome native host registry
"%ROOT%\DVCUploadGuardHost.exe" --health
if errorlevel 1 set FAIL=1
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
set "ROOT=C:\Program Files\DVC\BrowserUploadDiagnostic"
set "HOST=com.trcore.dvc_browser_upload_diagnostic"
reg delete "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f /reg:64 >nul 2>&1
reg delete "HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\%HOST%" /f >nul 2>&1
if exist "%ROOT%" rmdir /S /Q "%ROOT%"
echo UNINSTALL_OK
pause
exit /b 0
'@
Write-Utf8NoBom (Join-Path $out 'UNINSTALL.cmd') $uninstall

$readme = @'
DVC Browser Upload Diagnostic V1

PURPOSE
This package diagnoses the exact browser upload path before more enforcement changes are made.

HOW TO TEST
1. Run INSTALL.cmd as Administrator.
2. Run VERIFY.cmd and confirm VERIFY_PASS.
3. Use only the Chrome window opened by START_TEST.cmd.
4. Open the target upload website.
5. Confirm the top-right diagnostic panel shows ISOLATED_WORLD READY, MAIN_WORLD READY, and NATIVE_HOST READY.
6. Upload the same small DOCX test file.
7. Watch VERDICT and UPLOAD_PATH.
8. Click Export Diagnostic Log and send the JSON file for analysis.

VERDICT
GREEN  Safe file was observed in an instrumented upload/read path.
YELLOW Sanitization occurred but the final upload path is still unknown.
RED    An original file was observed after a safe mapping existed.

FORCE TEST MODE
Select a file and the diagnostic will sanitize it, create the safe mapping, then run an in-page FormData append test without sending a network request.
'@
Write-Utf8NoBom (Join-Path $out 'README_FIRST.txt') $readme
Write-Utf8NoBom (Join-Path $out 'ENGINE_MARKER.txt') "DVC_BROWSER_UPLOAD_DIAGNOSTIC_V1`r`n"

Write-Host 'DVC_BROWSER_UPLOAD_DIAGNOSTIC_V1_GENERATED'
exit 0
