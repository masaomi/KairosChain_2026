// Optional real-browser QA of the snapshot page: KAIROMONE_BROWSER_QA=1 node test_status_browser.mjs
// Requires Playwright and Chromium with permitted local IPC; no network service.
// Not run where no browser is installed; test_status_ui.mjs covers the logic.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
if (process.env.KAIROMONE_BROWSER_QA !== '1') {
  console.log('SKIP: optional browser QA; set KAIROMONE_BROWSER_QA=1 in a Chromium-capable environment.');
  process.exit(0);
}
const { chromium } = createRequire(import.meta.url)('playwright');
const root = path.dirname(fileURLToPath(import.meta.url));
const template = await fs.readFile(path.join(root, 'status.html'), 'utf8');
const hostile = JSON.parse(await fs.readFile(path.join(root, 'fixtures/status_xss.json'), 'utf8'));
const egg = 'data:image/svg+xml;base64,' + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#9cad7e"/></svg>').toString('base64');
const long = 'A very long unbroken source address https://example.org/' + 'segment'.repeat(40);
// A readable synthetic snapshot: widths are checked with it; the hostile fixture checks the sinks.
const payload = { ...structuredClone(hostile), name: 'Kairomone · Moss companion', drawing: { shown: 'drawing', data_uri: egg, form: 'A small round fox' },
  drawings: Array.from({ length: 12 }, (_, i) => i === 3 ? { missing: true, level: 40 } : { data_uri: egg, missing: false, level: 10 * (i + 1), form: 'Form ' + i }),
  cycles: Array.from({ length: 6 }, (_, i) => ({ subjects: [{ id: 'botany', en: 'Botany', ja: '植物学' }], title: 'Synthetic title ' + i,
    synthesis: 'Synthetic synthesis ' + i + '\n' + 'word '.repeat(80), finding: 'Synthetic finding ' + i, sources: ['https://example.org/' + i, long] })) };
const escape = value => JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'kairomone-status-'));
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage();
  const errors = [], requests = [], violations = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (/Content Security Policy|Refused to/i.test(message.text())) violations.push(message.text()); });
  page.on('request', request => { const url = request.url(); if (!url.startsWith('file:') && !url.startsWith('data:')) requests.push(url); });
  const filename = path.join(temp, 'status.html');
  await fs.writeFile(filename, template.replace('__KAIROMONE_STATUS_JSON__', () => escape(payload)));
  for (const width of [320, 375, 768, 1280]) {
    await page.setViewportSize({ width, height: 900 }); await page.goto(pathToFileURL(filename).href);
    assert.equal(await page.locator('#name').innerText(), payload.name);
    assert.equal(await page.locator('#hero-level').innerText(), 'レベル 31');
    assert.equal(await page.locator('#profession-name').innerText(), hostile.profession.name);
    assert.equal(await page.locator('#history li').count(), 12);
    assert.equal(await page.locator('#history li.missing img').count(), 0, 'a missing drawing shows no image');
    assert.equal(await page.locator('#cycles > li').count(), 6);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `No horizontal overflow at ${width}px`);
    const first = page.locator('#cycles > li').first();
    assert.equal(await first.locator('.synthesis').isVisible(), false, 'the synthesis starts closed');
    await first.locator('summary').click();
    assert.equal(await first.locator('.synthesis').isVisible(), true, 'the disclosure opens');
    await page.locator('#lang-en').click(); assert.equal(await page.locator('html').getAttribute('lang'), 'en');
    assert.equal(await page.locator('#hero-level').innerText(), 'Level 31');
    assert.equal(await page.locator('#cycles > li').count(), 6, 'a switch replaces rather than duplicates');
    const before = await page.locator('#generated-at').innerText();
    await page.reload(); assert.equal(await page.locator('#generated-at').innerText(), before, 'Reload does not fake a newer snapshot');
    const sources = await page.evaluate(() => [...document.querySelectorAll('img')].map(i => i.getAttribute('src')).filter(Boolean));
    assert(sources.every(src => src.startsWith('data:image/svg+xml;base64,')), 'images only from data: URIs');
    assert.equal(await page.locator('a, form, input, iframe').count(), 0, 'nothing to follow or submit');
    if (process.env.KAIROMONE_SCREENSHOT_DIR) {
      await fs.mkdir(process.env.KAIROMONE_SCREENSHOT_DIR, { recursive: true });
      await page.screenshot({ path: path.join(process.env.KAIROMONE_SCREENSHOT_DIR, `status-${width}.png`), fullPage: true });
    }
  }
  // The hostile fixture: every value stays text.
  await fs.writeFile(filename, template.replace('__KAIROMONE_STATUS_JSON__', () => escape(hostile)));
  await page.goto(pathToFileURL(filename).href);
  assert.equal(await page.locator('#name').innerText(), hostile.name.trim());
  assert.equal(await page.locator('#cycles script, #cycles img, #lineage img, #history script').count(), 0);
  assert.equal(await page.evaluate(() => globalThis.__KAIROMONE_XSS__), undefined);
  // A malformed snapshot shows the error and nothing else.
  await fs.writeFile(filename, template.replace('__KAIROMONE_STATUS_JSON__', '{"schema_version":1}'));
  await page.goto(pathToFileURL(filename).href);
  assert.equal(await page.locator('#data-error').isVisible(), true);
  assert.equal(await page.locator('#content').isVisible(), false);
  assert.deepEqual(errors, []); assert.deepEqual(violations, [], 'the pinned script and style hashes hold');
  assert.deepEqual(requests, [], 'Snapshot makes no external requests');
  console.log('PASS: Chromium 320/375/768/1280px, no overflow, disclosure, JA/EN, reload, data:-only images, no links or forms, actual DOM XSS, no CSP violation, zero external requests.');
} finally { if (browser) await browser.close(); await fs.rm(temp, { recursive: true, force: true }); }
