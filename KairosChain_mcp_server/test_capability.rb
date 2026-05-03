# frozen_string_literal: true

# Test: Capability Boundary Phase 1.5 (v1.1.1)
# Covers: §10 test suite enumeration

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/kairos_mcp/tools/base_tool'
require_relative 'lib/kairos_mcp/capability'

$pass = 0
$fail = 0
$errors = []

def assert(label)
  if yield
    $pass += 1
    puts "  ok  #{label}"
  else
    $fail += 1
    $errors << label
    puts "  FAIL #{label}"
  end
rescue StandardError => e
  $fail += 1
  $errors << "#{label} (#{e.class}: #{e.message})"
  puts "  FAIL #{label} (#{e.class}: #{e.message})"
end

def assert_raises(label, klass)
  yield
  $fail += 1
  $errors << "#{label} (no exception, expected #{klass})"
  puts "  FAIL #{label} (no exception)"
rescue StandardError => e
  if e.is_a?(klass)
    $pass += 1
    puts "  ok  #{label}"
  else
    $fail += 1
    $errors << "#{label} (got #{e.class}: #{e.message})"
    puts "  FAIL #{label} (got #{e.class})"
  end
end

def section(name)
  puts "\n--- #{name} ---"
end

CAP = KairosMcp::Capability

# Save real env to restore at end, clear all harness signals for hermetic tests
HARNESS_ENV_KEYS = %w[KAIROS_HARNESS CLAUDECODE CODEX_CLI CODEX_AGENT_ID CURSOR_AGENT CURSOR_TRACE_ID].freeze
CLAUDE_CODE_PREFIX_KEYS = ENV.keys.select { |k| k.start_with?('CLAUDE_CODE_') }
SAVED_ENV = (HARNESS_ENV_KEYS + CLAUDE_CODE_PREFIX_KEYS).each_with_object({}) { |k, h| h[k] = ENV[k] }

def clear_harness_env
  HARNESS_ENV_KEYS.each { |k| ENV.delete(k) }
  CLAUDE_CODE_PREFIX_KEYS.each { |k| ENV.delete(k) }
end

def restore_harness_env
  SAVED_ENV.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

at_exit { restore_harness_env }
clear_harness_env

# ============================================================
section('1. detect_harness — env_var preferred')
# ============================================================

CAP.reset!
ENV['KAIROS_HARNESS'] = 'claude_code'
detection = CAP.detect_harness
assert('env var → :claude_code') { detection[:active_harness] == :claude_code }
assert('detection_method=:env_var') { detection[:detection_method] == :env_var }
assert('confidence=:explicit') { detection[:confidence] == :explicit }

CAP.reset!
ENV['KAIROS_HARNESS'] = 'codex_cli'
assert('env var → :codex_cli') { CAP.detect_harness[:active_harness] == :codex_cli }

CAP.reset!
ENV['KAIROS_HARNESS'] = 'malformed value with spaces!@#'
detection = CAP.detect_harness
assert('malformed env → :unknown') { detection[:active_harness] == :unknown }
assert('malformed env → confidence :unknown') { detection[:confidence] == :unknown }

CAP.reset!
clear_harness_env

# ============================================================
section('2. detect_harness — auto-detect (limited)')
# ============================================================

CAP.reset!
clear_harness_env
ENV['CLAUDECODE'] = '1'
assert('auto-detect Claude Code via env var') { CAP.detect_harness[:active_harness] == :claude_code }
assert('auto-detect confidence=:inferred') { CAP.detect_harness[:confidence] == :inferred }
ENV.delete('CLAUDECODE')

# CWD markers should NOT auto-detect (intentional self-conflation prevention)
Dir.mktmpdir do |dir|
  Dir.chdir(dir) do
    File.write('CLAUDE.md', '# fake')
    CAP.reset!
    clear_harness_env
    detection = CAP.detect_harness
    assert('CWD CLAUDE.md does NOT trigger auto-detect (F5 fix)') do
      detection[:active_harness] == :unknown
    end
  end
end

CAP.reset!

# ============================================================
section('3. detect_harness — :unknown')
# ============================================================

CAP.reset!
clear_harness_env
detection = CAP.detect_harness
assert(':unknown when no signals') { detection[:active_harness] == :unknown }
assert(':unknown method=:none') { detection[:detection_method] == :none }
assert(':unknown confidence=:unknown') { detection[:confidence] == :unknown }

# ============================================================
section('4. Process boot cache — Capability.reset!')
# ============================================================

CAP.reset!
ENV['KAIROS_HARNESS'] = 'claude_code'
first = CAP.detect_harness
ENV['KAIROS_HARNESS'] = 'codex_cli'
second = CAP.detect_harness
assert('cache: env mid-runtime change does not affect cached value') do
  first[:active_harness] == second[:active_harness] && second[:active_harness] == :claude_code
end

CAP.reset!
ENV.delete('KAIROS_HARNESS')

# ============================================================
section('5. normalize_requirement — Symbol & Hash forms')
# ============================================================

assert('Symbol :core normalizes to {tier: :core}') do
  CAP.normalize_requirement(:core) == { tier: :core }
end

assert('Symbol :harness_assisted normalizes') do
  CAP.normalize_requirement(:harness_assisted) == { tier: :harness_assisted }
end

assert('Hash with tier and externals') do
  result = CAP.normalize_requirement({
    tier: :harness_assisted,
    requires_externals: %i[claude_cli codex_cli]
  })
  result[:tier] == :harness_assisted && result[:requires_externals] == %i[claude_cli codex_cli]
end

assert('String keys normalized to symbols') do
  result = CAP.normalize_requirement({
    'tier' => :core,
    'note' => 'hello'
  })
  result == { tier: :core, note: 'hello' }
end

# ============================================================
section('6. Lazy validation — ArgumentError raises')
# ============================================================

assert_raises('invalid tier rejected', ArgumentError) do
  CAP.normalize_requirement(:not_a_tier)
end

assert_raises('harness_specific without target_harness rejected', ArgumentError) do
  CAP.normalize_requirement({ tier: :harness_specific })
end

assert_raises('non-Symbol non-Hash rejected', ArgumentError) do
  CAP.normalize_requirement('bad string input')
end

assert_raises('requires_harness_features missing feature', ArgumentError) do
  CAP.normalize_requirement({
    tier: :harness_assisted,
    requires_harness_features: [{ target_harness: :claude_code }]
  })
end

assert_raises('fallback_chain missing path', ArgumentError) do
  CAP.normalize_requirement({
    tier: :harness_assisted,
    fallback_chain: [{ tier: :core, condition: 'always' }]
  })
end

assert_raises('fallback_chain harness_specific without target_harness (R3)', ArgumentError) do
  CAP.normalize_requirement({
    tier: :harness_assisted,
    fallback_chain: [{ path: 'p', tier: :harness_specific, condition: 'c' }]
  })
end

# Valid harness_specific with target_harness
assert('harness_specific with target_harness OK') do
  result = CAP.normalize_requirement({
    tier: :harness_specific,
    target_harness: :claude_code
  })
  result[:tier] == :harness_specific && result[:target_harness] == :claude_code
end

# Valid full multi_llm_review-style declaration
assert('full declaration OK') do
  result = CAP.normalize_requirement({
    tier: :harness_assisted,
    requires_externals: %i[claude_cli codex_cli],
    requires_harness_features: [
      { feature: :agent_tool, target_harness: :claude_code,
        used_for: 'persona gate', degrades_to: 'API direct' }
    ],
    fallback_chain: [
      { path: 'agent_personas', tier: :harness_specific,
        target_harness: :claude_code, condition: 'Claude Code available' },
      { path: 'manual', tier: :core, condition: 'always' }
    ]
  })
  result[:tier] == :harness_assisted
end

# ============================================================
section('7. cli_in_path? — filesystem PATH check (no subprocess)')
# ============================================================

# 'ls' should be in PATH on any Unix-like system
assert('ls is in PATH') { CAP.cli_in_path?(:ls) }
assert('absolutely_nonexistent_binary_xyz is NOT in PATH') do
  !CAP.cli_in_path?(:absolutely_nonexistent_binary_xyz_42)
end
assert('non-symbol non-string returns false') { !CAP.cli_in_path?(nil) }

# ============================================================
section('8. compute_used_externals — same-source exclusion (F4)')
# ============================================================

manifest_entries = [
  { name: 'multi_llm_review', requires_externals: %i[claude_cli codex_cli cursor_cli] },
  { name: 'agent_start',      requires_externals: %i[claude_cli] }
]

result = CAP.compute_used_externals(manifest_entries, :claude_code)
assert('same-source claude_cli excluded') do
  !result[:value].include?(:claude_cli) && result[:same_source_excluded] == [:claude_cli]
end
assert('codex_cli + cursor_cli remain') do
  result[:value].include?(:codex_cli) && result[:value].include?(:cursor_cli)
end

result = CAP.compute_used_externals(manifest_entries, :unknown)
assert(':unknown harness → no exclusion') do
  result[:same_source_excluded].empty? && result[:value].size == 3
end

result = CAP.compute_used_externals(manifest_entries, :codex_cli)
assert('codex_cli active → codex_cli excluded') do
  !result[:value].include?(:codex_cli) && result[:same_source_excluded] == [:codex_cli]
end

# ============================================================
section('9. BaseTool default harness_requirement = :core')
# ============================================================

class TestDefaultTool < KairosMcp::Tools::BaseTool
  def name; 'test_default'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args); text_content('ok'); end
end

class TestDeclaredCoreTool < KairosMcp::Tools::BaseTool
  def name; 'test_declared_core'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args); text_content('ok'); end
  def harness_requirement; :core; end
end

class TestAssistedTool < KairosMcp::Tools::BaseTool
  def name; 'test_assisted'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args); text_content('ok'); end
  def harness_requirement
    { tier: :harness_assisted, requires_externals: [:claude_cli], degrades_to: 'manual' }
  end
end

default_tool = TestDefaultTool.new
declared_tool = TestDeclaredCoreTool.new
assisted_tool = TestAssistedTool.new

assert('default tool harness_requirement returns :core') do
  default_tool.harness_requirement == :core
end

# Forward-only: default tool's method owner is BaseTool, declared tool's owner is the subclass
assert('default tool method owner == BaseTool (declared:false)') do
  default_tool.method(:harness_requirement).owner == KairosMcp::Tools::BaseTool
end
assert('declared tool method owner != BaseTool (declared:true)') do
  declared_tool.method(:harness_requirement).owner != KairosMcp::Tools::BaseTool
end
assert('assisted tool method owner != BaseTool (declared:true)') do
  assisted_tool.method(:harness_requirement).owner != KairosMcp::Tools::BaseTool
end

# ============================================================
section('10. with_acknowledgment helper — wrap pattern')
# ============================================================

class TestWrappedTool < KairosMcp::Tools::BaseTool
  def name; 'test_wrapped'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args)
    with_acknowledgment(path_taken: 'test_path', tier: :harness_specific,
                        target_harness: :claude_code) do
      { result: 'success', value: 42 }
    end
  end
end

result = TestWrappedTool.new.call({})
assert('with_acknowledgment returns text_content array') do
  result.is_a?(Array) && result.first[:type] == 'text'
end

parsed = JSON.parse(result.first[:text])
assert('response Hash includes original payload') do
  parsed['result'] == 'success' && parsed['value'] == 42
end
assert('response Hash includes harness_assistance_used') do
  parsed['harness_assistance_used'].is_a?(Hash) &&
    parsed['harness_assistance_used']['path_taken'] == 'test_path' &&
    parsed['harness_assistance_used']['tier_actually_used'] == 'harness_specific' &&
    parsed['harness_assistance_used']['target_harness'] == 'claude_code'
end

# Block returning non-Hash raises
class TestBadWrapTool < KairosMcp::Tools::BaseTool
  def name; 'test_bad'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args)
    with_acknowledgment(path_taken: 'p', tier: :core) { 'not a hash' }
  end
end

assert_raises('with_acknowledgment block must return Hash', ArgumentError) do
  TestBadWrapTool.new.call({})
end

# ============================================================
section('11. aggregate_manifest — registry walk + declaration_errors')
# ============================================================

# Mock minimal registry-like object
class FakeRegistry
  def initialize
    @tools = {}
    @tool_sources = {}
  end
  def register(tool, source: :core_tool)
    @tools[tool.name] = tool
    @tool_sources[tool.name] = source
  end
end

fake = FakeRegistry.new
fake.register(TestDefaultTool.new)        # declared:false, :core
fake.register(TestDeclaredCoreTool.new)    # declared:true, :core
fake.register(TestAssistedTool.new)        # declared:true, :harness_assisted

manifest = CAP.aggregate_manifest(fake)
assert('manifest includes all 3 tools') { manifest[:tools].size == 3 }
assert('default tool has declared:false') do
  manifest[:tools].find { |t| t[:name] == 'test_default' }[:declared] == false
end
assert('declared core tool has declared:true') do
  manifest[:tools].find { |t| t[:name] == 'test_declared_core' }[:declared] == true
end
assert('assisted tool tier=:harness_assisted') do
  manifest[:tools].find { |t| t[:name] == 'test_assisted' }[:tier] == :harness_assisted
end
assert('summary distinguishes undeclared_default_core') do
  manifest[:summary][:undeclared_default_core] == 1
end
assert('summary counts declared core') { manifest[:summary][:core] == 1 }
assert('summary counts declared harness_assisted') { manifest[:summary][:harness_assisted] == 1 }

# Partial-failure policy: bad tool surfaces as declaration_error, others continue
class TestBadDeclTool < KairosMcp::Tools::BaseTool
  def name; 'test_bad_decl'; end
  def description; 'test'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(args); text_content('ok'); end
  def harness_requirement; { tier: :harness_specific }; end  # missing target_harness
end

fake2 = FakeRegistry.new
fake2.register(TestDefaultTool.new)
fake2.register(TestBadDeclTool.new)

manifest2 = CAP.aggregate_manifest(fake2)
assert('partial-failure: bad tool in declaration_errors') do
  manifest2[:declaration_errors].any? { |e| e[:tool] == 'test_bad_decl' }
end
assert('partial-failure: other tools still aggregated') do
  manifest2[:tools].size == 2  # both included, bad one with :unknown tier
end

# ============================================================
section('12. SkillSet source attribution (F3)')
# ============================================================

fake3 = FakeRegistry.new
fake3.register(TestDefaultTool.new, source: :core_tool)
fake3.register(TestDeclaredCoreTool.new, source: 'skillset:multi_llm_review')

m3 = CAP.aggregate_manifest(fake3)
assert('core tool source=:core_tool') do
  m3[:tools].find { |t| t[:name] == 'test_default' }[:source] == :core_tool
end
assert('skillset tool source=skillset:...') do
  m3[:tools].find { |t| t[:name] == 'test_declared_core' }[:source] == 'skillset:multi_llm_review'
end

# ===== Summary =====
puts "\n===== RESULTS ====="
puts "  PASS: #{$pass}"
puts "  FAIL: #{$fail}"
if $fail > 0
  puts "\n  Failed tests:"
  $errors.each { |e| puts "    - #{e}" }
end
exit($fail > 0 ? 1 : 0)
