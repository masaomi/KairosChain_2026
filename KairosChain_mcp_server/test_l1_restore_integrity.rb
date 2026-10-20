#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for restore integrity.
#
# R1: fetch returns a stored body only while its bytes hash to the requested
#     hash; a damaged object is not retrievable.
# R2: a restore stands only if its record lands. If the append fails, the live
#     entry is put back exactly as it was and {success: false, error:} comes
#     back, with no index update and no pending-change tracking.
#
# Every case below fails on the code as it stands before this change.

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'

tmp = Dir.mktmpdir
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'

checks = 0
failures = 0

assert = lambda do |condition, message|
  checks += 1
  if condition
    puts "  ok   #{message}"
  else
    failures += 1
    puts "  FAIL #{message}"
  end
end

body = lambda { |v| "---\nname: note\ndescription: \"#{v}\"\n---\n# #{v}\n" }

object_path = lambda do |h|
  File.join(File.dirname(KairosMcp.knowledge_dir), 'l1_history', 'objects', h[0, 2], h)
end

note_dir = lambda { File.join(KairosMcp.knowledge_dir, 'note') }

live_body = lambda do
  path = Dir.glob(File.join(note_dir.call, '*.md')).sort.first
  path && File.read(path).force_encoding('UTF-8')
end

# Every knowledge_update record of 'note', read through the Chain API: each block
# carries an array of JSON strings, and L1 records name the entry as knowledge_id.
action_of = lambda { |data| data['action'].to_s }

note_updates = lambda do
  KairosMcp::KairosChain::Chain.new.chain.flat_map do |block|
    Array(block.data).map do |raw|
      begin
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        nil
      end
    end
  end.compact.select { |d| d['type'] == 'knowledge_update' && d['knowledge_id'] == 'note' }
end

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(tmp)
    abort "KAIROS_DATA_DIR was not honoured: #{KairosMcp.blockchain_path}"
  end

  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  kp = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)

  v1 = body.call('v1')
  v2 = body.call('v2')
  h1 = Digest::SHA256.hexdigest(v1)

  chain_class = KairosMcp::KairosChain::Chain
  original_add_block = chain_class.instance_method(:add_block)
  break_append = lambda do
    chain_class.send(:define_method, :add_block) do |*_args, **_kwargs, &_blk|
      raise KairosMcp::KairosChain::ChainStateError.new('test', state: :unreadable)
    end
  end
  heal_append = lambda { chain_class.send(:define_method, :add_block, original_add_block) }

  puts 'case 1: a damaged stored object is not restorable'
  kp.create('note', v1)
  kp.update('note', v2)
  abort "no stored object at #{object_path.call(h1)}" unless File.file?(object_path.call(h1))

  File.binwrite(object_path.call(h1), "these bytes are not the body of h1\n")
  before = note_updates.call.length
  result = kp.restore('note', h1)
  assert.call(result.is_a?(Hash) && !result[:success], 'case 1: restore of a damaged object fails')
  assert.call(live_body.call == v2, 'case 1: live file is still v2')
  assert.call(note_updates.call.length == before, 'case 1: no new knowledge_update record')

  puts 'case 2: the record does not land, for an entry that exists'
  File.binwrite(object_path.call(h1), v1)
  assert.call(File.binread(object_path.call(h1)) == v1, 'case 2: the v1 object is intact again')

  before = note_updates.call.length
  begin
    break_append.call
    result = kp.restore('note', h1)
  ensure
    heal_append.call
  end
  assert.call(result.is_a?(Hash) && result[:success] == false, 'case 2: restore returns success: false')
  assert.call(result.is_a?(Hash) && !result[:error].to_s.empty?, 'case 2: restore returns an error')
  assert.call(live_body.call == v2, 'case 2: live file is still v2')
  after = note_updates.call
  assert.call(after.length == before, 'case 2: no new knowledge_update record')
  assert.call(after.none? { |d| action_of.call(d) == 'restore' }, 'case 2: no restore record')

  puts 'case 3: the record does not land, for an entry that was recreated'
  kp.delete('note')
  assert.call(!Dir.exist?(note_dir.call), 'case 3: the entry is gone before the restore')

  begin
    break_append.call
    result = kp.restore('note', h1)
  ensure
    heal_append.call
  end
  assert.call(result.is_a?(Hash) && result[:success] == false, 'case 3: restore returns success: false')
  assert.call(!Dir.exist?(note_dir.call), 'case 3: the directory just created was removed')

  puts 'case 4: the record lands'
  result = kp.restore('note', h1)
  assert.call(result.is_a?(Hash) && result[:success], 'case 4: restore succeeds')
  assert.call(live_body.call == v1, 'case 4: live file is v1')
  newest = note_updates.call.last
  assert.call(!newest.nil? && action_of.call(newest) == 'restore', 'case 4: newest record has action restore')
rescue StandardError => e
  failures += 1
  puts "  ERROR #{e.class}: #{e.message}"
  puts Array(e.backtrace).first(5).map { |l| "    #{l}" }.join("\n")
ensure
  FileUtils.rm_rf(tmp)
end

puts
puts "#{checks} checks, #{failures} failure(s)"
exit(failures.zero? ? 0 : 1)
