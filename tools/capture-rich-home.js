const { chromium } = require('playwright-core');
const fs = require('fs');

async function captureBottom(browser, name, viewport) {
  const context = await browser.newContext({
    viewport,
    deviceScaleFactor: 1,
    locale: 'zh-TW',
    extraHTTPHeaders: { 'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.5' }
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  page.on('pageerror', err => pageErrors.push(String(err)));

  const url = 'https://www.dvc.tw/?v=bottom-pro15-v3-true-bottom';
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
  await page.waitForFunction(() => {
    const s = document.getElementById('dvcHomeBottomPro15ZH');
    if (!s) return false;
    const cs = getComputedStyle(s), r = s.getBoundingClientRect();
    return cs.display !== 'none' && cs.visibility !== 'hidden' && Number(cs.opacity || 1) > 0 && r.width > 300 && r.height > 800 && s.querySelectorAll('article').length === 15;
  }, { timeout: 140000 });

  const info = await page.evaluate(() => {
    const sec = document.getElementById('dvcHomeBottomPro15ZH');
    const dvc60 = document.getElementById('dvc60');
    const cs = sec ? getComputedStyle(sec) : null;
    const r = sec ? sec.getBoundingClientRect() : null;
    const headings = sec ? [...sec.querySelectorAll('h3')].map(x => (x.textContent || '').trim()) : [];
    const bodyText = (document.body?.innerText || '').replace(/\s+/g, ' ').trim();
    const afterDvc60 = !!(sec && dvc60 && (dvc60.compareDocumentPosition(sec) & Node.DOCUMENT_POSITION_FOLLOWING));
    return {
      url: location.href,
      title: document.title,
      sectionExists: !!sec,
      display: cs?.display || null,
      visibility: cs?.visibility || null,
      opacity: cs?.opacity || null,
      rect: r ? { width: Math.round(r.width), height: Math.round(r.height), top: Math.round(r.top) } : null,
      articleCount: sec ? sec.querySelectorAll('article').length : 0,
      headingCount: headings.length,
      headings,
      afterDvc60,
      isLastChildOfPage: !!(sec && document.body.lastElementChild === sec),
      bodyScrollHeight: document.body?.scrollHeight || 0,
      bodyTextLength: bodyText.length,
      consoleErrors: [],
      pageErrors: []
    };
  });
  info.consoleErrors = consoleErrors;
  info.pageErrors = pageErrors;
  info.ok = info.sectionExists && info.display !== 'none' && info.visibility !== 'hidden' && Number(info.opacity || 1) > 0 && info.articleCount === 15 && info.headingCount === 15 && info.afterDvc60 && info.isLastChildOfPage;

  await page.locator('#dvcHomeBottomPro15ZH').scrollIntoViewIfNeeded();
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `screenshots/${name}-bottom-viewport.png`, fullPage: false });
  await page.locator('#dvcHomeBottomPro15ZH').screenshot({ path: `screenshots/${name}-bottom-section.png` });
  fs.writeFileSync(`screenshots/${name}-bottom.json`, JSON.stringify(info, null, 2));
  await context.close();
  return info;
}

(async () => {
  fs.mkdirSync('screenshots', { recursive: true });
  const browser = await chromium.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
  });
  const results = {};
  results.desktop = await captureBottom(browser, 'zh-desktop', { width: 1440, height: 1000 });
  results.mobile = await captureBottom(browser, 'zh-mobile', { width: 390, height: 844 });
  fs.writeFileSync('screenshots/bottom15-summary.json', JSON.stringify(results, null, 2));
  await browser.close();
  const failed = Object.entries(results).filter(([,v]) => !v.ok).map(([k,v]) => `${k}: exists=${v.sectionExists}, display=${v.display}, articles=${v.articleCount}, headings=${v.headingCount}, after60=${v.afterDvc60}, lastPage=${v.isLastChildOfPage}`);
  if (failed.length) throw new Error('Bottom 15 verification failed: ' + failed.join(' | '));
})().catch(err => {
  fs.writeFileSync('screenshots/fatal-error.txt', String(err && err.stack || err));
  process.exitCode = 1;
});
