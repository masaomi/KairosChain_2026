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

test_section('Test 15: sweep reports staleness across all digests, stale-first') do
  # Existing written digests: topic_x (stale via tests 6/7), tooltopic (fresh).
  d = KairosMcp::SkillSets::Dream::Digester.new
  rows = d.sweep
  by_topic = rows.each_with_object({}) { |r, h| h[r[:topic]] = r }
  assert('topic_x present and stale') { by_topic['topic_x'] && by_topic['topic_x'][:stale] == true }
  assert('tooltopic present and fresh') { by_topic['tooltopic'] && by_topic['tooltopic'][:stale] == false }
  assert('topic_x flagged needs_refresh') { by_topic['topic_x'][:needs_refresh] == true }
  assert('stale sorts before fresh') { rows.first[:needs_refresh] == true }
  assert('age_days is an integer') { rows.all? { |r| r[:age_days].is_a?(Integer) } }
end

test_section('Test 16: refresh rebuilds package from provenance, drops missing (I4/I6)') do
  # topic_x cited s1/note_a (mutated, still exists) and s1/note_b (deleted in test 7).
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.refresh(topic: 'Topic X')
  refs = r[:snapshot].map { |s| s['ref'] }
  assert('found') { r[:found] }
  assert('keeps surviving source note_a') { refs.include?('s1/note_a') }
  assert('drops missing source note_b (I4)') { r[:dropped].include?('s1/note_b') && refs.none? { |x| x == 's1/note_b' } }
  assert('snapshot hash reflects CURRENT content (I6 re-read)') do
    cur = Digest::SHA256.hexdigest(File.read(File.join(KairosMcp.context_dir, 's1', 'note_a', 'note_a.md')))
    r[:snapshot].first['content_hash'] == cur
  end
end

test_section('Test 17: refresh -> write -> read becomes fresh again') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.refresh(topic: 'Topic X')
  d.write(topic: 'Topic X', snapshot: r[:snapshot], content: 'Regenerated: only Alpha (Z) survives.')
  again = d.read(topic: 'Topic X')
  assert('fresh after regeneration') { again[:stale] == false }
  assert('content regenerated') { again[:content].include?('Regenerated') }
end

test_section('Test 18: age + stale_after_days flags aged digests') do
  make_l2('age1', 'a1', tags: %w[aget], content: 'age body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'AgeTest', sources: [{ 'layer' => 'l2', 'session_id' => 'age1', 'name' => 'a1' }])
  d.write(topic: 'AgeTest', snapshot: pkg[:snapshot], content: 'aged digest')
  # backdate generated_at in the stored frontmatter
  p = File.join(KairosMcp.data_dir, 'dream', 'digest', 'agetest', 'agetest.md')
  raw = File.read(p)
  raw = raw.sub(/generated_at: .*/, 'generated_at: 2020-01-01T00:00:00Z')
  File.write(p, raw)
  rows = d.sweep(stale_after_days: 30)
  row = rows.find { |x| x[:topic] == 'agetest' }
  assert('aged flagged true') { row[:aged] == true }
  assert('needs_refresh true even though not drifted') { row[:needs_refresh] == true }
  assert('age_days large') { row[:age_days] > 1000 }
end

test_section('Test 19: resolved_from is stored and surfaced (refresh provenance origin)') do
  make_l2('rf1', 'rf_a', tags: %w[rftag], content: 'rf body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'RfTopic', from_tag: 'rftag', include_l1: false)
  d.write(topic: 'RfTopic', snapshot: pkg[:snapshot], content: 'rf digest', resolved_from: pkg[:resolved_from])
  r = d.read(topic: 'RfTopic')
  assert('resolved_from persisted') { r[:resolved_from] == 'tag:rftag' }
end

test_section('Test 20: path traversal in source identifiers is neutralized (security)') do
  # Plant a file outside the context tree.
  secret = File.join(test_dir, 'secret.md')
  File.write(secret, "---\nvisibility: private\n---\nTOP SECRET")
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Evil', sources: [
                  { 'layer' => 'l2', 'session_id' => '..', 'name' => '../secret' },
                  { 'layer' => 'l1', 'name' => '../../secret' }
                ])
  assert('traversal sources dropped (none resolve)') { r[:snapshot].empty? }
  assert('status no_sources') { r[:status] == 'no_sources' }
end

test_section('Test 21: name containing slash is rejected (ref-split safety)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Slashy', sources: [{ 'layer' => 'l2', 'session_id' => 's1', 'name' => 'a/b' }])
  assert('slashed name dropped') { r[:snapshot].empty? }
end

test_section('Test 22: slug collision raises instead of silent overwrite (I10)') do
  make_l2('c1', 'cc', tags: %w[col], content: 'x')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'Foo Bar', sources: [{ 'layer' => 'l2', 'session_id' => 'c1', 'name' => 'cc' }])
  d.write(topic: 'Foo Bar', snapshot: pkg[:snapshot], content: 'first topic')
  raised = begin
    # "foo-bar" slugifies to the same "foo_bar" but is a DIFFERENT topic string
    d.write(topic: 'foo-bar', snapshot: pkg[:snapshot], content: 'second topic'); false
  rescue KairosMcp::SkillSets::Dream::Digester::IdentifierError then true end
  assert('distinct topic mapping to same slug raises') { raised }
  assert('original digest intact') { d.read(topic: 'Foo Bar')[:content].include?('first topic') }
  # same topic re-write is regeneration, must NOT raise
  ok = begin
    d.write(topic: 'Foo Bar', snapshot: pkg[:snapshot], content: 'regenerated'); true
  rescue StandardError then false end
  assert('same-topic regeneration allowed') { ok }
end

test_section('Test 23: write re-derives hashes/access from sources, ignores caller-supplied (I4/I9)') do
  make_l2('sec', 'priv_src', tags: %w[sx], content: 'classified', visibility: 'private')
  d = KairosMcp::SkillSets::Dream::Digester.new
  # Caller tries to spoof: wrong hash + downgraded access.
  spoofed = [{ 'layer' => 'l2', 'ref' => 'sec/priv_src', 'content_hash' => 'deadbeef', 'access' => 'public' }]
  res = d.write(topic: 'Spoof', snapshot: spoofed, content: 'digest body')
  assert('access re-derived to private, not trusted public (I9)') { res[:access_bound] == 'private' }
  prov = res[:provenance].first
  cur = Digest::SHA256.hexdigest(File.read(File.join(KairosMcp.context_dir, 'sec', 'priv_src', 'priv_src.md')))
  assert('content_hash re-derived, not the spoofed deadbeef (I4)') { prov['content_hash'] == cur }
end

test_section('Test 24: write drops a nonexistent source; empty => raises (I4)') do
  d = KairosMcp::SkillSets::Dream::Digester.new
  raised = begin
    d.write(topic: 'Ghost', snapshot: [{ 'layer' => 'l2', 'ref' => 'no/such' }], content: 'x'); false
  rescue StandardError then true end
  assert('sourceless-at-write raises (I4)') { raised }
end

test_section('Test 25: I7 provenance carries content hashes + effective directive_id') do
  make_l2('i7', 'src', tags: %w[i7], content: 'i7 body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'I7Topic', sources: [{ 'layer' => 'l2', 'session_id' => 'i7', 'name' => 'src' }])
  res = d.write(topic: 'I7Topic', snapshot: pkg[:snapshot], content: 'body')
  assert('result provenance has content_hash (I7)') { res[:provenance].first['content_hash'] =~ /\A[0-9a-f]{64}\z/ }
  assert('result carries effective directive_id (I7)') { res[:directive_id] == 'dream_digest.synthesis.v1' }
end

test_section('Test 26: duplicate sources are deduped in the snapshot') do
  make_l2('dup', 'd', tags: %w[dup], content: 'dup body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Dup', sources: [
                  { 'layer' => 'l2', 'session_id' => 'dup', 'name' => 'd' },
                  { 'layer' => 'l2', 'session_id' => 'dup', 'name' => 'd' }
                ])
  assert('duplicate source counted once') { r[:snapshot].size == 1 }
end

test_section('Test 27: unknown access label treated as most restrictive (fail-closed I9)') do
  make_l2('u1', 'weird', tags: %w[u], content: 'x', visibility: 'topsecret')
  make_l2('u1', 'pubsrc', tags: %w[u], content: 'y', visibility: 'public')
  d = KairosMcp::SkillSets::Dream::Digester.new
  r = d.package(topic: 'Unk', sources: [
                  { 'layer' => 'l2', 'session_id' => 'u1', 'name' => 'weird' },
                  { 'layer' => 'l2', 'session_id' => 'u1', 'name' => 'pubsrc' }
                ])
  assert('unknown label normalized to most-restrictive known (private)') { r[:access_bound] == 'private' }
end

test_section('Test 28: body containing a --- line round-trips intact') do
  make_l2('rt', 'r', tags: %w[rt], content: 'rt body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'RT', sources: [{ 'layer' => 'l2', 'session_id' => 'rt', 'name' => 'r' }])
  body = "Intro line.\n\n---\n\nA section after a horizontal rule.\n\n---\n\nEnd."
  d.write(topic: 'RT', snapshot: pkg[:snapshot], content: body)
  got = d.read(topic: 'RT')[:content]
  assert('body with --- preserved') { got.include?('horizontal rule') && got.scan(/^---$/).size == 2 }
end

test_section('Test 29: symlink under data tree cannot escape confinement (R2 fix C)') do
  outside = File.join(test_dir, 'outside_secret.md')
  File.write(outside, "---\nvisibility: private\n---\nESCAPED")
  evil_dir = File.join(KairosMcp.context_dir, 'sx', 'evil')
  FileUtils.mkdir_p(evil_dir)
  begin
    File.symlink(outside, File.join(evil_dir, 'evil.md'))
    linked = true
  rescue NotImplementedError, Errno::EACCES
    linked = false
  end
  if linked
    d = KairosMcp::SkillSets::Dream::Digester.new
    r = d.package(topic: 'Sym', sources: [{ 'layer' => 'l2', 'session_id' => 'sx', 'name' => 'evil' }])
    assert('symlinked source escaping the tree is dropped') { r[:snapshot].empty? }
  else
    assert('symlink unsupported on this FS — skipped') { true }
  end
end

test_section('Test 30: collision guard is fail-closed on a corrupt existing digest (R2 fix A)') do
  make_l2('cg', 'src', tags: %w[cg], content: 'cg body')
  d = KairosMcp::SkillSets::Dream::Digester.new
  pkg = d.package(topic: 'CorruptGuard', sources: [{ 'layer' => 'l2', 'session_id' => 'cg', 'name' => 'src' }])
  res = d.write(topic: 'CorruptGuard', snapshot: pkg[:snapshot], content: 'ok')
  # Corrupt the stored digest: remove its topic frontmatter.
  File.write(res[:path], "---\nkind: dream_digest\n---\n\nbody without topic")
  raised = begin
    d.write(topic: 'CorruptGuard', snapshot: pkg[:snapshot], content: 'retry'); false
  rescue KairosMcp::SkillSets::Dream::Digester::IdentifierError then true end
  assert('refuses to overwrite an unidentifiable existing digest') { raised }
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
