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
    const rect = sec ? sec.getBoundingClientRect() : null;
    const absTop = rect ? rect.top + window.scrollY : 0;
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
      rect: rect ? { width: Math.round(rect.width), height: Math.round(rect.height), top: Math.round(absTop) } : null,
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

  const top = info.rect.top;
  const height = info.rect.height;
  const vh = viewport.height;
  const positions = [
    ['top', Math.max(0, top - 10)],
    ['middle', Math.max(0, top + Math.floor((height - vh) / 2))],
    ['end', Math.max(0, top + height - vh)]
  ];
  for (const [label, y] of positions) {
    await page.evaluate(y => window.scrollTo(0, y), y);
    await page.waitForTimeout(1000);
    await page.screenshot({ path: `screenshots/${name}-bottom-${label}.png`, fullPage: false });
  }
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
