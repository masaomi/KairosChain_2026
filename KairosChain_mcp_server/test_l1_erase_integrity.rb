#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for L1 body erasure integrity (review R1, invariants E1-E3).
# Every case below fails against the pre-fix erase_body.

require 'fileutils'
require 'tmpdir'
require 'digest'
require 'json'

tmp = Dir.mktmpdir('l1_erase_integrity')
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp/knowledge_provider'

# Refuse to run unless the library really resolved to the throwaway directory.
unless KairosMcp.blockchain_path.to_s.start_with?(tmp)
  FileUtils.rm_rf(tmp)
  abort "refusing to run: blockchain path #{KairosMcp.blockchain_path} is outside #{tmp}"
end

checks = 0
failures = []

assert = lambda do |condition, label|
  checks += 1
  if condition
    puts "  ok   #{label}"
  else
    failures << label
    puts "  FAIL #{label}"
  end
end

body = lambda { |n, v| "---\nname: #{n}\ndescription: \"#{v}\"\n---\n# #{v}\n" }
sha = lambda { |text| Digest::SHA256.hexdigest(text) }

object_path = lambda do |h|
  File.join(File.dirname(KairosMcp.knowledge_dir), 'l1_history', 'objects', h[0, 2], h)
end

stored = lambda { |h| File.exist?(object_path.call(h)) }

kp = nil

# Every record in the chain, flattened out of the per-block data arrays.
records = lambda do
  chain = KairosMcp::KairosChain::Chain.new(storage_backend: kp.send(:storage_backend)).chain
  chain.flat_map do |block|
    data = block.respond_to?(:data) ? block.data : block['data']
    Array(data).map do |raw|
      begin
        JSON.parse(raw.to_s)
      rescue StandardError
        nil
      end
    end.compact
  end
end

begin
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  kp = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)

  # --- case 1: a hash the named entry never pointed at (R1-2) --------------
  puts 'case 1: erasure under a name that never held the body is refused'
  a_v1 = body.call('a', 'v1')
  h_a_v1 = sha.call(a_v1)
  kp.create('a', a_v1)
  kp.update('a', body.call('a', 'v2'))

  res = kp.erase_body('zzz', h_a_v1, reason: 'x')
  assert.call(res[:success] == false, 'case 1: erase_body refuses an unrelated name')
  assert.call(stored.call(h_a_v1), 'case 1: object is still stored')

  # --- case 2: a body shared by two entries (R1-2) -------------------------
  puts 'case 2: erasure of a body shared by two entries is refused'
  kp.create('b', a_v1) # byte-identical body, therefore the same hash
  kp.update('b', body.call('b', 'v2'))

  res = kp.erase_body('a', h_a_v1, reason: 'x')
  assert.call(res[:success] == false, 'case 2: erase_body refuses a shared body')
  assert.call(res[:error].to_s.include?('b'), 'case 2: refusal names the sharing entry')
  assert.call(stored.call(h_a_v1), 'case 2: object is still stored')

  # --- case 3: live body under a differing directory name (R1-3) -----------
  puts 'case 3: live content is found per directory, not by declared name'
  alpha_body = body.call('beta', 'v')
  kp.create('alpha', alpha_body)

  res = kp.erase_body('alpha', sha.call(alpha_body), reason: 'x')
  assert.call(res[:success] == false, 'case 3: erase_body refuses a live body')

  # --- case 4: a failed append must leave the body in place (R1-1) ---------
  puts 'case 4: a failed append leaves the body stored and unrecorded'
  c_v1 = body.call('c', 'c-v1')
  h_c_v1 = sha.call(c_v1)
  kp.create('c', c_v1)
  kp.update('c', body.call('c', 'c-v2'))

  chain_class = KairosMcp::KairosChain::Chain
  original_add_block = chain_class.instance_method(:add_block)
  res = nil
  begin
    chain_class.send(:define_method, :add_block) do |*_args|
      raise KairosMcp::KairosChain::ChainStateError.new('test', state: :unreadable)
    end
    # The pre-fix method lets the error escape; record that as a failure rather
    # than letting it abort the run before case 5.
    res = begin
      kp.erase_body('c', h_c_v1, reason: 'x')
    rescue StandardError => e
      { success: :raised, error: "#{e.class}: #{e.message}" }
    end
  ensure
    chain_class.send(:define_method, :add_block, original_add_block)
  end

  assert.call(res[:success] == false,
              "case 4: erase_body returns success: false (got #{res[:success].inspect})")
  assert.call(stored.call(h_c_v1), 'case 4: object is still stored after the failed append')
  assert.call(records.call.none? { |r| r['type'] == 'l1_body_erasure' },
              'case 4: no l1_body_erasure record was written')

  # --- case 5: the same erasure succeeds once the append works -------------
  puts 'case 5: a recorded erasure removes the body'
  res = kp.erase_body('c', h_c_v1, reason: 'superseded')
  assert.call(res[:success] == true, "case 5: erase_body succeeds (got #{res.inspect})")
  assert.call(!stored.call(h_c_v1), 'case 5: object is gone')
  assert.call(Dir.glob("#{object_path.call(h_c_v1)}.erasing*").empty?,
              'case 5: no quarantined object is left behind')

  erasures = records.call.select { |r| r['type'] == 'l1_body_erasure' }
  assert.call(erasures.size == 1,
              "case 5: exactly one l1_body_erasure record (got #{erasures.size})")
  assert.call(erasures.first && erasures.first['knowledge_id'] == 'c',
              'case 5: the record names the entry')
  assert.call(erasures.first && erasures.first['content_hash'] == h_c_v1,
              'case 5: the record names the erased hash')
ensure
  FileUtils.rm_rf(tmp)
end

puts
puts "#{checks} checks, #{failures.size} failed"
unless failures.empty?
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
exit 0
