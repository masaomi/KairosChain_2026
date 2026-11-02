// Dependency-free checks of the console page's own logic (assets/console.html),
// run on a minimal stand-in for the DOM and fetch. Not a browser or layout
// test (test_console_browser.mjs is): it drives the page's real script through
// its event handlers, the events and the status responses the test hands it.
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
const MOMO_ART = 'data:image/svg+xml;base64,PHN2Zz5tb21vPC9zdmc+';
const PIP_ART = 'data:image/svg+xml;base64,PHN2Zz5waXA8L3N2Zz4=';
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
  removeChild(c) { this.children = this.children.filter((x) => x !== c); if (this.tagName === 'SELECT') this.selectedIndex = 0; return c; }
  get textContent() { return this.own + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.own = String(v); this.children = []; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type) { (this.listeners[type] || []).forEach((fn) => fn({ preventDefault() {}, target: this, detail: 1 })); }
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
  const tags = { message: 'textarea', 'kairomone-select': 'select', 'create-id': 'input', 'create-free': 'textarea', 'learn-cycles': 'input',
                 'skill-source': 'select', art: 'img' };
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
  doc.getElementById('learn-cycles').value = '3';

  const requests = [];
  const polls = [];
  const answer = (status, data) => ({ ok: status < 400, status, text: async () => JSON.stringify(data), json: async () => data });
  const fetch = (url, init = {}) => {
    if (url === '/session') return Promise.resolve(answer(200, { session: SESSION }));
    if (url.startsWith('/events')) return new Promise((resolve) => polls.push((events) => resolve(answer(200, { events, last: 0 }))));
    return new Promise((resolve) => requests.push({ url, method: init.method, body: init.body ? JSON.parse(init.body) : null,
                                                     resolve: (data, status = 200) => resolve(answer(status, data)),
                                                     fail: () => resolve(answer(500, { error: 'stand-in failure' })) }));
  };
  let seq = 0;
  const emit = async (...events) => {
    for (let i = 0; i < 50 && !polls.length; i += 1) await sleep(5);
    const poll = polls.shift();
    assert.ok(poll, 'the page is polling for events');
    poll(events.map((e) => ({ seq: ++seq, at: '2026-11-02T10:00:00Z', ...e })));
    await sleep(10);
  };
  const context = {
    document: doc, fetch, setTimeout, clearTimeout, TextEncoder, AbortController, console, performance,
    location: { hash: `#${TOKEN}`, pathname: '/', search: '', reload() {} },
    history: { replaceState() {} },
    sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    window: { addEventListener() {}, confirm: () => false }
  };
  vm.createContext(context);
  vm.runInContext(script, context, { filename: 'console.js' });
  return { doc, requests, emit, $: (id) => doc.getElementById(id) };
}

const own = (id, title, hex) => ({ entry_id: id, sha256: hex.repeat(64), title });
const fixture = (shown, name, proposal, identity = shown, extra = {}) => ({
  data_dir: '/fixture', shown,
  kairomones: [{ listing_id: 'momo', name: 'Momo' }, { listing_id: 'pip', name: 'Pip' }, { listing_id: 'twin', name: 'Momo' }],
  kinds: [{ kind: 'animal', label: '動物', traits: ['curious'] }],
  status: { schema_version: 1, initialized: true, profile: { display_name: name }, kairomone: { listing_id: shown, identity },
            progression: { level: 7, level_cap: 999, total_xp: 70, stage: { id: 'hatchling', ja: '幼体' } },
            profession: { current: null, tier: 0, branch: { due: false, offer: null } },
            integrity: { state: 'readable', valid: true, block_count: 12, pending_count: 0, host_l0: { state: 'unchanged' } },
            autonomy: { live: true, used_cycles: 2, max_cycles: 5, remaining_cycles: 3, policy: { declared: false, limit: null } } },
  waiting: { art: { shown: 'egg', data_uri: shown === 'pip' ? PIP_ART : MOMO_ART, waiting: [] },
             proposals: [{ proposal: proposal, kind: 'profile', name, sha256: 'c'.repeat(64) }] },
  lean: { subjects: [{ id: 'botany', en: 'Botany', ja: '植物学' }], owner_words: 'もっと苔のことを知ってほしい', request_id: 'lean_1' },
  skills: [{ sha256: 'f'.repeat(64), name: 'Count the moss', description: 'Measure before believing',
             methods: [{ id: 'quantify', en: 'Quantify', ja: '数で確かめる' }], focus: [{ id: 'botany', en: 'Botany', ja: '植物学' }] }],
  own_growth: [own('growth_moss', 'Moss on north faces', 'd'), own('growth_fern', 'Ferns', 'e')], own_growth_total: 2,
  lifetime_cycles: 4, lifetime_unknown: null, learned_subjects: [{ id: 'botany', en: 'Botany', ja: '植物学', count: 3 }],
  art_history: { digest: '1'.repeat(64), count: 2 },
  ...extra
});
const statusRequests = (p) => p.requests.filter((r) => r.url.startsWith('/status'));
const historyRequests = (p) => p.requests.filter((r) => r.url.startsWith('/art-history'));
const messages = (p) => p.requests.filter((r) => r.url === '/message');
const drawings = (shown) => ({ shown, digest: '1'.repeat(64), drawings: [
  { sha256: '2'.repeat(64), stage: 'hatchling', stage_name: { en: 'Hatchling', ja: '幼体' }, form: null, present: true, valid: true, missing: false, data_uri: MOMO_ART },
  { sha256: '3'.repeat(64), stage: 'young', form: 'A fern spirit', present: false, valid: false, missing: true, level: 30, milestone: 30 }
] });

async function booted(answerWith = fixture('momo', 'Momo', '1'.repeat(64))) {
  const p = page();
  await sleep(20);
  const first = statusRequests(p)[0];
  assert.equal(first.url, '/status', 'the first status names nobody: the server shows the first listed');
  first.resolve(answerWith);
  await sleep(20);
  return p;
}
// The box opens on the CLI's asking echo, as the console reports it.
async function opened(answerWith) {
  const p = await booted(answerWith);
  await p.emit({ kind: 'mode', word: 'default', asking: true, source: 'echo' }, { kind: 'accepting', value: true, reason: null });
  assert.equal(p.$('message').disabled, false, 'the box is open');
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

// Placed text carries the IDs: kind, export kinds; a malformed ID is not placed;
// a new Kairomone is asked for without a profession (0.9 N4).
{
  const p = await booted();
  const kind = p.$('create-kinds').querySelector('input[type=radio]');
  kind.checked = true;
  p.$('create-id').value = 'Momo';
  p.$('message').value = '';
  p.$('create-place').fire('click');
  assert.equal(p.$('message').value, '', 'a malformed ID is not placed');
  assert.equal(p.$('create-msg').hidden, false, 'and the owner is told why');
  p.$('create-id').value = 'momo2';
  p.$('create-place').fire('click');
  assert.equal(p.$('message').value, '新しい Kairomone の案を作って。種類: 動物（animal）。性格・好きなこと: おまかせ。識別子: momo2。ほかに: なし。プロフィールの案を全部見せて');
  assert.doesNotMatch(p.$('message').value, /職業|雛形/, 'no profession template is offered');
  p.$('message').value = '';
  p.$('export-place').fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: momo）を書き出す前の下見を見せて。入れる知識の種類: 学んだもの（learned）、あなたが書いたもの（owner_written）');
  console.log('PASS: placed text names the IDs the tools take');
}

// The facts belong to the Kairomone named above them: a switch empties
// them, a failed read leaves them empty, and one the host cannot read stays chosen.
{
  const p = await booted();
  assert.deepEqual(['st-level', 'st-integrity', 'st-used', 'st-lifetime'].map((id) => p.$(id).textContent), ['7', 'ローカルチェーンの検証に合格', '2', '4 回']);
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  const cleared = ['st-level', 'st-xp', 'st-integrity', 'st-blocks', 'st-l0', 'st-used', 'st-max', 'st-remaining', 'st-profession', 'st-lifetime', 'kairomone-id']
    .map((id) => p.$(id).textContent);
  assert.deepEqual(cleared, ['—', '—', '未確認', '—', '未確認', '—', '—', '—', '未確認', '—', 'pip'], 'nothing about momo stays under the name Pip');
  assert.equal(p.$('lean-words').hidden, true, 'momo\'s lean is not shown under Pip');
  assert.equal(p.$('skill-list').textContent, '読み込んでいます…');
  await sleep(20);
  const asked = statusRequests(p)[1];
  assert.equal(asked.url, '/status?kairomone=pip');
  asked.fail();
  await sleep(20);
  assert.equal(p.$('st-level').textContent, '—', 'a failed read leaves the facts empty');
  assert.equal(p.$('st-at').textContent, '状態を読み込めませんでした。「更新」で読み直せます。');
  assert.equal(p.$('wait-list').textContent, '待っている案を確かめられませんでした', 'what waits for one not read is unknown');
  // The console answers for a Kairomone it cannot read with the listing and no one shown.
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[2].resolve({ data_dir: '/fixture', kairomones: fixture('momo').kairomones, shown: null, status: null, error: 'pip: unreadable' });
  await sleep(20);
  assert.equal(p.$('kairomone-select').value, 'pip', 'the one chosen stays chosen');
  assert.equal(p.$('kairomone-name').textContent, 'Pip');
  assert.equal(p.$('st-integrity').textContent, '未確認');
  assert.equal(p.$('wait-list').textContent, '待っている案を確かめられませんでした', 'not "nothing waits"');
  assert.equal(p.$('st-warn').textContent, '状態を読み取れませんでした: pip: unreadable', 'the real cause, and no second, false one');
  assert.equal(p.$('lean-subjects').textContent, '傾きを確かめられませんでした', 'a lean not read is unknown, not none');
  p.$('status-refresh').fire('click');
  await sleep(20);
  assert.equal(statusRequests(p)[3].url, '/status?kairomone=pip', 'and is asked for again, not the first listed');
  console.log('PASS: the facts shown belong to the Kairomone named');
}

// A failed refresh of the one already shown keeps its facts and says when they were read.
{
  const p = await booted();
  const read = p.$('st-at').textContent;
  assert.match(read, /^取得: /);
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[1].fail();
  await sleep(20);
  assert.equal(p.$('st-level').textContent, '7', 'the facts are still momo\'s own');
  assert.equal(p.$('st-at').textContent, `状態を読み込めませんでした。表示は ${read.slice('取得: '.length)} に取得したものです。`);
  console.log('PASS: a failed refresh says the facts are from the earlier read');
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
  assert.equal(p.$('st-kairomone-id').textContent, 'twin（控えから戻した個体で、もとの個体の識別子 momo を受け継いでいます）');
  p.doc.querySelectorAll('button.q')[0].fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: twin）のいまの状態を教えて', 'the header and the placed text name the same ID');
  console.log('PASS: the header names the ID the placed text names');
}

// Every message the page sends begins with a line naming the listing ID of
// the Kairomone shown (0.9 Inv 10, N7); switching changes that ID only; the
// box stays closed until the one shown is known.
{
  const p = page();
  await sleep(20);
  await p.emit({ kind: 'mode', word: 'default', asking: true, source: 'echo' }, { kind: 'accepting', value: true, reason: null });
  assert.equal(p.$('message').disabled, true, 'closed while the Kairomone shown is still unknown');
  assert.match(p.$('reason').textContent, /表示する Kairomone を読み込むまで/);
  statusRequests(p)[0].resolve(fixture('momo', 'Momo', '1'.repeat(64)));
  await sleep(20);
  assert.equal(p.$('message').disabled, false);
  assert.equal(p.$('send-to').textContent, '送る会話の先頭に「[Kairomone: momo]」の 1 行が付き、Momo（momo）への会話になります。');
  p.$('message').value = 'こんにちは、元気？';
  p.$('send').fire('click');
  await sleep(10);
  assert.equal(messages(p)[0].body.text, '[Kairomone: momo]\nこんにちは、元気？', 'the ID line, then the box as typed');
  messages(p)[0].resolve({ accepted: true }, 202);
  await sleep(10);
  assert.equal(p.$('message').value, '', 'a sent message leaves the box');
  // A placed text untouched since it was placed goes with the switch; the ID line follows.
  p.$('message').value = '私の言葉';
  p.doc.querySelectorAll('button.q')[1].fire('click');
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  assert.equal(p.$('message').value, '私の言葉', 'the text placed about momo leaves; the owner\'s words stay');
  await sleep(20);
  statusRequests(p)[1].resolve(fixture('pip', 'Pip', '2'.repeat(64)));
  await sleep(20);
  p.$('send').fire('click');
  await sleep(10);
  assert.equal(messages(p)[1].body.text, '[Kairomone: pip]\n私の言葉');
  messages(p)[1].resolve({ accepted: true }, 202);
  await sleep(10);
  // Every control's text goes out the same way.
  p.$('learn-cycles').value = '2';
  p.$('learn-stop').fire('click');
  p.$('send').fire('click');
  await sleep(10);
  assert.equal(messages(p)[2].body.text, '[Kairomone: pip]\nKairomone「Pip」（識別子: pip）の学習を止めて');
  messages(p)[2].resolve({ accepted: true }, 202);
  // With no individual on the host, the line says none is shown.
  const none = page();
  await sleep(20);
  statusRequests(none)[0].resolve({ data_dir: '/fixture', kairomones: [], shown: null, kinds: [], status: { schema_version: 1, initialized: false } });
  await none.emit({ kind: 'accepting', value: true, reason: null });
  none.$('message').value = '新しい子を作りたい';
  none.$('send').fire('click');
  await sleep(10);
  assert.equal(messages(none)[0].body.text, '[Kairomone: (none shown)]\n新しい子を作りたい');
  console.log('PASS: every sent message starts with the line naming the Kairomone shown');
}

// The left column: profession (none yet, or its name), the lean with the
// owner's quoted words and a control placing the request to clear it, and
// the skills in force.
{
  const p = await opened();
  assert.equal(p.$('st-profession').textContent, 'まだ職業はない', 'current null is no profession yet');
  assert.equal(p.$('st-stage').textContent, '幼体');
  assert.equal(p.$('lean-subjects').textContent, '植物学');
  assert.equal(p.$('lean-words').textContent, '「もっと苔のことを知ってほしい」');
  assert.equal(p.$('lean-words').hidden, false);
  assert.equal(p.$('lean-clear').disabled, false);
  p.$('lean-clear').fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: momo）の傾きを消して');
  assert.match(p.$('skill-list').textContent, /Count the moss.*学び方: 数で確かめる.*分野: 植物学/);
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[1].resolve(fixture('momo', 'Momo', '1'.repeat(64), 'momo', {
    lean: { subjects: [], owner_words: '傾きを消して', request_id: 'lean_2' }, skills: [],
    status: { ...fixture('momo').status, profession: { current: { name: 'Moss Keeper', tier: 1 }, tier: 1, branch: { due: false, offer: null } } }
  }));
  await sleep(20);
  assert.equal(p.$('st-profession').textContent, 'Moss Keeper');
  assert.equal(p.$('lean-subjects').textContent, '傾きはありません');
  assert.equal(p.$('lean-words').hidden, true, 'the words of a clearing are not shown as a lean');
  assert.equal(p.$('lean-clear').disabled, true, 'nothing to clear');
  assert.equal(p.$('skill-list').textContent, 'まだスキルはありません');
  console.log('PASS: the left column shows profession, lean and skills, and clearing the lean is placed');
}

// The learn panel: N cycles placed as the owner chose them, a stop request,
// the live run's counts, lifetime cycles (unknown is not zero), the
// operator limit only when declared, and the learned subjects.
{
  const p = await opened(fixture('momo', 'Momo', '1'.repeat(64), 'momo', {
    status: { ...fixture('momo').status, autonomy: { live: false, used_cycles: 0, max_cycles: null, remaining_cycles: null, policy: { declared: false } } }
  }));
  assert.equal(p.$('learn-start').disabled, false);
  assert.equal(p.$('learn-stop').disabled, true, 'no live run to stop');
  assert.equal(p.$('st-policy').hidden, true, 'no operator limit is declared');
  p.$('learn-cycles').value = '5';
  p.$('learn-start').fire('click');
  assert.equal(p.$('message').value, 'Kairomone「Momo」（識別子: momo）、5回学習して');
  for (const bad of ['0', '1000', '2.5', '-1', 'abc', '']) {
    p.$('message').value = '';
    p.$('learn-cycles').value = bad;
    p.$('learn-start').fire('click');
    assert.equal(p.$('message').value, '', `${JSON.stringify(bad)} is not placed`);
    assert.equal(p.$('learn-msg').hidden, false);
  }
  assert.equal(p.$('st-learned').textContent, '植物学 × 3');
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[1].resolve(fixture('momo', 'Momo', '1'.repeat(64), 'momo', {
    lifetime_cycles: null, lifetime_unknown: { reason: 'the 0.6 growth state cannot be read', at_least: 2 }, learned_subjects: [],
    status: { ...fixture('momo').status, autonomy: { live: true, used_cycles: 1, max_cycles: 3, remaining_cycles: 2,
              policy: { declared: true, readable: true, max_claims: 40, window: 'month', used: 12, remaining: 28 } } }
  }));
  await sleep(20);
  assert.equal(p.$('st-lifetime').textContent, '不明');
  assert.equal(p.$('st-lifetime-note').textContent, '少なくとも 2 回。数えられない理由: the 0.6 growth state cannot be read');
  assert.equal(p.$('st-policy').textContent, 'このホストの運用上限: 月ごとに40 回まで（ホスト全体で使った 12 回、残り 28 回）。');
  assert.equal(p.$('st-policy').hidden, false);
  assert.deepEqual(['st-used', 'st-max', 'st-remaining'].map((id) => p.$(id).textContent), ['1', '3', '2']);
  assert.equal(p.$('learn-start').disabled, true, 'a run is live: stop it or let it end first');
  assert.equal(p.$('learn-stop').disabled, false);
  assert.equal(p.$('st-learned').textContent, 'まだありません');
  console.log('PASS: the learn panel places N cycles and a stop, and shows the counts and the limit');
}

// The drawing history comes by a separate read, once per digest: not again
// while the digest holds, again when it changes; a missing drawing is shown
// as missing, a drawing before 0.9 by its stage, never an invented level.
{
  const p = await opened();
  assert.equal(historyRequests(p).length, 1, 'asked for once on load');
  assert.equal(historyRequests(p)[0].url, '/art-history?kairomone=momo');
  historyRequests(p)[0].resolve(drawings('momo'));
  await sleep(20);
  const items = p.$('history-list').children;
  assert.equal(items.length, 2);
  assert.equal(items[0].children[0].src, MOMO_ART, 'a present drawing as its data: image');
  assert.equal(items[0].textContent, '段階: 幼体', 'a drawing accepted before 0.9 shows its stage');
  assert.equal(items[1].textContent, '見つからない絵Lv 30A fern spirit', 'a missing one is missing, at its level, with its form');
  for (let i = 0; i < 2; i += 1) {
    p.$('status-refresh').fire('click');
    await sleep(20);
    statusRequests(p)[1 + i].resolve(fixture('momo', 'Momo', '1'.repeat(64)));
    await sleep(20);
  }
  assert.equal(historyRequests(p).length, 1, 'the same digest is not read again');
  p.$('status-refresh').fire('click');
  await sleep(20);
  statusRequests(p)[3].resolve(fixture('momo', 'Momo', '1'.repeat(64), 'momo', { art_history: { digest: '4'.repeat(64), count: 3 } }));
  await sleep(20);
  assert.equal(historyRequests(p).length, 2, 'a changed digest is read');
  historyRequests(p)[1].resolve({ ...drawings('momo'), digest: '4'.repeat(64) });
  await sleep(20);
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  assert.equal(p.$('history-list').textContent, '読み込んでいます…', 'momo\'s history is not shown under Pip');
  await sleep(20);
  statusRequests(p)[4].resolve(fixture('pip', 'Pip', '2'.repeat(64)));
  await sleep(20);
  assert.equal(historyRequests(p)[2].url, '/art-history?kairomone=pip', 'switching reads the history of the one chosen');
  console.log('PASS: the drawing history is read once per digest and shows what is missing as missing');
}

// The skills panel names an own growth entry and its hash; the waiting list
// holds skill proposals too; a reply is shown with the drawing of the
// individual its message named.
{
  const p = await opened(fixture('momo', 'Momo', '1'.repeat(64), 'momo', {
    waiting: { art: { shown: 'egg', data_uri: MOMO_ART, waiting: [] },
               proposals: [{ proposal: '5'.repeat(64), kind: 'skill', name: 'Trace the fern', sha256: '6'.repeat(64) }] }
  }));
  assert.deepEqual(p.$('skill-source').options.map((o) => o.textContent), ['Moss on north faces（growth_moss）', 'Ferns（growth_fern）']);
  p.$('skill-source').value = 'growth_fern';
  p.$('skill-place').fire('click');
  assert.equal(p.$('message').value, `Kairomone「Momo」（識別子: momo）の学んだ知識「Ferns」（growth_fern、sha256: ${'e'.repeat(64)}）から、スキルの案を作って全部見せて`);
  p.doc.querySelectorAll('button.place')[0].fire('click');
  assert.equal(p.$('message').value, `Kairomone「Momo」（識別子: momo）のスキルの案 ${'5'.repeat(64)}（中身の sha256: ${'6'.repeat(64)}）を全部見せて`);
  await p.emit({ kind: 'owner_message', text: '[Kairomone: momo]\nおはよう' }, { kind: 'assistant_text', text: 'おはよう！' });
  const replies = p.$('log').children.filter((li) => li.className === 'msg assistant');
  assert.equal(replies.length, 1);
  const [avatar] = replies[0].children;
  assert.equal(avatar.tagName, 'IMG');
  assert.equal(avatar.src, MOMO_ART, 'the reply carries momo\'s drawing');
  assert.equal(avatar.hidden, false);
  assert.match(replies[0].textContent, /^Momo（Claude Code）/);
  const owner = p.$('log').children.find((li) => li.className === 'msg owner');
  assert.match(owner.textContent, /宛先: Momo（momo）おはよう$/, 'the ID line is shown apart from the words');
  await p.emit({ kind: 'owner_message', text: '[Kairomone: pip]\nやあ' }, { kind: 'assistant_text', text: 'やあ' });
  const pipReply = p.$('log').children.filter((li) => li.className === 'msg assistant')[1];
  assert.equal(pipReply.children[0].hidden, true, 'a drawing not yet read is not shown');
  p.$('kairomone-select').value = 'pip';
  p.$('kairomone-select').fire('change');
  await sleep(20);
  statusRequests(p)[1].resolve(fixture('pip', 'Pip', '2'.repeat(64)));
  await sleep(20);
  assert.equal(pipReply.children[0].src, PIP_ART, 'and arrives once it is read');
  console.log('PASS: skills, skill proposals and replies with the drawing of the one they answer as');
}
