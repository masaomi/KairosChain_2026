#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.2 M5-M7 — ProposalRoutes, CodeGenPhaseHandler, IdempotentChainRecorder tests.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'digest'

require 'kairos_mcp/daemon/proposal_routes'
require 'kairos_mcp/daemon/code_gen_phase_handler'
require 'kairos_mcp/daemon/idempotent_chain_recorder'
require 'kairos_mcp/daemon/approval_gate'
require 'kairos_mcp/daemon/code_gen_act'
require 'kairos_mcp/daemon/execution_context'

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

AG  = KairosMcp::Daemon::ApprovalGate
CGA = KairosMcp::Daemon::CodeGenAct
CGH = KairosMcp::Daemon::CodeGenPhaseHandler
ICR = KairosMcp::Daemon::IdempotentChainRecorder
PR  = KairosMcp::Daemon::ProposalRoutes
EC  = KairosMcp::Daemon::ExecutionContext

# Stubs
class StubSafety
  attr_reader :overrides
  def initialize; @overrides = {}; end
  def push_policy_override(cap, &b); raise "dup #{cap}" if @overrides[cap]; @overrides[cap] = b; end
  def pop_policy_override(cap); @overrides.delete(cap); end
  def can_modify_l0?; check(:can_modify_l0); end
  def can_modify_l1?; check(:can_modify_l1); end
  def current_user; 'kairos_daemon'; end
  private
  def check(cap); @overrides[cap]&.call(current_user) || false; end
end

class StubMailbox
  attr_reader :commands
  def initialize; @commands = []; end
  def enqueue(type, **kwargs)
    id = "cmd_#{@commands.size + 1}"
    @commands << { type: type, id: id, **kwargs }
    id
  end
end

class StubRequest
  attr_accessor :path, :request_method, :body
  def initialize(method:, path:, body: nil, token: 'valid_token')
    @request_method = method
    @path = path
    @body = body
    @headers = { 'Authorization' => "Bearer #{token}" }
  end
  def [](key)
    @headers[key]
  end
end

class StubResponse
  attr_accessor :status, :body
  def initialize; @headers = {}; @status = 200; @body = ''; end
  def []=(key, val); @headers[key] = val; end
  def [](key); @headers[key]; end
  def parsed_body; JSON.parse(@body); end
end

# ---------------------------------------------------------------------------
# M5: ProposalRoutes
# ---------------------------------------------------------------------------

section 'ProposalRoutes: dispatch'

Dir.mktmpdir('pr_test') do |dir|
  gate = AG.new(dir: dir)
  mailbox = StubMailbox.new
  auth = ->(req, res) do
    token = req['Authorization']&.sub('Bearer ', '')
    if token == 'valid_token'
      true
    else
      res.status = 401
      res.body = '{"error":"unauthorized"}'
      false
    end
  end

  handler = PR::Handler.new(approval_gate: gate, mailbox: mailbox, auth: auth)

  # Stage a proposal
  gate.stage({ proposal_id: 'prop_1', target: { path: 'test.md' },
               scope: { scope: :l1, auto_approve: false } })

  assert('I8: GET /v1/proposals returns pending proposals') do
    req = StubRequest.new(method: 'GET', path: '/v1/proposals')
    res = StubResponse.new
    handler.dispatch(req, res)
    body = res.parsed_body
    body['count'] == 1 && body['proposals'].is_a?(Array)
  end

  assert('I9: GET /v1/proposals/:id returns proposal with diff') do
    req = StubRequest.new(method: 'GET', path: '/v1/proposals/prop_1')
    res = StubResponse.new
    handler.dispatch(req, res)
    body = res.parsed_body
    body['proposal_id'] == 'prop_1' && body['current_status'] == 'pending'
  end

  assert('I10: POST /v1/proposals/:id/approve enqueues command') do
    req = StubRequest.new(method: 'POST', path: '/v1/proposals/prop_1/approve',
                          body: '{"reviewer":"masa","reason":"looks good"}')
    res = StubResponse.new
    handler.dispatch(req, res)
    body = res.parsed_body
    body['enqueued'] == true &&
      body['decision'] == 'approve' &&
      mailbox.commands.last[:type] == :approve_proposal &&
      mailbox.commands.last[:reviewer] == 'masa'
  end

  assert('I10b: POST /v1/proposals/:id/reject enqueues reject') do
    req = StubRequest.new(method: 'POST', path: '/v1/proposals/prop_1/reject',
                          body: '{"reviewer":"masa","reason":"not now"}')
    res = StubResponse.new
    handler.dispatch(req, res)
    body = res.parsed_body
    body['decision'] == 'reject' &&
      mailbox.commands.last[:type] == :reject_proposal
  end

  assert('I11: unauthenticated request returns 401') do
    req = StubRequest.new(method: 'GET', path: '/v1/proposals', token: 'bad')
    res = StubResponse.new
    handler.dispatch(req, res)
    res.status == 401
  end

  assert('I12: unknown path returns 404') do
    req = StubRequest.new(method: 'GET', path: '/v1/proposals/x/y/z')
    res = StubResponse.new
    handler.dispatch(req, res)
    res.status == 404
  end

  assert('I12b: unsupported method returns 405') do
    req = StubRequest.new(method: 'DELETE', path: '/v1/proposals/prop_1')
    res = StubResponse.new
    handler.dispatch(req, res)
    res.status == 405
  end
end

# ---------------------------------------------------------------------------
# M6: CodeGenPhaseHandler
# ---------------------------------------------------------------------------

section 'CodeGenPhaseHandler: pause and resume'

Dir.mktmpdir('cgh_test') do |ws|
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))

  path = File.join(ws, '.kairos', 'knowledge', 'test.md')
  File.write(path, "old text\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                 approval_gate: gate)
  handler = CGH.new(code_gen_act: cga)

  decision = { action: 'code_edit', target: '.kairos/knowledge/test.md',
               old_string: 'old text', new_string: 'new text' }
  mandate = { id: 'mandate_1', allow_llm_upload: %w[l1 l2] }

  assert('M6-1: handle_act returns paused for L1') do
    EC.current_elevation_token = nil
    result = handler.handle_act(decision, mandate)
    result[:status] == CGH::PAUSED_STATUS && result[:proposal_id].start_with?('prop_')
  end

  assert('M6-2: handler.paused? is true') do
    handler.paused?
  end

  assert('M6-3: resume_if_pending returns :still_pending when not approved') do
    EC.current_elevation_token = nil
    handler.resume_if_pending == :still_pending
  end

  # Approve
  gate.record_decision(handler.pending_proposal_id, decision: 'approve', reviewer: 'masa')

  assert('M6-4: resume_if_pending returns applied after approval') do
    EC.current_elevation_token = nil
    result = handler.resume_if_pending
    result.is_a?(Hash) && result[:status] == 'applied'
  end

  assert('M6-5: handler.paused? is false after resume') do
    !handler.paused?
  end

  assert('M6-6: file was changed') do
    File.read(path) == "new text\n"
  end
end

section 'CodeGenPhaseHandler: L2 auto-approve (no pause)'

Dir.mktmpdir('cgh_test') do |ws|
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))

  path = File.join(ws, '.kairos', 'context', 'notes.md')
  File.write(path, "hello\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                 approval_gate: gate)
  handler = CGH.new(code_gen_act: cga)

  decision = { action: 'code_edit', target: '.kairos/context/notes.md',
               old_string: 'hello', new_string: 'goodbye' }
  mandate = { id: 'mandate_2', allow_llm_upload: ['l2'] }

  assert('M6-7: L2 auto-approve returns applied directly') do
    result = handler.handle_act(decision, mandate)
    result[:status] == 'applied' && !handler.paused?
  end
end

section 'CodeGenPhaseHandler: resume nil when no pending'

assert('M6-8: resume_if_pending returns nil when nothing pending') do
  handler = CGH.new(code_gen_act: nil)
  handler.resume_if_pending.nil?
end

# ---------------------------------------------------------------------------
# M7: IdempotentChainRecorder
# ---------------------------------------------------------------------------

section 'IdempotentChainRecorder: basic recording'

Dir.mktmpdir('icr_test') do |dir|
  ledger = File.join(dir, 'chain_ledger.json')
  calls = []
  chain_tool = ->(payload) { calls << payload; 'tx_ok' }

  icr = ICR.new(chain_tool: chain_tool, ledger_path: ledger)

  assert('M7-1: first record succeeds') do
    r = icr.record({ proposal_id: 'p1', type: 'code_edit' })
    r[:status] == 'recorded' && calls.size == 1
  end

  assert('M7-2: duplicate is rejected') do
    r = icr.record({ proposal_id: 'p1', type: 'code_edit' })
    r[:status] == 'duplicate' && calls.size == 1  # no new call
  end

  assert('M7-3: ledger persists to disk') do
    data = JSON.parse(File.read(ledger))
    data.include?('p1')
  end

  assert('M7-4: second proposal records fine') do
    r = icr.record({ proposal_id: 'p2', type: 'code_edit' })
    r[:status] == 'recorded' && calls.size == 2
  end
end

section 'IdempotentChainRecorder: failure and retry'

Dir.mktmpdir('icr_test') do |dir|
  ledger = File.join(dir, 'chain_ledger.json')
  fail_count = 0
  chain_tool = lambda do |payload|
    fail_count += 1
    raise 'chain down' if fail_count <= 2
    'tx_ok'
  end

  icr = ICR.new(chain_tool: chain_tool, ledger_path: ledger)

  assert('M7-5: first attempt fails → pending_retry') do
    r = icr.record({ proposal_id: 'p_fail', type: 'code_edit' })
    r[:status] == 'pending_retry' && icr.pending_count == 1
  end

  assert('M7-6: retry_pending retries and eventually succeeds') do
    # Second retry (fail_count becomes 2 → still fails)
    r1 = icr.retry_pending
    # Third retry (fail_count becomes 3 → succeeds)
    r2 = icr.retry_pending
    icr.pending_count == 0
  end
end

section 'IdempotentChainRecorder: max retries exhausted'

Dir.mktmpdir('icr_test') do |dir|
  ledger = File.join(dir, 'chain_ledger.json')
  chain_tool = ->(_) { raise 'always fails' }

  icr = ICR.new(chain_tool: chain_tool, ledger_path: ledger)
  icr.record({ proposal_id: 'p_exhaust', type: 'code_edit' })

  # Retry 3 times → exhausted
  3.times { icr.retry_pending }

  assert('M7-7: after max retries, has_failures? is true') do
    icr.has_failures?
  end
end

section 'IdempotentChainRecorder: ledger reload'

Dir.mktmpdir('icr_test') do |dir|
  ledger = File.join(dir, 'chain_ledger.json')
  chain_tool = ->(_) { 'tx_ok' }

  icr1 = ICR.new(chain_tool: chain_tool, ledger_path: ledger)
  icr1.record({ proposal_id: 'p_persist', type: 'code_edit' })

  # Create new instance (simulates daemon restart)
  icr2 = ICR.new(chain_tool: chain_tool, ledger_path: ledger)

  assert('M7-8: new instance recognizes previously recorded proposal') do
    r = icr2.record({ proposal_id: 'p_persist', type: 'code_edit' })
    r[:status] == 'duplicate'
  end
end

section 'IdempotentChainRecorder: missing proposal_id'

Dir.mktmpdir('icr_test') do |dir|
  ledger = File.join(dir, 'chain_ledger.json')
  icr = ICR.new(chain_tool: ->(_) { 'ok' }, ledger_path: ledger)

  assert('M7-9: missing proposal_id raises ArgumentError') do
    begin
      icr.record({ type: 'code_edit' })
      false
    rescue ArgumentError
      true
    end
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
