$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$root = Join-Path (Get-Location).Path 'dist_diag\DVC_BROWSER_UPLOAD_DIAGNOSTIC_V1'
$ext = Join-Path $root 'extension'
if (-not (Test-Path -LiteralPath (Join-Path $ext 'manifest.json'))) { throw 'Diagnostic V1 package missing. Run base builder first.' }

$main = @'
'use strict';
/* DVC_PICKER_XHR_INTERCEPT_V2_MAIN */
(() => {
  const SAFE = new WeakSet();
  const pending = new Map();
  let seq = 0;
  const emit = (type, detail={}) => {
    try { window.postMessage({source:'DVC_DIAG_MAIN_EVENT',time:new Date().toISOString(),type,detail},'*'); } catch(_) {}
  };
  const meta = f => {
    try { return {name:f.name,size:f.size,type:f.type||'',lastModified:f.lastModified||0}; }
    catch(_) { return {}; }
  };
  const requestSanitize = file => new Promise((resolve,reject) => {
    if (!(file instanceof File)) return resolve(file);
    if (SAFE.has(file)) return resolve(file);
    const id = 'dvc-picker-' + Date.now() + '-' + (++seq);
    const timer = setTimeout(() => {
      pending.delete(id);
      emit('PICKER_SANITIZE_TIMEOUT',{id,file:meta(file)});
      reject(new Error('DVC sanitize timeout'));
    }, 20000);
    pending.set(id,{resolve,reject,timer,original:file});
    emit('PICKER_SANITIZE_REQUEST',{id,file:meta(file)});
    window.postMessage({source:'DVC_PICKER_SANITIZE_REQUEST',id,file},'*');
  });

  window.addEventListener('message', e => {
    if (e.source !== window || !e.data || e.data.source !== 'DVC_PICKER_SANITIZE_RESPONSE') return;
    const p = pending.get(e.data.id);
    if (!p) return;
    pending.delete(e.data.id); clearTimeout(p.timer);
    if (!e.data.ok || !(e.data.file instanceof File)) {
      emit('PICKER_SANITIZE_BLOCK',{id:e.data.id,reason:e.data.reason||'sanitize failed',original:meta(p.original)});
      p.reject(new Error(e.data.reason || 'DVC sanitize failed'));
      return;
    }
    SAFE.add(e.data.file);
    emit('PICKER_SAFE_FILE_RETURNED',{id:e.data.id,original:meta(p.original),safe:meta(e.data.file),matches:e.data.matches||0,action:e.data.action||''});
    p.resolve(e.data.file);
  }, true);

  if (typeof FileSystemFileHandle !== 'undefined' && FileSystemFileHandle.prototype && typeof FileSystemFileHandle.prototype.getFile === 'function') {
    const nativeGetFile = FileSystemFileHandle.prototype.getFile;
    FileSystemFileHandle.prototype.getFile = async function(...args) {
      const raw = await nativeGetFile.apply(this,args);
      emit('PICKER_GETFILE_CAPTURED',{file:meta(raw)});
      return await requestSanitize(raw);
    };
    emit('PICKER_GETFILE_HOOK_READY',{});
  } else {
    emit('PICKER_GETFILE_HOOK_UNAVAILABLE',{});
  }

  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    if (!(body instanceof File) || SAFE.has(body)) return nativeSend.call(this,body);
    const xhr = this;
    emit('XHR_DIRECT_SANITIZE_REQUEST',{file:meta(body)});
    requestSanitize(body).then(safe => {
      emit('XHR_DIRECT_SAFE_SEND',{original:meta(body),safe:meta(safe)});
      nativeSend.call(xhr,safe);
    }).catch(err => {
      emit('XHR_DIRECT_BLOCK',{file:meta(body),reason:String(err&&err.message||err)});
      try { xhr.abort(); } catch(_) {}
    });
    return undefined;
  };

  const nativeFetch = window.fetch;
  window.fetch = async function(input, init) {
    if (init && init.body instanceof File && !SAFE.has(init.body)) {
      const raw = init.body;
      emit('FETCH_DIRECT_SANITIZE_REQUEST',{file:meta(raw)});
      const safe = await requestSanitize(raw);
      emit('FETCH_DIRECT_SAFE_SEND',{original:meta(raw),safe:meta(safe)});
      init = Object.assign({},init,{body:safe});
    }
    return nativeFetch.call(this,input,init);
  };

  emit('PICKER_XHR_V2_READY',{});
})();
'@
Write-Utf8NoBom (Join-Path $ext 'picker_xhr_v2_main.js') $main

$isolated = @'
'use strict';
/* DVC_PICKER_XHR_INTERCEPT_V2_ISOLATED */
(() => {
  const MAX_BYTES = 512 * 1024;
  const native = payload => new Promise(resolve => {
    chrome.runtime.sendMessage({type:'DVC_NATIVE',payload}, r => {
      if (chrome.runtime.lastError) return resolve({ok:false,action:'block',reason:chrome.runtime.lastError.message});
      resolve(r || {ok:false,action:'block',reason:'No native response'});
    });
  });
  const b64 = buf => {
    const bytes=new Uint8Array(buf); let s='';
    for(let i=0;i<bytes.length;i+=0x8000) s+=String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)));
    return btoa(s);
  };
  const from64 = s => { const x=atob(s),o=new Uint8Array(x.length); for(let i=0;i<x.length;i++)o[i]=x.charCodeAt(i); return o; };
  const meta = f => ({name:f.name,size:f.size,type:f.type||'',lastModified:f.lastModified||0});
  const emit = (type,detail={}) => window.postMessage({source:'DVC_DIAG_MAIN_EVENT',time:new Date().toISOString(),type,detail},'*');

  window.addEventListener('message', async e => {
    if (e.source !== window || !e.data || e.data.source !== 'DVC_PICKER_SANITIZE_REQUEST') return;
    const id=e.data.id, file=e.data.file;
    if (!(file instanceof File)) {
      window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:false,reason:'Request did not contain a File'},'*');
      return;
    }
    emit('PICKER_ISOLATED_FILE_RECEIVED',{id,file:meta(file)});
    if (file.size > MAX_BYTES) {
      window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:false,reason:'File exceeds 512 KB diagnostic limit'},'*');
      return;
    }
    try {
      const r=await native({op:'sanitize',name:file.name,mime:file.type||'application/octet-stream',data:b64(await file.arrayBuffer())});
      emit('PICKER_HOST_RESPONSE',{id,ok:!!(r&&r.ok),action:r&&r.action||'',matches:r&&r.matches||0,reason:r&&r.reason||''});
      if(!r||!r.ok||r.action==='block') {
        window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:false,reason:r&&r.reason||'Native host blocked'},'*');
        return;
      }
      if(r.action==='rewrite') {
        const safe=new File([from64(r.data)],r.name||('DVC_SAFE_'+file.name),{type:r.mime||file.type||'application/octet-stream',lastModified:Date.now()});
        window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:true,action:'rewrite',matches:r.matches||0,file:safe},'*');
        return;
      }
      window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:true,action:'allow',matches:0,file},'*');
    } catch(err) {
      emit('PICKER_HOST_ERROR',{id,reason:String(err&&err.message||err)});
      window.postMessage({source:'DVC_PICKER_SANITIZE_RESPONSE',id,ok:false,reason:String(err&&err.message||err)},'*');
    }
  },true);
  emit('PICKER_ISOLATED_V2_READY',{});
})();
'@
Write-Utf8NoBom (Join-Path $ext 'picker_xhr_v2_isolated.js') $isolated

$manifestPath = Join-Path $ext 'manifest.json'
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$m.name = 'DVC Browser Upload Diagnostic Picker XHR V2'
$m.version = '2.0.0'
$mainScript = [pscustomobject]@{ matches=@('http://*/*','https://*/*'); js=@('picker_xhr_v2_main.js'); run_at='document_start'; all_frames=$true; world='MAIN' }
$isoScript  = [pscustomobject]@{ matches=@('http://*/*','https://*/*'); js=@('picker_xhr_v2_isolated.js'); run_at='document_start'; all_frames=$true; world='ISOLATED' }
$m.content_scripts = @($m.content_scripts) + @($mainScript,$isoScript)
Write-Utf8NoBom $manifestPath ($m | ConvertTo-Json -Depth 20)

Write-Utf8NoBom (Join-Path $root 'ENGINE_MARKER_V2.txt') "DVC_BROWSER_UPLOAD_PICKER_XHR_V2`r`nPrimary: FileSystemFileHandle.getFile -> sanitize -> safe File`r`nFallback: direct XHR/fetch File body sanitize before send`r`n"
Write-Host 'DVC_PICKER_XHR_V2_PATCHED'
