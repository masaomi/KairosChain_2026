#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1 tests for DSL/AST partial formalization
# Tests: DefinitionContext, AstNode, FormalizationDecision, backward compatibility, MCP tools

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'fileutils'
require 'kairos_mcp/skill_contexts'
require 'kairos_mcp/skills_dsl'
require 'kairos_mcp/kairos_chain/formalization_decision'

passed = 0
failed = 0

def assert(description, condition)
  if condition
    puts "  ✅ #{description}"
    true
  else
    puts "  ❌ #{description}"
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
# 1. AstNode Tests
# =============================================================================
test_section("AstNode Struct") do
  node = KairosMcp::AstNode.new(
    type: :Constraint,
    name: :ethics_approval,
    options: { required: true, timing: :before_data_collection },
    source_span: nil
  )

  result = assert("AstNode can be created", !node.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("AstNode type is :Constraint", node.type == :Constraint)
  passed += 1 if result; failed += 1 unless result

  result = assert("AstNode name is :ethics_approval", node.name == :ethics_approval)
  passed += 1 if result; failed += 1 unless result

  h = node.to_h
  result = assert("AstNode#to_h returns hash with type", h[:type] == :Constraint)
  passed += 1 if result; failed += 1 unless result

  result = assert("AstNode#to_h includes options", h[:options][:required] == true)
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 2. DefinitionContext Tests
# =============================================================================
test_section("DefinitionContext") do
  ctx = KairosMcp::DefinitionContext.new

  ctx.constraint :ethics_approval,
    required: true,
    timing: :before_data_collection

  ctx.node :hypothesis_revision,
    type: :SemanticReasoning,
    prompt: "Revise hypothesis flexibly",
    source_span: "Consider revising hypothesis"

  ctx.plan :experiment_workflow,
    steps: [:design, :execute, :analyze, :report]

  ctx.tool_call :run_pipeline,
    command: "ezrun --pipeline rnaseq"

  ctx.check :data_quality,
    condition: "quality_score >= 0.8"

  result = assert("DefinitionContext has 5 nodes", ctx.nodes.size == 5)
  passed += 1 if result; failed += 1 unless result

  result = assert("First node is Constraint", ctx.nodes[0].type == :Constraint)
  passed += 1 if result; failed += 1 unless result

  result = assert("Second node is SemanticReasoning", ctx.nodes[1].type == :SemanticReasoning)
  passed += 1 if result; failed += 1 unless result

  result = assert("Third node is Plan", ctx.nodes[2].type == :Plan)
  passed += 1 if result; failed += 1 unless result

  result = assert("Fourth node is ToolCall", ctx.nodes[3].type == :ToolCall)
  passed += 1 if result; failed += 1 unless result

  result = assert("Fifth node is Check", ctx.nodes[4].type == :Check)
  passed += 1 if result; failed += 1 unless result

  h = ctx.to_h
  result = assert("DefinitionContext#to_h has :nodes key", h.key?(:nodes))
  passed += 1 if result; failed += 1 unless result

  result = assert("Serialized nodes count matches", h[:nodes].size == 5)
  passed += 1 if result; failed += 1 unless result

  # SemanticReasoning node retains prompt
  sr_node = ctx.nodes[1]
  result = assert("SemanticReasoning has prompt in options", sr_node.options[:prompt] == "Revise hypothesis flexibly")
  passed += 1 if result; failed += 1 unless result

  result = assert("SemanticReasoning has source_span", sr_node.source_span == "Consider revising hypothesis")
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 3. Skill Struct Extension Tests
# =============================================================================
test_section("Skill Struct with definition + formalization_notes") do
  skill = KairosMcp::SkillsDsl::Skill.new(
    id: :test_skill,
    version: "1.0",
    title: "Test Skill",
    content: "Some content",
    definition: nil,
    formalization_notes: nil
  )

  result = assert("Skill with nil definition works", skill.definition.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("Skill with nil formalization_notes works", skill.formalization_notes.nil?)
  passed += 1 if result; failed += 1 unless result

  h = skill.to_h
  result = assert("Skill#to_h does not include nil definition", !h.key?(:definition) || h[:definition].nil?)
  passed += 1 if result; failed += 1 unless result

  # Skill with definition
  ctx = KairosMcp::DefinitionContext.new
  ctx.constraint :test_constraint, required: true

  skill_with_def = KairosMcp::SkillsDsl::Skill.new(
    id: :test_skill2,
    version: "1.0",
    title: "Test Skill 2",
    content: "Content",
    definition: ctx,
    formalization_notes: "## Notes\nSome formalization notes."
  )

  result = assert("Skill with definition has nodes", skill_with_def.definition.nodes.size == 1)
  passed += 1 if result; failed += 1 unless result

  result = assert("Skill has formalization_notes", skill_with_def.formalization_notes.include?("Notes"))
  passed += 1 if result; failed += 1 unless result

  h2 = skill_with_def.to_h
  result = assert("Skill#to_h includes definition when present", h2[:definition][:nodes].size == 1)
  passed += 1 if result; failed += 1 unless result

  result = assert("Skill#to_h includes formalization_notes when present", h2[:formalization_notes].include?("Notes"))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 4. SkillBuilder DSL Tests
# =============================================================================
test_section("SkillBuilder with definition block") do
  dsl = KairosMcp::SkillsDsl.new

  # Simulate DSL evaluation
  dsl.instance_eval do
    skill :research_protocol do
      version "1.0"
      title "Research Protocol"

      content "Research requires ethics approval and reproducibility."

      definition do
        constraint :ethics_approval,
          required: true,
          timing: :before_data_collection

        node :hypothesis_revision,
          type: :SemanticReasoning,
          prompt: "Revise flexibly"
      end

      formalization_notes "## Notes\nEthics is binary. Hypothesis revision is contextual."

      evolve do
        allow :content, :definition, :formalization_notes
        deny :behavior
      end
    end
  end

  skills = dsl.skills
  result = assert("DSL parsed one skill", skills.size == 1)
  passed += 1 if result; failed += 1 unless result

  skill = skills.first
  result = assert("Skill id is :research_protocol", skill.id == :research_protocol)
  passed += 1 if result; failed += 1 unless result

  result = assert("Skill has definition", !skill.definition.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("Definition has 2 nodes", skill.definition.nodes.size == 2)
  passed += 1 if result; failed += 1 unless result

  result = assert("Skill has formalization_notes", !skill.formalization_notes.nil?)
  passed += 1 if result; failed += 1 unless result

  # Evolve rules allow definition
  result = assert("Evolve allows :definition", skill.can_evolve?(:definition))
  passed += 1 if result; failed += 1 unless result

  result = assert("Evolve allows :formalization_notes", skill.can_evolve?(:formalization_notes))
  passed += 1 if result; failed += 1 unless result

  result = assert("Evolve denies :behavior", !skill.can_evolve?(:behavior))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 5. Backward Compatibility — Skills without definition
# =============================================================================
test_section("Backward Compatibility") do
  dsl = KairosMcp::SkillsDsl.new

  dsl.instance_eval do
    skill :legacy_skill do
      version "1.0"
      title "Legacy Skill"
      content "No definition block here."

      evolve do
        allow :content
        deny :behavior
      end
    end
  end

  skill = dsl.skills.first
  result = assert("Legacy skill loads without definition", skill.definition.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("Legacy skill loads without formalization_notes", skill.formalization_notes.nil?)
  passed += 1 if result; failed += 1 unless result

  result = assert("Legacy skill content is intact", skill.content == "No definition block here.")
  passed += 1 if result; failed += 1 unless result

  result = assert("Legacy skill to_h works", skill.to_h.is_a?(Hash))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 6. FormalizationDecision Tests
# =============================================================================
test_section("FormalizationDecision") do
  decision = KairosMcp::KairosChain::FormalizationDecision.new(
    skill_id: "core_safety",
    skill_version: "1.1",
    source_text: "Evolution is disabled by default",
    result: :formalized,
    rationale: "Binary condition. No ambiguity acceptable.",
    formalization_category: :invariant,
    ambiguity_before: :low,
    ambiguity_after: :none,
    decided_by: :human,
    confidence: 0.99
  )

  result = assert("FormalizationDecision created", !decision.nil?)
  passed += 1 if result; failed += 1 unless result

  h = decision.to_h
  result = assert("to_h has :type => :formalization_decision", h[:type] == :formalization_decision)
  passed += 1 if result; failed += 1 unless result

  result = assert("to_h has correct skill_id", h[:skill_id] == "core_safety")
  passed += 1 if result; failed += 1 unless result

  result = assert("to_h has correct result", h[:result] == :formalized)
  passed += 1 if result; failed += 1 unless result

  json = decision.to_json
  result = assert("to_json produces valid JSON", JSON.parse(json).is_a?(Hash))
  passed += 1 if result; failed += 1 unless result

  # Round-trip
  restored = KairosMcp::KairosChain::FormalizationDecision.from_json(json)
  result = assert("from_json restores skill_id", restored.skill_id == "core_safety")
  passed += 1 if result; failed += 1 unless result

  result = assert("from_json restores rationale", restored.rationale == "Binary condition. No ambiguity acceptable.")
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# 7. FormalizationDecision Blockchain Recording
# =============================================================================
test_section("FormalizationDecision Blockchain Recording") do
  require 'kairos_mcp/kairos_chain/chain'

  # Use a temporary chain file
  test_chain_dir = File.join(__dir__, 'tmp_test_chain')
  FileUtils.mkdir_p(test_chain_dir)
  test_chain_file = File.join(test_chain_dir, 'test_chain.json')

  begin
    # Create a test storage backend
    require 'kairos_mcp/storage/backend'
    require 'kairos_mcp/storage/file_backend'
    backend = KairosMcp::Storage::FileBackend.new(
      storage_dir: test_chain_dir,
      blockchain_file: test_chain_file,
      action_log_file: File.join(test_chain_dir, 'action_log.jsonl')
    )
    chain = KairosMcp::KairosChain::Chain.new(storage_backend: backend)

    initial_count = chain.chain.size

    decision = KairosMcp::KairosChain::FormalizationDecision.new(
      skill_id: "evolution_rules",
      skill_version: "1.0",
      source_text: "Session evolution count < max_evolutions_per_session",
      result: :formalized,
      rationale: "Numeric comparison. Fully deterministic.",
      formalization_category: :rule,
      decided_by: :human
    )

    new_block = chain.add_block([decision.to_json])

    result = assert("Block was added", chain.chain.size == initial_count + 1)
    passed += 1 if result; failed += 1 unless result

    result = assert("Block has correct index", new_block.index == initial_count)
    passed += 1 if result; failed += 1 unless result

    # Verify the data can be parsed back
    stored_data = JSON.parse(new_block.data.first, symbolize_names: true)
    result = assert("Stored data has type :formalization_decision", stored_data[:type].to_s == "formalization_decision")
    passed += 1 if result; failed += 1 unless result

    result = assert("Stored data has correct skill_id", stored_data[:skill_id] == "evolution_rules")
    passed += 1 if result; failed += 1 unless result

    result = assert("Chain is still valid", chain.valid?)
    passed += 1 if result; failed += 1 unless result
  ensure
    FileUtils.rm_rf(test_chain_dir)
  end
end

# =============================================================================
# 8. Load kairos.rb with new definition blocks
# =============================================================================
test_section("Load kairos.rb with definition blocks") do
  skills_path = File.expand_path('skills/kairos.rb', __dir__)

  begin
    skills = KairosMcp::SkillsDsl.load(skills_path)

    result = assert("kairos.rb loads successfully", skills.is_a?(Array))
    passed += 1 if result; failed += 1 unless result

    result = assert("kairos.rb has 8 skills", skills.size == 8)
    passed += 1 if result; failed += 1 unless result

    # core_safety should have definition
    core_safety = skills.find { |s| s.id == :core_safety }
    result = assert("core_safety exists", !core_safety.nil?)
    passed += 1 if result; failed += 1 unless result

    result = assert("core_safety has definition", !core_safety.definition.nil?)
    passed += 1 if result; failed += 1 unless result

    result = assert("core_safety definition has 4 Constraint nodes", core_safety.definition.nodes.size == 4)
    passed += 1 if result; failed += 1 unless result

    result = assert("core_safety has formalization_notes", !core_safety.formalization_notes.nil?)
    passed += 1 if result; failed += 1 unless result

    # evolution_rules should have definition
    evolution = skills.find { |s| s.id == :evolution_rules }
    result = assert("evolution_rules exists", !evolution.nil?)
    passed += 1 if result; failed += 1 unless result

    result = assert("evolution_rules has definition", !evolution.definition.nil?)
    passed += 1 if result; failed += 1 unless result

    result = assert("evolution_rules definition has 6 nodes", evolution.definition.nodes.size == 6)
    passed += 1 if result; failed += 1 unless result

    # Mixed node types in evolution_rules
    node_types = evolution.definition.nodes.map(&:type)
    result = assert("evolution_rules has Constraint nodes", node_types.count(:Constraint) == 3)
    passed += 1 if result; failed += 1 unless result

    result = assert("evolution_rules has Check node", node_types.include?(:Check))
    passed += 1 if result; failed += 1 unless result

    result = assert("evolution_rules has Plan node", node_types.include?(:Plan))
    passed += 1 if result; failed += 1 unless result

    result = assert("evolution_rules has SemanticReasoning node", node_types.include?(:SemanticReasoning))
    passed += 1 if result; failed += 1 unless result

    # Skills WITHOUT definition should still work
    layer_awareness = skills.find { |s| s.id == :layer_awareness }
    result = assert("layer_awareness has no definition (backward compat)", layer_awareness.definition.nil?)
    passed += 1 if result; failed += 1 unless result

    result = assert("layer_awareness content is intact", layer_awareness.content.include?("Layer Structure"))
    passed += 1 if result; failed += 1 unless result
  rescue StandardError => e
    result = assert("kairos.rb loading failed: #{e.message}", false)
    failed += 1
    puts e.backtrace.first(5).join("\n")
  end
end

# =============================================================================
# 9. MCP Tool Integration Tests
# =============================================================================
test_section("MCP Tool Integration") do
  require 'kairos_mcp/protocol'
  require 'kairos_mcp/skills_config'
  require 'kairos_mcp/layer_registry'

  protocol = KairosMcp::Protocol.new

  # Initialize
  init_request = {
    jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {} }
  }
  protocol.handle_message(init_request.to_json)

  # Check tools list includes new tools
  tools_request = {
    jsonrpc: '2.0', id: 1, method: 'tools/list'
  }
  response = protocol.handle_message(tools_request.to_json)
  tool_names = response[:result][:tools].map { |t| t[:name] }

  result = assert("formalization_record tool is registered", tool_names.include?('formalization_record'))
  passed += 1 if result; failed += 1 unless result

  result = assert("formalization_history tool is registered", tool_names.include?('formalization_history'))
  passed += 1 if result; failed += 1 unless result

  # Test skills_dsl_get with definition
  get_request = {
    jsonrpc: '2.0', id: 2, method: 'tools/call',
    params: {
      name: 'skills_dsl_get',
      arguments: { 'skill_id' => 'core_safety' }
    }
  }
  response = protocol.handle_message(get_request.to_json)
  output_text = response[:result][:content].first[:text]

  result = assert("skills_dsl_get shows Definition section", output_text.include?("Structural Layer"))
  passed += 1 if result; failed += 1 unless result

  result = assert("skills_dsl_get shows Constraint nodes", output_text.include?("Constraint"))
  passed += 1 if result; failed += 1 unless result

  result = assert("skills_dsl_get shows Formalization Notes", output_text.include?("Formalization Notes"))
  passed += 1 if result; failed += 1 unless result

  # Test skills_dsl_get for skill WITHOUT definition (backward compat)
  get_request2 = {
    jsonrpc: '2.0', id: 3, method: 'tools/call',
    params: {
      name: 'skills_dsl_get',
      arguments: { 'skill_id' => 'layer_awareness' }
    }
  }
  response2 = protocol.handle_message(get_request2.to_json)
  output_text2 = response2[:result][:content].first[:text]

  result = assert("skills_dsl_get for legacy skill has no Definition section", !output_text2.include?("Structural Layer"))
  passed += 1 if result; failed += 1 unless result

  result = assert("skills_dsl_get for legacy skill still shows content", output_text2.include?("Layer Structure"))
  passed += 1 if result; failed += 1 unless result
end

# =============================================================================
# Summary
# =============================================================================
puts "\n#{'=' * 60}"
puts "RESULTS: #{passed} passed, #{failed} failed (#{passed + failed} total)"
puts '=' * 60

exit(failed > 0 ? 1 : 0)
