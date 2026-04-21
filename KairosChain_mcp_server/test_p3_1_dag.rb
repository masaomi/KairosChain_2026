#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.1 — Active OBSERVE + Task DAG tests.
#
# Usage:
#   ruby KairosChain_mcp_server/test_p3_1_dag.rb
#
# Philosophy:
#   * Single-threaded DAG execution: next_runnable returns ONE node.
#   * Kahn's algorithm for cycle detection and topological sort.
#   * Failure policies (:halt, :skip_dependents, :continue) are verified
#     by observing pending → cancelled transitions on peer and descendant
#     nodes — not by inspecting internal state.
#   * ActiveObserve is exercised through a stub tool_invoker so no real
#     MCP tools are required.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'json'
require 'tmpdir'

require 'kairos_mcp/daemon/canonical'
require 'kairos_mcp/daemon/task_dag'
require 'kairos_mcp/daemon/active_observe'

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

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
  puts "    #{e.backtrace.first(5).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

DAG = KairosMcp::Daemon::TaskDag
AO  = KairosMcp::Daemon::ActiveObserve

# Helpers -------------------------------------------------------------------

def linear_nodes(policy: :halt)
  [
    { id: 'A', tool: 't.a', depends_on: [], failure_policy: policy },
    { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: policy },
    { id: 'C', tool: 't.c', depends_on: %w[B], failure_policy: policy }
  ]
end

def diamond_nodes(policy: :halt)
  [
    { id: 'A', tool: 't.a', depends_on: [],          failure_policy: policy },
    { id: 'B', tool: 't.b', depends_on: %w[A],       failure_policy: policy },
    { id: 'C', tool: 't.c', depends_on: %w[A],       failure_policy: policy },
    { id: 'D', tool: 't.d', depends_on: %w[B C],     failure_policy: policy }
  ]
end

# ---------------------------------------------------------------------------
# TaskDag — construction, cycles
# ---------------------------------------------------------------------------

section 'TaskDag: construction'

assert('linear DAG builds with 3 nodes') do
  DAG.new(linear_nodes).size == 3
end

assert('diamond DAG builds with 4 nodes') do
  DAG.new(diamond_nodes).size == 4
end

assert('empty DAG builds (size 0)') do
  DAG.new([]).size.zero?
end

assert('node accessor returns by id') do
  d = DAG.new(linear_nodes)
  d.node('B').tool == 't.b'
end

assert('unknown dependency raises InvalidNodeError') do
  begin
    DAG.new([{ id: 'X', tool: 't.x', depends_on: %w[NOPE] }])
    false
  rescue DAG::InvalidNodeError
    true
  end
end

assert('duplicate node id raises InvalidNodeError') do
  begin
    DAG.new([
              { id: 'A', tool: 't.a' },
              { id: 'A', tool: 't.a2' }
            ])
    false
  rescue DAG::InvalidNodeError
    true
  end
end

assert('missing id raises InvalidNodeError') do
  begin
    DAG.new([{ tool: 't.a' }])
    false
  rescue DAG::InvalidNodeError
    true
  end
end

assert('missing tool raises InvalidNodeError') do
  begin
    DAG.new([{ id: 'A' }])
    false
  rescue DAG::InvalidNodeError
    true
  end
end

assert('self-dependency raises CyclicGraphError') do
  begin
    DAG.new([{ id: 'A', tool: 't.a', depends_on: %w[A] }])
    false
  rescue DAG::CyclicGraphError
    true
  end
end

assert('2-node cycle raises CyclicGraphError') do
  begin
    DAG.new([
              { id: 'A', tool: 't.a', depends_on: %w[B] },
              { id: 'B', tool: 't.b', depends_on: %w[A] }
            ])
    false
  rescue DAG::CyclicGraphError
    true
  end
end

assert('3-node cycle raises CyclicGraphError') do
  begin
    DAG.new([
              { id: 'A', tool: 't.a', depends_on: %w[C] },
              { id: 'B', tool: 't.b', depends_on: %w[A] },
              { id: 'C', tool: 't.c', depends_on: %w[B] }
            ])
    false
  rescue DAG::CyclicGraphError
    true
  end
end

assert('invalid failure_policy raises InvalidNodeError') do
  begin
    DAG.new([{ id: 'A', tool: 't.a', failure_policy: :nope }])
    false
  rescue DAG::InvalidNodeError
    true
  end
end

# ---------------------------------------------------------------------------
# TaskDag — topological order
# ---------------------------------------------------------------------------

section 'TaskDag: topological_order'

assert('linear chain A→B→C topo order is [A,B,C]') do
  DAG.new(linear_nodes).topological_order == %w[A B C]
end

assert('diamond topo order respects all deps') do
  order = DAG.new(diamond_nodes).topological_order
  order.index('A') < order.index('B') &&
    order.index('A') < order.index('C') &&
    order.index('B') < order.index('D') &&
    order.index('C') < order.index('D')
end

assert('topological_order is deterministic across calls') do
  d = DAG.new(diamond_nodes)
  d.topological_order == d.topological_order
end

assert('empty DAG topo order is []') do
  DAG.new([]).topological_order == []
end

# ---------------------------------------------------------------------------
# TaskDag — next_runnable and mark
# ---------------------------------------------------------------------------

section 'TaskDag: next_runnable single-threaded scheduling'

assert('empty DAG next_runnable is nil') do
  DAG.new([]).next_runnable.nil?
end

assert('linear chain starts at A') do
  DAG.new(linear_nodes).next_runnable.id == 'A'
end

assert('next_runnable returns nil while A is :running (B blocked)') do
  d = DAG.new(linear_nodes)
  d.mark('A', :running)
  d.next_runnable.nil?
end

assert('marking A completed unblocks B') do
  d = DAG.new(linear_nodes)
  d.mark('A', :completed)
  d.next_runnable.id == 'B'
end

assert('linear chain executes in order A,B,C') do
  d = DAG.new(linear_nodes)
  order = []
  while (n = d.next_runnable)
    order << n.id
    d.mark(n.id, :completed)
  end
  order == %w[A B C]
end

assert('diamond runs A first, then B or C, both before D') do
  d = DAG.new(diamond_nodes)
  order = []
  while (n = d.next_runnable)
    order << n.id
    d.mark(n.id, :completed)
  end
  order.first == 'A' && order.last == 'D' && order.sort == %w[A B C D]
end

assert('next_runnable nil when all completed') do
  d = DAG.new(linear_nodes)
  %w[A B C].each { |id| d.mark(id, :completed) }
  d.next_runnable.nil?
end

assert('mark unknown id raises InvalidNodeError') do
  d = DAG.new(linear_nodes)
  begin
    d.mark('ZZZ', :completed)
    false
  rescue DAG::InvalidNodeError
    true
  end
end

assert('mark invalid status raises InvalidTransitionError') do
  d = DAG.new(linear_nodes)
  begin
    d.mark('A', :bogus)
    false
  rescue DAG::InvalidTransitionError
    true
  end
end

# ---------------------------------------------------------------------------
# TaskDag — failure policies
# ---------------------------------------------------------------------------

section 'TaskDag: failure_policy :halt'

assert(':halt cancels all pending nodes on failure') do
  d = DAG.new(diamond_nodes(policy: :halt))
  d.mark('A', :failed, error: 'boom')
  d.node('A').failed? &&
    d.node('B').cancelled? &&
    d.node('C').cancelled? &&
    d.node('D').cancelled?
end

assert(':halt next_runnable is nil after failure') do
  d = DAG.new(diamond_nodes(policy: :halt))
  d.mark('A', :failed)
  d.next_runnable.nil?
end

assert(':halt all_completed? true once propagation runs') do
  d = DAG.new(diamond_nodes(policy: :halt))
  d.mark('A', :failed)
  d.all_completed?
end

assert(':halt does not resurrect completed nodes') do
  d = DAG.new(diamond_nodes(policy: :halt))
  d.mark('A', :completed)
  d.mark('B', :failed)
  d.node('A').completed?
end

section 'TaskDag: failure_policy :skip_dependents'

assert(':skip_dependents cancels only descendants') do
  # Graph:  A → B (fails) → D
  #         A → C (independent branch)
  nodes = [
    { id: 'A', tool: 't.a', depends_on: [],        failure_policy: :skip_dependents },
    { id: 'B', tool: 't.b', depends_on: %w[A],     failure_policy: :skip_dependents },
    { id: 'C', tool: 't.c', depends_on: %w[A],     failure_policy: :skip_dependents },
    { id: 'D', tool: 't.d', depends_on: %w[B],     failure_policy: :skip_dependents }
  ]
  d = DAG.new(nodes)
  d.mark('A', :completed)
  d.mark('B', :failed, error: 'oops')
  d.node('D').cancelled? && d.node('C').pending?
end

assert(':skip_dependents still allows unrelated branch to run') do
  nodes = [
    { id: 'A', tool: 't.a', depends_on: [],    failure_policy: :skip_dependents },
    { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: :skip_dependents },
    { id: 'C', tool: 't.c', depends_on: %w[A], failure_policy: :skip_dependents },
    { id: 'D', tool: 't.d', depends_on: %w[B], failure_policy: :skip_dependents }
  ]
  d = DAG.new(nodes)
  d.mark('A', :completed)
  d.mark('B', :failed)
  d.next_runnable&.id == 'C'
end

assert(':skip_dependents cascades transitively through chain') do
  # A → B → C → D; B fails ⇒ C and D both cancelled.
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [],    failure_policy: :skip_dependents },
                { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: :skip_dependents },
                { id: 'C', tool: 't.c', depends_on: %w[B], failure_policy: :skip_dependents },
                { id: 'D', tool: 't.d', depends_on: %w[C], failure_policy: :skip_dependents }
              ])
  d.mark('A', :completed)
  d.mark('B', :failed)
  d.node('C').cancelled? && d.node('D').cancelled?
end

section 'TaskDag: failure_policy :continue'

assert(':continue leaves peer pending nodes untouched') do
  # A and B are peers (no deps), both :continue.
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [], failure_policy: :continue },
                { id: 'B', tool: 't.b', depends_on: [], failure_policy: :continue }
              ])
  d.mark('A', :failed)
  d.node('B').pending?
end

assert(':continue still allows B to be scheduled') do
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [], failure_policy: :continue },
                { id: 'B', tool: 't.b', depends_on: [], failure_policy: :continue }
              ])
  d.mark('A', :failed)
  d.next_runnable&.id == 'B'
end

assert(':continue allows dependent to run after failed dep (no deadlock)') do
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [], failure_policy: :continue },
                { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: :continue }
              ])
  d.mark('A', :failed)
  d.next_runnable&.id == 'B'
end

assert(':continue chain A(fail)->B->C all runnable') do
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [], failure_policy: :continue },
                { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: :continue },
                { id: 'C', tool: 't.c', depends_on: %w[B], failure_policy: :continue }
              ])
  d.mark('A', :failed)
  d.mark('B', :completed)
  d.next_runnable&.id == 'C'
end

assert(':halt dep failure still blocks dependent (not affected by :continue fix)') do
  d = DAG.new([
                { id: 'A', tool: 't.a', depends_on: [], failure_policy: :halt },
                { id: 'B', tool: 't.b', depends_on: %w[A], failure_policy: :halt }
              ])
  d.mark('A', :failed)
  d.node('B').cancelled? && d.next_runnable.nil?
end

# ---------------------------------------------------------------------------
# TaskDag — all_completed?
# ---------------------------------------------------------------------------

section 'TaskDag: all_completed?'

assert('empty DAG reports all_completed? true') do
  DAG.new([]).all_completed?
end

assert('pending nodes ⇒ not all_completed') do
  !DAG.new(linear_nodes).all_completed?
end

assert('all completed ⇒ all_completed true') do
  d = DAG.new(linear_nodes)
  %w[A B C].each { |id| d.mark(id, :completed) }
  d.all_completed?
end

assert('mix of cancelled+completed ⇒ all_completed true') do
  d = DAG.new(linear_nodes(policy: :halt))
  d.mark('A', :completed)
  d.mark('B', :failed)
  d.all_completed?
end

# ---------------------------------------------------------------------------
# TaskDag — to_plan_steps
# ---------------------------------------------------------------------------

section 'TaskDag: to_plan_steps (WAL-compatible)'

assert('to_plan_steps returns Array of 4 steps for diamond') do
  steps = DAG.new(diamond_nodes).to_plan_steps(plan_id: 'plan_d', cycle: 1)
  steps.is_a?(Array) && steps.size == 4
end

assert('to_plan_steps ordering is topologically valid') do
  steps = DAG.new(diamond_nodes).to_plan_steps(plan_id: 'plan_d', cycle: 1)
  ids = steps.map { |s| s[:step_id] }
  ids.first == 'A' &&
    ids.last  == 'D' &&
    ids.index('B') > ids.index('A') &&
    ids.index('C') > ids.index('A') &&
    ids.index('D') > ids.index('B') &&
    ids.index('D') > ids.index('C')
end

assert('each step has WAL-compatible shape') do
  steps = DAG.new(linear_nodes).to_plan_steps
  steps.all? do |s|
    s[:step_id].is_a?(String) &&
      s[:tool].is_a?(String) &&
      s[:params_hash].start_with?('sha256-') &&
      s[:pre_hash].start_with?('sha256-') &&
      s[:expected_post_hash].start_with?('sha256-')
  end
end

assert('to_plan_steps is deterministic for fixed input') do
  a = DAG.new(linear_nodes).to_plan_steps(plan_id: 'p', cycle: 1)
  b = DAG.new(linear_nodes).to_plan_steps(plan_id: 'p', cycle: 1)
  a == b
end

# ---------------------------------------------------------------------------
# ActiveObserve
# ---------------------------------------------------------------------------

section 'ActiveObserve: basic invocation'

assert('empty policies returns empty observation') do
  obs = AO.new.observe({ observe_policies: [] }, tool_invoker: ->(_, _) { :noop })
  obs[:policies_invoked].empty? &&
    obs[:policies_skipped].empty? &&
    obs[:results].empty? &&
    obs[:relevant].empty? &&
    obs[:errors].empty?
end

assert('missing observe_policies key returns empty observation') do
  obs = AO.new.observe({}, tool_invoker: ->(_, _) { :noop })
  obs[:policies_invoked].empty? && obs[:results].empty?
end

assert('calls listed allowlisted tools and records results') do
  seen = []
  invoker = lambda do |tool, args|
    seen << [tool, args]
    "result_of_#{tool}"
  end
  ao = AO.new
  obs = ao.observe({ observe_policies: %w[chain_status knowledge_list] },
                   tool_invoker: invoker)
  seen.map(&:first) == %w[chain_status knowledge_list] &&
    obs[:policies_invoked] == %w[chain_status knowledge_list] &&
    obs[:results]['chain_status']   == 'result_of_chain_status' &&
    obs[:results]['knowledge_list'] == 'result_of_knowledge_list'
end

assert('tools not in read-only allowlist are skipped, not invoked') do
  invoked = []
  invoker = ->(tool, _args) { invoked << tool; 'x' }
  obs = AO.new.observe({ observe_policies: %w[chain_status chain_record] },
                       tool_invoker: invoker)
  invoked == %w[chain_status] &&
    obs[:policies_skipped] == %w[chain_record] &&
    obs[:policies_invoked] == %w[chain_status]
end

assert('tool invocation errors are captured in :errors') do
  invoker = lambda do |tool, _args|
    raise 'kaboom' if tool == 'knowledge_list'
    'ok'
  end
  obs = AO.new.observe({ observe_policies: %w[chain_status knowledge_list] },
                       tool_invoker: invoker)
  obs[:policies_invoked] == %w[chain_status] &&
    obs[:errors]['knowledge_list'].include?('kaboom')
end

assert('Hash-form policy { tool:, args: } is invoked with its args') do
  got = nil
  invoker = ->(tool, args) { got = [tool, args]; 'ok' }
  AO.new.observe(
    { observe_policies: [{ tool: 'knowledge_get', args: { key: 'foo' } }] },
    tool_invoker: invoker
  )
  got == ['knowledge_get', { key: 'foo' }]
end

assert('custom allowlist overrides the default') do
  invoker = ->(_t, _a) { 'ok' }
  ao = AO.new(allowlist: %w[custom_tool])
  obs = ao.observe({ observe_policies: %w[custom_tool chain_status] },
                   tool_invoker: invoker)
  obs[:policies_invoked] == %w[custom_tool] &&
    obs[:policies_skipped] == %w[chain_status]
end

assert('select_relevant returns entry per invoked tool') do
  invoker = ->(_t, _a) { 'payload with summary keyword' }
  ao = AO.new(keywords: %w[summary])
  obs = ao.observe({ observe_policies: %w[chain_status] }, tool_invoker: invoker)
  obs[:relevant]['chain_status'][:match] == true &&
    obs[:relevant]['chain_status'][:matched_keywords] == %w[summary]
end

assert('select_relevant derives keywords from mandate goal when none provided') do
  invoker = ->(_t, _a) { 'contains summarize somewhere' }
  ao = AO.new
  obs = ao.observe(
    { observe_policies: %w[chain_status], goal_name: 'summarize_daily_summary' },
    tool_invoker: invoker
  )
  # "summarize" token from goal_name should match the payload.
  rel = obs[:relevant]['chain_status']
  rel[:matched_keywords].include?('summarize')
end

assert('non-callable tool_invoker raises ArgumentError') do
  begin
    AO.new.observe({ observe_policies: [] }, tool_invoker: 'not a proc')
    false
  rescue ArgumentError
    true
  end
end

assert('non-Hash mandate raises ArgumentError') do
  begin
    AO.new.observe('nope', tool_invoker: ->(_, _) {})
    false
  rescue ArgumentError
    true
  end
end

# ---------------------------------------------------------------------------
# R1 fix: monotonic transition guard
# ---------------------------------------------------------------------------

section 'TaskDag: transition guard (R1 fix)'

assert('completed -> pending raises InvalidTransitionError') do
  d = DAG.new(linear_nodes)
  d.mark('A', :completed)
  begin
    d.mark('A', :pending)
    false
  rescue DAG::InvalidTransitionError => e
    e.message.include?('completed -> pending')
  end
end

assert('failed -> running raises InvalidTransitionError') do
  d = DAG.new([{ id: 'A', tool: 't', failure_policy: :continue }])
  d.mark('A', :failed)
  begin
    d.mark('A', :running)
    false
  rescue DAG::InvalidTransitionError => e
    e.message.include?('failed -> running')
  end
end

assert('cancelled -> completed raises InvalidTransitionError') do
  d = DAG.new(linear_nodes(policy: :halt))
  d.mark('A', :failed) # cancels B and C
  begin
    d.mark('B', :completed)
    false
  rescue DAG::InvalidTransitionError => e
    e.message.include?('cancelled -> completed')
  end
end

assert('running -> pending raises InvalidTransitionError') do
  d = DAG.new(linear_nodes)
  d.mark('A', :running)
  begin
    d.mark('A', :pending)
    false
  rescue DAG::InvalidTransitionError => e
    e.message.include?('running -> pending')
  end
end

assert('pending -> completed is allowed (skip running)') do
  d = DAG.new(linear_nodes)
  d.mark('A', :completed)
  d.node('A').completed?
end

assert('pending -> running -> completed is the full lifecycle') do
  d = DAG.new(linear_nodes)
  d.mark('A', :running)
  d.mark('A', :completed)
  d.node('A').completed?
end

# ---------------------------------------------------------------------------
# R1 fix: duplicate tool dedup in ActiveObserve
# ---------------------------------------------------------------------------

section 'ActiveObserve: duplicate tool dedup (R1 fix)'

assert('duplicate tool policies are deduplicated (first wins)') do
  calls = []
  invoker = ->(tool, args) { calls << [tool, args]; "result_#{args[:key] || 'default'}" }
  obs = AO.new.observe(
    { observe_policies: [
      { tool: 'knowledge_get', args: { key: 'a' } },
      { tool: 'knowledge_get', args: { key: 'b' } }
    ] },
    tool_invoker: invoker
  )
  # Should only invoke once (first entry wins via uniq)
  calls.size == 1 &&
    obs[:policies_invoked] == %w[knowledge_get] &&
    obs[:results].key?('knowledge_get')
end

# ---------------------------------------------------------------------------
# R1 fix: logger compatibility
# ---------------------------------------------------------------------------

section 'ActiveObserve: logger compatibility (R1 fix)'

assert('stdlib Logger does not crash ActiveObserve on error path') do
  require 'logger'
  logger = Logger.new(File.open(File::NULL, 'w'))
  invoker = lambda do |tool, _args|
    raise 'kaboom' if tool == 'knowledge_list'
    'ok'
  end
  ao = AO.new(logger: logger)
  obs = ao.observe(
    { observe_policies: %w[chain_status knowledge_list] },
    tool_invoker: invoker
  )
  obs[:policies_invoked] == %w[chain_status] &&
    obs[:errors]['knowledge_list'].include?('kaboom')
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
