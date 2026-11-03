// Dependency-free static and DOM-sink checks of the snapshot page
// (Kairomone 0.9 design Inv 10, N6). This is not a browser/layout test.
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
const rendered = template.replace(token, () => escaped(fixture));
const scripts = html => [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
const sha = text => crypto.createHash('sha256').update(text).digest('base64');

// --- Renderer contract and offline guarantees -----------------------------
assert.equal(template.split(token).length - 1, 1, 'exactly one renderer token');
assert.equal(scripts(rendered).length, 2, 'payload cannot add script elements');
assert(scripts(rendered)[0][1].includes('type="application/json"'), 'the payload sits in a JSON data block');
assert(!rendered.includes('<img src=x'), 'payload cannot add markup');
assert(!rendered.includes('<script>globalThis'), 'script end-tag escape is neutralized');
assert(!/[<>&\u2028\u2029]/.test(scripts(rendered)[0][2]), 'payload holds no raw <, >, &, U+2028, U+2029');
assert.deepEqual(JSON.parse(scripts(rendered)[0][2]), fixture, 'serialization preserves untrusted text');
const executable = scripts(rendered)[1][2];
assert.equal(scripts(template)[1][2], executable, 'the payload does not change the executable script');
assert(template.includes("script-src 'sha256-" + sha(executable) + "'"), 'CSP script hash matches executable bytes');
const styles = [...template.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/g)];
assert.equal(styles.length, 1, 'one style element');
assert(template.includes("style-src 'sha256-" + sha(styles[0][1]) + "'"), 'CSP style hash matches the style bytes');
for (const directive of ["default-src 'none'", "connect-src 'none'", "img-src data:;", "font-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"]) {
  assert(template.includes(directive), directive);
}
assert(!/unsafe-inline|unsafe-eval/.test(template), 'only the pinned script and style apply');
assert(!/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write\s*\(|\beval\s*\(|new\s+Function\b/.test(executable), 'no HTML or code execution sinks');
assert(!/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|\.src\s*=|\.href\s*=|window\.open|location\s*=|import\s*\(/.test(executable), 'no network or navigation APIs');
assert(!/localStorage|sessionStorage|indexedDB|document\.cookie|setInterval|setTimeout/.test(executable), 'no persistence or fake live updates');
const markup = template.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '');
assert(!/<(?:link|iframe|object|embed|form|input|textarea|select|a|base)\b|\bsrc\s*=|\bhref\s*=|@import|url\s*\(/i.test(markup), 'self-contained, and no link, form or input');
assert(!/\sstyle\s*=/.test(markup), 'no style attribute (style-src is pinned by hash)');
assert(!/<foreignObject\b|\son[a-z]+\s*=/i.test(template), 'no embedded HTML or inline handlers');
assert(!/createElement\(\s*['"](?:a|script|iframe|form|input|link|object|embed|style)['"]/.test(executable), 'the script creates no active element');
assert.equal((template.match(/<button\b/g) || []).length, 2, 'only the two language controls; nothing to start, stop or choose');
for (const needle of ['width=device-width, initial-scale=1', 'min-height:44px', '@media(max-width:480px)', 'grid-template-columns:1fr', 'overflow-wrap:anywhere', 'focus-visible']) {
  assert(template.includes(needle), needle);
}
for (const words of ['まだ職業はない', 'No profession yet', '能力や気持ちをはかるものではありません', 'not ability, and not feeling', '同期されません', 'it is not synced', '学習の依頼や題目は載せていません']) {
  assert(template.includes(words), words);
}
new vm.Script(executable, { filename: 'kairomone-status-ui.js' });

// --- A DOM with text-only sinks --------------------------------------------
const CREATED = ['li', 'ul', 'span', 'div', 'img', 'h3', 'p', 'details', 'summary'];
class Element {
  constructor(tagName = 'div', attributes = {}) { this.tagName = tagName; this.children = []; this.attributes = { ...attributes }; this._text = ''; this.hidden = 'hidden' in attributes; this.className = attributes.class || ''; this.events = {}; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { assert(child instanceof Element); this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
  setAttribute(name, value) { assert(!/^on|^style$|^href$/i.test(name), 'no handler, style or link attribute: ' + name); this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name]; }
  addEventListener(name, callback) { this.events[name] = callback; }
  click() { this.events.click(); }
}
function parseAttributes(source) {
  const attributes = {};
  for (const match of source.matchAll(/([a-zA-Z0-9:-]+)(?:="([^"]*)")?/g)) attributes[match[1]] = match[2] === undefined ? '' : match[2];
  return attributes;
}
function execute(value, raw) {
  const nodes = new Map(), translated = [];
  for (const match of markup.matchAll(/<([a-z0-9]+)\b([^>]*)>/gi)) {
    const attributes = parseAttributes(match[2]);
    if (!('id' in attributes) && !('data-i18n' in attributes)) continue;
    const element = new Element(match[1].toLowerCase(), attributes);
    if ('id' in attributes) { assert(!nodes.has(attributes.id), 'unique id ' + attributes.id); nodes.set(attributes.id, element); }
    if ('data-i18n' in attributes) translated.push(element);
  }
  const data = new Element('script', { id: 'kairomone-status' });
  data.textContent = raw === undefined ? JSON.stringify(value) : raw;
  nodes.set('kairomone-status', data);
  const document = {
    title: '',
    documentElement: new Element('html'),
    getElementById(id) { assert(nodes.has(id), 'element exists: ' + id); return nodes.get(id); },
    createElement(tag) { assert(CREATED.includes(tag), 'only text-bearing nodes are created, not ' + tag); return new Element(tag); },
    querySelectorAll(selector) { assert.equal(selector, '[data-i18n]'); return translated; }
  };
  const context = vm.createContext({ document });
  vm.runInContext(executable, context, { timeout: 1000 });
  assert.equal(context.__KAIROMONE_XSS__, undefined, 'untrusted values never execute');
  return { nodes, document, context, translated, n: id => nodes.get(id) };
}
const clone = () => structuredClone(fixture);
const en = view => { view.n('lang-en').click(); return view; };
const egg = 'data:image/svg+xml;base64,PHN2Zy8+';
// Every created node below the page's lists, flattened.
const all = element => [element, ...element.children.flatMap(all)];

// --- The fixture, in Japanese (the default) ---------------------------------
let view = execute(fixture);
assert.equal(view.document.documentElement.lang, 'ja');
assert.equal(view.n('lang-ja').getAttribute('aria-pressed'), 'true');
assert.equal(view.n('name').textContent, fixture.name, 'the name stays text');
assert(view.document.title.startsWith(fixture.name));
assert.equal(view.n('hero-stage').textContent, '若者');
assert.equal(view.n('hero-level').textContent, 'レベル 31');
assert.equal(view.n('hero-image').getAttribute('src'), egg);
assert.equal(view.n('hero-image').hidden, false);
assert.equal(view.n('hero-placeholder').hidden, true);
assert.equal(view.n('hero-image').getAttribute('alt'), fixture.drawing.form);
assert.equal(view.n('hero-caption').textContent, fixture.drawing.form);
assert.equal(view.n('generated-at').textContent, '2026-01-01 00:00:00 UTC');
assert.equal(view.n('generated-at').getAttribute('datetime'), fixture.generated_at);
const history = view.n('history').children;
assert.equal(history.length, 3, 'one item per accepted drawing');
assert.equal(history[0].children[0].children[0].tagName, 'img');
assert.equal(history[0].children[0].children[0].getAttribute('src'), egg);
assert.equal(history[0].children[1].textContent, '幼体', 'a pre-0.9 drawing shows its stage, never a level');
assert.equal(history[0].children[2].textContent, fixture.drawings[0].form);
assert.equal(history[1].className, 'drawing missing', 'a missing drawing is shown as missing');
assert.equal(history[1].children[0].textContent, '見つからない');
assert.equal(all(history[1]).filter(e => e.tagName === 'img').length, 0, 'never another image in its place');
assert.equal(history[1].children[1].textContent, 'レベル 20');
assert.equal(history[2].children[1].textContent, 'レベル 31');
assert.equal(view.n('history-empty').hidden, true);
assert.equal(view.n('count-lifetime').textContent, '2');
assert.equal(view.n('count-sources').textContent, '2');
assert.equal(view.n('count-l1').textContent, '2');
assert.equal(view.n('count-l2').textContent, '1');
assert.equal(view.n('profession-name').textContent, fixture.profession.name);
assert.deepEqual(view.n('lineage').children.map(c => c.textContent), fixture.profession.lineage);
const cycles = view.n('cycles').children;
assert.equal(cycles.length, 2, 'one card per cycle');
const first = cycles[0];
assert.deepEqual(first.children[0].children.map(c => c.textContent), ['植物学', fixture.cycles[0].subjects[1].ja], 'labelled by its subject names');
assert.equal(first.children[1].tagName, 'h3');
assert.equal(first.children[1].textContent, fixture.cycles[0].title);
assert.equal(first.children[2].textContent, '見つけたこと');
assert.equal(first.children[3].textContent, fixture.cycles[0].finding);
assert.equal(first.children[4].tagName, 'details', 'the synthesis is a disclosure');
assert.equal(first.children[4].children[0].tagName, 'summary');
assert.equal(first.children[4].children[1].textContent, fixture.cycles[0].synthesis);
assert.equal(first.children[5].textContent, '出どころ');
assert.deepEqual(first.children[6].children.map(c => c.textContent), fixture.cycles[0].sources, 'sources are shown as text');
assert(view.n('cycles').children.flatMap(all).every(e => CREATED.includes(e.tagName) && e.tagName !== 'img' && !('href' in e.attributes) && !('src' in e.attributes)), 'cycle cards hold text only');
const second = cycles[1];
assert.equal(second.children[0].children[0].textContent, '分野の記録なし');
assert.equal(second.children[1].textContent, '無題の学習');
assert.equal(second.children.filter(c => c.tagName === 'details').length, 0, 'nothing to disclose when there is no synthesis');
assert.equal(second.children.at(-1).children[0].textContent, '出どころの記録なし');
assert.equal(view.n('cycles-empty').hidden, true);
assert.equal(view.n('cycles-more').hidden, true);
assert.equal(view.n('withheld').hidden, false);
assert(view.n('withheld').textContent.includes('2 件'));
assert.equal(view.n('data-error').hidden, true);
assert.equal(view.n('content').hidden, false);
assert.equal(view.n('footer-made').textContent, 'Kairomone 0.9.0 が書き出しました。');
assert(view.translated.length >= 30, 'the static texts are found');
assert(view.translated.every(e => typeof e._text === 'string' && e._text.length), 'every static text is filled');

// --- English, and switching back -------------------------------------------
en(view);
assert.equal(view.document.documentElement.lang, 'en');
assert.equal(view.n('lang-en').getAttribute('aria-pressed'), 'true');
assert.equal(view.n('lang-ja').getAttribute('aria-pressed'), 'false');
assert.equal(view.n('hero-stage').textContent, 'Young');
assert.equal(view.n('hero-level').textContent, 'Level 31');
assert.equal(view.n('history').children[0].children[1].textContent, 'Hatchling');
assert.equal(view.n('history').children[1].children[0].textContent, 'Missing');
assert.equal(view.n('history').children.length, 3, 'a switch replaces rather than duplicates');
assert.equal(view.n('cycles').children.length, 2);
assert.deepEqual(view.n('cycles').children[0].children[0].children.map(c => c.textContent), ['Botany', fixture.cycles[0].subjects[1].en]);
assert.equal(view.n('cycles').children[1].children[1].textContent, 'Untitled');
assert.equal(view.n('name').textContent, fixture.name, 'a switch keeps data as text');
assert(view.n('withheld').textContent.startsWith('2 texts or drawings were left out'));
assert.equal(view.n('footer-made').textContent, 'Written by Kairomone 0.9.0.');
view.n('lang-ja').click();
assert.equal(view.document.documentElement.lang, 'ja');
assert.equal(view.n('lineage').children.length, 2);

// --- Profession: none, and a name left out ----------------------------------
let data = clone(); data.profession = { chosen: false, name: null, lineage: [] };
view = execute(data);
assert.equal(view.n('profession-name').textContent, 'まだ職業はない');
assert.equal(view.n('lineage').children[0].textContent, '系譜はありません');
assert.equal(en(view).n('profession-name').textContent, 'No profession yet');
data = clone(); data.profession = { chosen: true, name: null, lineage: [42, '', 'Parent'] };
view = en(execute(data));
assert.equal(view.n('profession-name').textContent, 'The profession’s name was left out by the public check');
assert.deepEqual(view.n('lineage').children.map(c => c.textContent), ['Parent']);

// --- The hero: egg, withheld drawing, unusable images -----------------------
data = clone(); data.drawing = { shown: 'egg', data_uri: egg };
view = en(execute(data));
assert.equal(view.n('hero-image').getAttribute('alt'), 'An egg, not yet drawn');
assert.equal(view.n('hero-caption').textContent, 'Not drawn yet; shown as an egg');
data = clone(); data.drawing = { shown: 'drawing', form: 'Synthetic' };
view = en(execute(data));
assert.equal(view.n('hero-image').hidden, true);
assert.equal(view.n('hero-image').getAttribute('src'), undefined);
assert.equal(view.n('hero-placeholder').hidden, false);
assert.equal(view.n('hero-caption').textContent, 'This drawing was left out by the public check');
for (const uri of ['javascript:alert(1)', 'data:text/html;base64,PHN2Zy8+', 'data:image/svg+xml,<svg onload=alert(1)>', 'data:image/svg+xml;base64,PHN2Zy8+"><script>', 'https://example.org/a.svg', 42, null]) {
  data = clone(); data.drawing = { shown: 'drawing', data_uri: uri }; data.drawings = [{ data_uri: uri, missing: false, level: 10 }];
  view = execute(data);
  assert.equal(view.n('hero-image').getAttribute('src'), undefined, String(uri));
  assert.equal(view.n('hero-image').hidden, true);
  const item = view.n('history').children[0];
  assert.equal(item.className, 'drawing missing', 'an unusable image is shown as missing: ' + String(uri));
  assert.equal(all(item).filter(e => e.tagName === 'img').length, 0);
}
data = clone(); data.drawings = [{ data_uri: egg, missing: true, level: 10 }];
assert.equal(execute(data).n('history').children[0].className, 'drawing missing', 'missing wins over an image');

// --- History bounds, labels and absence -------------------------------------
data = clone(); data.drawings = Array.from({ length: 45 }, (_, i) => ({ data_uri: egg, missing: false, level: 10 * (i + 1) > 999 ? 999 : 10 * (i + 1) }));
view = execute(data);
assert.equal(view.n('history').children.length, 30, 'at most thirty drawings');
assert.equal(view.n('history').children[29].children[1].textContent, 'レベル 450', 'the newest thirty, in order');
data = clone(); data.drawings = [{ data_uri: egg, missing: false, level: '10', stage: { id: 'x' } }, { data_uri: egg, missing: false, stage: 'young' }, { data_uri: egg, missing: false, level: 1000 }];
view = en(execute(data));
assert.deepEqual(view.n('history').children.map(c => c.children[1].textContent), ['x', 'Time not recorded', 'Time not recorded']);
data = clone(); data.drawings = 'not a list';
view = en(execute(data));
assert.equal(view.n('history').children.length, 0);
assert.equal(view.n('history-empty').hidden, false);
assert.equal(view.translated.find(e => e.attributes.id === 'history-empty').textContent, 'No drawing yet; it is shown as an egg.');

// --- Counts are actual or unknown, never zero for unknown -------------------
for (const bad of [-1, 1.5, '3', null, 9007199254740992, undefined]) {
  data = clone(); data.counts = { lifetime_cycles: bad, learned_sources: bad, own_growth_l1: bad, own_growth_l2: bad };
  view = en(execute(data));
  for (const id of ['count-lifetime', 'count-sources', 'count-l1', 'count-l2']) assert.equal(view.n(id).textContent, '—', id + ' ' + String(bad));
  assert.equal(view.n('lifetime-note').textContent, 'Could not be counted at this moment');
}
data = clone(); data.counts.lifetime_cycles = 0;
assert.equal(en(execute(data)).n('lifetime-note').textContent, 'Counts only cycles whose knowledge is still here');

// --- Levels and stages that are not what the snapshot writes ----------------
for (const bad of [0, -1, 1000, '24', null, 1.5]) {
  data = clone(); data.level = bad; data.stage = { id: 'young' };
  view = en(execute(data));
  assert.equal(view.n('hero-level').textContent, 'Level —', String(bad));
  assert.equal(view.n('hero-stage').textContent, 'young', 'a stage without its name in this language shows its id');
}
data = clone(); data.stage = '<b>young</b>';
assert.equal(en(execute(data)).n('hero-stage').textContent, 'Stage unknown');

// --- Cycles: bounds, "more", malformed members ------------------------------
data = clone(); data.counts.own_growth_l1 = 150;
data.cycles = Array.from({ length: 120 }, (_, i) => ({ subjects: [], title: 'Synthetic ' + i, sources: [] }));
view = en(execute(data));
assert.equal(view.n('cycles').children.length, 100, 'at most a hundred cycles');
assert.equal(view.n('cycles-more').hidden, false);
assert.equal(view.n('cycles-more').textContent, 'Showing the newest 100 of 150.');
data = clone(); data.cycles = [null, 'x', { subjects: 'botany', title: 7, finding: ['x'], synthesis: {}, sources: [1, null, 'https://example.org/ok'] }];
view = en(execute(data));
assert.equal(view.n('cycles').children.length, 3);
const odd = view.n('cycles').children[2];
assert.equal(odd.children[1].textContent, 'Untitled');
assert.deepEqual(odd.children.at(-1).children.map(c => c.textContent), ['https://example.org/ok']);
data = clone(); data.cycles = []; data.counts.own_growth_l1 = 0;
view = en(execute(data));
assert.equal(view.n('cycles-empty').hidden, false);
assert.equal(view.n('cycles-more').hidden, true);

// --- Withheld note only for a positive count --------------------------------
for (const value of [0, -1, '3', null, 1.5]) {
  data = clone(); data.withheld = value;
  assert.equal(execute(data).n('withheld').hidden, true, String(value));
}

// --- Missing and malformed snapshots ----------------------------------------
view = en(execute({ schema: 'kairomone-snapshot-1' }));
assert.equal(view.n('name').textContent, 'Kairomone');
assert.equal(view.n('hero-level').textContent, 'Level —');
assert.equal(view.n('count-lifetime').textContent, '—');
assert.equal(view.n('profession-name').textContent, 'No profession yet');
assert.equal(view.n('history-empty').hidden, false);
assert.equal(view.n('cycles-empty').hidden, false);
assert.equal(view.n('withheld').hidden, true);
assert.equal(view.n('hero-caption').textContent, 'The drawing cannot be shown');
for (const raw of ['{broken', 'null', '[]', '"text"', '{"schema":"kairomone-snapshot-2"}', '{"schema_version":1,"initialized":true}']) {
  view = en(execute(null, raw));
  assert.equal(view.n('data-error').hidden, false, raw);
  assert(view.n('data-error').textContent.includes('cannot be read'));
  assert.equal(view.n('content').hidden, true, 'nothing is shown from data the page cannot read');
  view.n('lang-ja').click();
  assert(view.n('data-error').textContent.includes('読み取れません'));
}

console.log('PASS: renderer contract (one marker, escaped JSON, hashed script and style, connect-src none), offline and text-only sinks, no links or controls beyond language, hero/egg/withheld drawing, drawing history (levels, stages, missing, at most 30), counts actual or unknown, profession or none, cycle cards (subjects, title, finding, synthesis disclosure, sources as text, at most 100), withheld note, JA/EN, malformed snapshots.');
console.log('Layout has static 320px safeguards; use test_status_browser.mjs for real-browser verification.');
