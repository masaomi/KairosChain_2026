#!/usr/bin/env ruby
# frozen_string_literal: true

# Cycle 1 (INV-A) detection floor tests for CorrespondenceChecker.
#
# Verifies the use-gap detection: an L1 artifact read "in order to act upon"
# is checked against its current recorded provenance (the chain head next_hash).
# A silent out-of-band edit must surface as :mismatch; a recorded-but-absent
# artifact as :missing_artifact; an un-recorded live artifact as :missing_record.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'kairos_mcp/storage/file_backend'
require 'kairos_mcp/kairos_chain/chain'
require 'kairos_mcp/drift_detection/correspondence_checker'

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

def check(description, condition, counters)
  if assert(description, condition)
    counters[0] += 1
  else
    counters[1] += 1
  end
end

# Write an L1 knowledge .md file and record its provenance on the chain.
# Returns the md file path.
def seed_knowledge(knowledge_dir, backend, name, content)
  skill_dir = File.join(knowledge_dir, name)
  FileUtils.mkdir_p(skill_dir)
  md_path = File.join(skill_dir, "#{name}.md")
  File.write(md_path, content)

  chain = KairosMcp::KairosChain::Chain.new(storage_backend: backend)
  chain.add_block([{
    type: 'knowledge_update',
    layer: 'L1',
    knowledge_id: name,
    action: 'create',
    prev_hash: nil,
    next_hash: Digest::SHA256.hexdigest(content),
    reason: "seed #{name}",
    timestamp: Time.now.iso8601
  }.to_json])

  md_path
end

Checker = KairosMcp::DriftDetection::CorrespondenceChecker
counters = [0, 0]

Dir.mktmpdir('drift_floor_test') do |tmp|
  knowledge_dir = File.join(tmp, 'knowledge')
  storage_dir = File.join(tmp, 'storage')
  FileUtils.mkdir_p(knowledge_dir)
  backend = KairosMcp::Storage::FileBackend.new(
    storage_dir: storage_dir,
    blockchain_file: File.join(storage_dir, 'blockchain.json')
  )

  puts "\n#{'=' * 60}\nTEST: match — live artifact corresponds to provenance\n#{'=' * 60}"
  original = "---\nname: alpha\nversion: 1\n---\n\nbody text\n"
  md = seed_knowledge(knowledge_dir, backend, 'alpha', original)
  r = Checker.check_l1(name: 'alpha', md_file_path: md, storage_backend: backend)
  check('status is :match', r.status == :match, counters)
  check('corresponds? is true', r.corresponds? == true, counters)
  check('divergence? is false', r.divergence? == false, counters)
  check('active digest equals recorded digest', r.active_digest == r.recorded_digest, counters)

  puts "\n#{'=' * 60}\nTEST: mismatch — silent out-of-band edit is detected\n#{'=' * 60}"
  File.write(md, original + "\nan unrecorded external edit\n")
  r = Checker.check_l1(name: 'alpha', md_file_path: md, storage_backend: backend)
  check('status is :mismatch', r.status == :mismatch, counters)
  check('divergence? is true', r.divergence? == true, counters)
  check('corresponds? is false', r.corresponds? == false, counters)
  check('message names the knowledge', r.message.to_s.include?('alpha'), counters)
  check('active digest differs from recorded', r.active_digest != r.recorded_digest, counters)

  puts "\n#{'=' * 60}\nTEST: missing_record — live artifact with no provenance\n#{'=' * 60}"
  orphan_dir = File.join(knowledge_dir, 'orphan')
  FileUtils.mkdir_p(orphan_dir)
  orphan_md = File.join(orphan_dir, 'orphan.md')
  File.write(orphan_md, "---\nname: orphan\n---\n\nno chain record\n")
  r = Checker.check_l1(name: 'orphan', md_file_path: orphan_md, storage_backend: backend)
  check('status is :missing_record', r.status == :missing_record, counters)
  check('divergence? is true', r.divergence? == true, counters)
  check('recorded digest is nil', r.recorded_digest.nil?, counters)

  puts "\n#{'=' * 60}\nTEST: missing_artifact — recorded artifact absent at reliance\n#{'=' * 60}"
  r = Checker.check_l1(name: 'alpha', md_file_path: File.join(knowledge_dir, 'gone', 'gone.md'), storage_backend: backend)
  check('status is :missing_artifact', r.status == :missing_artifact, counters)
  check('divergence? is true', r.divergence? == true, counters)

  puts "\n#{'=' * 60}\nTEST: provenance tracks the latest record (re-record after edit)\n#{'=' * 60}"
  # Record a new provenance matching the edited content; should now correspond.
  edited = File.read(md)
  chain = KairosMcp::KairosChain::Chain.new(storage_backend: backend)
  chain.add_block([{
    type: 'knowledge_update',
    layer: 'L1',
    knowledge_id: 'alpha',
    action: 'update',
    prev_hash: Digest::SHA256.hexdigest(original),
    next_hash: Digest::SHA256.hexdigest(edited),
    reason: 'record the edit',
    timestamp: Time.now.iso8601
  }.to_json])
  r = Checker.check_l1(name: 'alpha', md_file_path: md, storage_backend: backend)
  check('latest provenance wins → status is :match', r.status == :match, counters)
end

passed, failed = counters
puts "\n#{'=' * 60}"
puts "RESULTS: #{passed} passed, #{failed} failed"
puts '=' * 60
exit(failed.zero? ? 0 : 1)
