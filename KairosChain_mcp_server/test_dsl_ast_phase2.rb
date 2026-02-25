#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 2 tests for DSL/AST executable definitions & drift detection
# Tests: AstEngine, Decompiler, DriftDetector, MCP tools, backward compatibility

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'fileutils'
require 'kairos_mcp/skill_contexts'
require 'kairos_mcp/skills_dsl'
require 'kairos_mcp/dsl_ast/ast_engine'
require 'kairos_mcp/dsl_ast/decompiler'
require 'kairos_mcp/dsl_ast/drift_detector'

passed = 0
failed = 0

def assert(description, condition)
  if condition
    puts "  \u2705 #{description}"
    true
  else
    puts "  \u274c #{description}"
    false
  end
end

def test_section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
  yield
end

# =============================================================================
# 1. AstEngine: evaluate_node for each node type
# =============================================================================
test_section("AstEngine — Constraint evaluation") do
  # Constraint with no condition (structural declaration)
  node = KairosMcp::AstNode.new(
    type: :Constraint, name: :ethics,
    options: { required: true }, source_span: nil
  )
  r = KairosMcp::DslAst::AstEngine.evaluate_node(node)
  result = assert("Constraint with required: true is satisfied", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result

  result = assert("Constraint with required: true is evaluable", r.evaluable == true)
  passed += 1 if result; failed += 1 unless result

  # Constraint with boolean condition — variable present
  node2 = KairosMcp::AstNode.new(
    type: :Constraint, name: :enabled,
    options: { condition: "evolution_enabled == true" }, source_span: nil
  )
  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node2, binding_context: { evolution_enabled: true })
  result = assert("Constraint 'X == true' satisfied when true", r2.satisfied == true)
  passed += 1 if result; failed += 1 unless result

  # Constraint with boolean condition — variable false
  r3 = KairosMcp::DslAst::AstEngine.evaluate_node(node2, binding_context: { evolution_enabled: false })
  result = assert("Constraint 'X == true' not satisfied when false", r3.satisfied == false)
  passed += 1 if result; failed += 1 unless result

  # Constraint with boolean condition — variable missing
  r4 = KairosMcp::DslAst::AstEngine.evaluate_node(node2, binding_context: {})
  result = assert("Constraint with missing variable is not evaluable", r4.evaluable == false)
  passed += 1 if result; failed += 1 unless result

  result = assert("Constraint with missing variable has :unknown satisfied", r4.satisfied == :unknown)
  passed += 1 if result; failed += 1 unless result

  # Constraint with no condition and no required flag
  node3 = KairosMcp::AstNode.new(
    type: :Constraint, name: :simple,
    options: { scope: :l0 }, source_span: nil
  )
  r5 = KairosMcp::DslAst::AstEngine.evaluate_node(node3)
  result = assert("Constraint without condition is structurally satisfied", r5.satisfied == true)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — Numeric comparison") do
  node = KairosMcp::AstNode.new(
    type: :Constraint, name: :limit,
    options: { condition: "evolution_count < max_evolutions_per_session" }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {
    evolution_count: 2, max_evolutions_per_session: 5
  })
  result = assert("2 < 5 is satisfied", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("Numeric comparison is evaluable", r.evaluable == true)
  passed += 1 if result; failed += 1 unless result

  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {
    evolution_count: 5, max_evolutions_per_session: 5
  })
  result = assert("5 < 5 is not satisfied", r2.satisfied == false)
  passed += 1 if result; failed += 1 unless result

  # Missing variables
  r3 = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {})
  result = assert("Missing numeric vars are not evaluable", r3.evaluable == false)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — Method call pattern") do
  node = KairosMcp::AstNode.new(
    type: :Check, name: :evolve_check,
    options: { condition: "skill.can_evolve?(:content)" }, source_span: nil
  )

  # Create a mock skill with evolve context
  dsl = KairosMcp::SkillsDsl.new
  dsl.instance_eval do
    skill :test do
      version "1.0"
      title "Test"
      content "test"
      evolve do
        allow :content
        deny :behavior
      end
    end
  end
  test_skill = dsl.skills.first

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: { skill: test_skill })
  result = assert("Method call can_evolve?(:content) returns true", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("Method call is evaluable", r.evaluable == true)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — 'not in' pattern") do
  node = KairosMcp::AstNode.new(
    type: :Constraint, name: :not_immutable,
    options: { condition: "skill not in immutable_skills" }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {
    skill: :evolution_rules,
    immutable_skills: [:core_safety]
  })
  result = assert("'not in' satisfied when item absent from collection", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result

  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {
    skill: :core_safety,
    immutable_skills: [:core_safety]
  })
  result = assert("'not in' not satisfied when item in collection", r2.satisfied == false)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — Check node") do
  node = KairosMcp::AstNode.new(
    type: :Check, name: :quality,
    options: { condition: "quality_score >= threshold" }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node, binding_context: {
    quality_score: 0.9, threshold: 0.8
  })
  result = assert("Check 0.9 >= 0.8 is satisfied", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("Check node type is :Check", r.node_type == :Check)
  passed += 1 if result; failed += 1 unless result

  # No condition
  node2 = KairosMcp::AstNode.new(
    type: :Check, name: :empty, options: {}, source_span: nil
  )
  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node2)
  result = assert("Check without condition is not evaluable", r2.evaluable == false)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — Plan node") do
  node = KairosMcp::AstNode.new(
    type: :Plan, name: :workflow,
    options: { steps: [:propose, :review, :apply] }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node)
  result = assert("Plan with steps is satisfied", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("Plan is evaluable", r.evaluable == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("Plan detail includes step count", r.detail.include?("3 steps"))
  passed += 1 if result; failed += 1 unless result

  # Plan with no steps
  node2 = KairosMcp::AstNode.new(
    type: :Plan, name: :empty_plan, options: { steps: [] }, source_span: nil
  )
  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node2)
  result = assert("Plan with empty steps is not satisfied", r2.satisfied == false)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — ToolCall node") do
  node = KairosMcp::AstNode.new(
    type: :ToolCall, name: :run_pipeline,
    options: { command: "ezrun --pipeline rnaseq" }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node)
  result = assert("ToolCall with command is satisfied", r.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("ToolCall is evaluable", r.evaluable == true)
  passed += 1 if result; failed += 1 unless result

  # ToolCall with no command
  node2 = KairosMcp::AstNode.new(
    type: :ToolCall, name: :no_cmd, options: {}, source_span: nil
  )
  r2 = KairosMcp::DslAst::AstEngine.evaluate_node(node2)
  result = assert("ToolCall without command is not satisfied", r2.satisfied == false)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — SemanticReasoning node") do
  node = KairosMcp::AstNode.new(
    type: :SemanticReasoning, name: :review,
    options: { prompt: "Human reviews for correctness" }, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node)
  result = assert("SemanticReasoning is not evaluable", r.evaluable == false)
  passed += 1 if result; failed += 1 unless result
  result = assert("SemanticReasoning satisfied is :unknown", r.satisfied == :unknown)
  passed += 1 if result; failed += 1 unless result
  result = assert("SemanticReasoning detail includes prompt", r.detail.include?("Human reviews"))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 2. AstEngine: verify with real Skills from kairos.rb
# =============================================================================
test_section("AstEngine — verify core_safety") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  core_safety = skills.find { |s| s.id == :core_safety }

  report = KairosMcp::DslAst::AstEngine.verify(core_safety)

  result = assert("core_safety verification returns report", !report.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("core_safety has 4 results", report.results.size == 4)
  passed += 1 if result; failed += 1 unless result

  result = assert("core_safety skill_id is correct", report.skill_id == :core_safety)
  passed += 1 if result; failed += 1 unless result

  # All are Constraints — some have conditions that need binding_context
  # Without binding_context, condition-bearing nodes should be non-evaluable or structurally valid
  result = assert("core_safety has timestamp", !report.timestamp.nil?)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — verify evolution_rules") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  evolution = skills.find { |s| s.id == :evolution_rules }

  report = KairosMcp::DslAst::AstEngine.verify(evolution)

  result = assert("evolution_rules has 6 results", report.results.size == 6)
  passed += 1 if result; failed += 1 unless result

  result = assert("evolution_rules has human_required nodes", !report.human_required.empty?)
  passed += 1 if result; failed += 1 unless result

  # SemanticReasoning should be in human_required
  sr = report.human_required.find { |r| r.node_type == :SemanticReasoning }
  result = assert("SemanticReasoning is in human_required", !sr.nil?)
  passed += 1 if result; failed += 1 unless result

  # Plan node should be evaluable and satisfied
  plan_result = report.results.find { |r| r.node_type == :Plan }
  result = assert("Plan node is satisfied", plan_result.satisfied == true)
  passed += 1 if result; failed += 1 unless result

  result = assert("Plan node is evaluable", plan_result.evaluable == true)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — verify with binding_context") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  core_safety = skills.find { |s| s.id == :core_safety }

  report = KairosMcp::DslAst::AstEngine.verify(core_safety, binding_context: {
    evolution_enabled: true
  })

  # The explicit_enablement constraint should now be evaluable
  enablement = report.results.find { |r| r.node_name == :explicit_enablement }
  result = assert("explicit_enablement with context is satisfied", enablement.satisfied == true)
  passed += 1 if result; failed += 1 unless result
  result = assert("explicit_enablement with context is evaluable", enablement.evaluable == true)
  passed += 1 if result; failed += 1 unless result
end

test_section("AstEngine — verify returns nil for no-definition skill") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  layer = skills.find { |s| s.id == :layer_awareness }

  report = KairosMcp::DslAst::AstEngine.verify(layer)
  result = assert("verify returns nil for skill without definition", report.nil?)
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 3. Decompiler tests
# =============================================================================
test_section("Decompiler — individual node types") do
  # Constraint
  node = KairosMcp::AstNode.new(
    type: :Constraint, name: :ethics,
    options: { required: true, condition: "approved == true", timing: :before },
    source_span: nil
  )
  md = KairosMcp::DslAst::Decompiler.decompile_node(node)
  result = assert("Constraint decompiles with 'Requirement'", md.include?("**Requirement**"))
  passed += 1 if result; failed += 1 unless result
  result = assert("Constraint includes condition", md.include?("approved == true"))
  passed += 1 if result; failed += 1 unless result
  result = assert("Constraint includes required qualifier", md.include?("required"))
  passed += 1 if result; failed += 1 unless result

  # Plan
  plan_node = KairosMcp::AstNode.new(
    type: :Plan, name: :workflow,
    options: { steps: [:design, :execute, :report] }, source_span: nil
  )
  md2 = KairosMcp::DslAst::Decompiler.decompile_node(plan_node)
  result = assert("Plan decompiles with 'Workflow'", md2.include?("**Workflow**"))
  passed += 1 if result; failed += 1 unless result
  result = assert("Plan includes step count", md2.include?("3 steps"))
  passed += 1 if result; failed += 1 unless result
  result = assert("Plan includes step names", md2.include?("design -> execute -> report"))
  passed += 1 if result; failed += 1 unless result

  # SemanticReasoning
  sr_node = KairosMcp::AstNode.new(
    type: :SemanticReasoning, name: :judge,
    options: { prompt: "Review for correctness" }, source_span: nil
  )
  md3 = KairosMcp::DslAst::Decompiler.decompile_node(sr_node)
  result = assert("SemanticReasoning decompiles with 'Human Judgment Required'", md3.include?("**Human Judgment Required**"))
  passed += 1 if result; failed += 1 unless result

  # Check
  check_node = KairosMcp::AstNode.new(
    type: :Check, name: :quality,
    options: { condition: "score >= 0.8" }, source_span: nil
  )
  md4 = KairosMcp::DslAst::Decompiler.decompile_node(check_node)
  result = assert("Check decompiles with 'Check'", md4.include?("**Check**"))
  passed += 1 if result; failed += 1 unless result

  # ToolCall
  tc_node = KairosMcp::AstNode.new(
    type: :ToolCall, name: :run,
    options: { command: "ezrun --pipeline rnaseq" }, source_span: nil
  )
  md5 = KairosMcp::DslAst::Decompiler.decompile_node(tc_node)
  result = assert("ToolCall decompiles with 'Tool Call'", md5.include?("**Tool Call**"))
  passed += 1 if result; failed += 1 unless result
  result = assert("ToolCall includes command", md5.include?("ezrun"))
  passed += 1 if result; failed += 1 unless result
end

test_section("Decompiler — full definition round-trip") do
  ctx = KairosMcp::DefinitionContext.new
  ctx.constraint :ethics, required: true
  ctx.plan :workflow, steps: [:a, :b, :c]
  ctx.node :review, type: :SemanticReasoning, prompt: "Check it"

  md = KairosMcp::DslAst::Decompiler.decompile(ctx)
  result = assert("Full decompile produces Markdown", md.include?("## Definition (Decompiled)"))
  passed += 1 if result; failed += 1 unless result
  result = assert("Full decompile includes all 3 nodes", md.scan(/\*\*/).size >= 3)
  passed += 1 if result; failed += 1 unless result

  # Empty definition
  empty_ctx = KairosMcp::DefinitionContext.new
  md2 = KairosMcp::DslAst::Decompiler.decompile(empty_ctx)
  result = assert("Empty definition returns empty string", md2 == "")
  passed += 1 if result; failed += 1 unless result

  # Nil definition
  md3 = KairosMcp::DslAst::Decompiler.decompile(nil)
  result = assert("Nil definition returns empty string", md3 == "")
  passed += 1 if result; failed += 1 unless result
end

test_section("Decompiler — real kairos.rb skills") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  core_safety = skills.find { |s| s.id == :core_safety }

  md = KairosMcp::DslAst::Decompiler.decompile(core_safety.definition)
  result = assert("core_safety decompiles to non-empty Markdown", md.length > 50)
  passed += 1 if result; failed += 1 unless result
  result = assert("core_safety decompile includes 4 Requirement items", md.scan("**Requirement**").size == 4)
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 4. DriftDetector tests
# =============================================================================
test_section("DriftDetector — no drift (aligned skill)") do
  dsl = KairosMcp::SkillsDsl.new
  dsl.instance_eval do
    skill :aligned do
      version "1.0"
      title "Aligned Skill"
      content <<~MD
        ## Rules
        Ethics approval is required before any work.
        Human oversight must be maintained.
      MD
      definition do
        constraint :ethics, required: true
        constraint :human_oversight, required: true
      end
    end
  end

  skill = dsl.skills.first
  report = KairosMcp::DslAst::DriftDetector.detect(skill)

  result = assert("Aligned skill has no drift", !report.drifted?)
  passed += 1 if result; failed += 1 unless result
  result = assert("Aligned skill coverage is 1.0", report.coverage_ratio == 1.0)
  passed += 1 if result; failed += 1 unless result
end

test_section("DriftDetector — definition-orphaned drift") do
  dsl = KairosMcp::SkillsDsl.new
  dsl.instance_eval do
    skill :orphaned do
      version "1.0"
      title "Orphaned Node Skill"
      content <<~MD
        ## Rules
        Ethics approval is required.
      MD
      definition do
        constraint :ethics, required: true
        constraint :quantum_validation, required: true  # Not in content
      end
    end
  end

  skill = dsl.skills.first
  report = KairosMcp::DslAst::DriftDetector.detect(skill)

  result = assert("Orphaned definition detected", report.drifted?)
  passed += 1 if result; failed += 1 unless result

  orphaned = report.items.select { |i| i.direction == :definition_orphaned }
  result = assert("Has definition_orphaned item", !orphaned.empty?)
  passed += 1 if result; failed += 1 unless result
  result = assert("Orphaned node is quantum_validation", orphaned.first.node_name == :quantum_validation)
  passed += 1 if result; failed += 1 unless result
  result = assert("Coverage ratio < 1.0", report.coverage_ratio < 1.0)
  passed += 1 if result; failed += 1 unless result
end

test_section("DriftDetector — content-uncovered drift") do
  dsl = KairosMcp::SkillsDsl.new
  dsl.instance_eval do
    skill :uncovered do
      version "1.0"
      title "Uncovered Content Skill"
      content <<~MD
        ## Rules
        Ethics approval is required.
        Blockchain recording must always happen.
        Temporal consistency is mandatory for all operations.
      MD
      definition do
        constraint :ethics, required: true
        constraint :blockchain, required: true
      end
    end
  end

  skill = dsl.skills.first
  report = KairosMcp::DslAst::DriftDetector.detect(skill)

  uncovered = report.items.select { |i| i.direction == :content_uncovered }
  result = assert("Has content_uncovered items", !uncovered.empty?)
  passed += 1 if result; failed += 1 unless result
  result = assert("Uncovered assertion mentions temporal", uncovered.any? { |i| i.description.downcase.include?("temporal") })
  passed += 1 if result; failed += 1 unless result
end

test_section("DriftDetector — skill without definition") do
  dsl = KairosMcp::SkillsDsl.new
  dsl.instance_eval do
    skill :no_def do
      version "1.0"
      title "No Definition"
      content "Just content, no definition."
    end
  end

  skill = dsl.skills.first
  report = KairosMcp::DslAst::DriftDetector.detect(skill)

  result = assert("No-definition skill has no drift", !report.drifted?)
  passed += 1 if result; failed += 1 unless result
  result = assert("No-definition skill coverage is nil", report.coverage_ratio.nil?)
  passed += 1 if result; failed += 1 unless result
end

test_section("DriftDetector — real kairos.rb core_safety") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  core_safety = skills.find { |s| s.id == :core_safety }

  report = KairosMcp::DslAst::DriftDetector.detect(core_safety)

  result = assert("core_safety drift report exists", !report.nil?)
  passed += 1 if result; failed += 1 unless result
  result = assert("core_safety coverage > 0.5", report.coverage_ratio > 0.5)
  passed += 1 if result; failed += 1 unless result
  result = assert("core_safety skill_id is correct", report.skill_id == :core_safety)
  passed += 1 if result; failed += 1 unless result
end

test_section("DriftDetector — real kairos.rb evolution_rules") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)
  skills = KairosMcp::SkillsDsl.load(skills_path)
  evolution = skills.find { |s| s.id == :evolution_rules }

  report = KairosMcp::DslAst::DriftDetector.detect(evolution)

  result = assert("evolution_rules drift report exists", !report.nil?)
  passed += 1 if result; failed += 1 unless result
  result = assert("evolution_rules has coverage ratio", !report.coverage_ratio.nil?)
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 5. MCP Tool Integration
# =============================================================================
test_section("MCP Tool Integration — tool registration") do
  require 'kairos_mcp/protocol'
  require 'kairos_mcp/skills_config'
  require 'kairos_mcp/layer_registry'

  protocol = KairosMcp::Protocol.new

  init_request = {
    jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} }
  }
  protocol.handle_message(init_request.to_json)

  tools_request = { jsonrpc: '2.0', id: 1, method: 'tools/list' }
  response = protocol.handle_message(tools_request.to_json)
  tool_names = response[:result][:tools].map { |t| t[:name] }

  result = assert("definition_verify is registered", tool_names.include?('definition_verify'))
  passed += 1 if result; failed += 1 unless result

  result = assert("definition_decompile is registered", tool_names.include?('definition_decompile'))
  passed += 1 if result; failed += 1 unless result

  result = assert("definition_drift is registered", tool_names.include?('definition_drift'))
  passed += 1 if result; failed += 1 unless result
end

test_section("MCP Tool Integration — definition_verify call") do
  require 'kairos_mcp/protocol'
  protocol = KairosMcp::Protocol.new
  protocol.handle_message({ jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} } }.to_json)

  response = protocol.handle_message({
    jsonrpc: '2.0', id: 2, method: 'tools/call',
    params: { name: 'definition_verify', arguments: { 'skill_id' => 'core_safety' } }
  }.to_json)
  text = response[:result][:content].first[:text]

  result = assert("definition_verify output includes 'Verification Report'", text.include?("Verification Report"))
  passed += 1 if result; failed += 1 unless result
  result = assert("definition_verify output includes Constraint", text.include?("Constraint"))
  passed += 1 if result; failed += 1 unless result

  # Test with no-definition skill
  response2 = protocol.handle_message({
    jsonrpc: '2.0', id: 3, method: 'tools/call',
    params: { name: 'definition_verify', arguments: { 'skill_id' => 'layer_awareness' } }
  }.to_json)
  text2 = response2[:result][:content].first[:text]

  result = assert("definition_verify handles no-definition skill", text2.include?("no definition block"))
  passed += 1 if result; failed += 1 unless result
end

test_section("MCP Tool Integration — definition_decompile call") do
  require 'kairos_mcp/protocol'
  protocol = KairosMcp::Protocol.new
  protocol.handle_message({ jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} } }.to_json)

  response = protocol.handle_message({
    jsonrpc: '2.0', id: 4, method: 'tools/call',
    params: { name: 'definition_decompile', arguments: { 'skill_id' => 'core_safety' } }
  }.to_json)
  text = response[:result][:content].first[:text]

  result = assert("definition_decompile output includes 'Decompile'", text.include?("Decompile"))
  passed += 1 if result; failed += 1 unless result
  result = assert("definition_decompile output includes Requirement", text.include?("Requirement"))
  passed += 1 if result; failed += 1 unless result
end

test_section("MCP Tool Integration — definition_drift call") do
  require 'kairos_mcp/protocol'
  protocol = KairosMcp::Protocol.new
  protocol.handle_message({ jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} } }.to_json)

  response = protocol.handle_message({
    jsonrpc: '2.0', id: 5, method: 'tools/call',
    params: { name: 'definition_drift', arguments: { 'skill_id' => 'core_safety' } }
  }.to_json)
  text = response[:result][:content].first[:text]

  result = assert("definition_drift output includes 'Drift Report'", text.include?("Drift Report"))
  passed += 1 if result; failed += 1 unless result
  result = assert("definition_drift output includes 'Coverage Ratio'", text.include?("Coverage Ratio"))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 6. Backward Compatibility
# =============================================================================
test_section("Backward Compatibility — skills_dsl_get with verification status") do
  require 'kairos_mcp/protocol'
  protocol = KairosMcp::Protocol.new
  protocol.handle_message({ jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} } }.to_json)

  # Skill WITH definition should have Verification Status
  response = protocol.handle_message({
    jsonrpc: '2.0', id: 6, method: 'tools/call',
    params: { name: 'skills_dsl_get', arguments: { 'skill_id' => 'core_safety' } }
  }.to_json)
  text = response[:result][:content].first[:text]

  result = assert("skills_dsl_get shows Verification Status for defined skill", text.include?("Verification Status"))
  passed += 1 if result; failed += 1 unless result

  # Skill WITHOUT definition should NOT have Verification Status
  response2 = protocol.handle_message({
    jsonrpc: '2.0', id: 7, method: 'tools/call',
    params: { name: 'skills_dsl_get', arguments: { 'skill_id' => 'layer_awareness' } }
  }.to_json)
  text2 = response2[:result][:content].first[:text]

  result = assert("skills_dsl_get no Verification Status for legacy skill", !text2.include?("Verification Status"))
  passed += 1 if result; failed += 1 unless result

  result = assert("skills_dsl_get legacy skill still shows content", text2.include?("Layer Structure"))
  passed += 1 if result; failed += 1 unless result
end

test_section("Backward Compatibility — Phase 1 structures unchanged") do
  # DefinitionContext still works
  ctx = KairosMcp::DefinitionContext.new
  ctx.constraint :test, required: true
  result = assert("DefinitionContext API unchanged", ctx.nodes.size == 1)
  passed += 1 if result; failed += 1 unless result

  # AstNode still works
  node = KairosMcp::AstNode.new(type: :Constraint, name: :test, options: {}, source_span: nil)
  result = assert("AstNode API unchanged", node.to_h.is_a?(Hash))
  passed += 1 if result; failed += 1 unless result

  # NodeResult and VerificationReport are new but don't break old code
  nr = KairosMcp::DslAst::NodeResult.new(
    node_name: :test, node_type: :Constraint,
    satisfied: true, detail: "ok", evaluable: true
  )
  result = assert("NodeResult struct works", nr.satisfied == true)
  passed += 1 if result; failed += 1 unless result

  vr = KairosMcp::DslAst::VerificationReport.new(
    skill_id: :test, results: [nr], timestamp: Time.now.iso8601
  )
  result = assert("VerificationReport struct works", vr.all_deterministic_passed?)
  passed += 1 if result; failed += 1 unless result
  result = assert("VerificationReport summary works", vr.summary[:total] == 1)
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 7. Unknown node type handling
# =============================================================================
test_section("Edge Cases — unknown node type") do
  node = KairosMcp::AstNode.new(
    type: :FutureType, name: :unknown_node, options: {}, source_span: nil
  )

  r = KairosMcp::DslAst::AstEngine.evaluate_node(node)
  result = assert("Unknown node type returns evaluable: false", r.evaluable == false)
  passed += 1 if result; failed += 1 unless result

  md = KairosMcp::DslAst::Decompiler.decompile_node(node)
  result = assert("Unknown node type decompiles gracefully", md.include?("Unknown"))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# Summary
# =============================================================================
puts "\n#{'=' * 60}"
puts "RESULTS: #{passed} passed, #{failed} failed (#{passed + failed} total)"
puts '=' * 60

exit(failed > 0 ? 1 : 0)
