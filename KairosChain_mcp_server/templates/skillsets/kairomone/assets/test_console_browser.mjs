// Real-browser QA for the Kairomone console page (assets/console.html), driven
// end to end: the real console entry runs against a temporary host with a
// scripted fake `claude`, and headless Chromium opens the URL the console
// prints, with no network beyond the 127.0.0.1 servers this file starts.
// Gated so that it skips everywhere else:
//
//   KAIROMONE_BROWSER_QA=1 NODE_PATH=<node_modules holding playwright> \
//     node KairosChain_mcp_server/templates/skillsets/kairomone/assets/test_console_browser.mjs
//
// Optional: KAIROS_CORE_LIB (KairosChain lib dir; default ../../../../lib from
// here), RUBY (default "ruby"), CHROMIUM_PATH (default: Playwright's own
// headless shell), KAIROMONE_QA_TMP (default /tmp), KAIROMONE_QA_KEEP=1 keeps
// the temporary hosts. The fake calls no model and no network. Every process
// started here has its temporary root in its command line; teardown stops the
// console and then kills only those.
import assert from 'node:assert/strict';
import { test, before, after } from 'node:test';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

if (process.env.KAIROMONE_BROWSER_QA !== '1') {
  console.log('SKIP: optional console browser QA; set KAIROMONE_BROWSER_QA=1 where Ruby, Playwright and Chromium are available.');
  process.exit(0);
}

function loadPlaywright() {
  const bases = [import.meta.url, ...(process.env.NODE_PATH || '').split(path.delimiter).filter(Boolean).map((dir) => path.join(dir, 'noop.js'))];
  for (const base of bases) {
    try { return createRequire(base)('playwright'); } catch { /* try the next base */ }
  }
  throw new Error('Playwright is not installed here; set NODE_PATH to a node_modules directory that holds it');
}

const { chromium } = loadPlaywright();
const ASSETS = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE = path.resolve(ASSETS, '..');
const CORE_LIB = path.resolve(process.env.KAIROS_CORE_LIB || path.join(PACKAGE, '..', '..', '..', 'lib'));
const RUBY = process.env.RUBY || 'ruby';
const RUBY_PATH = execFileSync(RUBY, ['-e', 'print RbConfig.ruby'], { encoding: 'utf8' });
const TMP = process.env.KAIROMONE_QA_TMP || '/tmp';
assert.ok(fsSync.existsSync(path.join(CORE_LIB, 'kairos_mcp.rb')), `KairosChain core lib not found at ${CORE_LIB}; set KAIROS_CORE_LIB`);

const URL_RE = /http:\/\/127\.0\.0\.1:(\d+)\/#([0-9a-f]{64})/g;
const ASKING = '確認あり（default）';
const UNKNOWN = 'モード: 不明';
const QUICK = ['いまの状態を教えて', '最近覚えたことを見せて', '〈話題〉について 1 回学習して', 'バックアップを取って、検証して'];
// What each quick request places: the text names the Kairomone the page shows.
const WHO = 'Kairomone「Console fixture」（識別子: console_dot）';
const PLACED = [`${WHO}のいまの状態を教えて`, `${WHO}が最近覚えたことを見せて`, `${WHO}に〈話題〉について 1 回学習させて`, `${WHO}のバックアップを取って、検証して`];
// Markup, entities and bidirectional controls the stream may carry.
const PAYLOAD = [
  '<script>window.__KX__="script"</script>',
  '<img src=x onerror="window.__KX__=\'img\'">',
  '<svg onload="window.__KX__=\'svg\'"><a href="javascript:window.__KX__=1">x</a></svg>',
  '<iframe srcdoc="<script>parent.__KX__=1</script>"></iframe>',
  '&lt;b&gt;not bold&lt;/b&gt; &amp;amp; &#x3C;i&#x3E; &nbsp;',
  // RLO ... PDF, RLI ... PDI, Hebrew, Arabic
  '\u202Ereversed\u202C \u2067isolated\u2069 \u05E2\u05D1\u05E8\u05D9\u05EA \u0627\u0644\u0639\u0631\u0628\u064A\u0629',
  '{{7*7}} </script><b>bold?</b>',
].join(' | ');

const SETUP_RB = String.raw`
core, pkg, data, init = ARGV
$LOAD_PATH.unshift(core)
$LOAD_PATH.unshift(File.join(pkg, 'lib'))
require 'kairomone'
require 'kairos_mcp/skillset_manager'
KairosMcp.data_dir = data
result = KairosMcp::SkillSetManager.new(skillsets_dir: File.join(data, 'skillsets')).install(pkg)
abort("install failed: #{result.inspect}") unless result[:success]
Kairomone::Instance.new(host_root: data, bind: false).init(kairomone_id: 'console_dot', display_name: 'Console fixture') if init == 'init'
`;

// Speaks the stream-json measured on 2026-10-21 (log/kairomone_console_probes_20261021/).
// Owner messages are scripts: PLAIN <text>, ASKJSON <spec>, ASK2 [<spec>, <spec>],
// XSS, FOREIGN, HOLD. A spec is {"tool","display_name","description","input","then"}:
// "then" is asked right after the first is answered, as the CLI does for the next
// tool use. Files in ../reports switch the k-th mode answer: hold_mode_<k> holds
// it until release_mode_<k>, echo_word_<k> replaces its word, echo_error_<k>
// refuses it.
const FAKE_CLAUDE = String.raw`
# frozen_string_literal: true
require 'json'
require 'time'
require 'securerandom'

REPORTS = File.expand_path('../reports', __dir__)
$stdout.sync = true
$stderr.sync = true
$term = false
trap('TERM') { $term = true }

def report(name) = File.join(REPORTS, name)
def flag?(name) = File.exist?(report(name))

def append(name, value)
  File.open(report(name), 'a') { |f| f.puts(JSON.generate(value)) }
end

class Fake
  def initialize
    @mode = 'default'
    @n = 0
    @modes = 0
    @waiting = {}
    @in_turn = false
    @session = (i = ARGV.index('--resume')) ? ARGV[i + 1] : SecureRandom.uuid
  end

  def run
    pending = +''
    until $term
      next unless IO.select([$stdin], nil, nil, 0.1)
      chunk = $stdin.read_nonblock(65_536, exception: false)
      if chunk.nil?
        sleep 0.1 until $term
        break
      end
      next if chunk == :wait_readable
      pending << chunk
      while (newline = pending.index("\n"))
        handle(pending.slice!(0, newline + 1))
      end
    end
    drain(pending)
  end

  # A stopping console writes its last answers just before the watchdog's TERM.
  def drain(pending)
    loop do
      chunk = $stdin.read_nonblock(65_536, exception: false)
      break unless chunk.is_a?(String)
      pending << chunk
    end
    pending.each_line { |line| record(line) }
  rescue IOError, SystemCallError
    nil
  end

  def record(line)
    append('stdin.jsonl', JSON.parse(line))
  rescue JSON::ParserError
    append('stdin.jsonl', { 'unparsed' => line })
  end

  def handle(line)
    record(line)
    message = JSON.parse(line)
    case message['type']
    when 'control_request' then control(message)
    when 'control_response' then answered(message)
    when 'user' then turn(message)
    end
  rescue JSON::ParserError
    nil
  end

  def emit(hash)
    $stdout.puts(JSON.generate(hash))
  rescue Errno::EPIPE, IOError
    nil
  end

  def control(message)
    request = message['request'] || {}
    id = message['request_id']
    if request['subtype'] == 'set_permission_mode'
      set_mode(id, request['mode'])
    else
      emit('type' => 'control_response', 'response' => { 'subtype' => 'success', 'request_id' => id })
      finish('error_during_execution', true) if request['subtype'] == 'interrupt' && @in_turn
    end
  end

  # manual is echoed as default, and a change is followed by system/status (m8, m9).
  def set_mode(id, requested)
    @modes += 1
    k = @modes
    append('modes.jsonl', { 'k' => k, 'requested' => requested })
    if flag?("hold_mode_#{k}")
      append('held.jsonl', { 'k' => k })
      sleep 0.05 until flag?("release_mode_#{k}") || $term
    end
    if flag?("echo_error_#{k}")
      emit('type' => 'control_response', 'response' => { 'subtype' => 'error', 'request_id' => id, 'error' => 'refused by the fake' })
      return
    end
    word = flag?("echo_word_#{k}") ? File.read(report("echo_word_#{k}")) : (requested == 'manual' ? 'default' : requested.to_s)
    changed = word != @mode
    @mode = word
    emit('type' => 'control_response', 'response' => { 'subtype' => 'success', 'request_id' => id, 'response' => { 'mode' => word } })
    emit('type' => 'system', 'subtype' => 'status', 'status' => nil, 'permissionMode' => word, 'uuid' => SecureRandom.uuid, 'session_id' => @session) if changed
  end

  def turn(message)
    text = text_of(message.dig('message', 'content'))
    @n += 1
    @in_turn = true
    emit(init_line)
    emit('type' => 'user', 'message' => message['message'], 'session_id' => @session, 'parent_tool_use_id' => nil,
         'uuid' => SecureRandom.uuid, 'timestamp' => Time.now.utc.iso8601(3), 'isReplay' => true)
    command, argument = text.split(' ', 2)
    case command
    when 'PLAIN'
      say("ASSISTANT-REPLY: #{argument}")
      finish
    when 'ASKJSON'
      ask(JSON.parse(argument))
    when 'ASK2'
      pair = JSON.parse(argument)
      ids = pair.map { "toolu_fake_#{@n}_#{SecureRandom.hex(4)}" }
      emit(assistant(pair.each_with_index.map { |s, i| { 'type' => 'tool_use', 'id' => ids[i], 'name' => s['tool'], 'input' => s['input'] } }))
      pair.each_with_index { |s, i| ask(s, tool_use_id: ids[i], announce: false) }
    when 'XSS' then xss
    when 'FOREIGN' then foreign
    when 'HOLD' then say('holding the turn open')
    else
      say("unknown #{command}")
      finish
    end
  end

  def payload = JSON.parse(File.read(report('payload.json')))['text']

  def xss
    p = payload
    say(p)
    read_id = "toolu_fake_read_#{@n}"
    emit(assistant([{ 'type' => 'tool_use', 'id' => read_id, 'name' => 'Read', 'input' => { 'file_path' => p, 'nested' => [p, { 'k' => p }] } }]))
    emit(tool_result(read_id, [{ 'type' => 'text', 'text' => p }], 'accept', 'config', false))
    emit('type' => 'system', 'subtype' => 'informational', 'content' => p, 'level' => 'notice', 'uuid' => SecureRandom.uuid, 'session_id' => @session)
    $stderr.puts(p)
    ask({ 'tool' => 'Bash', 'display_name' => p, 'description' => p, 'input' => { 'command' => "echo #{p}", 'description' => p } })
  end

  # A turn from another session arriving while idle (m6).
  def foreign
    say('before the foreign turn')
    finish
    sleep 0.3
    @in_turn = true
    emit(init_line)
    emit('type' => 'user', 'message' => { 'role' => 'user', 'content' => payload }, 'session_id' => @session,
         'parent_tool_use_id' => nil, 'uuid' => SecureRandom.uuid, 'timestamp' => Time.now.utc.iso8601(3),
         'isReplay' => true, 'isSynthetic' => true, 'origin' => { 'kind' => 'peer', 'name' => payload })
  end

  def ask(spec, tool_use_id: "toolu_fake_#{@n}_#{SecureRandom.hex(4)}", announce: true)
    name = spec['tool']
    input = spec['input']
    # "quiet": the request comes without a preceding tool_use block.
    emit(assistant([{ 'type' => 'tool_use', 'id' => tool_use_id, 'name' => name, 'input' => input }])) if announce && !spec['quiet']
    request_id = SecureRandom.uuid
    request = { 'subtype' => 'can_use_tool', 'tool_name' => name, 'display_name' => spec['display_name'] || name,
                'input' => input, 'permission_suggestions' => [], 'tool_use_id' => tool_use_id }
    request['description'] = spec['description'] if spec.key?('description')
    @waiting[request_id] = { 'tool_use_id' => tool_use_id, 'then' => spec['then'] }
    append('requests.jsonl', { 'request_id' => request_id, 'tool_use_id' => tool_use_id, 'tool_name' => name,
                               'input' => input, 'label' => spec['label'] })
    emit('type' => 'control_request', 'request_id' => request_id, 'request' => request)
  end

  # The CLI writes the host's answer back on stdout (m8 line 24), then the result.
  def answered(message)
    waiting = @waiting.delete(message.dig('response', 'request_id'))
    return unless waiting
    emit(message)
    body = message.dig('response', 'response') || {}
    if body['behavior'] == 'allow'
      emit(tool_result(waiting['tool_use_id'], [{ 'type' => 'text', 'text' => "TOOL-RESULT #{waiting['tool_use_id']}" }], 'accept', 'user_temporary', false))
    else
      emit(tool_result(waiting['tool_use_id'], body['message'].to_s, 'reject', 'user_reject', true))
    end
    if waiting['then']
      ask(waiting['then'])
    elsif @waiting.empty?
      say('after the tools')
      finish
    end
  end

  def init_line
    { 'type' => 'system', 'subtype' => 'init', 'cwd' => Dir.pwd, 'session_id' => @session,
      'tools' => %w[Bash Glob Grep Read ToolSearch], 'mcp_servers' => [{ 'name' => 'kairos-chain', 'status' => 'connected' }],
      'model' => 'claude-haiku-5-5', 'permissionMode' => @mode, 'slash_commands' => [], 'apiKeySource' => 'none',
      'claude_code_version' => '2.1.303', 'output_style' => 'default', 'uuid' => SecureRandom.uuid }
  end

  def assistant(blocks)
    { 'type' => 'assistant',
      'message' => { 'model' => 'claude-haiku-5-5', 'id' => "msg_#{SecureRandom.hex(12)}", 'type' => 'message',
                     'role' => 'assistant', 'content' => blocks, 'stop_reason' => nil },
      'parent_tool_use_id' => nil, 'session_id' => @session, 'uuid' => SecureRandom.uuid }
  end

  def say(text) = emit(assistant([{ 'type' => 'text', 'text' => text }]))

  def tool_result(tool_use_id, content, decision, source, is_error)
    { 'type' => 'user',
      'message' => { 'role' => 'user', 'content' => [{ 'tool_use_id' => tool_use_id, 'type' => 'tool_result',
                                                       'content' => content, 'is_error' => is_error }] },
      'parent_tool_use_id' => nil, 'session_id' => @session, 'uuid' => SecureRandom.uuid, 'timestamp' => Time.now.utc.iso8601(3),
      'tool_result_meta' => [{ 'id' => tool_use_id, 'permission_decision' => { 'decision' => decision, 'source' => source } }] }
  end

  def finish(subtype = 'success', is_error = false)
    emit('type' => 'result', 'subtype' => subtype, 'is_error' => is_error, 'duration_ms' => 12, 'num_turns' => 1,
         'result' => 'fake', 'session_id' => @session, 'permission_denials' => [], 'uuid' => SecureRandom.uuid)
    @in_turn = false
  end

  def text_of(content)
    return content.to_s unless content.is_a?(Array)
    content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join
  end
end

File.write(report("started-#{Process.pid}.json"), JSON.generate('pid' => Process.pid, 'argv' => ARGV))
Fake.new.run
exit!(0)
`;

// --- small helpers -----------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class Fatal extends Error {}

async function waitFor(what, predicate, { timeout = 15000, interval = 50 } = {}) {
  const deadline = Date.now() + timeout;
  let problem = null;
  for (;;) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      if (error instanceof Fatal) throw error;
      problem = error;
    }
    if (Date.now() > deadline) throw new Error(`timed out after ${timeout} ms waiting for ${what}${problem ? `: ${problem.message}` : ''}`);
    await sleep(interval);
  }
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
    let output = '';
    child.stdout.on('data', (d) => { output += d; });
    child.stderr.on('data', (d) => { output += d; });
    child.on('error', reject);
    child.on('exit', (code) => (code === 0 ? resolve(output) : reject(new Error(`${command} exited ${code}: ${output}`))));
  });
}

async function jsonl(host, name) {
  try {
    return (await fs.readFile(path.join(host.reports, name), 'utf8')).split('\n').filter(Boolean).map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}
const stdinOf = (host) => jsonl(host, 'stdin.jsonl');
const userLines = async (host) => (await stdinOf(host)).filter((m) => m.type === 'user');
const answersFor = async (host, requestId) => (await stdinOf(host)).filter((m) => m.type === 'control_response' && m.response?.request_id === requestId);
const modeRequests = async (host) => (await stdinOf(host)).filter((m) => m.type === 'control_request' && m.request?.subtype === 'set_permission_mode').map((m) => m.request.mode);
const setFlag = (host, name, content = '') => fs.writeFile(path.join(host.reports, name), content);

function processesUnder(root) {
  const listing = execFileSync('ps', ['-A', '-ww', '-o', 'pid=,stat=,command='], { encoding: 'utf8' });
  return listing.split('\n').map((line) => line.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/)).filter(Boolean)
    .filter(([, pid, stat, command]) => Number(pid) !== process.pid && !stat.startsWith('Z') && command.includes(root))
    .map(([, pid]) => Number(pid));
}

async function sweep(root) {
  const deadline = Date.now() + 8000; // the watchdog's 5 s grace, and some
  while (processesUnder(root).length && Date.now() < deadline) await sleep(100);
  for (const pid of processesUnder(root)) {
    try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ }
  }
}

// --- hosts and consoles ------------------------------------------------------

async function makeHost({ init = true } = {}) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(TMP, 'kairomone-console-qa-')));
  const host = { root, project: path.join(root, 'project'), home: path.join(root, 'home'), bin: path.join(root, 'bin'),
                 reports: path.join(root, 'reports'), consoles: [] };
  host.data = path.join(host.project, '.kairos');
  for (const dir of [host.data, host.home, host.bin, host.reports]) await fs.mkdir(dir, { recursive: true });
  const setup = path.join(root, 'setup.rb');
  await fs.writeFile(setup, SETUP_RB);
  await run(RUBY, [setup, CORE_LIB, PACKAGE, host.data, init ? 'init' : '']);
  await fs.writeFile(path.join(host.project, '.mcp.json'),
    JSON.stringify({ mcpServers: { 'kairos-chain': { command: 'kairos-chain', args: ['--data-dir', host.data] } } }));
  host.fake = path.join(host.bin, 'claude');
  await fs.writeFile(host.fake, `#!${RUBY_PATH}\n${FAKE_CLAUDE}`, { mode: 0o755 });
  await fs.writeFile(path.join(host.reports, 'payload.json'), JSON.stringify({ text: PAYLOAD }));
  return host;
}

async function startConsole(host, args = []) {
  const entry = path.join(host.data, 'skillsets', 'kairomone', 'scripts', 'kairomone_console.rb');
  const env = { ...process.env, HOME: host.home, PATH: `${host.bin}${path.delimiter}${process.env.PATH || ''}`, KAIROMONE_CONSOLE_CLAUDE: host.fake };
  delete env.KAIROS_DATA_DIR;
  const child = spawn(RUBY, ['-I', CORE_LIB, entry, ...args], { cwd: host.project, env, stdio: ['pipe', 'pipe', 'pipe'] });
  const con = { child, host, text: '', exit: null };
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (d) => { con.text += d; });
  child.stderr.on('data', (d) => { con.text += d; });
  child.stdin.on('error', () => {});
  con.exited = new Promise((resolve) => child.on('exit', (code, signal) => { con.exit = { code, signal }; resolve(con.exit); }));
  con.urls = () => [...con.text.matchAll(URL_RE)].map((m) => ({ url: m[0], port: Number(m[1]), bootstrap: m[2] }));
  con.pressEnter = () => child.stdin.write('\n');
  con.alive = () => con.exit === null;
  host.consoles.push(con);
  const first = await waitFor('the console to print its start URL', () => {
    if (con.exit) throw new Fatal(`the console ended before printing a URL:\n${con.text}`);
    return con.urls()[0];
  }, { timeout: 40000 });
  return Object.assign(con, first, { origin: `http://127.0.0.1:${first.port}` });
}

async function stopConsole(con) {
  if (!con.alive()) return;
  con.child.kill('SIGTERM');
  if (await Promise.race([con.exited, sleep(15000).then(() => null)])) return;
  con.child.kill('SIGKILL');
  await Promise.race([con.exited, sleep(5000)]);
}

async function cleanupHost(host) {
  for (const con of host.consoles) await stopConsole(con);
  await sweep(host.root);
  if (process.env.KAIROMONE_QA_KEEP !== '1') await fs.rm(host.root, { recursive: true, force: true });
}

// --- browser -----------------------------------------------------------------

let browser;

before(async () => {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}),
    // No name resolves except the one rebinding fixture, which points at loopback.
    args: ['--host-resolver-rules=MAP rebind.test 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', '--no-first-run'],
  });
});

after(async () => { if (browser) await browser.close(); });

async function newContext(origins, options = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, ...options });
  await context.route('**/*', (route) => {
    const url = route.request().url();
    return origins.some((origin) => url === origin || url.startsWith(`${origin}/`)) ? route.continue() : route.abort('blockedbyclient');
  });
  // Injected by the test driver (not subject to the page's CSP): records violations.
  await context.addInitScript(() => {
    window.__qaCsp = [];
    document.addEventListener('securitypolicyviolation', (e) => {
      window.__qaCsp.push({ directive: e.violatedDirective, blocked: e.blockedURI, sample: e.sample });
    });
  });
  return context;
}

async function openPage(context, url) {
  const page = await context.newPage();
  const rec = { console: [], errors: [], requests: [], dialogs: [], answers: [] };
  page.on('console', (m) => rec.console.push({ type: m.type(), text: m.text() }));
  page.on('pageerror', (e) => rec.errors.push(String((e && e.message) || e)));
  page.on('request', (r) => rec.requests.push({ method: r.method(), url: r.url(), session: r.headers()['x-kairomone-session'] || null,
                                                bootstrap: r.headers()['x-kairomone-bootstrap'] || null, body: r.postData() }));
  page.on('dialog', async (dialog) => {
    rec.dialogs.push({ type: dialog.type(), message: dialog.message() });
    if ((rec.answers.length ? rec.answers.shift() : 'dismiss') === 'accept') await dialog.accept();
    else await dialog.dismiss();
  });
  if (url) await page.goto(url);
  return { page, rec };
}

async function withConsole(options, body) {
  const host = await makeHost(options);
  let context;
  try {
    if (options.prepare) await options.prepare(host);
    const con = await startConsole(host, options.args || []);
    context = await newContext([con.origin, ...(options.origins || [])], options.context || {});
    await body({ host, con, context });
  } finally {
    if (context) await context.close().catch(() => {});
    await cleanupHost(host);
  }
}

const badge = (page) => page.evaluate(() => {
  const node = document.getElementById('mode-badge');
  return { text: node.textContent, cls: node.className };
});
const waitBadge = (page, text, timeout = 15000) => waitFor(`the mode badge to read ${text}`, async () => (await badge(page)).text === text, { timeout });
const boxOpen = (page) => page.evaluate(() => !document.getElementById('message').disabled);
const waitBoxOpen = (page) => waitFor('the message box to open', () => boxOpen(page));
const logTexts = (page) => page.evaluate(() => Array.from(document.querySelectorAll('#log > li')).map((li) => `${li.className} :: ${li.textContent.replace(/\d{1,2}:\d{2}:\d{2}/g, '')}`));
const turnEnds = (page) => page.locator('#log > li.turn-end').count();
const cardFor = (page, requestId) => page.locator('#pending-list article.request', { hasText: `依頼 ID: ${requestId}` });

async function send(page, host, text) {
  const before = (await userLines(host)).length;
  await page.fill('#message', text);
  await page.click('#send');
  await waitFor(`the child to receive "${text.slice(0, 40)}"`, async () => (await userLines(host)).length > before);
}

async function nextRequest(host, count) {
  return waitFor('a permission request from the fake', async () => (await jsonl(host, 'requests.jsonl'))[count]);
}

async function assertCleanPage(page, rec, origin) {
  assert.deepEqual(rec.errors, [], 'no page error');
  assert.deepEqual(await page.evaluate(() => window.__qaCsp), [], 'no CSP violation event');
  assert.deepEqual(rec.console.filter((m) => /Content.Security.Policy|Refused to (execute|load|apply|frame)/i.test(m.text)), [], 'no CSP message in the console log');
  assert.deepEqual(rec.requests.filter((r) => !r.url.startsWith(`${origin}/`)), [], 'the page requests nothing outside the console origin');
  assert.equal(await page.evaluate(() => window.__KX__), undefined, 'no injected script ran');
}

// --- tests -------------------------------------------------------------------

test('the bootstrap leaves the address bar, is sent once, and the session survives a reload', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBadge(page, ASKING);
    await waitBoxOpen(page);
    assert.equal(new URL(page.url()).hash, '', 'the fragment is gone from the address bar');
    assert.equal(page.url(), `${con.origin}/`);
    const entries = await page.evaluate(() => (window.navigation ? navigation.entries().map((e) => e.url) : [location.href]));
    assert.ok(entries.every((u) => !u.includes(con.bootstrap)), 'no session-history entry keeps the bootstrap');
    const stored = await page.evaluate(() => sessionStorage.getItem('kairomone-console-session'));
    assert.match(stored, /^[0-9a-f]{64}$/, 'the session secret is kept in sessionStorage');
    assert.equal(await page.evaluate(() => document.cookie), '', 'no cookie');
    const withBootstrap = rec.requests.filter((r) => r.bootstrap || r.url.includes(con.bootstrap) || (r.body || '').includes(con.bootstrap));
    assert.deepEqual(withBootstrap.map((r) => `${r.method} ${new URL(r.url).pathname}`), ['POST /session'], 'the bootstrap is sent exactly once, to POST /session');
    assert.equal(withBootstrap[0].bootstrap, con.bootstrap);
    assert.ok(rec.requests.filter((r) => r.session).every((r) => r.session === stored), 'every control request carries the stored session');

    await send(page, host, 'PLAIN hello <b>owner</b>');
    await waitFor('the assistant reply', async () => (await logTexts(page)).some((t) => t.startsWith('msg assistant') && t.includes('ASSISTANT-REPLY: hello <b>owner</b>')));
    assert.ok((await logTexts(page)).some((t) => t.startsWith('msg owner') && t.includes('PLAIN hello <b>owner</b>')), 'the owner message is rendered as text');
    await waitFor('the turn to end', async () => (await turnEnds(page)) === 1);
    const shown = await logTexts(page);

    await page.reload();
    await waitBadge(page, ASKING);
    await waitFor('the replay after reload', async () => (await logTexts(page)).length === shown.length);
    assert.deepEqual(await logTexts(page), shown, 'a reload replays the same session events');
    assert.equal(await page.evaluate(() => document.getElementById('gate').hidden), true, 'no gate after reload');
    await waitBoxOpen(page);
    await send(page, host, 'PLAIN after reload');
    assert.equal(new URL(page.url()).hash, '');

    const second = await openPage(context, con.url);
    await waitFor('the spent-URL gate in a second tab', () => second.page.evaluate(() => !document.getElementById('gate').hidden));
    assert.match(await second.page.locator('#gate').textContent(), /もう使えません/, 'a second tab is told the URL is spent');
    assert.equal(await second.page.evaluate(() => sessionStorage.getItem('kairomone-console-session')), null);
    assert.equal(await second.page.evaluate(() => document.getElementById('message').disabled), true);
    assert.equal((await badge(second.page)).text, UNKNOWN);

    await assertCleanPage(page, rec, con.origin);
    await assertCleanPage(second.page, second.rec, con.origin);
  });
});

test('the mode badge stays unknown and the message box closed until the CLI echoes the asking word', { timeout: 120000 }, async () => {
  await withConsole({ prepare: (host) => setFlag(host, 'hold_mode_1') }, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitFor('the child start line', async () => (await logTexts(page)).some((t) => t.includes('Claude Code を起動しました')));
    await waitFor('the fake to hold the first mode answer', async () => (await jsonl(host, 'held.jsonl')).length === 1);
    await sleep(800);
    assert.deepEqual(await badge(page), { text: UNKNOWN, cls: 'mode-badge unknown' }, 'unknown before the echo');
    const closed = await page.evaluate(() => ({
      message: document.getElementById('message').disabled, send: document.getElementById('send').disabled,
      auto: document.getElementById('auto-switch').disabled, quick: Array.from(document.querySelectorAll('button.q')).map((b) => b.disabled),
      reason: document.getElementById('reason').textContent,
    }));
    assert.deepEqual(closed, { message: true, send: true, auto: true, quick: [true, true, true, true], reason: closed.reason });
    assert.match(closed.reason, /確認あり/, 'the reason names the asking mode');
    await page.keyboard.press('Control+Enter');
    await page.locator('#send').dispatchEvent('click');
    await sleep(300);
    assert.equal(rec.requests.filter((r) => r.url.endsWith('/message')).length, 0, 'nothing is posted before the echo');
    assert.deepEqual(await userLines(host), [], 'no message reaches the child before the echo');

    // A non-asking word from the CLI is shown as its own word, as not asking, and the box stays closed.
    await setFlag(host, 'echo_word_1', 'acceptEdits');
    await setFlag(host, 'release_mode_1');
    await waitBadge(page, '確認なし（acceptEdits）');
    assert.equal((await badge(page)).cls, 'mode-badge not-asking');
    await sleep(500);
    assert.equal(await boxOpen(page), false, 'a non-asking echo does not open the box');
    assert.ok((await logTexts(page)).some((t) => t.startsWith('line not-asking') && t.includes('acceptEdits')));

    // Back to asking through the page: unchecking asks for manual, and only the CLI's echo and status move the badge.
    assert.equal(await page.isChecked('#auto-switch'), true, 'a non-asking word shows the switch as not asking');
    await page.uncheck('#auto-switch');
    await waitBadge(page, ASKING);
    await waitBoxOpen(page);
    assert.deepEqual(await modeRequests(host), ['manual', 'manual']);
    assert.deepEqual(rec.dialogs, [], 'going back to asking needs no confirmation');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a permission request shows its full input; Allow carries exactly that input once; Deny works; reload keeps it pending', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    const input = { command: "printf '%s\\n' \"a b\" && echo 'ok' # 確認", description: 'Print two lines', timeout: 120000,
                    nested: { list: [1, 2.5, true, null, 'x'], 'key with spaces': '値', empty: {} } };
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'Bash', description: 'Print two lines', input })}`);
    const asked = await nextRequest(host, 0);
    const card = cardFor(page, asked.request_id);
    await card.waitFor();
    assert.equal(await card.locator('.tool-name').textContent(), 'Bash');
    assert.equal(await card.locator('.request-desc').textContent(), 'Print two lines');
    assert.equal(await card.locator('pre.cmd').textContent(), input.command, 'the command is shown verbatim');
    assert.equal(await card.locator('details pre').textContent(), JSON.stringify(input, null, 2), 'the full input is shown');
    assert.equal(await card.locator('details').evaluate((d) => d.open), true, 'the input is open on the request');
    assert.equal(await page.locator('#pending').isVisible(), true);

    await sleep(2500);
    assert.deepEqual(await answersFor(host, asked.request_id), [], 'nothing is answered while the owner waits');
    await page.reload();
    await cardFor(page, asked.request_id).waitFor();
    const again = cardFor(page, asked.request_id);
    assert.equal(await again.locator('details pre').textContent(), JSON.stringify(input, null, 2), 'the pending request survives a reload');

    const buttons = await again.elementHandle();
    await again.locator('button.allow').click();
    await buttons.evaluate((root) => root.querySelectorAll('button').forEach((b) => b.dispatchEvent(new MouseEvent('click', { bubbles: true }))));
    const answer = await waitFor('the allow to reach the child', async () => (await answersFor(host, asked.request_id))[0]);
    assert.equal(answer.response.response.behavior, 'allow');
    assert.deepEqual(answer.response.response.updatedInput, input, 'Allow carries back exactly the input shown');
    await sleep(800);
    assert.equal((await answersFor(host, asked.request_id)).length, 1, 'a second click sends nothing');
    const posts = rec.requests.filter((r) => r.url.endsWith(`/permission/${asked.request_id}`));
    assert.deepEqual(posts.map((r) => JSON.parse(r.body)), [{ decision: 'allow' }], 'the page posts the decision only, once');
    await waitFor('the result on the tool card', async () => (await page.locator('#log li.tool .badge').first().textContent()) === '結果');
    const tool = page.locator('#log li.tool').first();
    assert.match(await tool.textContent(), /この画面での答えです。/);
    assert.match(await tool.textContent(), /user_temporary/);
    await waitFor('the turn to end', async () => (await turnEnds(page)) === 1);

    await waitBoxOpen(page);
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'Bash', description: 'Create a file', input: { command: 'touch ./x', description: 'Create a file' } })}`);
    const denied = await nextRequest(host, 1);
    await cardFor(page, denied.request_id).locator('button.deny').click();
    const no = await waitFor('the deny to reach the child', async () => (await answersFor(host, denied.request_id))[0]);
    assert.equal(no.response.response.behavior, 'deny');
    await waitFor('the denied tool card', async () => (await page.locator('#log li.tool .badge').nth(1).textContent()) === '拒否');
    assert.match(await page.locator('#log li.tool').nth(1).textContent(), /この画面での答えです。/);
    await waitFor('the pending list to empty', async () => page.locator('#pending').isHidden());
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a permission request without a preceding tool_use keeps its input on the tool card after the answer and across a reload', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    const input = { command: 'ls -la', description: 'List the folder' };
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'Bash', description: 'List the folder', input, quiet: true })}`);
    const asked = await nextRequest(host, 0);
    await cardFor(page, asked.request_id).waitFor();
    const shownInput = (card) => card.locator('.tool-input details pre');
    const tool = page.locator('#log li.tool').first();
    assert.equal(await tool.locator('.tool-name').textContent(), 'Bash');
    assert.equal(await shownInput(tool).count(), 1, 'the tool card shows the request input while it waits');
    assert.equal(await shownInput(tool).textContent(), JSON.stringify(input, null, 2));
    await cardFor(page, asked.request_id).locator('button.allow').click();
    await waitFor('the allow to reach the child', async () => (await answersFor(host, asked.request_id))[0]);
    await waitFor('the pending list to empty', async () => page.locator('#pending').isHidden());
    await waitFor('the turn to end', async () => (await turnEnds(page)) === 1);
    assert.equal(await shownInput(tool).count(), 1, 'the input stays on the tool card after the answer');
    assert.equal(await shownInput(tool).textContent(), JSON.stringify(input, null, 2));
    assert.equal(await tool.locator('pre.cmd').textContent(), input.command, 'the command stays shown');
    await page.reload();
    await waitFor('the replayed tool card', async () => (await page.locator('#log li.tool').count()) === 1);
    const replayed = page.locator('#log li.tool').first();
    assert.equal(await shownInput(replayed).count(), 1, 'the input is shown again after a reload');
    assert.equal(await shownInput(replayed).textContent(), JSON.stringify(input, null, 2));
    assert.equal(await page.locator('#pending-list article.request').count(), 0, 'nothing is pending after the answer');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a double-click on Allow cannot answer a request that appears under the pointer', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    // B is asked as soon as A is answered (the CLI's next tool use). B differs from A in
    // size and content: with one card showing, the pending list sits on the composer,
    // so every card's Allow button lands at the same place.
    const first = { tool: 'Bash', description: 'Show the date', input: { command: 'date', description: 'Show the date' }, label: 'A' };
    const other = { tool: 'Bash', description: 'List the build folders and their sizes before the next step of the task',
                    input: { command: 'ls -la ./build ./dist && du -sh ./build ./dist && wc -l ./build/*.log',
                             description: 'List the build folders and their sizes before the next step of the task' }, label: 'B' };
    await send(page, host, `ASKJSON ${JSON.stringify({ ...first, then: other })}`);
    const a = await nextRequest(host, 0);
    const allowA = cardFor(page, a.request_id).locator('button.allow');
    await allowA.waitFor();
    await sleep(600); // the owner has read A
    const box = await allowA.boundingBox();
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    const started = Date.now();
    await page.mouse.click(x, y); // first click of a double-click, on A
    // The moment the next request's card is on the page in A's place:
    await page.waitForFunction((id) => {
      const cards = Array.from(document.querySelectorAll('#pending-list article.request'));
      return cards.length > 0 && cards.every((c) => !c.textContent.includes(`依頼 ID: ${id}`));
    }, a.request_id, { polling: 'raf', timeout: 3000 });
    const bBox = await page.locator('#pending-list article.request button.allow').first().boundingBox();
    assert.ok(bBox && x >= bBox.x && x <= bBox.x + bBox.width && y >= bBox.y && y <= bBox.y + bBox.height,
      'fixture: B took A\'s place, its Allow is under the pointer');
    await page.mouse.click(x, y, { clickCount: 2 }); // the second click of the same double-click
    const elapsed = Date.now() - started;
    assert.ok(elapsed < 500, `fixture: the second click came ${elapsed} ms after the first, within a double-click`);
    const b = await nextRequest(host, 1);
    await sleep(1000);
    assert.equal((await answersFor(host, a.request_id)).length, 1, 'A is answered once');
    assert.deepEqual((await answersFor(host, b.request_id)).map((m) => m.response.response.behavior), [],
      `B appeared under the pointer and the second click of a double-click (${elapsed} ms after the first) must not answer it`);
    assert.equal(rec.requests.filter((r) => r.url.endsWith(`/permission/${b.request_id}`)).length, 0, 'no answer to B is posted');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('auto asks for confirmation and the badge moves only when the CLI reports the mode', { timeout: 120000 }, async () => {
  await withConsole({ prepare: (host) => setFlag(host, 'hold_mode_2') }, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBadge(page, ASKING);
    await waitBoxOpen(page);

    rec.answers.push('dismiss');
    await page.click('#auto-switch');
    await waitFor('the confirmation', () => rec.dialogs.length === 1);
    assert.equal(rec.dialogs[0].type, 'confirm');
    assert.match(rec.dialogs[0].message, /分類器/, 'the confirmation says Claude Code\'s classifier decides');
    assert.match(rec.dialogs[0].message, /問うことはありません/, 'the confirmation says nothing asks the owner');
    await sleep(500);
    assert.equal(await page.isChecked('#auto-switch'), false, 'a dismissed confirmation leaves the switch off');
    assert.equal(rec.requests.filter((r) => r.url.endsWith('/mode')).length, 0, 'nothing is posted when dismissed');
    assert.deepEqual(await modeRequests(host), ['manual']);

    rec.answers.push('accept');
    await page.click('#auto-switch');
    await waitFor('the fake to hold the auto answer', async () => (await jsonl(host, 'held.jsonl')).length === 1);
    assert.deepEqual(await modeRequests(host), ['manual', 'auto']);
    assert.deepEqual(rec.requests.filter((r) => r.url.endsWith('/mode')).map((r) => JSON.parse(r.body)), [{ mode: 'auto' }]);
    await sleep(1200);
    assert.deepEqual(await badge(page), { text: ASKING, cls: 'mode-badge asking' }, 'the badge waits for the CLI');
    await setFlag(host, 'release_mode_2');
    await waitBadge(page, '確認なし（auto）');
    assert.equal((await badge(page)).cls, 'mode-badge not-asking');
    assert.equal(await page.isChecked('#auto-switch'), true);

    await page.click('#auto-switch'); // back to asking: no confirmation needed
    await waitBadge(page, ASKING);
    await waitBoxOpen(page);
    assert.equal(rec.dialogs.length, 2, 'only turning auto on asks');
    assert.deepEqual(await modeRequests(host), ['manual', 'auto', 'manual']);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('quick requests only fill the editable box and never send', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    assert.deepEqual(await page.locator('button.q').allTextContents(), QUICK, 'the four fixed requests');
    for (const text of await page.locator('button.q').allTextContents()) {
      assert.doesNotMatch(text, /許可|承認|同意|保存|復元|restore|approve|consent/i, 'no consent, approval, save or restore wording');
    }
    await waitFor('the status', async () => (await page.locator('#kairomone-id').textContent()) === 'console_dot');
    for (const [index, text] of PLACED.entries()) {
      await page.locator('button.q').nth(index).click();
      assert.equal(await page.inputValue('#message'), text, 'the box holds the fixed text naming the Kairomone');
      assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.id), 'message', 'the box is focused for editing');
    }
    assert.equal(await page.evaluate(() => {
      const box = document.getElementById('message');
      return box.value.slice(box.selectionStart, box.selectionEnd);
    }), '', 'nothing is pre-selected in a request without a topic');
    await page.locator('button.q').nth(2).click();
    assert.equal(await page.evaluate(() => {
      const box = document.getElementById('message');
      return box.value.slice(box.selectionStart, box.selectionEnd);
    }), '〈話題〉', 'the topic placeholder is selected for typing over');
    await page.keyboard.type('苔');
    assert.equal(await page.inputValue('#message'), `${WHO}に苔について 1 回学習させて`, 'the text is editable');
    await sleep(800);
    assert.equal(rec.requests.filter((r) => r.url.endsWith('/message')).length, 0, 'no quick request is sent');
    assert.deepEqual(await userLines(host), [], 'the child received no message');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('the box stays closed while Claude is answering, and interrupt ends the turn', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    await send(page, host, 'HOLD');
    await waitFor('the box to close for the turn', async () => !(await boxOpen(page)));
    assert.match(await page.locator('#reason').textContent(), /応答しています/, 'the reason says Claude is answering');
    assert.equal(await page.locator('button.q').first().isDisabled(), true, 'quick requests are off during a turn');
    await page.click('#interrupt');
    await waitFor('the interrupt to reach the child', async () => (await stdinOf(host)).some((m) => m.type === 'control_request' && m.request?.subtype === 'interrupt'));
    await waitBoxOpen(page);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('markup, entities and bidirectional text from the stream and the CLI are shown as text', { timeout: 120000 }, async () => {
  await withConsole({ prepare: (host) => setFlag(host, 'echo_word_2', PAYLOAD) }, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    await send(page, host, `XSS ${PAYLOAD}`);
    const asked = await nextRequest(host, 0);
    const card = cardFor(page, asked.request_id);
    await card.waitFor();
    await waitFor('both notices', async () => (await page.locator('#log li.notice').count()) >= 2);

    const has = (texts, needle) => texts.some((t) => t.includes(needle));
    const texts = await page.evaluate(() => Array.from(document.querySelectorAll('#log > li')).map((li) => li.textContent));
    assert.ok(has(texts, `XSS ${PAYLOAD}`), 'owner message as text');
    assert.ok((await page.locator('#log li.msg.assistant .body').allTextContents()).includes(PAYLOAD), 'assistant text verbatim');
    assert.ok(has(await page.locator('#log li.notice').allTextContents(), `Claude Code: ${PAYLOAD}`), 'informational notice as text');
    assert.ok(has(await page.locator('#log li.notice').allTextContents(), `Claude Code (stderr): ${PAYLOAD}`), 'stderr notice as text');
    const read = page.locator('#log li.tool').first();
    assert.equal(await read.locator('.input-view details pre').textContent(), JSON.stringify({ file_path: PAYLOAD, nested: [PAYLOAD, { k: PAYLOAD }] }, null, 2), 'tool input verbatim');
    assert.equal(await read.locator('.tool-result pre').textContent(), PAYLOAD, 'tool result verbatim');
    assert.match(await read.textContent(), /この画面の判断ではありません。/, 'a decision the page did not make is marked');
    assert.match(await read.textContent(), /出所: config/);
    assert.equal(await card.locator('.request-desc').textContent(), PAYLOAD, 'request description verbatim');
    assert.equal(await card.locator('.caption').first().textContent(), `表示名: ${PAYLOAD}`, 'display name verbatim');
    assert.equal(await card.locator('pre.cmd').textContent(), `echo ${PAYLOAD}`, 'command verbatim');
    assert.equal(await card.locator('details pre').textContent(), JSON.stringify({ command: `echo ${PAYLOAD}`, description: PAYLOAD }, null, 2));

    await card.locator('button.deny').click();
    await waitFor('the turn to end', async () => (await turnEnds(page)) === 1);
    await waitBoxOpen(page);
    await send(page, host, 'FOREIGN');
    await waitFor('the foreign alert', async () => (await page.locator('#log li.alert').count()) === 1);
    const alert = page.locator('#log li.alert').first();
    assert.equal(await alert.locator('.body').textContent(), PAYLOAD, 'foreign turn verbatim');
    assert.equal(await alert.locator('.caption').textContent(), `出所: ${JSON.stringify({ kind: 'peer', name: PAYLOAD }, null, 2)}`);

    // The CLI's own mode word is shown as its word, as not asking.
    await waitFor('the switch to be usable', () => page.evaluate(() => !document.getElementById('auto-switch').disabled));
    rec.answers.push('accept');
    await page.click('#auto-switch');
    await waitBadge(page, `確認なし（${PAYLOAD}）`);
    assert.equal((await badge(page)).cls, 'mode-badge not-asking');
    assert.equal(await page.evaluate(() => document.getElementById('mode-detail').textContent.includes('</script>')), true);

    const injected = await page.evaluate(() => Array.from(document.querySelectorAll('#log *, #pending-list *, .badges *, .mode-row *'))
      .filter((n) => ['IMG', 'SCRIPT', 'IFRAME', 'SVG', 'svg', 'OBJECT', 'EMBED', 'A', 'B', 'I', 'FORM'].includes(n.tagName)).map((n) => n.outerHTML));
    assert.deepEqual(injected, [], 'no element was created from stream text');
    await sleep(500);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a growth claim request says the attempt is spent and names its 15-minute lease', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    const input = { command: 'claim', worker_id: 'console-1', lease_seconds: 900 };
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'mcp__kairos-chain__kairomone_growth', display_name: 'Kairomone Growth', input })}`);
    const asked = await nextRequest(host, 0);
    const card = cardFor(page, asked.request_id);
    await card.waitFor();
    const note = await card.locator('.claim-note').textContent();
    assert.match(note, /1 回/, 'one attempt is spent once allowed');
    assert.match(note, /15 分/, 'the lease runs 15 minutes');
    assert.equal(await card.locator('details pre').textContent(), JSON.stringify(input, null, 2));
    await card.locator('button.deny').click();
    await waitFor('the deny', async () => (await answersFor(host, asked.request_id)).length === 1);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a growth claim without lease_seconds names the lease the tool will actually grant (300 s, not 15 minutes)', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    // kairomone_growth claim defaults to lease_seconds 300 (tools/kairomone_tools.rb, docs/bounded-growth.md).
    const input = { command: 'claim', worker_id: 'console-1' };
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'mcp__kairos-chain__kairomone_growth', display_name: 'Kairomone Growth', input })}`);
    const asked = await nextRequest(host, 0);
    const card = cardFor(page, asked.request_id);
    await card.waitFor();
    const note = await card.locator('.claim-note').textContent();
    assert.match(note, /1 回/, 'one attempt is spent once allowed');
    assert.match(note, /(?<![0-9])(300|5\s*分)/, `the note must name the 300-second (5-minute) lease this claim gets; it says: ${note}`);
    await card.locator('button.deny').click();
    await waitFor('the deny', async () => (await answersFor(host, asked.request_id)).length === 1);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('the status panel names the Kairomone ID and data directory and shows unknown counts as unknown', { timeout: 120000 }, async () => {
  const facts = (page) => page.evaluate(() => Object.fromEntries(Array.from(document.querySelectorAll('.facts dd, .small-facts dd, .paths dd'))
    .map((dd) => [dd.id, dd.textContent])));
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitFor('the status', async () => (await page.locator('#kairomone-id').textContent()) === 'console_dot');
    assert.equal(await page.locator('#data-dir').textContent(), host.data);
    const shown = await facts(page);
    assert.equal(shown['st-kairomone-id'], 'console_dot');
    assert.equal(shown['st-data-dir'], host.data);
    assert.equal(shown['st-root'], path.join(host.data, 'kairomones', 'console_dot'), 'the instance root');
    assert.equal(await page.locator('#st-integrity').textContent(), 'ローカルチェーンの検証に合格');
    assert.equal(shown['st-l1'], '0', 'a readable empty store is a known zero');
    assert.equal(shown['st-used'], '—', 'without a live run there are no run counts');
    assert.equal(await page.locator('#art').getAttribute('hidden'), null, 'the drawing (the egg) is shown as an image');
    await assertCleanPage(page, rec, con.origin);
  });
  await withConsole({ init: false }, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitFor('the status', async () => (await page.locator('#st-at').textContent()).startsWith('取得'));
    const shown = await facts(page);
    assert.equal(await page.locator('#kairomone-id').textContent(), '未確認', 'no ID before a Kairomone exists');
    assert.equal(shown['st-data-dir'], host.data);
    for (const id of ['st-level', 'st-xp', 'st-l1', 'st-l2', 'st-blocks', 'st-pending', 'st-used', 'st-max', 'st-remaining']) {
      assert.equal(shown[id], '—', `${id} is unknown, not zero`);
    }
    assert.match(await page.locator('#st-warn').textContent(), /初期化されていません/);
    await assertCleanPage(page, rec, con.origin);
  });
});

test('stop asks for confirmation, then pending requests are denied and the page reports the end', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    await send(page, host, `ASKJSON ${JSON.stringify({ tool: 'Bash', description: 'Waits', input: { command: 'sleep 1', description: 'Waits' } })}`);
    const asked = await nextRequest(host, 0);
    await cardFor(page, asked.request_id).waitFor();

    rec.answers.push('dismiss');
    await page.click('#stop');
    await waitFor('the stop confirmation', () => rec.dialogs.length === 1);
    assert.match(rec.dialogs[0].message, /拒否/, 'the confirmation says pending requests are denied');
    await sleep(800);
    assert.equal(rec.requests.filter((r) => r.url.endsWith('/stop')).length, 0, 'a dismissed stop posts nothing');
    assert.equal(con.alive(), true);

    rec.answers.push('accept');
    await page.click('#stop');
    await waitFor('the console to end', () => !con.alive(), { timeout: 30000 });
    await waitFor('the page to report the end', async () => (await page.locator('#conn').textContent()) === 'コンソールは停止しました', { timeout: 20000 });
    assert.match(await page.locator('#gate').textContent(), /停止しました/);
    assert.equal(await page.locator('#gate').isVisible(), true);
    const denial = await waitFor('the pending request to be denied', async () => (await answersFor(host, asked.request_id))[0], { timeout: 10000 });
    assert.equal(denial.response.response.behavior, 'deny');
    assert.match(await page.locator('#log li.tool').first().textContent(), /コンソールの停止による/, 'the page shows the stop denied it');
    const controls = await page.evaluate(() => ['message', 'send', 'interrupt', 'stop', 'auto-switch'].map((id) => document.getElementById(id).disabled));
    assert.deepEqual(controls, [true, true, true, true, true], 'every control is off after the end');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a fresh URL opened in the tab that already shows the console is exchanged and leaves the address bar', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const { page, rec } = await openPage(context, con.url);
    await waitBoxOpen(page);
    con.pressEnter();
    const fresh = await waitFor('a fresh URL at the terminal', () => con.urls()[1]);
    // The owner opens the fresh URL where the console already is (only the fragment differs).
    await page.goto(fresh.url);
    await sleep(2000);
    assert.equal(new URL(page.url()).hash, '', 'the fresh bootstrap must leave the address bar');
    assert.equal(rec.requests.filter((r) => r.bootstrap === fresh.bootstrap).length, 1, 'the fresh bootstrap is exchanged');
    assert.equal(await page.evaluate(() => document.getElementById('gate').hidden), true, 'the tab is signed in again');
    await waitBoxOpen(page);
    await send(page, host, 'PLAIN with the fresh session');
    await assertCleanPage(page, rec, con.origin);
  });
});

test('a revoked tab learns it is signed out, and a new tab replays the pending request and the last mode', { timeout: 120000 }, async () => {
  await withConsole({}, async ({ host, con, context }) => {
    const old = await openPage(context, con.url);
    await waitBoxOpen(old.page);
    await send(old.page, host, `ASKJSON ${JSON.stringify({ tool: 'Bash', description: 'List', input: { command: 'ls', description: 'List' } })}`);
    const asked = await nextRequest(host, 0);
    await cardFor(old.page, asked.request_id).waitFor();
    old.rec.answers.push('accept');
    await old.page.click('#auto-switch');
    await waitBadge(old.page, '確認なし（auto）');
    con.pressEnter();
    const fresh = await waitFor('a fresh URL at the terminal', () => con.urls()[1]);
    await old.page.click('#status-refresh');
    await waitFor('the revoked tab to show the gate', () => old.page.evaluate(() => !document.getElementById('gate').hidden));
    assert.match(await old.page.locator('#gate').textContent(), /無効/);
    assert.equal(await old.page.evaluate(() => sessionStorage.getItem('kairomone-console-session')), null, 'the revoked session is forgotten');
    assert.equal(await cardFor(old.page, asked.request_id).locator('button.allow').isDisabled(), true, 'the revoked tab cannot answer');

    const next = await openPage(context, fresh.url);
    await waitBadge(next.page, '確認なし（auto）');
    assert.equal(await next.page.isChecked('#auto-switch'), true, 'the new tab shows the last reported mode');
    const card = cardFor(next.page, asked.request_id);
    await card.waitFor();
    await card.locator('button.allow').click();
    const answer = await waitFor('the allow from the new tab', async () => (await answersFor(host, asked.request_id))[0]);
    assert.deepEqual(answer.response.response.updatedInput, { command: 'ls', description: 'List' });
    await assertCleanPage(old.page, old.rec, con.origin);
    await assertCleanPage(next.page, next.rec, con.origin);
  });
});

test('framing, cross-origin and rebound pages cannot use the console or spend its URL', { timeout: 120000 }, async () => {
  const host = await makeHost();
  let attacker;
  let context;
  try {
    const con = await startConsole(host);
    const html = `<!doctype html><meta charset="utf-8"><title>another origin</title>
<iframe id="frame" src="${con.url}"></iframe><iframe name="sink"></iframe>
<form id="post" method="POST" action="${con.origin}/stop" target="sink" enctype="text/plain"><input name='{"x":"' value='"}'></form>
<script>
window.__qa = {};
fetch('${con.origin}/events?after=0').then((r) => { __qa.events = r.status; }, () => { __qa.events = 'blocked'; });
fetch('${con.origin}/message', { method: 'POST', mode: 'no-cors', body: JSON.stringify({ text: 'PLAIN from another origin' }) })
  .then((r) => { __qa.message = r.type; }, () => { __qa.message = 'blocked'; });
navigator.sendBeacon('${con.origin}/message', JSON.stringify({ text: 'PLAIN by beacon' }));
document.getElementById('post').submit();
</script>`;
    attacker = await new Promise((resolve) => {
      const server = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); });
      server.listen(0, '127.0.0.1', () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` }));
    });
    const rebound = `http://rebind.test:${con.port}`;
    context = await newContext([con.origin, attacker.origin, rebound]);
    const all = [];
    context.on('request', (r) => all.push({ method: r.method(), url: r.url(), frame: r.frame()?.url() }));
    const evil = await openPage(context, `${attacker.origin}/`);
    await waitFor('the other-origin page to finish its attempts', () => evil.page.evaluate(() => window.__qa.events !== undefined && window.__qa.message !== undefined));
    await sleep(1500);
    assert.equal(all.filter((r) => r.method === 'POST' && r.url === `${con.origin}/session`).length, 0, 'a framed console runs no script and spends no bootstrap');
    for (const frame of evil.page.frames().filter((f) => f.url().startsWith(con.origin))) {
      assert.equal(await frame.evaluate(() => !!document.getElementById('mode-badge')).catch(() => false), false, 'the framed console never renders');
    }
    assert.deepEqual(await userLines(host), [], 'no message from another origin reaches the child');
    assert.equal(con.alive(), true, 'a cross-origin POST /stop is refused');

    const rebind = await openPage(context);
    const res = await rebind.page.goto(`${rebound}/#${con.bootstrap}`);
    assert.equal(res.status(), 403, 'a DNS-rebound name is refused');

    const { page, rec } = await openPage(context, con.url);
    await waitBadge(page, ASKING);
    assert.equal(rec.requests.filter((r) => r.bootstrap === con.bootstrap).length, 1);
    await waitBoxOpen(page);
    await assertCleanPage(page, rec, con.origin);
  } finally {
    if (context) await context.close().catch(() => {});
    if (attacker) attacker.server.close();
    await cleanupHost(host);
  }
});
