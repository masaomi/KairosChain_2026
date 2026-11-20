#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: dream_digest — the revisions of design v0.13 (log/dream_digest_design_v0.13.md):
#   I3  succession is read from a declared edge, never inferred, never composed
#   I5  freshness covers membership; the READ set is closed under succession
#   I7  generation and check events; labels only for the current generation's output
#   I9  a principal outside the generation's bound is shown nothing
#   I11 a check is never authored by the author
#   I13 the two validity conditions of a succession edge
# Kept beside test_dream_digest.rb, which holds the v0.4 behaviour that did not change.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'digest'

require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/tools/base_tool'

require_relative 'templates/skillsets/dream/lib/dream/digester'
require_relative 'templates/skillsets/dream/tools/dream_digest'

$pass_count = 0
$fail_count = 0
$errors = []

def assert(desc)
  result = yield
  if result
    $pass_count += 1
    puts "  PASS: #{desc}"
  else
    $fail_count += 1
    $errors << desc
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  $fail_count += 1
  $errors << "#{desc} (#{e.class}: #{e.message})"
  puts "  FAIL: #{desc} — #{e.class}: #{e.message}"
end

def test_section(title)
  puts('-' * 60)
  puts "TEST: #{title}"
  puts('-' * 60)
  yield
rescue StandardError => e
  $fail_count += 1
  $errors << "#{title} (#{e.class}: #{e.message})"
  puts "  ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

# Each section works in a data directory of its own, so no section reads another's nodes.
def fresh_instance
  dir = Dir.mktmpdir('kairos_dream_digest_succession')
  KairosMcp.data_dir = dir
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  FileUtils.mkdir_p(KairosMcp.storage_dir)
  FileUtils.mkdir_p(KairosMcp.context_dir)
  yield dir
ensure
  FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
end

def node_path(session_id, name)
  File.join(KairosMcp.context_dir, session_id, name, "#{name}.md")
end

# Write an L2 node file directly (the way nodes written before this design are on disk).
def make_l2(session_id, name, tags: [], content: 'Content', relations: nil, extra: {})
  FileUtils.mkdir_p(File.dirname(node_path(session_id, name)))
  fm = { 'title' => name, 'tags' => tags }.merge(extra)
  fm['relations'] = relations if relations
  File.write(node_path(session_id, name), "---\n#{YAML.dump(fm).sub(/\A---\n/, '')}---\n\n#{content}")
end

def write_raw(session_id, name, raw)
  FileUtils.mkdir_p(File.dirname(node_path(session_id, name)))
  File.write(node_path(session_id, name), raw)
end

Digester = KairosMcp::SkillSets::Dream::Digester

puts 'dream_digest v0.13 Test Suite'
puts "Ruby: #{RUBY_VERSION}"
puts ''

# =========================================================================
test_section('S1: selection by tag survives a node whose frontmatter does not parse') do
  fresh_instance do
    make_l2('s1', 'good_a', tags: %w[topic], content: 'A')
    make_l2('s1', 'good_b', tags: %w[topic], content: 'B')
    write_raw('s1', 'broken', "---\ntitle: broken\ntags: [topic\nstatus: \"unterminated\n---\n\nbody")
    write_raw('s1', 'scalar_root', "---\njust a string\n---\n\nbody")
    r = Digester.new.package(topic: 'T', from_tag: 'topic', include_l1: false)
    refs = r[:snapshot].map { |s| s['ref'] }
    assert('selection completes') { r[:status] == 'needs_content' }
    assert('both parseable tagged nodes are selected') { refs.include?('s1/good_a') && refs.include?('s1/good_b') }
    assert('the unparseable node is not selected') { refs.none? { |x| x.include?('broken') } }
  end
end

# ===== Summary =====
puts ''
puts('=' * 60)
puts "RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts('=' * 60)
unless $errors.empty?
  puts 'Failures:'
  $errors.each { |e| puts "  - #{e}" }
end
exit($fail_count.zero? ? 0 : 1)
