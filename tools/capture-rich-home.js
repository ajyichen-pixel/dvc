const { chromium } = require('playwright-core');
const fs = require('fs');

async function capture(browser, name, url, rootId, locale) {
  const context = await browser.newContext({ viewport:{width:1440,height:1000}, deviceScaleFactor:1, locale, extraHTTPHeaders:{'Accept-Language':locale==='zh-TW'?'zh-TW,zh;q=0.9,en;q=0.5':'en-US,en;q=0.9'} });
  const page = await context.newPage();
  const consoleErrors=[], pageErrors=[];
  page.on('console',m=>{if(m.type()==='error')consoleErrors.push(m.text())}); page.on('pageerror',e=>pageErrors.push(String(e)));
  await page.goto(url,{waitUntil:'domcontentloaded',timeout:120000});
  await page.waitForSelector('#'+rootId,{state:'attached',timeout:60000});
  await page.evaluate(rootId=>{const s=document.getElementById(rootId);if(!s)return;[...s.querySelectorAll('img')].forEach(i=>{i.loading='eager';i.src=i.src});s.scrollIntoView({block:'start'});},rootId);
  await page.waitForTimeout(9000);
  const info=await page.evaluate(rootId=>{const s=document.getElementById(rootId),d=document.getElementById('dvc60'),imgs=s?[...s.querySelectorAll('img')]:[],r=s?s.getBoundingClientRect():null,cs=s?getComputedStyle(s):null;return{url:location.href,exists:!!s,display:cs?.display||null,visibility:cs?.visibility||null,articleCount:s?s.querySelectorAll('article').length:0,photoCount:imgs.length,loadedPhotoCount:imgs.filter(i=>i.complete&&i.naturalWidth>900&&i.naturalHeight>500).length,headingCount:s?s.querySelectorAll('.pc-copy h2').length:0,afterDvc60:!!(s&&d&&(d.compareDocumentPosition(s)&Node.DOCUMENT_POSITION_FOLLOWING)),rect:r?{top:Math.round(r.top+scrollY),height:Math.round(r.height),width:Math.round(r.width)}:null,bodyHeight:document.body.scrollHeight};},rootId);
  info.consoleErrors=consoleErrors;info.pageErrors=pageErrors;info.ok=info.exists&&info.display!=='none'&&info.visibility!=='hidden'&&info.articleCount===15&&info.photoCount===15&&info.loadedPhotoCount===15&&info.headingCount===15&&info.afterDvc60;
  const y=Math.max(0,info.rect.top); await page.screenshot({path:`screenshots/${name}-photo15-top.png`,clip:{x:0,y,width:1440,height:1000}});
  const y2=Math.min(Math.max(0,info.bodyHeight-1000),y+1700); await page.screenshot({path:`screenshots/${name}-photo15-next.png`,clip:{x:0,y:y2,width:1440,height:1000}});
  fs.writeFileSync(`screenshots/${name}.json`,JSON.stringify(info,null,2)); await context.close(); return info;
}

(async()=>{fs.mkdirSync('screenshots',{recursive:true});const browser=await chromium.launch({executablePath:'/usr/bin/google-chrome',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});const stamp='photo15-v3-root-sibling';const zh=await capture(browser,'zh','https://www.dvc.tw/?v='+stamp,'dvcHomeBottomPhoto15ZH','zh-TW');const en=await capture(browser,'en','https://www.dvc.tw/en?v='+stamp,'dvcHomeBottomPhoto15EN','en-US');fs.writeFileSync('screenshots/summary.json',JSON.stringify({zh,en},null,2));await browser.close();if(!zh.ok||!en.ok)throw new Error('Final photo15 verification failed: '+JSON.stringify({zh,en}));})().catch(e=>{fs.writeFileSync('screenshots/fatal-error.txt',String(e&&e.stack||e));process.exitCode=1});
