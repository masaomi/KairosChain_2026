#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: SkillSet-declared knowledge dirs are reachable from any KnowledgeProvider
#
# Regression test for the defect found 2026-07-26: knowledge bundled with a
# SkillSet and declared in skillset.json `knowledge_dirs` was write-only —
# present on disk, declared in the manifest, and unreachable by name. Two causes:
#   1. Nothing in the core read `knowledge_dirs`; the field was declarative only.
#   2. `add_external_dir` mutates one provider instance at SkillSet load time,
#      while knowledge_get builds a fresh provider per call, discarding it.
#
# The fix resolves `knowledge_dirs` at provider construction, so the manifest
# declaration is load-bearing for every provider instance.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'
require 'tmpdir'
require 'fileutils'
require 'json'

@failures = 0
@passes = 0

def assert(cond, msg)
  if cond
    print '.'
    @passes += 1
  else
    puts "\nFAIL: #{msg}"
    @failures += 1
  end
end

def write_knowledge(dir, name, description)
  FileUtils.mkdir_p(File.join(dir, name))
  File.write(File.join(dir, name, "#{name}.md"), <<~MD)
    ---
    title: #{name}
    description: #{description}
    version: "0.1.0"
    tags: [test]
    ---

    # #{name}

    Body of #{name}.
  MD
end

def write_skillset(skillsets_dir, name, knowledge_dirs:, layer: 'L1', valid_json: true)
  ss_dir = File.join(skillsets_dir, name)
  FileUtils.mkdir_p(ss_dir)

  if valid_json
    File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
                                                     'name' => name,
                                                     'version' => '0.1.0',
                                                     'description' => "test skillset #{name}",
                                                     'layer' => layer,
                                                     'knowledge_dirs' => knowledge_dirs
                                                   ))
  else
    File.write(File.join(ss_dir, 'skillset.json'), '{ this is not json')
  end

  knowledge_dirs.each do |rel|
    parent = File.join(ss_dir, File.dirname(rel))
    write_knowledge(parent, File.basename(rel), "knowledge from #{name}")
  end
  ss_dir
end

Dir.mktmpdir('kairos-ss-knowledge-test') do |tmp|
  KairosMcp.data_dir = tmp

  main_knowledge = File.join(tmp, 'knowledge')
  FileUtils.mkdir_p(main_knowledge)
  write_knowledge(main_knowledge, 'main_entry', 'lives in the main knowledge dir')

  skillsets_dir = File.join(tmp, 'skillsets')
  FileUtils.mkdir_p(skillsets_dir)
  write_skillset(skillsets_dir, 'demo_ss', knowledge_dirs: ['knowledge/demo_guide'])
  write_skillset(skillsets_dir, 'off_ss', knowledge_dirs: ['knowledge/off_guide'])
  File.write(File.join(skillsets_dir, 'config.yml'), <<~YML)
    skillsets:
      off_ss:
        enabled: false
  YML

  # ==========================================================================
  puts "\n[Section 1] Declared knowledge is retrievable by name"
  # ==========================================================================

  provider = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)

  entry = provider.get('demo_guide')
  assert !entry.nil?, 'get() must find knowledge declared in skillset.json knowledge_dirs'
  assert entry && entry.name == 'demo_guide', 'entry name should be the knowledge dir name'

  assert !provider.get('main_entry').nil?, 'main knowledge dir must still resolve'

  listed = provider.list.find { |s| s[:name] == 'demo_guide' }
  assert !listed.nil?, 'list() must include SkillSet-declared knowledge'
  assert listed && listed[:source] == 'skillset:demo_ss', "list() entry must carry its source (got #{listed && listed[:source].inspect})"
  assert listed && listed[:layer] == :L1, 'list() entry must carry the declared layer'

  # ==========================================================================
  puts "\n[Section 2] Disabled SkillSets contribute nothing"
  # ==========================================================================

  assert provider.get('off_guide').nil?, 'knowledge from a disabled SkillSet must not resolve'
  assert provider.list.none? { |s| s[:name] == 'off_guide' }, 'disabled SkillSet knowledge must not be listed'

  # ==========================================================================
  puts "\n[Section 3] Opt-out and idempotency"
  # ==========================================================================

  scoped = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false,
                                                 include_skillset_knowledge: false)
  assert scoped.get('demo_guide').nil?, 'include_skillset_knowledge: false must scope to the main dir'
  assert !scoped.get('main_entry').nil?, 'opt-out provider must still see the main dir'

  # A SkillSet that also registers itself (the pre-fix idiom) must not duplicate.
  dup_dir = File.join(skillsets_dir, 'demo_ss', 'knowledge')
  before = provider.list.count { |s| s[:name] == 'demo_guide' }
  provider.add_external_dir(dup_dir, source: 'skillset:demo_ss', layer: :L1, index: true)
  after = provider.list.count { |s| s[:name] == 'demo_guide' }
  assert before == 1 && after == 1, "re-registering the same dir must be idempotent (#{before} -> #{after})"

  # ==========================================================================
  puts "\n[Section 4] Undeclared knowledge stays invisible"
  # ==========================================================================

  # A SkillSet that ships an entry without declaring it in knowledge_dirs must
  # not have it become L1-visible by sitting next to a declared one.
  write_knowledge(File.join(skillsets_dir, 'demo_ss', 'knowledge'), 'undeclared_guide', 'never declared')

  fresh = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)
  assert !fresh.get('demo_guide').nil?, 'declared entry must still resolve'
  assert fresh.get('undeclared_guide').nil?, 'undeclared sibling entry must not resolve'
  assert fresh.list.none? { |s| s[:name] == 'undeclared_guide' }, 'undeclared sibling must not be listed'

  # ==========================================================================
  puts "\n[Section 5] A broken manifest does not break the knowledge layer"
  # ==========================================================================

  write_skillset(skillsets_dir, 'broken_ss', knowledge_dirs: [], valid_json: false)

  resilient = nil
  begin
    resilient = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)
  rescue StandardError => e
    assert false, "provider construction must survive a malformed skillset.json (raised #{e.class})"
  end

  if resilient
    assert !resilient.get('main_entry').nil?,
           'main knowledge must stay reachable when a SkillSet manifest is malformed'
  end
end

puts "\n\n#{@passes} passed, #{@failures} failed"
exit(@failures.zero? ? 0 : 1)
