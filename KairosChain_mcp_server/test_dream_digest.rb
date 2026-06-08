#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: dream_digest — Digester + DreamDigest tool
# Verifies the frozen design invariants (dream_digest_design_v0.4):
#   I1/I8 derived & non-authoritative, I2/I7 snapshot, I4 no sourceless digest,
#   I5 staleness labelled not corrected, I6 citable universe fixed by snapshot,
#   I9 access bound, I10 per-topic partition.

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

# ===== Harness =====
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

# ===== Setup =====
test_dir = Dir.mktmpdir('kairos_dream_digest_test')
KairosMcp.data_dir = test_dir
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.context_dir)

puts "dream_digest Test Suite"
puts "Ruby: #{RUBY_VERSION}  Temp: #{test_dir}"
puts ""

def make_l2(session_id, name, tags: [], content: "Content", visibility: nil)
  dir = File.join(KairosMcp.context_dir, session_id, name)
  FileUtils.mkdir_p(dir)
  fm = { 'title' => name, 'tags' => tags }
  fm['visibility'] = visibility if visibility
  File.write(File.join(dir, "#{name}.md"), "---\n#{YAML.dump(fm)}---\n\n#{content}")
  dir
end

# =========================================================================
test_section('Test 1: package builds content-addressed snapshot (I2/I6)') do
  make_l2('s1', 'note_a', tags: %w[topicx], content: 'Alpha says X')
  make_l2('s1', 'note_b', tags: %w[topicx], content: 'Beta says Y')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Topic X', sources: [
                  { 'layer' => 'l2', 'session_id' => 's1', 'name' => 'note_a' },
                  { 'layer' => 'l2', 'session_id' => 's1', 'name' => 'note_b' }
                ])
  assert('status needs_content') { r[:status] == 'needs_content' }
  assert('snapshot has 2 sources') { r[:snapshot].size == 2 }
  assert('each source has a content_hash') { r[:snapshot].all? { |s| s['content_hash'] =~ /\A[0-9a-f]{64}\z/ } }
  assert('directive forbids flattening (I3)') { r[:directive].include?('do NOT pick a winner') }
  assert('directive fixes citable universe (I6)') { r[:directive].include?('Cite ONLY these sources') }
  assert('access_bound present (I9)') { !r[:access_bound].nil? }
end

test_section('Test 2: missing sources are dropped; empty => no_sources (I4)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Empty', sources: [{ 'layer' => 'l2', 'session_id' => 'nope', 'name' => 'ghost' }])
  assert('no resolvable sources') { r[:snapshot].empty? }
  assert('status no_sources') { r[:status] == 'no_sources' }
end

test_section('Test 3: write refuses sourceless / empty content (I4)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  raised1 = begin
    d.write(topic: 'T', snapshot: [], content: 'x'); false
  rescue StandardError then true end
  assert('empty snapshot rejected') { raised1 }
  raised2 = begin
    d.write(topic: 'T', snapshot: [{ 'layer' => 'l2', 'ref' => 's1/note_a', 'content_hash' => 'abc' }], content: '  '); false
  rescue StandardError then true end
  assert('empty content rejected') { raised2 }
end

test_section('Test 4: write persists derived, non-authoritative digest (I1/I8/I10)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'Topic X', sources: [
                    { 'layer' => 'l2', 'session_id' => 's1', 'name' => 'note_a' },
                    { 'layer' => 'l2', 'session_id' => 's1', 'name' => 'note_b' }
                  ])
  res = d.write(topic: 'Topic X', snapshot: pkg[:snapshot],
                content: 'Alpha holds X; Beta holds Y; unresolved.')
  assert('write succeeded') { res[:success] }
  assert('output_hash present (I7)') { res[:output_hash] =~ /\A[0-9a-f]{64}\z/ }
  assert('provenance_count == 2 (I4)') { res[:provenance_count] == 2 }
  # I10: lives under derived per-topic tier, NOT in knowledge/ or context/
  assert('stored in derived dream/digest tier (I1/I10)') { res[:path].include?(File.join('dream', 'digest', 'topic_x')) }
  assert('NOT under knowledge dir') { !res[:path].start_with?(KairosMcp.knowledge_dir) }
  assert('NOT under context dir') { !res[:path].start_with?(KairosMcp.context_dir) }
  raw = File.read(res[:path])
  fm = YAML.safe_load(raw[/\A---\n(.*?)\n---/m, 1])
  assert('frontmatter marks derived=true (I1)') { fm['derived'] == true }
  assert('frontmatter marks authoritative=false (I8)') { fm['authoritative'] == false }
  assert('frontmatter records provenance hashes (I7)') { fm['provenance'].all? { |p| p['content_hash'] } }
end

test_section('Test 5: read returns content, fresh when sources unchanged (I5)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.read(topic: 'Topic X')
  assert('found') { r[:found] }
  assert('fresh (no drift)') { r[:stale] == false }
  assert('content present') { r[:content].include?('Alpha holds X') }
end

test_section('Test 6: source drift marks digest STALE, does not rewrite it (I5)') do
  # Mutate a cited source AFTER generation.
  make_l2('s1', 'note_a', tags: %w[topicx], content: 'Alpha now says Z (changed)')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.read(topic: 'Topic X')
  assert('now stale') { r[:stale] == true }
  assert('drift names the changed source') { r[:drifted].any? { |x| x['ref'] == 's1/note_a' && x['reason'] == 'hash_changed' } }
  # I5: digest content itself is unchanged (not auto-corrected)
  assert('content NOT auto-rewritten') { r[:content].include?('Alpha holds X') }
end

test_section('Test 7: missing source counts as drift (I5)') do
  FileUtils.rm_rf(File.join(KairosMcp.context_dir, 's1', 'note_b'))
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.read(topic: 'Topic X')
  assert('missing source => drift reason missing') { r[:drifted].any? { |x| x['ref'] == 's1/note_b' && x['reason'] == 'missing' } }
end

test_section('Test 8: access bound = most restrictive among READ set (I9)') do
  make_l2('s2', 'pub', tags: %w[t], content: 'public', visibility: 'public')
  make_l2('s2', 'priv', tags: %w[t], content: 'secret', visibility: 'private')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Mixed', sources: [
                  { 'layer' => 'l2', 'session_id' => 's2', 'name' => 'pub' },
                  { 'layer' => 'l2', 'session_id' => 's2', 'name' => 'priv' }
                ])
  assert('bound is the most restrictive (private)') { r[:access_bound] == 'private' }
end

test_section('Test 9: tool package/write/read round-trip') do
  tool = KairosMcp::SkillSets::Dream::Tools::DreamDigest.new
  make_l2('s3', 'd1', tags: %w[tool], content: 'one')
  pkg_out = tool.call('mode' => 'package', 'topic' => 'Tooltopic',
                      'sources' => [{ 'layer' => 'l2', 'session_id' => 's3', 'name' => 'd1' }])
  pkg_text = pkg_out.first[:text]
  assert('package output mentions READ set') { pkg_text.include?('READ set') }

  d = KairosMcp::SkillSets::Dream::Digester.new
  snap = d.package(topic: 'Tooltopic', sources: [{ 'layer' => 'l2', 'session_id' => 's3', 'name' => 'd1' }])[:snapshot]
  w = tool.call('mode' => 'write', 'topic' => 'Tooltopic', 'snapshot' => snap, 'content' => 'A digest of one.')
  assert('write output confirms path') { w.first[:text].include?('Written') }
  rd = tool.call('mode' => 'read', 'topic' => 'Tooltopic')
  assert('read output shows content') { rd.first[:text].include?('A digest of one.') }
  ls = tool.call('mode' => 'list')
  assert('list includes the topic') { ls.first[:text].include?('tooltopic') }
end

test_section('Test 10: L1 source supported in READ set') do
  kdir = File.join(KairosMcp.knowledge_dir, 'some_l1')
  FileUtils.mkdir_p(kdir)
  File.write(File.join(kdir, 'some_l1.md'), "---\nname: some_l1\n---\n\nL1 body")
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'L1topic', sources: [{ 'layer' => 'l1', 'name' => 'some_l1' }])
  assert('L1 source resolved') { r[:snapshot].size == 1 && r[:snapshot].first['layer'] == 'l1' }
  assert('L1 ref is the name') { r[:snapshot].first['ref'] == 'some_l1' }
end

test_section('Test 11: from_tag resolves live fragments across sessions (I6 wiring)') do
  make_l2('w1', 'frag_a', tags: %w[wireup design], content: 'A on wireup')
  make_l2('w2', 'frag_b', tags: %w[wireup review], content: 'B on wireup')
  make_l2('w3', 'unrelated', tags: %w[other], content: 'noise')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Wireup', from_tag: 'wireup', include_l1: false)
  refs = r[:snapshot].map { |s| s['ref'] }
  assert('resolved 2 tagged fragments') { r[:snapshot].size == 2 }
  assert('includes both wireup frags') { refs.include?('w1/frag_a') && refs.include?('w2/frag_b') }
  assert('excludes untagged fragment') { refs.none? { |x| x.include?('unrelated') } }
  assert('resolved_from records the tag') { r[:resolved_from] == 'tag:wireup' }
  assert('status needs_content') { r[:status] == 'needs_content' }
end

test_section('Test 12: from_tag excludes soft-archived stubs') do
  make_l2('w4', 'archived_frag', tags: %w[wireup], content: 'stub')
  # mark it soft-archived in frontmatter
  p = File.join(KairosMcp.context_dir, 'w4', 'archived_frag', 'archived_frag.md')
  fm = { 'title' => 'archived_frag', 'tags' => %w[wireup], 'status' => 'soft-archived' }
  File.write(p, "---\n#{YAML.dump(fm)}---\n\nstub body")
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Wireup', from_tag: 'wireup', include_l1: false)
  refs = r[:snapshot].map { |s| s['ref'] }
  assert('archived stub not cited as live') { refs.none? { |x| x.include?('archived_frag') } }
  assert('still resolves the 2 live frags') { r[:snapshot].size == 2 }
end

test_section('Test 13: explicit sources take precedence over from_tag') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Wireup',
                sources: [{ 'layer' => 'l2', 'session_id' => 'w1', 'name' => 'frag_a' }],
                from_tag: 'wireup')
  assert('only the explicit source is used') { r[:snapshot].size == 1 }
  assert('resolved_from is nil (explicit path)') { r[:resolved_from].nil? }
end

test_section('Test 14: from_tag is hyphen/underscore tolerant') do
  make_l2('h1', 'h_frag', tags: %w[multi_llm], content: 'tagged with underscore')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'MLLM', from_tag: 'multi-llm', include_l1: false)
  assert('hyphen query matches underscore tag') { r[:snapshot].any? { |s| s['ref'] == 'h1/h_frag' } }
end

# ===== Summary =====
puts ""
puts('=' * 60)
puts "RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts('=' * 60)
unless $errors.empty?
  puts "Failures:"
  $errors.each { |e| puts "  - #{e}" }
end
FileUtils.remove_entry(test_dir)
exit($fail_count.zero? ? 0 : 1)
