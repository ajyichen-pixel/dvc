const { chromium } = require('playwright-core');
const fs = require('fs');

const expectedIds = [
  'dvc06','dvc10','dvc11','dvc15','dvc16','dvc20','dvc21','dvc25',
  'dvc26','dvc30','dvc31','dvc35','dvc36','dvc40','dvc41','dvc43',
  'dvc44','dvc50','dvc51','dvc54','dvc55','dvc60'
];

async function capture(browser, name, url, viewport, rootId, locale) {
  const context = await browser.newContext({
    viewport,
    deviceScaleFactor: 1,
    locale,
    extraHTTPHeaders: { 'Accept-Language': locale === 'zh-TW' ? 'zh-TW,zh;q=0.9,en;q=0.5' : 'en-US,en;q=0.9' }
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  page.on('pageerror', err => pageErrors.push(String(err)));
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
  await page.waitForTimeout(30000);
  const info = await page.evaluate(({ rootId, expectedIds }) => {
    const root = document.getElementById(rootId);
    const visibleIds = expectedIds.filter(id => {
      const el = document.getElementById(id);
      if (!el) return false;
      const s = getComputedStyle(el), r = el.getBoundingClientRect();
      return s.display !== 'none' && s.visibility !== 'hidden' && Number(s.opacity || 1) > 0 && r.width > 10 && r.height > 10;
    });
    const images = [...document.images].filter(img => {
      const s = getComputedStyle(img), r = img.getBoundingClientRect();
      return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 50 && r.height > 50;
    }).map(img => img.currentSrc || img.src).filter(Boolean);
    const backgrounds = [...document.querySelectorAll('body *')]
      .map(el => getComputedStyle(el).backgroundImage)
      .filter(v => v && v !== 'none' && v.includes('url('));
    const fixedCandidates = [...document.querySelectorAll('body *')].filter(el => {
      const s = getComputedStyle(el), r = el.getBoundingClientRect();
      return s.position === 'fixed' && r.top < 220 && r.width > 25 && r.height > 20 && s.display !== 'none' && s.visibility !== 'hidden';
    }).slice(0, 20).map(el => ({
      id: el.id || null,
      cls: typeof el.className === 'string' ? el.className.slice(0,120) : null,
      text: (el.textContent || '').replace(/\s+/g,' ').trim().slice(0,120),
      tag: el.tagName,
      rect: { x: Math.round(el.getBoundingClientRect().x), y: Math.round(el.getBoundingClientRect().y), w: Math.round(el.getBoundingClientRect().width), h: Math.round(el.getBoundingClientRect().height) }
    }));
    const heroCta = root ? root.querySelector('.hero .cta') : null;
    const heroCtaRect = heroCta ? heroCta.getBoundingClientRect() : null;
    const text = (document.body?.innerText || '').replace(/\s+/g, ' ').trim();
    return {
      title: document.title,
      url: location.href,
      htmlLang: document.documentElement.lang,
      rootExists: !!root,
      rootDisplay: root ? getComputedStyle(root).display : null,
      rootVisibility: root ? getComputedStyle(root).visibility : null,
      rootRect: root ? { width: root.getBoundingClientRect().width, height: root.getBoundingClientRect().height } : null,
      visibleIds,
      missingIds: expectedIds.filter(id => !visibleIds.includes(id)),
      staticCardCount: document.querySelectorAll('.d65-card').length,
      bodyTextLength: text.length,
      bodyTextPreview: text.slice(0, 2400),
      bodyScrollHeight: document.body?.scrollHeight || 0,
      bodyScrollWidth: document.body?.scrollWidth || 0,
      imageCount: images.length,
      imageSamples: images.slice(0, 15),
      backgroundCount: backgrounds.length,
      backgroundSamples: backgrounds.slice(0, 15),
      navExists: !!document.getElementById('trStableNav'),
      navPosition: (() => { const n = document.getElementById('trStableNav'); return n ? getComputedStyle(n).position : null; })(),
      heroCtaRect: heroCtaRect ? { width: Math.round(heroCtaRect.width), height: Math.round(heroCtaRect.height) } : null,
      heroCtaBorder: heroCta ? getComputedStyle(heroCta).borderTopWidth : null,
      fixedCandidates
    };
  }, { rootId, expectedIds });
  info.consoleErrors = consoleErrors;
  info.pageErrors = pageErrors;
  info.ok = info.rootExists && info.rootDisplay !== 'none' && info.rootVisibility !== 'hidden' &&
    info.rootRect?.width > 300 && info.rootRect?.height > 6000 && info.visibleIds.length >= 18 &&
    info.staticCardCount === 0 && info.bodyTextLength > 5000 && info.bodyScrollHeight > 7000 &&
    (info.imageCount + info.backgroundCount) >= 3 && info.navExists && info.navPosition === 'fixed' &&
    info.heroCtaRect && info.heroCtaRect.height < 160 && info.heroCtaBorder === '0px';
  fs.writeFileSync(`screenshots/${name}.json`, JSON.stringify(info, null, 2));
  await page.screenshot({ path: `screenshots/${name}-viewport.png`, fullPage: false });
  await page.screenshot({ path: `screenshots/${name}-full.png`, fullPage: true });
  await context.close();
  return info;
}

(async () => {
  fs.mkdirSync('screenshots', { recursive: true });
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox','--disable-dev-shm-usage','--disable-gpu'] });
  const stamp = 'rich-photo-restore-v6';
  const results = {};
  results.zhDesktop = await capture(browser, 'zh-desktop', `https://www.dvc.tw/?v=${stamp}`, { width: 1440, height: 1000 }, 'dvcFlag00', 'zh-TW');
  results.enDesktop = await capture(browser, 'en-desktop', `https://www.dvc.tw/en?v=${stamp}`, { width: 1440, height: 1000 }, 'dvcFlag00en', 'en-US');
  results.zhMobile = await capture(browser, 'zh-mobile', `https://www.dvc.tw/?v=${stamp}&device=mobile`, { width: 390, height: 844 }, 'dvcFlag00', 'zh-TW');
  results.enMobile = await capture(browser, 'en-mobile', `https://www.dvc.tw/en?v=${stamp}&device=mobile`, { width: 390, height: 844 }, 'dvcFlag00en', 'en-US');
  fs.writeFileSync('screenshots/summary.json', JSON.stringify(results, null, 2));
  await browser.close();
  const failed = Object.entries(results).filter(([,v]) => !v.ok).map(([k,v]) => `${k}: url=${v.url}, root=${v.rootDisplay}, rich=${v.visibleIds.length}, cards=${v.staticCardCount}, text=${v.bodyTextLength}, height=${v.bodyScrollHeight}, media=${v.imageCount + v.backgroundCount}, nav=${v.navExists}/${v.navPosition}, cta=${JSON.stringify(v.heroCtaRect)}/${v.heroCtaBorder}, missing=${v.missingIds.join(',')}`);
  if (failed.length) throw new Error('Rich homepage verification failed: ' + failed.join(' | '));
})().catch(err => {
  fs.writeFileSync('screenshots/fatal-error.txt', String(err && err.stack || err));
  process.exitCode = 1;
});
