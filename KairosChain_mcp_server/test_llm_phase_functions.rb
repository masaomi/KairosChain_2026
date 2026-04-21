#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for LlmPhaseFunctions + UsageAccumulator + OodaCycleRunner integration.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'tmpdir'
require 'fileutils'

require 'kairos_mcp/daemon/llm_phase_functions'
require 'kairos_mcp/daemon/ooda_cycle_runner'
require 'kairos_mcp/daemon/active_observe'
require 'kairos_mcp/daemon/code_gen_act'
require 'kairos_mcp/daemon/code_gen_phase_handler'
require 'kairos_mcp/daemon/approval_gate'
require 'kairos_mcp/daemon/idempotent_chain_recorder'
require 'kairos_mcp/daemon/restricted_shell'
require 'kairos_mcp/daemon/execution_context'
require 'kairos_mcp/daemon/wal_phase_recorder'

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

LPF = KairosMcp::Daemon::LlmPhaseFunctions
UA  = LPF::UsageAccumulator
OCR = KairosMcp::Daemon::OodaCycleRunner
EC  = KairosMcp::Daemon::ExecutionContext

# ---------------------------------------------------------------------------
# UsageAccumulator
# ---------------------------------------------------------------------------

section 'UsageAccumulator'

assert('UA-1: starts at zero') do
  ua = UA.new
  ua.llm_calls == 0 && ua.input_tokens == 0 && ua.output_tokens == 0
end

assert('UA-2: record accumulates') do
  ua = UA.new
  ua.record({ input_tokens: 100, output_tokens: 50 })
  ua.record({ input_tokens: 200, output_tokens: 80 })
  ua.llm_calls == 2 && ua.input_tokens == 300 && ua.output_tokens == 130
end

assert('UA-3: to_h returns correct shape') do
  ua = UA.new
  ua.record({ input_tokens: 10, output_tokens: 5 })
  h = ua.to_h
  h[:llm_calls] == 1 && h[:input_tokens] == 10 && h[:output_tokens] == 5
end

assert('UA-4: reset! clears counters') do
  ua = UA.new
  ua.record({ input_tokens: 100, output_tokens: 50 })
  ua.reset!
  ua.llm_calls == 0 && ua.input_tokens == 0
end

assert('UA-5: handles string keys') do
  ua = UA.new
  ua.record({ 'input_tokens' => 100, 'output_tokens' => 50 })
  ua.input_tokens == 100
end

# ---------------------------------------------------------------------------
# LlmPhaseFunctions — with mock LLM caller
# ---------------------------------------------------------------------------

section 'LlmPhaseFunctions: orient_fn'

assert('LPF-1: orient_fn calls LLM and returns parsed JSON') do
  call_count = 0
  mock_llm = lambda do |messages:, system:, max_tokens:|
    call_count += 1
    {
      content: '{"summary":"site looks good","priorities":["update readme"],"risk_level":"low"}',
      input_tokens: 150,
      output_tokens: 40
    }
  end
  ua = UA.new
  fn = LPF.orient_fn(llm_caller: mock_llm, usage: ua)
  result = fn.call({ results: { chain_status: 'ok' }, relevant: {} },
                   { goal: 'maintain site' })

  result['summary'] == 'site looks good' &&
    result['priorities'] == ['update readme'] &&
    call_count == 1 &&
    ua.llm_calls == 1 &&
    ua.input_tokens == 150
end

assert('LPF-2: orient_fn handles malformed LLM response') do
  mock_llm = ->(**_) { { content: 'not json!!!', input_tokens: 10, output_tokens: 5 } }
  ua = UA.new
  fn = LPF.orient_fn(llm_caller: mock_llm, usage: ua)
  result = fn.call({}, { goal: 'test' })
  (result['summary'] || result[:summary]) == 'no orientation' && ua.llm_calls == 1
end

assert('LPF-3: orient_fn handles markdown-fenced JSON') do
  mock_llm = ->(**_) do
    { content: "```json\n{\"summary\":\"fenced\",\"priorities\":[],\"risk_level\":\"low\"}\n```",
      input_tokens: 20, output_tokens: 10 }
  end
  ua = UA.new
  fn = LPF.orient_fn(llm_caller: mock_llm, usage: ua)
  result = fn.call({}, { goal: 'test' })
  result['summary'] == 'fenced'
end

section 'LlmPhaseFunctions: decide_fn'

assert('LPF-4: decide_fn returns code_edit decision') do
  mock_llm = ->(**_) do
    { content: '{"action":"code_edit","target":"README.md","old_string":"old","new_string":"new","intent":"fix"}',
      input_tokens: 200, output_tokens: 60 }
  end
  ua = UA.new
  fn = LPF.decide_fn(llm_caller: mock_llm, usage: ua, workspace_root: '/tmp/ws')
  result = fn.call({ summary: 'update needed' }, { goal: 'maintain' })
  result[:action] == 'code_edit' && result[:target] == 'README.md' && ua.llm_calls == 1
end

assert('LPF-5: decide_fn returns noop on malformed response') do
  mock_llm = ->(**_) { { content: 'garbage', input_tokens: 10, output_tokens: 5 } }
  ua = UA.new
  fn = LPF.decide_fn(llm_caller: mock_llm, usage: ua, workspace_root: '/tmp')
  result = fn.call({}, { goal: 'test' })
  result[:action] == 'noop'
end

section 'LlmPhaseFunctions: reflect_fn'

assert('LPF-6: reflect_fn returns assessment') do
  mock_llm = ->(**_) do
    { content: '{"assessment":"success","lessons":["worked well"],"confidence":0.9}',
      input_tokens: 80, output_tokens: 20 }
  end
  ua = UA.new
  fn = LPF.reflect_fn(llm_caller: mock_llm, usage: ua)
  result = fn.call({ status: 'applied' }, { goal: 'test' })
  result['assessment'] == 'success' && result['confidence'] == 0.9
end

# ---------------------------------------------------------------------------
# Integration: OodaCycleRunner with UsageAccumulator
# ---------------------------------------------------------------------------

section 'OodaCycleRunner + UsageAccumulator integration'

class StubSafety
  attr_reader :overrides
  def initialize; @overrides = {}; end
  def push_policy_override(cap, &b); @overrides[cap] = b; end
  def pop_policy_override(cap); @overrides.delete(cap); end
  def current_user; 'daemon'; end
end

class StubWal
  def mark_executing(*); end
  def mark_completed(*); end
  def mark_failed(*); end
  def close; end
end

Dir.mktmpdir('lpf_integ') do |tmp|
  ws = File.join(tmp, 'site')
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'wal'))
  File.write(File.join(ws, 'README.md'), "# Test\n\nOld content here.\n")

  # Mock LLM that tracks calls
  total_calls = 0
  mock_llm = lambda do |messages:, system: nil, max_tokens: nil|
    total_calls += 1
    case total_calls
    when 1 # orient
      { content: '{"summary":"readme needs update","priorities":["fix readme"],"risk_level":"low"}',
        input_tokens: 150, output_tokens: 40 }
    when 2 # decide
      { content: '{"action":"code_edit","target":"README.md","old_string":"Old content here.","new_string":"Updated content.","intent":"refresh"}',
        input_tokens: 200, output_tokens: 60 }
    when 3 # reflect
      { content: '{"assessment":"success","lessons":[],"confidence":0.95}',
        input_tokens: 80, output_tokens: 20 }
    end
  end

  ua = UA.new
  safety = StubSafety.new
  invoker = ->(tool, args) { "stub" }
  gate = KairosMcp::Daemon::ApprovalGate.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  chain_tool = ->(_) { 'tx' }
  chain = KairosMcp::Daemon::IdempotentChainRecorder.new(
    chain_tool: chain_tool, ledger_path: File.join(ws, '.kairos', 'chain.json'))
  cga = KairosMcp::Daemon::CodeGenAct.new(
    workspace_root: ws, safety: safety, invoker: invoker,
    approval_gate: gate, chain_recorder: chain)
  handler = KairosMcp::Daemon::CodeGenPhaseHandler.new(code_gen_act: cga)

  runner = OCR.new(
    workspace_root: ws, safety: safety, invoker: invoker,
    active_observe: KairosMcp::Daemon::ActiveObserve.new,
    orient_fn: LPF.orient_fn(llm_caller: mock_llm, usage: ua),
    decide_fn: LPF.decide_fn(llm_caller: mock_llm, usage: ua, workspace_root: ws),
    reflect_fn: LPF.reflect_fn(llm_caller: mock_llm, usage: ua),
    code_gen_phase_handler: handler,
    chain_recorder: chain,
    shell: KairosMcp::Daemon::RestrictedShell.method(:run),
    wal_factory: ->(_) { StubWal.new },
    usage_accumulator: ua
  )

  mandate = {
    id: 'mandate_integ', cycles_completed: 0,
    observe_policies: %w[chain_status],
    allow_llm_upload: ['l2'],
    goal: 'maintain the test site'
  }

  EC.current_elevation_token = nil
  result = runner.call(mandate)

  assert('INTEG-1: cycle completes ok') do
    result[:status] == 'ok'
  end

  assert('INTEG-2: usage counters reflect 3 LLM calls') do
    result[:llm_calls] == 3
  end

  assert('INTEG-3: input_tokens accumulated') do
    result[:input_tokens] == 430  # 150 + 200 + 80
  end

  assert('INTEG-4: output_tokens accumulated') do
    result[:output_tokens] == 120  # 40 + 60 + 20
  end

  assert('INTEG-5: file actually changed') do
    File.read(File.join(ws, 'README.md')).include?('Updated content.')
  end

  assert('INTEG-6: all 5 phases executed') do
    result[:phases] == [:observe, :orient, :decide, :act, :reflect]
  end
end

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
