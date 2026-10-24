// Dependency-free checks of the console page's own logic (assets/console.html),
// run on a minimal stand-in for the DOM and fetch. Not a browser or layout
// test (test_console_browser.mjs is): it drives the page's real script through
// its event handlers and status responses the test hands it.
//
//   node KairosChain_mcp_server/templates/skillsets/kairomone/assets/test_console_logic.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const script = fs.readFileSync(path.join(root, 'console.html'), 'utf8').match(/<script>([\s\S]*)<\/script>/)[1];
const TOKEN = 'a'.repeat(64);
const SESSION = 'b'.repeat(64);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class Node {
  constructor(doc, tag, text = '') {
    Object.assign(this, { doc, tagName: tag.toUpperCase(), children: [], parentNode: null, attrs: {}, listeners: {}, own: text,
                          hidden: false, disabled: false, checked: false, type: '', name: '', id: '', className: '' });
    this.fieldValue = '';
  }
  get value() {
    if (this.tagName !== 'SELECT') return this.fieldValue;
    const o = this.options[this.selectedIndex || 0];
    return o ? o.value : '';
  }
  set value(v) {
    if (this.tagName !== 'SELECT') { this.fieldValue = String(v); return; }
    const i = this.options.findIndex((o) => o.value === v);
    if (i >= 0) this.selectedIndex = i;
  }
  get options() { return this.children.filter((c) => c.tagName === 'OPTION'); }
  get firstChild() { return this.children[0] || null; }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); return c; }
  get textContent() { return this.own + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.own = String(v); this.children = []; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type) { (this.listeners[type] || []).forEach((fn) => fn({ preventDefault() {}, target: this })); }
  focus() { this.doc.activeElement = this; }
  setSelectionRange(a, b) { this.selectionStart = a; this.selectionEnd = b; }
  all() { return this.children.flatMap((c) => [c, ...c.all()]); }
  querySelectorAll(sel) { return this.all().filter((n) => matches(n, sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}
function matches(n, sel) {
  let m;
  if ((m = /^(\w+)\.([\w-]+)$/.exec(sel))) return n.tagName === m[1].toUpperCase() && n.className.split(/\s+/).includes(m[2]);
  if ((m = /^input\[type=(\w+)\](:checked)?$/.exec(sel))) return n.tagName === 'INPUT' && n.type === m[1] && (!m[2] || n.checked);
  throw new Error(`selector not supported here: ${sel}`);
}

function page() {
  const doc = { byId: {}, title: '', activeElement: null };
  const body = new Node(doc, 'body');
  const tags = { message: 'textarea', 'kairomone-select': 'select', 'create-id': 'input', 'create-free': 'textarea', 'create-template': 'select' };
  doc.getElementById = (id) => (doc.byId[id] ||= Object.assign(body.appendChild(new Node(doc, tags[id] || 'div')), { id }));
  doc.createElement = (tag) => new Node(doc, tag);
  doc.createTextNode = (text) => new Node(doc, '#text', text);
  doc.querySelectorAll = (sel) => body.querySelectorAll(sel);
  // The markup the script finds by class or inside fieldsets.
  for (const key of ['status', 'recent', 'learn', 'backup']) {
    const b = body.appendChild(new Node(doc, 'button'));
    Object.assign(b, { className: 'q' }).setAttribute('data-place', key);
  }
  for (const [value, on] of [['learned', true], ['owner_written', true], ['received', false], ['inherited', false]]) {
    doc.getElementById('export-kinds').appendChild(Object.assign(new Node(doc, 'input'), { type: 'checkbox', value, checked: on }));
  }
  doc.getElementById('create-template').appendChild(Object.assign(new Node(doc, 'option', 'おまかせ'), { value: '' }));

  const requests = [];
  const answer = (status, data) => ({ ok: status < 400, status, text: async () => JSON.stringify(data), json: async () => data });
  const fetch = (url, init = {}) => {
    if (url === '/session') return Promise.resolve(answer(200, { session: SESSION }));
    if (url.startsWith('/events')) return new Promise(() => {}); // the long poll never returns here
    return new Promise((resolve) => requests.push({ url, method: init.method, resolve: (data) => resolve(answer(200, data)),
                                                     fail: () => resolve(answer(500, { error: 'stand-in failure' })) }));
  };
  const context = {
    document: doc, fetch, setTimeout, clearTimeout, TextEncoder, AbortController, console,
    location: { hash: `#${TOKEN}`, pathname: '/', search: '', reload() {} },
    history: { replaceState() {} },
    sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    window: { addEventListener() {}, confirm: () => false }
  };
  vm.createContext(context);
  vm.runInContext(script, context, { filename: 'console.js' });
  return { doc, requests, $: (id) => doc.getElementById(id) };
}

const fixture = (shown, name, proposal, identity = shown) => ({
  data_dir: '/fixture', shown,
  kairomones: [{ listing_id: 'momo', name: 'Momo' }, { listing_id: 'pip', name: 'Pip' }, { listing_id: 'twin', name: 'Momo' }],
  kinds: [{ kind: 'animal', label: '動物', traits: ['curious'] }], templates: [{ id: 'researcher', name: 'Researcher' }],
  status: { schema_version: 1, initialized: true, profile: { display_name: name }, kairomone: { listing_id: shown, identity },
            progression: { level: 7, level_cap: 999, total_xp: 70, stage: { id: 'egg', ja: '卵' } },
            integrity: { state: 'readable', valid: true, block_count: 12, pending_count: 0, host_l0: { state: 'unchanged' } },
            autonomy: { live: true, used_cycles: 2, max_cycles: 5, remaining_cycles: 3 } },
  waiting: { art: { waiting: [] }, proposals: [{ proposal: proposal, kind: 'profile', name, sha256: 'c'.repeat(64) }] }
});
const statusRequests = (p) => p.requests.filter((r) => r.url.startsWith('/status'));

async function booted() {
  const p = page();
  await sleep(20);
  const first = statusRequests(p)[0];
  assert.equal(first.url, '/status', 'the first status names nobody: the server shows the first listed');
  first.resolve(fixture('momo', 'Momo', '1'.repeat(64)));
  await sleep(20);
  return p;
}

// A switch made while a status request is in flight is not undone by it.
{
  const p = await booted();
  p.$('status-refresh').fire('click');
  await sleep(20);
  const inFlight = statusRequests(p)[1];
  assert.equal(inFlight.url, '/status?kairomone=momo');
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  assert.equal(p.$('kairomone-name').textContent, 'Pip', 'the name follows the switch at once');
  assert.equal(p.$('wait-list').textContent, '読み込んでいます…', 'what waited for the one left is not offered');
  inFlight.resolve(fixture('momo', 'Momo', '1'.repeat(64)));
  await sleep(30);
  assert.equal(p.$('kairomone-select').value, 'pip', 'the late answer about momo does not switch back');
  const next = statusRequests(p)[2];
  assert.equal(next.url, '/status?kairomone=pip', 'the one now chosen is asked for');
  next.resolve(fixture('pip', 'Pip', '2'.repeat(64)));
  await sleep(20);
  p.doc.querySelectorAll('button.q')[0].fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Pip」（識別子: pip）のいまの状態を教えて');
  console.log('PASS: a switch survives a status answer already in flight');
}

// What the owner typed stays when one placed text replaces another.
{
  const p = await booted();
  const [status, recent] = p.doc.querySelectorAll('button.q');
  p.$('message').value = 'こんにちは';
  status.fire('click');
  recent.fire('click');
  assert.equal(p.$('message').value, 'こんにちは\nKairomone「Momo」（識別子: momo）が最近覚えたことを見せて');
  p.$('message').value += ' — 追記';
  status.fire('click');
  assert.equal(p.$('message').value.split('\n').length, 3, 'an edited box is kept whole and the new text goes after it');
  console.log('PASS: placed text keeps what the owner typed');
}

// Placed text carries the IDs: kind, template, export kinds; a malformed ID is not placed.
{
  const p = await booted();
  p.$('create-template').value = 'researcher';
  const kind = p.$('create-kinds').querySelector('input[type=radio]');
  kind.checked = true;
  p.$('create-id').value = 'Momo';
  p.$('message').value = '';
  p.$('create-place').fire('click');
  assert.equal(p.$('message').value, '', 'a malformed ID is not placed');
  assert.equal(p.$('create-msg').hidden, false, 'and the owner is told why');
  p.$('create-id').value = 'momo2';
  p.$('create-place').fire('click');
  assert.match(p.$('message').value, /種類: 動物（animal）。.*最初の職業の雛形: Researcher（researcher）。識別子: momo2。/);
  p.$('message').value = '';
  p.$('export-place').fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: momo）を書き出す前の下見を見せて。入れる知識の種類: 学んだもの（learned）、あなたが書いたもの（owner_written）');
  console.log('PASS: placed text names the IDs the tools take');
}

// The card's facts belong to the Kairomone named above them: a switch empties
// them, a failed read leaves them empty, and one the host cannot read stays chosen.
{
  const p = await booted();
  assert.deepEqual(['st-level', 'st-integrity', 'st-used'].map((id) => p.$(id).textContent), ['7', 'ローカルチェーンの検証に合格', '2']);
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  const cleared = ['st-level', 'st-xp', 'st-integrity', 'st-blocks', 'st-l0', 'st-used', 'st-max', 'st-remaining', 'kairomone-id'].map((id) => p.$(id).textContent);
  assert.deepEqual(cleared, ['—', '—', '未確認', '—', '未確認', '—', '—', '—', 'pip'], 'nothing about momo stays under the name Pip');
  await sleep(20);
  const asked = statusRequests(p)[1];
  assert.equal(asked.url, '/status?kairomone=pip');
  asked.fail();
  await sleep(20);
  assert.equal(p.$('st-level').textContent, '—', 'a failed read leaves the facts empty');
  assert.equal(p.$('st-at').textContent, '状態を読み込めませんでした。「更新」で読み直せます。');
  // The console answers for a Kairomone it cannot read with the listing and no one shown.
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[2].resolve({ data_dir: '/fixture', kairomones: fixture('momo').kairomones, shown: null, status: null, error: 'pip: unreadable' });
  await sleep(20);
  assert.equal(p.$('kairomone-select').value, 'pip', 'the one chosen stays chosen');
  assert.equal(p.$('kairomone-name').textContent, 'Pip');
  assert.equal(p.$('st-integrity').textContent, '未確認');
  p.$('status-refresh').fire('click');
  await sleep(20);
  assert.equal(statusRequests(p)[3].url, '/status?kairomone=pip', 'and is asked for again, not the first listed');
  console.log('PASS: the facts shown belong to the Kairomone named');
}

// 識別子 is the listing ID the placed text names; a twin's identity is shown beside it.
{
  const p = await booted();
  p.$('kairomone-select').value = 'twin';
  p.$('kairomone-select').fire('change');
  await sleep(20);
  statusRequests(p)[1].resolve(fixture('twin', 'Momo', '3'.repeat(64), 'momo'));
  await sleep(20);
  assert.equal(p.$('kairomone-id').textContent, 'twin');
  assert.equal(p.$('st-kairomone-id').textContent, 'twin（控えから戻した双子。同一性: momo）');
  p.doc.querySelectorAll('button.q')[0].fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: twin）のいまの状態を教えて', 'the header and the placed text name the same ID');
  console.log('PASS: the header names the ID the placed text names');
}
