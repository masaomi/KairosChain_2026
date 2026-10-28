// Optional real-browser QA: KAIROMONE_BROWSER_QA=1 node test_status_browser.mjs
// Requires Playwright and Chromium with permitted local IPC; no network service.
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
const base = JSON.parse(await fs.readFile(path.join(root, 'fixtures/status_xss.json'), 'utf8'));
const payload = { ...base, profile: { display_name: 'Kairomone · Moss companion' }, progression: {level:24,level_cap:999,total_xp:470,xp_into_level:10,xp_for_next_level:20,xp_to_next_level:10,unique_l1:8,unique_l2:7}, profession: {selected_id:null,name:'Generalist',selection_required:true,catalog:[{id:'generalist',name:'Generalist',unlock_level:1,unlocked:true},{id:'guardian',name:'Guardian',unlock_level:30,unlocked:false}]}, autonomy: {configured:true,used_cycles:3,max_cycles:10,remaining_cycles:7,stopped:true,worker_online:false,last_result:{state:'completed',request_id:'synthetic-cycle',source_count:1,completed_at:'2026-01-01T00:00:00Z'}} };
const escape = value => JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4,'0'));
const temp = await fs.mkdtemp(path.join(os.tmpdir(),'kairomone-status-'));
let browser;
try {
browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',headless:true,args:['--no-sandbox']});
const page = await browser.newPage();
const errors=[], requests=[];
page.on('pageerror', error => errors.push(error.message));
page.on('request', request => { if (!request.url().startsWith('file:')) requests.push(request.url()); });
  const filename = path.join(temp,'status.html');
  await fs.writeFile(filename,template.replace('__KAIROMONE_STATUS_JSON__',escape(payload)));
  for (const width of [320,375,768,1280]) {
    await page.setViewportSize({width,height:900}); await page.goto(pathToFileURL(filename).href);
    assert.equal(await page.locator('#level-value').innerText(),'24');
    assert.equal(await page.locator('#profession-state').innerText(),'未選択');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),true, `No horizontal overflow at ${width}px`);
    await page.locator('#lang-en').click(); assert.equal(await page.locator('html').getAttribute('lang'),'en');
    assert.equal(await page.locator('#growth-state').innerText(),'Stopped');
    const before=await page.locator('#generated-at').innerText();
    await page.reload(); assert.equal(await page.locator('#generated-at').innerText(),before,'Reload does not fake a newer snapshot');
    await page.locator('#knowledge-details summary').click();
    assert.equal(await page.locator('#knowledge-list img, #knowledge-list script').count(),0);
    await page.locator('#lang-en').click(); await page.locator('#lang-ja').click();
    assert.equal(await page.locator('#knowledge-list li').count(),1);
    if (process.env.KAIROMONE_SCREENSHOT_DIR) {
      await fs.mkdir(process.env.KAIROMONE_SCREENSHOT_DIR,{recursive:true});
      await page.screenshot({path:path.join(process.env.KAIROMONE_SCREENSHOT_DIR,`status-${width}.png`),fullPage:true});
    }
  }
  const pictures=[];
  for (const level of [1,5,20,100,500]) {
    payload.progression.level=level;
    await fs.writeFile(filename,template.replace('__KAIROMONE_STATUS_JSON__',escape(payload)));
    await page.goto(pathToFileURL(filename).href);
    pictures.push((await page.locator('#creature').screenshot()).toString('base64'));
  }
  assert.equal(new Set(pictures).size,5,'Five visibly distinct SVG stages');
  assert.deepEqual(errors,[]); assert.deepEqual(requests,[],'Snapshot makes no external requests');
  assert.equal(await page.evaluate(() => globalThis.__KAIROMONE_XSS__),undefined);
  console.log('PASS: Chromium 320/375/768/1280px, JA/EN/repeated toggles, snapshot reload, actual DOM XSS, five distinct rendered stages, zero external requests.');
} finally { if (browser) await browser.close(); await fs.rm(temp,{recursive:true,force:true}); }
