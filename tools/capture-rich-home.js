const { chromium } = require('playwright-core');
const fs = require('fs');

async function capture(browser, cfg) {
  const context = await browser.newContext({
    viewport: cfg.viewport,
    deviceScaleFactor: 1,
    locale: cfg.locale,
    extraHTTPHeaders: { 'Accept-Language': cfg.locale === 'zh-TW' ? 'zh-TW,zh;q=0.9,en;q=0.5' : 'en-US,en;q=0.9' }
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  page.on('pageerror', err => pageErrors.push(String(err)));

  await page.goto(cfg.url, { waitUntil: 'domcontentloaded', timeout: 120000 });
  await page.waitForFunction(({ rootId }) => {
    const s = document.getElementById(rootId);
    if (!s) return false;
    const cs = getComputedStyle(s), r = s.getBoundingClientRect();
    const imgs = [...s.querySelectorAll('img')];
    return cs.display !== 'none' && cs.visibility !== 'hidden' && Number(cs.opacity || 1) > 0 &&
      r.width > 300 && r.height > 3000 && s.querySelectorAll('article').length === 15 && imgs.length === 15 && imgs.every(i => i.complete && i.naturalWidth > 1000 && i.naturalHeight > 500);
  }, { rootId: cfg.rootId }, { timeout: 140000 });

  const info = await page.evaluate(({ rootId }) => {
    const sec = document.getElementById(rootId);
    const dvc60 = document.getElementById('dvc60');
    const cs = sec ? getComputedStyle(sec) : null;
    const rect = sec ? sec.getBoundingClientRect() : null;
    const absTop = rect ? rect.top + window.scrollY : 0;
    const imgs = sec ? [...sec.querySelectorAll('img')] : [];
    const headings = sec ? [...sec.querySelectorAll('.pc-copy h2')].map(x => (x.textContent || '').trim()) : [];
    const text = (document.body?.innerText || '').replace(/\s+/g, ' ').trim();
    return {
      url: location.href,
      title: document.title,
      sectionExists: !!sec,
      display: cs?.display || null,
      visibility: cs?.visibility || null,
      opacity: cs?.opacity || null,
      rect: rect ? { width: Math.round(rect.width), height: Math.round(rect.height), top: Math.round(absTop) } : null,
      articleCount: sec ? sec.querySelectorAll('article').length : 0,
      photoCount: imgs.length,
      loadedPhotoCount: imgs.filter(i => i.complete && i.naturalWidth > 1000 && i.naturalHeight > 500).length,
      headingCount: headings.length,
      headings,
      afterDvc60: !!(sec && dvc60 && (dvc60.compareDocumentPosition(sec) & Node.DOCUMENT_POSITION_FOLLOWING)),
      bodyScrollHeight: document.body?.scrollHeight || 0,
      bodyTextLength: text.length
    };
  }, { rootId: cfg.rootId });
  info.consoleErrors = consoleErrors;
  info.pageErrors = pageErrors;
  info.ok = info.sectionExists && info.display !== 'none' && info.visibility !== 'hidden' && Number(info.opacity || 1) > 0 &&
    info.articleCount === 15 && info.photoCount === 15 && info.loadedPhotoCount === 15 && info.headingCount === 15 && info.afterDvc60;

  const vh = cfg.viewport.height, vw = cfg.viewport.width;
  const top = info.rect.top, height = info.rect.height, maxY = Math.max(0, info.bodyScrollHeight - vh);
  const shots = [
    ['top', Math.min(maxY, Math.max(0, top))],
    ['middle', Math.min(maxY, Math.max(0, top + Math.floor((height - vh) / 2)))],
    ['end', Math.min(maxY, Math.max(0, top + height - vh))]
  ];
  for (const [label, y] of shots) {
    await page.screenshot({ path: `screenshots/${cfg.name}-${label}.png`, clip: { x: 0, y, width: vw, height: vh } });
  }
  fs.writeFileSync(`screenshots/${cfg.name}.json`, JSON.stringify(info, null, 2));
  await context.close();
  return info;
}

(async () => {
  fs.mkdirSync('screenshots', { recursive: true });
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox','--disable-dev-shm-usage','--disable-gpu'] });
  const stamp = 'photo15-v1';
  const configs = [
    { name:'zh-desktop', url:`https://www.dvc.tw/?v=${stamp}`, viewport:{width:1440,height:1000}, rootId:'dvcHomeBottomPhoto15ZH', locale:'zh-TW' },
    { name:'en-desktop', url:`https://www.dvc.tw/en?v=${stamp}`, viewport:{width:1440,height:1000}, rootId:'dvcHomeBottomPhoto15EN', locale:'en-US' },
    { name:'zh-mobile', url:`https://www.dvc.tw/?v=${stamp}&device=mobile`, viewport:{width:390,height:844}, rootId:'dvcHomeBottomPhoto15ZH', locale:'zh-TW' },
    { name:'en-mobile', url:`https://www.dvc.tw/en?v=${stamp}&device=mobile`, viewport:{width:390,height:844}, rootId:'dvcHomeBottomPhoto15EN', locale:'en-US' }
  ];
  const results = {};
  for (const cfg of configs) results[cfg.name] = await capture(browser, cfg);
  fs.writeFileSync('screenshots/summary.json', JSON.stringify(results, null, 2));
  await browser.close();
  const failed = Object.entries(results).filter(([,v]) => !v.ok).map(([k,v]) => `${k}: exists=${v.sectionExists}, articles=${v.articleCount}, photos=${v.loadedPhotoCount}/${v.photoCount}, headings=${v.headingCount}, after60=${v.afterDvc60}`);
  if (failed.length) throw new Error('Photo 15 verification failed: ' + failed.join(' | '));
})().catch(err => {
  fs.writeFileSync('screenshots/fatal-error.txt', String(err && err.stack || err));
  process.exitCode = 1;
});
