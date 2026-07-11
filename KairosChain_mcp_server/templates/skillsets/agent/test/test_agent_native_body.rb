#!/usr/bin/env ruby
# frozen_string_literal: true

# Slice 2 substitution probes (native body design v0.6 FROZEN, NB-6).
# The Slice 1 suite is substrate-neutral; THESE probes carry the slice's
# real proof. Every NB-6 bullet is exercised, adversarial case first:
#   closure tamper / closure escape / staged-work disjointness + merge
#   exclusion / driver-side intake refusal / tool-surface refusal (both
#   surfaces) / credential-absent-from-tool-env / egress shared-address +
#   redirect-hop + direct-socket / profile mismatch / excluded transport
#   (structural) / spend cutoff + missing usage + per-call overshoot (both
#   axes) / stub-model-driven discrimination on the REAL body loop.
# Usage: ruby test_agent_native_body.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'socket'
require 'rbconfig'

$LOAD_PATH.unshift File.expand_path('../../llm_client/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)

require_relative '../lib/agent/confinement'
require_relative '../lib/agent/staging'
require_relative '../lib/agent/mediator'
require_relative '../lib/agent/verdict'
require_relative '../lib/agent/native_body/spend_meter'
require_relative '../lib/agent/native_body/tool_layer'
require_relative '../lib/agent/native_body/model_client'

CONF = KairosMcp::SkillSets::Agent::Confinement
STAGING = KairosMcp::SkillSets::Agent::Staging
MEDIATOR = KairosMcp::SkillSets::Agent::Mediator
VERDICT = KairosMcp::SkillSets::Agent::Verdict
METER = KairosMcp::SkillSets::Agent::NativeBody::SpendMeter
TOOLS = KairosMcp::SkillSets::Agent::NativeBody::ToolLayer
MODEL = KairosMcp::SkillSets::Agent::NativeBody::ModelClient

$pass = 0
$fail = 0

def assert(description)
  result = yield
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "        #{e.backtrace.first(2).join("\n        ")}"
end

def assert_raises(description, klass)
  yield
  $fail += 1
  puts "  FAIL: #{description} (no exception raised)"
rescue klass
  $pass += 1
  puts "  PASS: #{description}"
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (wrong exception #{e.class}: #{e.message})"
end

darwin = RUBY_PLATFORM.include?('darwin') && system('which sandbox-exec > /dev/null 2>&1')

# Minimal scripted OpenAI-shape stub server (boundary-side, loopback).
# Each request pops the next scripted response; Connection: close per
# request so every hop through the mediator is a fresh, re-checked one.
class StubModelServer
  attr_reader :port, :requests

  def initialize(responses)
    @responses = responses
    @requests = []
    @mutex = Mutex.new
  end

  def start!
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |c| serve(c) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def stop!
    @server&.close
    @thread&.kill
  end

  private

  def serve(client)
    request_line = client.gets
    return client.close if request_line.nil?

    headers = {}
    while (line = client.gets)
      line = line.strip
      break if line.empty?

      k, v = line.split(':', 2)
      headers[k.to_s.downcase] = v.to_s.strip if k && v
    end
    body = headers['content-length'] ? client.read(headers['content-length'].to_i) : ''
    idx = @mutex.synchronize { @requests << { 'line' => request_line, 'body' => body }; @requests.size - 1 }
    payload = JSON.generate(@responses[idx] || @responses.last)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    client.close
  rescue StandardError
    client.close rescue nil
  end
end

def openai_tool_call_response(name, input)
  { 'choices' => [{ 'message' => {
      'content' => nil,
      'tool_calls' => [{ 'id' => 't1', 'type' => 'function',
                         'function' => { 'name' => name, 'arguments' => JSON.generate(input) } }]
    }, 'finish_reason' => 'tool_calls' }],
    'usage' => { 'prompt_tokens' => 50, 'completion_tokens' => 10 }, 'model' => 'stub-1' }
end

def openai_text_response(text, usage: { 'prompt_tokens' => 30, 'completion_tokens' => 5 })
  r = { 'choices' => [{ 'message' => { 'content' => text }, 'finish_reason' => 'stop' }],
        'model' => 'stub-1' }
  r['usage'] = usage if usage
  r
end

Dir.mktmpdir('nb_probe_root_') do |raw_root|
  root = File.realpath(raw_root)
  stores = File.join(root, '.kairos')
  FileUtils.mkdir_p(File.join(stores, 'storage'))
  File.write(File.join(stores, 'storage', 'secret.json'), '{"canary":"stores"}')

  scratch = File.realpath(Dir.mktmpdir('nb_probe_scratch_'))

  puts '== NB-2: closure staging, content-address pin, verify =='
  staged_root = Dir.mktmpdir('nb_probe_stage_')
  staged = STAGING.stage!(staged_root, scratch_dir: scratch, project_root: root)
  sha = staged['closure_sha256']
  assert('staging pins the whole closure with a 64-hex content address') { sha&.length == 64 }
  assert('pre-launch re-verification is green on an untampered closure') do
    STAGING.verify!(staged['staged_dir']) == sha
  end
  assert('closure is self-described: body, adapters, and vendored gems staged') do
    d = staged['staged_dir']
    File.file?(File.join(d, 'lib', 'native_body', 'main.rb')) &&
      File.file?(File.join(d, 'lib', 'llm_client', 'anthropic_adapter.rb')) &&
      File.directory?(File.join(d, 'vendor', 'faraday', 'lib'))
  end
  assert('NB-4 structural exclusion: no subprocess-CLI / bedrock / router code in the staged set') do
    d = File.join(staged['staged_dir'], 'lib', 'llm_client')
    %w[call_router.rb claude_code_adapter.rb codex_adapter.rb codex_mcp_adapter.rb
       cursor_adapter.rb bedrock_adapter.rb safe_subprocess.rb].none? { |f| File.exist?(File.join(d, f)) }
  end

  puts '== NB-2: closure tamper halts (guarded-failure branch) =='
  victim = File.join(staged['staged_dir'], 'lib', 'native_body', 'main.rb')
  File.chmod(0o644, victim)
  File.write(victim, "# tampered\n#{File.read(victim)}")
  assert_raises('a tampered closure refuses to verify (NB-2 halt)', STAGING::StagingError) do
    STAGING.verify!(staged['staged_dir'])
  end
  FileUtils.remove_entry(staged_root)

  puts '== NB-2: staged region geometry (disjointness) =='
  assert_raises('staging INTO the work area is refused', STAGING::StagingError) do
    inside = File.join(scratch, 'stage_inside')
    FileUtils.mkdir_p(inside)
    STAGING.assert_staged_geometry!(inside, scratch, root)
  end
  assert_raises('staging into the stores is refused', CONF::ConfinementError) do
    inside = File.join(stores, 'stage_sneaky')
    FileUtils.mkdir_p(inside)
    STAGING.assert_staged_geometry!(inside, scratch, root)
  end
  assert_raises('a work area inside the staged region is refused', STAGING::StagingError) do
    outer = File.realpath(Dir.mktmpdir('nb_probe_outer_'))
    inner = File.join(outer, 'work')
    FileUtils.mkdir_p(inner)
    STAGING.assert_staged_geometry!(outer, inner, root)
  end

  puts '== NB-2: merge exclusion — staged paths never enter the merge set =='
  restaged_root = Dir.mktmpdir('nb_probe_stage2_')
  restaged = STAGING.stage!(restaged_root, scratch_dir: scratch, project_root: root)
  File.write(File.join(scratch, 'produced.txt'), 'act output')
  manifest = CONF.manifest(scratch)
  assert('the manifest covers only work-area files (staged region is structurally outside)') do
    manifest == ['produced.txt']
  end
  assert_raises('a manifest entry escaping toward staged code is refused at merge', CONF::ConfinementError) do
    CONF.merge!(scratch, ["../#{File.basename(restaged['staged_dir'])}/lib/native_body/main.rb"], root)
  end

  puts '== NB-3: driver-side intake refusal (store handle / instance channel) =='
  clean = { 'task' => 'do a thing', 'context' => '', 'tools' => %w[Read],
            'model_config' => { 'provider' => 'anthropic' }, 'credential' => 'k' }
  assert('a clean value-only payload passes intake') { STAGING.validate_intake!(clean).equal?(clean) }
  assert_raises('a payload carrying stores_dir is refused pre-launch', STAGING::StagingError) do
    STAGING.validate_intake!(clean.merge('stores_dir' => stores))
  end
  assert_raises('a NESTED instance-channel grant is refused pre-launch', STAGING::StagingError) do
    STAGING.validate_intake!(clean.merge('context_values' => [{ 'mcp_endpoint' => 'unix:///x.sock' }]))
  end
  assert_raises('an invocation_context grant is refused pre-launch', STAGING::StagingError) do
    STAGING.validate_intake!(clean.merge('model_config' => { 'invocation_context' => {} }))
  end

  puts '== NB-4: excluded transports refused structurally, eligible pass =='
  %w[claude_code codex cursor codex_mcp bedrock].each do |p|
    assert_raises("provider #{p} refused before any act (driver-side gate)", STAGING::StagingError) do
      STAGING.assert_eligible_provider!(p)
    end
  end
  assert('eligible HTTP transports pass the gate') do
    %w[anthropic openai openrouter local].all? { |p| STAGING.assert_eligible_provider!(p) }
  end
  assert_raises('in-body transport gate mirrors the exclusion (no fallback path exists)', MODEL::TransportRefusal) do
    MODEL.new({ 'provider' => 'codex', 'api_key_env' => 'X' }, 'k', METER.new(max_spend_tokens: 10, max_steps: 1))
  end

  puts '== NB-2: closure escape — a load outside the pinned region raises =='
  ruby = RbConfig.ruby
  load_args = STAGING.load_path_args(restaged['staged_dir'])
  out, = Open3.capture2e(ruby, '--disable-gems', *load_args, '-e',
                         "require 'llm_client/anthropic_adapter'; require 'llm_client/openai_adapter'; puts 'CLOSURE_OK'")
  assert('the staged closure is self-contained (adapters + vendored faraday load in-closure)') do
    out.include?('CLOSURE_OK')
  end
  out2, st2 = Open3.capture2e(ruby, '--disable-gems', *load_args, '-e', "require 'llm_client/call_router'")
  assert('requiring non-staged code (the router with its fallback) fails inside the closure') do
    !st2.success? && out2.include?('cannot load such file')
  end
  out3, st3 = Open3.capture2e(ruby, '--disable-gems', '-I', File.join(restaged['staged_dir'], 'lib'), '-e', "require 'faraday'")
  assert('without the pinned vendor path a gem load escapes nowhere: LoadError, not ambient resolution') do
    !st3.success? && out3.include?('cannot load such file')
  end

  puts '== NB-3: tool layer is load-bearing for the granted surface =='
  work = File.realpath(Dir.mktmpdir('nb_probe_work_'))
  layer = TOOLS.new(work_dir: work, granted: %w[Read Write])
  layer.execute('Write', { 'path' => 'a/file.txt', 'content' => 'hello native' })
  assert('a granted tool executes into the work area') do
    File.read(File.join(work, 'a', 'file.txt')) == 'hello native'
  end
  assert_raises('an out-of-surface request is refused by the tool layer (NB-3)', TOOLS::SurfaceRefusal) do
    layer.execute('Edit', { 'path' => 'a/file.txt', 'old_string' => 'hello', 'new_string' => 'bye' })
  end
  assert('the refusal is recorded as a guarded property, not dropped') do
    layer.refused_requests == ['Edit']
  end
  assert_raises('an ungoverned grant (shell) is refused at construction', TOOLS::SurfaceRefusal) do
    TOOLS.new(work_dir: work, granted: %w[Read Bash])
  end
  assert_raises('an absolute path is refused in-layer', TOOLS::PathRefusal) do
    layer.execute('Write', { 'path' => '/etc/hosts', 'content' => 'x' })
  end
  assert_raises('a dot-dot escape is refused in-layer', TOOLS::PathRefusal) do
    layer.execute('Write', { 'path' => '../escape.txt', 'content' => 'x' })
  end
  File.symlink(root, File.join(work, 'link_out'))
  assert_raises('a symlink escape is refused in-layer (second surface is the substrate)', TOOLS::PathRefusal) do
    layer.execute('Write', { 'path' => 'link_out/smuggled.txt', 'content' => 'x' })
  end

  puts '== NB-5: spend meter — cumulative cutoff, missing usage, per-call bound (both axes) =='
  m = METER.new(max_spend_tokens: 1000, max_steps: 3)
  m.assert_call!(prompt_bytes: 400, max_output_tokens: 100)
  m.record_usage!(100, 100)
  assert('spend accumulates from returned usage') { m.remaining_tokens == 800 }
  assert_raises('cumulative cutoff halts at the configured bound', METER::CeilingHalt) do
    m.record_usage!(700, 200)
  end
  m2 = METER.new(max_spend_tokens: 1000, max_steps: 3)
  assert_raises('missing usage halts — never under-counts to zero (bypasses nil→0 coercion)', METER::CeilingHalt) do
    m2.record_usage!(nil, 5)
  end
  m3 = METER.new(max_spend_tokens: 500, max_steps: 3)
  assert_raises('per-call bound refuses a LARGE-PROMPT request pre-send (input axis)', METER::CeilingHalt) do
    m3.assert_call!(prompt_bytes: 40_000, max_output_tokens: 1)
  end
  assert_raises('per-call bound refuses a LARGE-OUTPUT request pre-send (output axis)', METER::CeilingHalt) do
    m3.assert_call!(prompt_bytes: 40, max_output_tokens: 4096)
  end
  m4 = METER.new(max_spend_tokens: 100, max_steps: 2)
  m4.step!
  m4.step!
  assert_raises('step ceiling halts the loop', METER::CeilingHalt) { m4.step! }
  assert_raises('a non-positive ceiling is refused fail-closed', ArgumentError) do
    METER.new(max_spend_tokens: 0, max_steps: 5)
  end

  puts '== NB-4: credential window — absent from the tool loop environment =='
  probe_env_var = 'NB_PROBE_API_KEY'
  ENV.delete(probe_env_var)
  meter = METER.new(max_spend_tokens: 10_000, max_steps: 5)
  client = MODEL.new({ 'provider' => 'local', 'api_key_env' => probe_env_var,
                       'base_url' => 'http://localhost:1', 'model' => 'stub', 'max_tokens' => 50 },
                     'secret-credential', meter)
  seen_during = nil
  stub_adapter = Object.new
  stub_adapter.define_singleton_method(:call) do |**_kw|
    seen_during = ENV[probe_env_var]
    { 'content' => 'ok', 'tool_use' => nil, 'input_tokens' => 5, 'output_tokens' => 5 }
  end
  client.instance_variable_set(:@adapter, stub_adapter)
  assert('credential is absent from the environment before any call') { ENV[probe_env_var].nil? }
  client.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
  assert('credential is present ONLY inside the adapter-call window') { seen_during == 'secret-credential' }
  assert('credential is removed from the environment after the window (tool surface sees nothing)') do
    ENV[probe_env_var].nil?
  end
  failing_adapter = Object.new
  failing_adapter.define_singleton_method(:call) { |**_kw| raise 'provider exploded' }
  client.instance_variable_set(:@adapter, failing_adapter)
  begin
    client.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
  rescue StandardError
    nil
  end
  assert('credential is removed even when the adapter raises (ensure path)') { ENV[probe_env_var].nil? }
  missing_usage_adapter = Object.new
  missing_usage_adapter.define_singleton_method(:call) do |**_kw|
    { 'content' => 'ok', 'tool_use' => nil, 'input_tokens' => nil, 'output_tokens' => nil }
  end
  client.instance_variable_set(:@adapter, missing_usage_adapter)
  assert_raises('a provider response without usage halts through the client path', METER::CeilingHalt) do
    client.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
  end

  puts '== NB-4: mediator — destination identity, per-hop re-decision =='
  target = TCPServer.new('127.0.0.1', 0)
  target_port = target.addr[1]
  Thread.new { loop { c = target.accept rescue break; c.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"); c.close } }
  med = MEDIATOR.new(allowed_hosts: ['localhost']).start!
  assert('identity decision is by hostname, exact and case-insensitive') do
    med.allowed_host?('LOCALHOST') && !med.allowed_host?('evil.example.com')
  end
  assert('shared-address probe: a non-provider NAME at the provider ADDRESS is refused (address-only would pass falsely)') do
    # 127.0.0.1 reaches the same machine as "localhost" — but it is not the
    # curated destination identity, so the hop is refused.
    !med.allowed_host?('127.0.0.1')
  end
  connect_via = lambda do |host|
    s = TCPSocket.new('127.0.0.1', med.port)
    s.write("CONNECT #{host}:#{target_port} HTTP/1.1\r\nHost: #{host}:#{target_port}\r\n\r\n")
    line = s.gets
    s.close
    line
  end
  assert('CONNECT to the provider destination is tunneled (200)') { connect_via.call('localhost').include?('200') }
  assert('CONNECT to a non-provider host at the same address is refused (403)') { connect_via.call('127.0.0.1').include?('403') }
  get_via = lambda do |url|
    s = TCPSocket.new('127.0.0.1', med.port)
    s.write("GET #{url} HTTP/1.1\r\nHost: #{URI.parse(url).host}\r\nConnection: close\r\n\r\n")
    line = s.gets
    s.close rescue nil
    line
  end
  assert('redirect-hop probe: a legitimate first hop does not whitelist the connection — the NEXT hop is re-decided and refused') do
    first = get_via.call("http://localhost:#{target_port}/v1/x")
    second = get_via.call('http://evil.example.com/steal')
    first.include?('200') && second.include?('403')
  end
  assert('refusals are observable boundary-side (for the record)') do
    med.refusals.include?('127.0.0.1') && med.refusals.include?('evil.example.com')
  end
  med.stop!
  target.close

  puts '== NB-5: substrate→profile binding (profile mismatch refused) =='
  legacy = CONF.profile(scratch, stores)
  native = CONF.native_body_profile(scratch, stores, 54_321)
  assert('the legacy default-allow profile is NOT egress-scoped') { !CONF.egress_scoped?(legacy) }
  assert('the native profile is egress-scoped (deny network* + loopback-only allow)') { CONF.egress_scoped?(native) }
  assert_raises('launching the native body under the legacy profile is refused before any act', CONF::ConfinementError) do
    CONF.assert_native_profile!(legacy)
  end
  assert_raises('a port outside range fails closed', CONF::ConfinementError) do
    CONF.native_body_profile(scratch, stores, 0)
  end
  assert('wrap_native asserts the profile then wraps') do
    CONF.wrap_native(['/bin/echo', 'x'], scratch, stores, 54_321).first == 'sandbox-exec'
  end

  puts '== Driver contract: parse mapping, native env, host scope, config gate =='
  require 'kairos_mcp/tools/base_tool'
  require_relative '../tools/agent_execute'
  drv = KairosMcp::SkillSets::Agent::Tools::AgentExecute.allocate
  pn = ->(h) { drv.send(:parse_native_output, "#{JSON.generate(h)}\n") }
  assert('body "completed" maps to driver ok') { pn.call('status' => 'completed', 'summary' => 's')['status'] == 'ok' }
  assert('body "guard_failure" maps to guard_halt (halts the loop, AGT-6)') do
    r = pn.call('status' => 'guard_failure', 'halt_reason' => 'closure escape')
    r['status'] == 'guard_halt' && r['error'].include?('closure escape')
  end
  assert('body "halted_ceiling" is a non-success outcome, never silent truncation into success') do
    r = pn.call('status' => 'halted_ceiling', 'halt_reason' => 'spend')
    r['status'] == 'halted_ceiling' && r['is_error'] == true
  end
  assert('garbage body output maps to no_result (fail-closed)') do
    drv.send(:parse_native_output, 'not json at all')['status'] == 'no_result'
  end
  env_probe_key = 'ANTHROPIC_API_KEY'
  had = ENV.key?(env_probe_key)
  ENV[env_probe_key] = 'x' unless had
  nenv = drv.send(:build_native_env, 'http://127.0.0.1:9')
  assert('native env carries no provider credential (NB-4: absent from the tool loop env)') do
    nenv.keys.none? { |k| k.include?('API_KEY') || k.include?('AWS') }
  end
  assert('native env routes egress through the mediator proxy') do
    nenv['https_proxy'] == 'http://127.0.0.1:9' && nenv['http_proxy'] == 'http://127.0.0.1:9'
  end
  ENV.delete(env_probe_key) unless had
  assert('egress scope derives from the curated provider + base_url identity') do
    hosts = drv.send(:allowed_hosts_for, 'local', { 'base_url' => 'http://stub.test:9999' })
    hosts.include?('stub.test')
  end
  drv.instance_variable_set(:@_agent_yml_cache,
                            { 'agent_execute' => { 'substrate' => 'native_body' } })
  assert_raises('substrate native_body without a curated model config fails closed', CONF::ConfinementError) do
    drv.send(:native_body_config)
  end
  drv2 = KairosMcp::SkillSets::Agent::Tools::AgentExecute.allocate
  drv2.instance_variable_set(:@_agent_yml_cache,
                             { 'guard' => { 'enabled' => false },
                               'agent_execute' => { 'substrate' => 'native_body',
                                                    'native_body' => { 'provider' => 'anthropic' } } })
  resp = drv2.call({ 'task' => 'probe' })
  parsed = JSON.parse(resp.first[:text] || resp.first['text'])
  assert('substrate native_body + guard off → guard_halt (unconfined native launch refused, NB-5)') do
    parsed['status'] == 'guard_halt' && parsed['error'].include?('egress-scoped')
  end

  puts '== R1/R2 regression: findings closed by implementation review =='
  # F1 (R1) + G1 (R2) — the per-call input estimate must be a true UPPER
  # bound on real tokens. R2 showed chars is NOT one for byte-level BPE
  # (a CJK glyph is 3 bytes and can be 2+ tokens); the sound bound is the
  # BYTE length (num_tokens <= num_bytes). Callers pass bytesize.
  mf1 = METER.new(max_spend_tokens: 400, max_steps: 5)
  jp = '系統的な自己言及性' * 60   # 540 chars, 1620 bytes
  assert('G1: input estimate is a true upper bound on the BYTE length (not chars)') do
    mf1.estimate_input_tokens(jp.bytesize) >= jp.bytesize && jp.bytesize > jp.length
  end
  assert_raises('F1/G1: a multibyte prompt is refused pre-send on its byte size (input-axis overshoot closed)', METER::CeilingHalt) do
    mf1.assert_call!(prompt_bytes: jp.bytesize, max_output_tokens: 1)
  end
  # G1 sharper: a CJK prompt whose CHAR count fits the budget but whose BYTE
  # count does not must still be refused (the exact chars-vs-bytes gap R2 hit).
  mg1 = METER.new(max_spend_tokens: 300, max_steps: 5)
  cjk = 'あ' * 200   # 200 chars, 600 bytes
  assert_raises('G1: a prompt whose char-count fits but byte-count does not is refused', METER::CeilingHalt) do
    mg1.assert_call!(prompt_bytes: cjk.bytesize, max_output_tokens: 1)
  end
  # G3 — the estimate is driven by the SAME payload shape actually sent
  # (provider tool-schema envelope), via model_client. Confirm a client call
  # meters on bytes of the sent shape by observing the pre-send refusal for a
  # tiny budget with a real (stubbed) adapter.
  mg3 = METER.new(max_spend_tokens: 5, max_steps: 3)
  g3_client = MODEL.new({ 'provider' => 'local', 'api_key_env' => 'G3_KEY',
                          'base_url' => 'http://localhost:1', 'model' => 'stub', 'max_tokens' => 1 },
                        'k', mg3)
  g3_reached = true
  g3_stub = Object.new
  g3_stub.define_singleton_method(:call) { |**_kw| g3_reached = false; { 'content' => 'x', 'tool_use' => nil, 'input_tokens' => 1, 'output_tokens' => 1 } }
  g3_client.instance_variable_set(:@adapter, g3_stub)
  begin
    g3_client.call(messages: [{ 'role' => 'user', 'content' => 'a fairly long user message that exceeds five bytes' }])
  rescue METER::CeilingHalt
    nil
  end
  assert('G3: the pre-send byte estimate refuses before the adapter is ever called') { g3_reached }

  # F2 — a planted symlink must break the pin (not be silently dropped), so
  # verify! cannot report an escaped closure as unchanged.
  f2_root = Dir.mktmpdir('f2_stage_')
  f2 = STAGING.stage!(f2_root, scratch_dir: scratch, project_root: root)
  File.symlink('/tmp/nonexistent_evil.rb', File.join(f2['staged_dir'], 'lib', 'faraday.rb'))
  assert_raises('F2: a symlink in the staged closure makes verify! halt (closure-escape closed)', STAGING::StagingError) do
    STAGING.verify!(f2['staged_dir'])
  end
  FileUtils.remove_entry(f2_root)

  # F3 — Glob must not enumerate names through a symlinked directory.
  f3_work = File.realpath(Dir.mktmpdir('f3_work_'))
  f3_out = File.realpath(Dir.mktmpdir('f3_out_'))
  File.write(File.join(f3_out, 'secret.txt'), 'outside')
  File.symlink(f3_out, File.join(f3_work, 'link_out'))
  f3_layer = TOOLS.new(work_dir: f3_work, granted: %w[Glob Grep])
  assert('F3: Glob does not enumerate files through a symlinked directory') do
    f3_layer.execute('Glob', { 'pattern' => 'link_out/*' })['matches'].empty?
  end

  # F4 — egress_scoped? must reject broad-network profiles, not only
  # non-loopback remote-ip ones.
  base_deny = "(version 1)\n(deny network*)\n"
  assert('F4: (allow network*) is rejected') { !CONF.egress_scoped?(base_deny + '(allow network*)') }
  assert('F4: unfiltered (allow network-outbound) is rejected') do
    !CONF.egress_scoped?(base_deny + '(allow network-outbound)')
  end
  assert('F4: (remote host ...) allow is rejected') do
    !CONF.egress_scoped?(base_deny + '(allow network-outbound (remote host "evil.com"))')
  end
  assert('F4: a genuine loopback-only allow still passes') do
    CONF.egress_scoped?(base_deny + '(allow network-outbound (remote ip "localhost:5000"))')
  end
  # G2 (R2) — the predicate must be format-independent: a broad allow clause
  # spanning multiple lines, or two clauses sharing one line, must NOT slip
  # past a line-based scan.
  assert('G2: a MULTI-LINE broad (remote host) allow is rejected even beside a loopback allow') do
    !CONF.egress_scoped?(base_deny +
      "(allow network-outbound\n  (remote host \"evil.example\")\n)\n" \
      "(allow network-outbound (remote ip \"localhost:5000\"))")
  end
  assert('G2: two clauses on ONE line (loopback + unfiltered broad) are rejected') do
    !CONF.egress_scoped?(base_deny +
      '(allow network-outbound (remote ip "localhost:5000")) (allow network-outbound)')
  end
  assert('G2: a real multi-line loopback-only profile still passes') do
    CONF.egress_scoped?(base_deny + "(allow network-outbound\n  (remote ip \"localhost:5000\")\n)")
  end
  # G2-WS (R3) — whitespace between "(" and "allow" is legal SBPL, so a broad
  # "( allow network ...)" must NOT slip past the scan (sandbox-exec would
  # honor it — no backstop).
  assert('G2-WS: "( allow network-outbound (remote host ...))" with space after paren is rejected') do
    !CONF.egress_scoped?(base_deny +
      '( allow network-outbound (remote host "evil.example")) (allow network-outbound (remote ip "localhost:5000"))')
  end
  assert('G2-WS: a nested broad allow inside a loopback clause is rejected (self-sound predicate)') do
    !CONF.egress_scoped?(base_deny +
      '(allow network-outbound (remote ip "localhost:5000") (allow network*))')
  end
  assert('G2-WS: whitespace-tolerant loopback profile still passes') do
    CONF.egress_scoped?(base_deny + "( allow  network-outbound  ( remote  ip  \"localhost:5000\" ) )")
  end

  # F6 — a native pre-launch guard failure (empty egress scope for a local
  # provider with no base_url) must surface as guard_halt, not a plain error.
  drv_f6 = KairosMcp::SkillSets::Agent::Tools::AgentExecute.allocate
  drv_f6.instance_variable_set(:@_agent_yml_cache,
                               { 'guard' => { 'enabled' => true },
                                 'agent_execute' => { 'substrate' => 'native_body',
                                                      'native_body' => { 'provider' => 'local',
                                                                         'model' => 'm', 'api_key_env' => 'X' } } })
  f6_parsed = JSON.parse(drv_f6.call({ 'task' => 'probe' }).first[:text] || drv_f6.call({ 'task' => 'probe' }).first['text'])
  assert('F6: native empty-egress-scope prelaunch failure is a guard_halt, not act error') do
    f6_parsed['status'] == 'guard_halt' && f6_parsed['error'].to_s.include?('egress scope is empty')
  end
  # G4 (R2) — a malformed base_url is the same class of pre-launch failure and
  # must also be a guard_halt (URI::InvalidURIError → ConfinementError), not a
  # bare act error the driver would treat as an ordinary failure.
  drv_g4 = KairosMcp::SkillSets::Agent::Tools::AgentExecute.allocate
  drv_g4.instance_variable_set(:@_agent_yml_cache,
                               { 'guard' => { 'enabled' => true },
                                 'agent_execute' => { 'substrate' => 'native_body',
                                                      'native_body' => { 'provider' => 'local', 'model' => 'm',
                                                                         'api_key_env' => 'X',
                                                                         'base_url' => 'http://bad host with spaces' } } })
  g4_parsed = JSON.parse(drv_g4.call({ 'task' => 'probe' }).first[:text] || drv_g4.call({ 'task' => 'probe' }).first['text'])
  assert('G4: a malformed native base_url surfaces as guard_halt, not act error') do
    g4_parsed['status'] == 'guard_halt' && g4_parsed['error'].to_s.include?('base_url')
  end

  # F7 — the per-cycle constitutive record must PERSIST which executable
  # carried the act (closure digest + spec hash + substrate), not drop it with
  # the in-memory result Hash. Exercise the real persistence path:
  # session.save_progress writing progress.jsonl.
  require 'kairos_mcp/invocation_context'
  require_relative '../lib/agent/session'
  f7_store = File.realpath(Dir.mktmpdir('f7_store_'))
  f7_autonomos = Module.new do
    define_singleton_method(:storage_path) do |subpath|
      p = File.join(f7_store, subpath)
      FileUtils.mkdir_p(p)
      p
    end
  end
  Object.const_set(:Autonomos, f7_autonomos) unless defined?(Autonomos)
  f7_session = KairosMcp::SkillSets::Agent::Session.new(
    session_id: 'f7_sess', mandate_id: 'm', goal_name: 'g',
    invocation_context: KairosMcp::InvocationContext.new, config: { 'guard' => { 'enabled' => true } }
  )
  guard_record = { 'substrate' => 'native_body', 'closure_sha256' => 'a' * 64, 'spec_sha256' => 'b' * 64 }
  f7_session.save_progress({ 'confidence' => 0.9 }, 1, 'completed', 'do', guard_record: guard_record)
  f7_persisted = JSON.parse(File.readlines(File.join(f7_session.guard_dir, 'progress.jsonl')).last)
  assert('F7: the persisted cycle record names the executable (closure_sha256 + spec_sha256 + substrate)') do
    f7_persisted['guard_record'] == guard_record
  end
  assert('F7: a CLI-substrate cycle omits the closure field but records substrate (no false native claim)') do
    cli_rec = { 'substrate' => 'cli' }
    f7_session.save_progress({ 'confidence' => 0.9 }, 2, 'completed', 'do', guard_record: cli_rec)
    last = JSON.parse(File.readlines(File.join(f7_session.guard_dir, 'progress.jsonl')).last)
    last['guard_record'] == cli_rec && !last['guard_record'].key?('closure_sha256')
  end

  unless darwin
    puts "\n(live confined probes skipped: sandbox-exec unavailable)"
    puts "\n#{$pass} passed, #{$fail} failed"
    exit($fail.zero? ? 0 : 1)
  end

  puts '== F5 (LIVE): plain-HTTP pipelining — 2nd request never reaches upstream =='
  f5_seen = []
  f5_up = TCPServer.new('127.0.0.1', 0)
  f5_port = f5_up.addr[1]
  f5_thread = Thread.new do
    loop do
      c = f5_up.accept rescue break
      Thread.new(c) do |s|
        while (line = s.gets)
          f5_seen << line.strip if line.start_with?('GET', 'POST')
        end
        s.close rescue nil
      end
    end
  end
  f5_med = MEDIATOR.new(allowed_hosts: ['localhost']).start!
  f5_client = TCPSocket.new('127.0.0.1', f5_med.port)
  # Two pipelined plain-HTTP requests in one segment: first allowed, second to
  # a non-provider host smuggled behind it.
  f5_client.write("GET http://localhost:#{f5_port}/one HTTP/1.1\r\nHost: localhost:#{f5_port}\r\n\r\n" \
                  "GET http://evil.example.com/two HTTP/1.1\r\nHost: evil.example.com\r\n\r\n")
  sleep 0.4
  f5_client.close rescue nil
  f5_med.stop!
  f5_up.close
  assert('F5: the smuggled 2nd pipelined request never reached the approved upstream') do
    f5_seen.none? { |l| l.include?('evil.example.com') || l.include?('/two') }
  end

  puts '== LIVE: direct-socket egress refused; mediator port is the sole path =='
  live_target = TCPServer.new('127.0.0.1', 0)
  live_port = live_target.addr[1]
  Thread.new { loop { c = live_target.accept rescue break; c.close } }
  med2 = MEDIATOR.new(allowed_hosts: ['localhost']).start!
  nprof = CONF.native_body_profile(scratch, stores, med2.port)
  ok_med = system('sandbox-exec', '-p', nprof, ruby, '--disable-gems', '-rsocket', '-e',
                  "TCPSocket.new('127.0.0.1', #{med2.port}).close")
  denied_direct = !system('sandbox-exec', '-p', nprof, ruby, '--disable-gems', '-rsocket', '-e',
                          "TCPSocket.new('127.0.0.1', #{live_port}).close", err: File::NULL)
  assert('confined body can reach the mediator port') { ok_med }
  assert('confined body CANNOT open a direct, un-mediated socket (refused by the substrate)') { denied_direct }
  med2.stop!
  live_target.close

  puts '== LIVE: real body loop, stub model — discrimination + guard geometry =='
  session_dir = Dir.mktmpdir('nb_probe_session_')
  VERDICT.pin!(session_dir, {
                 'acceptance' => [
                   { 'type' => 'file_exists', 'path' => 'out/report.txt' },
                   { 'type' => 'file_contains', 'path' => 'out/report.txt', 'substring' => 'COMPLETE' }
                 ],
                 'layer_surface' => []
               })

  run_body = lambda do |scripted, ceilings: {}, tools: %w[Read Write], granted_extra: nil|
    work = File.realpath(Dir.mktmpdir('nb_live_work_'))
    stage_tmp = Dir.mktmpdir('nb_live_stage_')
    st = STAGING.stage!(stage_tmp, scratch_dir: work, project_root: root)
    STAGING.verify!(st['staged_dir'])
    stub = StubModelServer.new(scripted).start!
    med = MEDIATOR.new(allowed_hosts: ['localhost']).start!
    payload = {
      'task' => 'Write out/report.txt reporting the work result, then summarize.',
      'context' => '',
      'tools' => granted_extra || tools,
      'ceilings' => { 'max_steps' => 8, 'max_spend_tokens' => 100_000, 'max_wall_seconds' => 30 }.merge(ceilings),
      'model_config' => { 'provider' => 'local', 'model' => 'stub-1',
                          'api_key_env' => 'NB_LIVE_STUB_KEY',
                          'base_url' => "http://localhost:#{stub.port}",
                          'proxy' => med.proxy_url,
                          'max_tokens' => 64, 'timeout_seconds' => 20 },
      'credential' => 'stub-credential',
      'work_dir' => work
    }
    STAGING.validate_intake!(payload)
    env = { 'PATH' => ENV['PATH'], 'HOME' => ENV['HOME'],
            'http_proxy' => med.proxy_url, 'https_proxy' => med.proxy_url }
    cmd = CONF.wrap_native([ruby, '--disable-gems', *STAGING.load_path_args(st['staged_dir']),
                            STAGING.body_entrypoint(st['staged_dir'])],
                           work, stores, med.port)
    out, err, status = Open3.capture3(env, *cmd, stdin_data: JSON.generate(payload), chdir: work)
    report = begin
      JSON.parse(out.lines.map(&:strip).reject(&:empty?).last.to_s)
    rescue StandardError
      nil
    end
    { 'work' => work, 'report' => report, 'exit' => status.exitstatus, 'stderr' => err,
      'stub_requests' => stub.requests.size, 'refusals' => med.refusals.dup }
  ensure
    stub&.stop!
    med&.stop!
    FileUtils.remove_entry(stage_tmp) if stage_tmp && Dir.exist?(stage_tmp)
  end

  # (1) Non-conforming act on the REAL loop: dispatch → tool layer →
  # work-area effect → manifest → FAILING mechanical verdict.
  r1 = run_body.call([
                       openai_tool_call_response('Write', { 'path' => 'out/report.txt', 'content' => 'work FAILED' }),
                       openai_text_response('done')
                     ])
  assert('body ran the real loop through the stub model (2 hops, both mediated)') do
    r1['report'] && r1['report']['status'] == 'completed' && r1['stub_requests'] == 2
  end
  assert('tool effect landed in the work area via the tool layer') do
    File.read(File.join(r1['work'], 'out', 'report.txt')) == 'work FAILED'
  end
  assert('body reports spend from returned usage (in-body metering live)') do
    r1['report']['spend'] && r1['report']['spend']['total_tokens'].positive?
  end
  v_fail = VERDICT.judge(session_dir, { 'scratch_dir' => r1['work'],
                                        'manifest' => CONF.manifest(r1['work']),
                                        'execution_summary' => 'completed' })
  assert('DISCRIMINATION: the non-conforming native-body act FAILS the mechanical verdict') do
    v_fail['verdict'] == VERDICT::FAIL
  end

  # (2) Conforming act PASSes and merges — the AGT-1 return path unchanged.
  r2 = run_body.call([
                       openai_tool_call_response('Write', { 'path' => 'out/report.txt', 'content' => 'work COMPLETE' }),
                       openai_text_response('done')
                     ])
  v_pass = VERDICT.judge(session_dir, { 'scratch_dir' => r2['work'],
                                        'manifest' => CONF.manifest(r2['work']),
                                        'execution_summary' => 'completed' })
  assert('the conforming native-body act PASSes the same pinned spec') { v_pass['verdict'] == VERDICT::PASS }
  assert('PASS results merge into the live tree through the driver, never the body') do
    written = CONF.merge!(r2['work'], CONF.manifest(r2['work']), root)
    written.any? && File.read(File.join(root, 'out', 'report.txt')).include?('COMPLETE')
  end

  # (3) Tool-surface refusal on the real loop: the stub proposes a
  # non-granted tool; the layer refuses; nothing executes.
  r3 = run_body.call([
                       openai_tool_call_response('Bash', { 'command' => 'rm -rf /' }),
                       openai_text_response('ok I will stop')
                     ], granted_extra: %w[Read Write])
  assert('an out-of-surface proposal is refused by the tool layer on the live loop') do
    r3['report'] && r3['report']['refused_tool_requests'] == ['Bash']
  end
  assert('the refused proposal had no effect and the loop continued to completion') do
    r3['report']['status'] == 'completed' && Dir.glob(File.join(r3['work'], '**/*')).empty?
  end

  # (4) Per-call spend bound pre-send: with a tiny budget the request is
  # refused BEFORE it reaches the provider (stub sees zero requests).
  r4 = run_body.call([openai_text_response('never reached')],
                     ceilings: { 'max_spend_tokens' => 50 })
  assert('per-call overshoot halts pre-send: ceiling exit, zero provider requests') do
    r4['exit'] == 3 && r4['report']['status'] == 'halted_ceiling' &&
      r4['report']['halt_reason'].include?('per_call_overshoot') && r4['stub_requests'].zero?
  end

  # (5) Missing usage halts live (fail-closed metering).
  r5 = run_body.call([openai_text_response('no usage here', usage: nil)])
  assert('a response without usage data halts the loop (unmeasurable spend)') do
    r5['exit'] == 3 && r5['report']['halt_reason'].include?('missing_usage')
  end

  # (6) Credential absent from the process env the tool loop runs under.
  r6_env = { 'PATH' => ENV['PATH'], 'HOME' => ENV['HOME'] }
  out6, = Open3.capture2(r6_env, 'sandbox-exec', '-p', CONF.native_body_profile(scratch, stores, 54_321),
                         ruby, '--disable-gems', '-e', "print ENV['NB_LIVE_STUB_KEY'].inspect")
  assert('LIVE: the launched process environment never contains the credential') { out6 == 'nil' }

  FileUtils.remove_entry(session_dir)
  FileUtils.remove_entry(restaged_root) if Dir.exist?(restaged_root)
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
