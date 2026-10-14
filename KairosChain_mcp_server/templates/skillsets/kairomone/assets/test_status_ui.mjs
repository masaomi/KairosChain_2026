// Dependency-free static and DOM-sink checks. This is not a browser/layout test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const template = fs.readFileSync(path.join(root, 'status.html'), 'utf8');
const fixture = JSON.parse(fs.readFileSync(path.join(root, 'fixtures/status_xss.json'), 'utf8'));
const token = '__KAIROMONE_STATUS_JSON__';
const escaped = value => JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, char => '\\u' + char.charCodeAt(0).toString(16).padStart(4, '0'));
const rendered = template.replace(token, escaped(fixture));
const scripts = html => [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
assert.equal(template.split(token).length - 1, 1, 'exactly one renderer token');
assert.equal(scripts(rendered).length, 2, 'payload cannot add script elements');
assert(!rendered.includes('<img src=x'), 'payload cannot add markup');
assert(!rendered.includes('<script>globalThis'), 'script end-tag escape is neutralized');
assert.deepEqual(JSON.parse(scripts(rendered)[0][2]), fixture, 'serialization preserves untrusted text');
const executable = scripts(rendered)[1][2];
const digest = crypto.createHash('sha256').update(executable).digest('base64');
assert(template.includes("script-src 'sha256-" + digest + "'"), 'CSP hash matches executable bytes');
assert(template.includes("default-src 'none'"));
assert(template.includes("connect-src 'none'"));
assert(template.includes("base-uri 'none'"));
assert(template.includes("form-action 'none'"));
assert(!/script-src[^;]*unsafe-inline/.test(template), 'only the known script can execute');
assert(!/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write\s*\(|\beval\s*\(|new\s+Function\b/.test(executable), 'no HTML or code execution sinks');
assert(!/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|\.src\s*=|window\.open|location\s*=/.test(executable), 'no network or navigation APIs');
assert(!/<(?:link|iframe|object|embed|form)\b|\bsrc\s*=|\bhref\s*=|@import|url\s*\(/i.test(template.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')), 'self-contained assets only');
assert(!/<foreignObject\b|\son[a-z]+\s*=/i.test(template), 'no embedded HTML or inline handlers');
assert(template.includes('width=device-width, initial-scale=1'));
assert(template.includes('min-height:44px'));
assert(template.includes('@media(max-width:480px)'));
assert(template.includes('grid-template-columns:1fr'));
assert(template.includes('overflow-wrap:anywhere'));
assert(!/localStorage|sessionStorage|setInterval|setTimeout/.test(executable), 'no persistence or fake live updates');
new vm.Script(executable, { filename: 'kairomone-status-ui.js' });

class Element {
  constructor(tagName = 'div') { this.tagName = tagName; this.children = []; this.attributes = {}; this._text = ''; this.hidden = false; this.className = ''; this.events = {}; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { assert(child instanceof Element); this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name]; }
  addEventListener(name, callback) { this.events[name] = callback; }
  click() { this.events.click(); }
}
function execute(value, raw) {
  const nodes = new Map();
  for (const match of template.matchAll(/\bid="([^"]+)"/g)) nodes.set(match[1], new Element());
  const translated = [...template.matchAll(/\bdata-i18n="([^"]+)"/g)].map(match => { const el = new Element(); el.setAttribute('data-i18n', match[1]); return el; });
  const document = {
    documentElement: new Element('html'),
    getElementById(id) { assert(nodes.has(id), 'element exists: ' + id); return nodes.get(id); },
    createElement(tag) { assert(['li', 'small', 'a'].includes(tag), 'only text-bearing list nodes created'); return new Element(tag); },
    querySelectorAll(selector) { assert.equal(selector, '[data-i18n]'); return translated; }
  };
  nodes.get('kairomone-status').textContent = raw === undefined ? JSON.stringify(value) : raw;
  const context = vm.createContext({ document, URL });
  vm.runInContext(executable, context, { timeout: 1000 });
  assert.equal(context.__KAIROMONE_XSS__, undefined, 'untrusted values never execute');
  return { nodes, document, context };
}
let { nodes, document } = execute(fixture);
assert.equal(nodes.get('profile-name').textContent, fixture.profile.display_name);
assert.equal(nodes.get('knowledge-count').textContent, '1');
assert.equal(nodes.get('observations-count').textContent, '1');
assert.equal(nodes.get('knowledge-list').children[0]._text, fixture.knowledge.items[0].title);
assert.equal(nodes.get('knowledge-list').children[0].children[0].textContent, fixture.knowledge.items[0].snippet);
assert.equal(nodes.get('observations-list').children[0]._text, fixture.observations.recent[0].title);
assert.equal(nodes.get('integrity-details').children[1].textContent, fixture.integrity.details[1]);
assert.equal(nodes.get('backup-scope').children[1].textContent, fixture.backup.scope[1]);
assert.equal(nodes.get('backup-excluded').children[1].textContent, fixture.backup.excluded[1]);
assert.equal(nodes.get('refresh-cli').textContent, fixture.instructions.cli);
assert.equal(document.documentElement.lang, 'ja');
nodes.get('lang-en').click();
assert.equal(document.documentElement.lang, 'en');
assert.equal(nodes.get('lang-en').getAttribute('aria-pressed'), 'true');
assert.equal(nodes.get('lang-ja').getAttribute('aria-pressed'), 'false');
assert.equal(nodes.get('integrity-state').textContent, 'Local chain check passed');
assert.equal(nodes.get('profile-name').textContent, fixture.profile.display_name, 'language switch keeps data as text');
assert.equal(nodes.get('knowledge-list').children.length, 1, 'switch replaces rather than duplicates list');
nodes.get('lang-ja').click();
assert.equal(document.documentElement.lang, 'ja');

const clone = () => JSON.parse(JSON.stringify(fixture));
for (const available of [false, undefined, 'true', 1]) {
  const data = clone(); data.knowledge.available = available; data.knowledge.count = 0;
  const result = execute(data); assert.equal(result.nodes.get('knowledge-count').textContent, '—');
  assert.equal(result.nodes.get('knowledge-details').hidden, true);
}
for (const invalidCount of [-1, 1.1, '3', null, 9007199254740992]) {
  const data = clone(); data.observations.count = invalidCount;
  assert.equal(execute(data).nodes.get('observations-count').textContent, '—');
}
for (const [state, valid, label] of [
  ['readable', true, 'Local chain check passed'], ['readable', false, 'Integrity mismatch detected'],
  ['readable', 'true', 'Not verified'], ['corrupt', true, 'Integrity mismatch detected'],
  ['absent', false, 'No chain found'], ['unreadable', false, 'Chain cannot be read'],
  ['empty', true, 'No records in the chain'], ['<script>bad</script>', true, 'Not verified']
]) {
  const data = clone(); data.integrity.state = state; data.integrity.valid = valid;
  const result = execute(data); result.nodes.get('lang-en').click();
  assert.equal(result.nodes.get('integrity-state').textContent, label);
  assert(!result.nodes.get('integrity-state').className.includes('<'));
}
const missing = execute({ schema_version: 1 });
missing.nodes.get('lang-en').click();
assert.equal(missing.nodes.get('knowledge-count').textContent, '—');
assert.equal(missing.nodes.get('backup-scope').textContent, 'Not specified');
assert.equal(missing.nodes.get('profile-name').textContent, 'Kairomone');
for (const raw of ['{broken', 'null', '[]', '{"schema_version":2}']) {
  const result = execute(null, raw); result.nodes.get('lang-en').click();
  assert.equal(result.nodes.get('data-error').hidden, false);
  assert(result.nodes.get('data-error').textContent.includes('could not be read'));
}
const many = clone(); many.knowledge.items = Array.from({ length: 90 }, (_, i) => ({ title: 'Synthetic ' + i }));
assert.equal(execute(many).nodes.get('knowledge-list').children.length, 50, 'snapshot titles bounded');
// Growth is derived from runtime snapshots, never fabricated by this view.
const growth = clone();
growth.progression = {level: 24, level_cap: 999, total_xp: 470, xp_into_level: 10, xp_for_next_level: 20, xp_to_next_level: 10, unique_l1: 8, unique_l2: 7};
growth.profession = {selected_id: null, effective_id: 'generalist', name: 'Generalist', selection_required: true, catalog: [{id: 'generalist', name: 'Generalist', unlock_level: 1, unlocked: true}, {id: 'guardian', name: 'Guardian', unlock_level: 30, unlocked: false}]};
growth.autonomy = {configured: true, used_cycles: 3, max_cycles: 10, remaining_cycles: 7, stopped: false, queue: {request_id: 'test'}, worker_online: false, last_result: {state: 'completed', request_id: fixture.profile.display_name, source_count: 1, completed_at: '2026-01-01T00:00:00Z', sources: [{url: 'https://example.org/research', title: fixture.profile.display_name}]}};
let view = execute(growth); view.nodes.get('lang-en').click();
assert.equal(view.nodes.get('level-value').textContent, '24');
assert.equal(view.nodes.get('xp-value').textContent, 'Total XP: 470');
assert.equal(view.nodes.get('xp-progress').getAttribute('value'), '10');
assert.equal(view.nodes.get('creature').getAttribute('data-stage'), 'grove');
assert.equal(view.nodes.get('unique-l1').textContent, '8');
assert.equal(view.nodes.get('profession-state').textContent, 'Not selected');
assert.equal(view.nodes.get('profession-catalog').children[1].className, 'locked');
assert.equal(view.nodes.get('growth-state').textContent, 'Queued');
assert.equal(view.nodes.get('growth-used').textContent, '3');
assert(view.nodes.get('growth-last').textContent.includes(fixture.profile.display_name));
assert.equal(view.nodes.get('growth-sources').children[0].children[0].textContent, fixture.profile.display_name);
assert.equal(view.nodes.get('growth-sources').children[0].children[0].getAttribute('href'), 'https://example.org/research');
assert.equal(view.nodes.get('growth-sources').children[0].children[0].getAttribute('rel'), 'noreferrer noopener');
view.nodes.get('lang-ja').click(); assert.equal(view.nodes.get('profession-state').textContent, '未選択');
assert.equal(view.nodes.get('growth-sources').children.length, 1, 'language switches replace source links');
for (const [level, stage] of [[1,'seed'],[5,'sprout'],[20,'grove'],[100,'canopy'],[500,'ancient'],[999,'ancient']]) {
  const data = structuredClone(growth); data.progression.level = level;
  const result = execute(data); assert.equal(result.nodes.get('creature').getAttribute('data-stage'), stage);
  if (level === 999) { result.nodes.get('lang-en').click(); assert.equal(result.nodes.get('xp-next').textContent, 'Level cap reached'); assert.equal(result.nodes.get('xp-progress').hidden, true); }
}
for (const level of [0, -1, 1000, '24', null, 1.5]) {
  const data = structuredClone(growth); data.progression.level = level;
  const result = execute(data); assert.equal(result.nodes.get('level-value').textContent, '—'); assert.equal(result.nodes.get('creature').getAttribute('data-stage'), 'unknown'); assert.equal(result.nodes.get('xp-progress').hidden, true);
}
const selected = structuredClone(growth); selected.profession.selected_id = 'generalist'; selected.profession.selection_required = false;
view = execute(selected); view.nodes.get('lang-en').click(); assert.equal(view.nodes.get('profession-state').textContent, 'Selected: Generalist'); assert.equal(view.nodes.get('profession-catalog').children[0].className, 'selected');
for (const url of ['javascript:alert(1)', 'data:text/html,evil', 'http://example.org', 'https://a:b@example.org', 'https://example.org/#secret', 'https://example.org:444', 'not a url']) {
  const data = structuredClone(growth); data.autonomy.last_result.sources = [{url, title: 'unsafe'}];
  const result = execute(data); result.nodes.get('lang-en').click(); assert.equal(result.nodes.get('growth-sources').textContent, 'No source links included in this snapshot');
}
for (const [changes, label] of [[{stopped:true}, 'Stopped'], [{queue:null,active_claim:{request_id:'test'}}, 'Worker lease recorded'], [{queue:null},'No request queued'], [{configured:false},'Not configured']]) {
  const data = structuredClone(growth); Object.assign(data.autonomy, changes);
  const result = execute(data); result.nodes.get('lang-en').click(); assert.equal(result.nodes.get('growth-state').textContent, label);
}
view = execute({schema_version:1}); view.nodes.get('lang-en').click();
assert.equal(view.nodes.get('level-value').textContent, '—'); assert.equal(view.nodes.get('profession-state').textContent, 'Not verified'); assert.equal(view.nodes.get('growth-used').textContent, '—');
assert.equal(view.nodes.get('growth-state').textContent, 'Not verified');
assert.equal((template.match(/<button\b/g) || []).length, 2, 'only functional language controls; no pretend start/stop/select buttons');
assert(template.includes('Level is not an intelligence or personality score.'));
assert(template.includes('Read-only snapshot. You cannot start or stop growth here.'));
console.log('PASS: offline/CSP, XSS text sinks, safe source links, JA/EN, actual counts, progression/stages/cap, profession selection/catalog, growth budget/states, missing/malformed snapshots.');
console.log('Layout has static 320px safeguards; use test_status_browser.mjs for real-browser verification.');
