# frozen_string_literal: true

# AutoExec SkillSet Tests
# Run: ruby test/test_autoexec.rb

require 'tmpdir'
require_relative '../lib/autoexec'

$pass = 0
$fail = 0
$errors = []

def assert(condition, message)
  if condition
    $pass += 1
    print '.'
  else
    $fail += 1
    $errors << message
    print 'F'
  end
end

def assert_raises(error_class, message, &block)
  block.call
  $fail += 1
  $errors << "Expected #{error_class} but nothing raised: #{message}"
  print 'F'
rescue error_class
  $pass += 1
  print '.'
rescue StandardError => e
  $fail += 1
  $errors << "Expected #{error_class} but got #{e.class}: #{e.message} — #{message}"
  print 'F'
end

def section(name)
  puts "\n\n== #{name} =="
end

# ============================================================================
section 'TaskDsl — Valid DSL Parsing'
# ============================================================================

valid_dsl = <<~DSL
  task :test_task do
    meta description: "A test task", risk_default: :low

    step :step_one, action: "read files", risk: :low, depends_on: []
    step :step_two, action: "edit code", risk: :medium, depends_on: [:step_one]
    step :step_three, action: "run tests", risk: :medium, depends_on: [:step_two], requires_human_cognition: true
  end
DSL

plan = Autoexec::TaskDsl.parse(valid_dsl)
assert(plan.task_id == :test_task, 'Task ID should be :test_task')
assert(plan.meta.description == 'A test task', 'Meta description should match')
assert(plan.meta.risk_default == :low, 'Meta risk_default should be :low')
assert(plan.steps.size == 3, 'Should have 3 steps')
assert(plan.steps[0].step_id == :step_one, 'First step should be :step_one')
assert(plan.steps[0].risk == :low, 'First step risk should be :low')
assert(plan.steps[1].depends_on == [:step_one], 'Step two depends on step_one')
assert(plan.steps[2].requires_human_cognition == true, 'Step three requires human cognition')
assert(!plan.source_hash.nil?, 'Source hash should be computed')

# ============================================================================
section 'TaskDsl — Colons in Action Strings'
# ============================================================================

colon_dsl = <<~DSL
  task :colon_test do
    step :s1, action: "run command: echo hello", risk: :low
    step :s2, action: "check status: pending items", risk: :medium, depends_on: [:s1]
    step :s3, action: "URL: https://example.com test", risk: :low, depends_on: [:s2]
  end
DSL

colon_plan = Autoexec::TaskDsl.parse(colon_dsl)
assert(colon_plan.steps.size == 3, 'Colons in actions: should have 3 steps')
assert(colon_plan.steps[0].action == 'run command: echo hello', 'Action with colon should be preserved')
assert(colon_plan.steps[1].action == 'check status: pending items', 'Action with colon+space should be preserved')
assert(colon_plan.steps[2].action == 'URL: https://example.com test', 'Action with URL-like colon should be preserved')

# Roundtrip with colons
colon_source = Autoexec::TaskDsl.to_source(colon_plan)
colon_plan2 = Autoexec::TaskDsl.parse(colon_source)
assert(colon_plan2.steps[0].action == colon_plan.steps[0].action, 'Colon roundtrip: action preserved')

# JSON with colons
colon_json = JSON.generate({
  task_id: 'colon_json_test',
  steps: [{ step_id: 's1', action: 'deploy to server: production', risk: 'medium' }]
})
colon_json_plan = Autoexec::TaskDsl.from_json(colon_json)
assert(colon_json_plan.steps[0].action == 'deploy to server: production', 'JSON colon action preserved')

# ============================================================================
section 'TaskDsl — Roundtrip (parse -> to_source -> parse)'
# ============================================================================

source = Autoexec::TaskDsl.to_source(plan)
plan2 = Autoexec::TaskDsl.parse(source)
assert(plan2.task_id == plan.task_id, 'Roundtrip: task_id preserved')
assert(plan2.steps.size == plan.steps.size, 'Roundtrip: step count preserved')
assert(plan2.steps[0].action == plan.steps[0].action, 'Roundtrip: step action preserved')
assert(plan2.steps[2].requires_human_cognition == true, 'Roundtrip: requires_human_cognition preserved')

# Hash determinism
hash1 = Autoexec::TaskDsl.compute_hash(source)
hash2 = Autoexec::TaskDsl.compute_hash(source)
assert(hash1 == hash2, 'Hash should be deterministic')

# ============================================================================
section 'TaskDsl — JSON Input'
# ============================================================================

json_input = JSON.generate({
  task_id: 'json_task',
  meta: { description: 'From JSON', risk_default: 'low' },
  steps: [
    { step_id: 'read_files', action: 'read source code', risk: 'low', depends_on: [] },
    { step_id: 'write_code', action: 'create new file', risk: 'medium', depends_on: ['read_files'] }
  ]
})

json_plan = Autoexec::TaskDsl.from_json(json_input)
assert(json_plan.task_id == :json_task, 'JSON: task_id should be :json_task')
assert(json_plan.steps.size == 2, 'JSON: should have 2 steps')
assert(json_plan.steps[1].depends_on == [:read_files], 'JSON: dependency preserved')
assert(!json_plan.source_hash.nil?, 'JSON: source hash computed')

# ============================================================================
section 'TaskDsl — Forbidden Patterns (Security)'
# ============================================================================

forbidden_dsls = [
  ['eval', "task :bad do\n  step :s1, action: \"eval something\", risk: :low\nend"],
  ['system', "task :bad do\n  step :s1, action: \"system command\", risk: :low\nend"],
  ['require', "task :bad do\n  step :s1, action: \"require lib\", risk: :low\nend"],
  ['Kernel', "task :bad do\n  step :s1, action: \"Kernel.exit\", risk: :low\nend"],
  ['__send__', "task :bad do\n  step :s1, action: \"__send__ method\", risk: :low\nend"],
  ['instance_eval', "task :bad do\n  step :s1, action: \"instance_eval block\", risk: :low\nend"],
  ['File', "task :bad do\n  step :s1, action: \"File.read secrets\", risk: :low\nend"],
  ['ENV', "task :bad do\n  step :s1, action: \"ENV access\", risk: :low\nend"],
]

forbidden_dsls.each do |name, dsl|
  assert_raises(Autoexec::TaskDsl::ParseError, "Should reject DSL with '#{name}'") do
    Autoexec::TaskDsl.parse(dsl)
  end
end

# ============================================================================
section 'TaskDsl — Validation Errors'
# ============================================================================

# Duplicate step IDs
assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject duplicate step IDs') do
  Autoexec::TaskDsl.parse("task :bad do\n  step :s1, action: \"a\", risk: :low\n  step :s1, action: \"b\", risk: :low\nend")
end

# Unknown dependency
assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject unknown dependency') do
  Autoexec::TaskDsl.parse("task :bad do\n  step :s1, action: \"a\", risk: :low, depends_on: [:nonexistent]\nend")
end

# Invalid risk
assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject invalid risk') do
  Autoexec::TaskDsl.parse("task :bad do\n  step :s1, action: \"a\", risk: :extreme\nend")
end

# Circular dependency
assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject circular dependency') do
  Autoexec::TaskDsl.parse("task :bad do\n  step :s1, action: \"a\", risk: :low, depends_on: [:s2]\n  step :s2, action: \"b\", risk: :low, depends_on: [:s1]\nend")
end

# ============================================================================
section 'TaskDsl — Path Traversal Prevention'
# ============================================================================

# Path traversal in task_id via JSON
assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject task_id with path traversal') do
  Autoexec::TaskDsl.from_json(JSON.generate({ task_id: '../../etc/cron', steps: [] }))
end

assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject task_id with slashes') do
  Autoexec::TaskDsl.from_json(JSON.generate({ task_id: 'foo/bar', steps: [] }))
end

assert_raises(Autoexec::TaskDsl::ParseError, 'Should reject task_id with dots') do
  Autoexec::TaskDsl.from_json(JSON.generate({ task_id: 'foo.bar', steps: [] }))
end

# Valid task_id should still work
valid_json = JSON.generate({ task_id: 'valid_task_123', meta: { description: 'test' }, steps: [] })
valid_plan = Autoexec::TaskDsl.from_json(valid_json)
assert(valid_plan.task_id == :valid_task_123, 'Valid task_id should be accepted')

# ============================================================================
section 'RiskClassifier — Static Rules'
# ============================================================================

assert(Autoexec::RiskClassifier.classify(action: 'read files') == :low, 'read should be :low')
assert(Autoexec::RiskClassifier.classify(action: 'search codebase') == :low, 'search should be :low')
assert(Autoexec::RiskClassifier.classify(action: 'analyze patterns') == :low, 'analyze should be :low')
assert(Autoexec::RiskClassifier.classify(action: 'edit source code') == :medium, 'edit should be :medium')
assert(Autoexec::RiskClassifier.classify(action: 'create new file') == :medium, 'create should be :medium')
assert(Autoexec::RiskClassifier.classify(action: 'delete old files') == :high, 'delete should be :high')
assert(Autoexec::RiskClassifier.classify(action: 'push to remote') == :high, 'push should be :high')
assert(Autoexec::RiskClassifier.classify(action: 'something unknown') == :medium, 'unknown should default to :medium')

# ============================================================================
section 'RiskClassifier — L0 Deny List'
# ============================================================================

assert(Autoexec::RiskClassifier.denied?('l0_evolution') == true, 'l0_evolution should be denied')
assert(Autoexec::RiskClassifier.denied?('chain_modification') == true, 'chain_modification should be denied')
assert(Autoexec::RiskClassifier.denied?('skill_deletion') == true, 'skill_deletion should be denied')
assert(Autoexec::RiskClassifier.denied?('read files') == false, 'read files should not be denied')

assert_raises(Autoexec::RiskClassifier::DeniedOperationError, 'Should raise on denied operation') do
  Autoexec::RiskClassifier.classify(action: 'l0_evolution attempt')
end

# ============================================================================
section 'RiskClassifier — Protected Files'
# ============================================================================

assert(Autoexec::RiskClassifier.classify(action: 'edit config', target: 'autoexec.yml') == :high,
       'autoexec.yml should force :high')
assert(Autoexec::RiskClassifier.classify(action: 'edit config', target: 'config.yml') == :high,
       'config.yml should force :high')
assert(Autoexec::RiskClassifier.classify(action: 'edit config', target: 'kairos.rb') == :high,
       'kairos.rb should force :high')
assert(Autoexec::RiskClassifier.classify(action: 'edit config', target: '.env') == :high,
       '.env should force :high')

# ============================================================================
section 'RiskClassifier — L0 Firewall'
# ============================================================================

assert(Autoexec::RiskClassifier.classify(action: 'modify l0 skill') == :high,
       'L0-touching action should be :high')
assert(Autoexec::RiskClassifier.classify(action: 'edit core_safety rules') == :high,
       'core_safety action should be :high')

# ============================================================================
section 'PlanStore — Save/Load/Hash'
# ============================================================================

# Use temp directory for test storage
test_dir = File.join(Dir.tmpdir, "autoexec_test_#{Process.pid}")
FileUtils.mkdir_p(test_dir)

# Override storage path for testing
Autoexec.instance_variable_set(:@config, {
  'stale_lock_timeout' => 3600,
  'max_steps' => 20
})

original_storage = Autoexec.method(:storage_path)
Autoexec.define_singleton_method(:storage_path) do |subdir|
  path = File.join(test_dir, subdir)
  FileUtils.mkdir_p(path) unless Dir.exist?(path)
  path
end

begin
  test_plan = Autoexec::TaskDsl.parse(valid_dsl)
  test_source = Autoexec::TaskDsl.to_source(test_plan)
  test_hash = Autoexec::PlanStore.save('test_save', test_plan, test_source)

  assert(!test_hash.nil?, 'Save should return hash')
  assert(test_hash.length == 64, 'Hash should be SHA-256 (64 hex chars)')

  loaded = Autoexec::PlanStore.load('test_save')
  assert(!loaded.nil?, 'Load should return data')
  assert(loaded[:hash] == test_hash, 'Loaded hash should match saved hash')
  assert(loaded[:plan].task_id == :test_task, 'Loaded plan should have correct task_id')

  assert(Autoexec::PlanStore.verify_hash('test_save', test_hash) == true, 'Hash should verify')
  assert(Autoexec::PlanStore.verify_hash('test_save', 'wrong_hash') == false, 'Wrong hash should fail')
  assert(Autoexec::PlanStore.verify_hash('nonexistent', test_hash) == false, 'Nonexistent task should fail')

  # List
  list = Autoexec::PlanStore.list
  assert(list.size >= 1, 'List should contain at least 1 plan')

  # ============================================================================
  section 'PlanStore — Execution Lock'
  # ============================================================================

  assert(Autoexec::PlanStore.locked? == false, 'Should not be locked initially')

  Autoexec::PlanStore.acquire_lock('test_lock')
  assert(Autoexec::PlanStore.locked? == true, 'Should be locked after acquire')

  # Double lock should raise
  assert_raises(RuntimeError, 'Should raise on double lock') do
    Autoexec::PlanStore.acquire_lock('test_lock_2')
  end

  Autoexec::PlanStore.release_lock
  assert(Autoexec::PlanStore.locked? == false, 'Should be unlocked after release')

  # ============================================================================
  section 'PlanStore — Checkpoint'
  # ============================================================================

  checkpoint_data = { task_id: 'test_cp', completed_steps: ['s1'], halted_at_step: 's2' }
  Autoexec::PlanStore.save_checkpoint('test_cp', checkpoint_data)

  loaded_cp = Autoexec::PlanStore.load_checkpoint('test_cp')
  assert(!loaded_cp.nil?, 'Checkpoint should load')
  assert(loaded_cp[:task_id] == 'test_cp', 'Checkpoint task_id should match')

  Autoexec::PlanStore.clear_checkpoint('test_cp')
  assert(Autoexec::PlanStore.load_checkpoint('test_cp').nil?, 'Checkpoint should be cleared')

ensure
  # Cleanup
  FileUtils.rm_rf(test_dir)
  Autoexec.define_singleton_method(:storage_path, original_storage)
end

# ============================================================================
# Summary
# ============================================================================

puts "\n\n#{'=' * 60}"
puts "AutoExec SkillSet Tests: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $errors.empty?
  puts "\nFailures:"
  $errors.each_with_index { |e, i| puts "  #{i + 1}. #{e}" }
end

exit($fail > 0 ? 1 : 0)
