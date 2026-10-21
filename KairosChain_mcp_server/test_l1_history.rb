#!/usr/bin/env ruby
# frozen_string_literal: true
# L1 history unit test: the provider body store (create/update/restore/history/
# erase_body) and the knowledge_update tool surface. Cases 1-5, 7, 8 fail without
# the provider change; case 6 fails without the tool edits above.

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'yaml'

tmp = Dir.mktmpdir('l1_history')
ENV['KAIROS_DATA_DIR'] = tmp # must be set before kairos_mcp is loaded

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/tools/knowledge_update'

unless KairosMcp.blockchain_path.start_with?(tmp)
  abort "aborting: chain resolves outside the sandbox (#{KairosMcp.blockchain_path})"
end

$pass = 0
$fail = 0

def assert(cond, msg)
  if cond
    $pass += 1
    puts "ok   #{msg}"
  else
    $fail += 1
    puts "FAIL #{msg}"
  end
end

# Full markdown body with YAML frontmatter; the hash is taken over exactly this.
def body(version, name = 'note')
  "---\nname: #{name}\ndescription: \"#{version}\"\n---\n# #{version}\n"
end

def hash_of(str)
  Digest::SHA256.hexdigest(str)
end

def store_dir
  File.join(File.dirname(KairosMcp.knowledge_dir), 'l1_history')
end

def stored?(hash)
  File.exist?(File.join(store_dir, 'objects', hash[0, 2], hash))
end

def records
  KairosMcp::KairosChain::Chain.new.chain.flat_map do |b|
    b.data.map { |d| JSON.parse(d) rescue nil }
  end.compact
end

def updates
  records.select { |r| r['type'] == 'knowledge_update' }
end

# Reads the live body without hard-coding the entry filename.
def current(name)
  path = Dir[File.join(KairosMcp.knowledge_dir, name, '*.md')].first
  path && File.read(path)
end

def tool_text(args)
  KairosMcp::Tools::KnowledgeUpdate.new.call(args).map { |c| c[:text] || c['text'] }.join("\n")
end

cfg_path = nil
cfg_backup = nil

begin
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  provider = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)

  v1 = body('v1')
  v2 = body('v2')
  h1 = hash_of(v1)
  h2 = hash_of(v2)

  # 1. create + update: both bodies land in the store, activation noted once.
  provider.create('note', v1)
  provider.update('note', v2)
  assert stored?(h1), '1: v1 body retrievable'
  assert stored?(h2), '1: v2 body retrievable'
  assert records.count { |r| r['type'] == 'l1_history_activation' } == 1,
         '1: exactly one activation record'

  # 2. restore to v1: the file and the newest record both point at v1.
  res = provider.restore('note', h1, reason: 'back to v1')
  assert res[:success], '2: restore reports success'
  assert current('note') == v1, '2: live file equals v1'
  last = updates.last
  assert last['action'] == 'restore', '2: newest record action is restore'
  assert last['next_hash'] == h1, '2: next_hash is v1'
  assert last['restored_from'] == h1, '2: restored_from is v1'

  # 3. history is in chain order and nothing is pruned yet.
  rows = provider.history('note')
  assert rows.map { |r| r[:action] } == %w[create update restore], '3: history order'
  assert rows.all? { |r| r[:retrievable] }, '3: every row retrievable'

  # 4. the live body is protected; a superseded one can go, and the hash survives
  #    in the knowledge_update records even though the body does not.
  assert provider.erase_body('note', h1, reason: 'live')[:success] == false,
         '4: erasing the live body is refused'
  assert provider.erase_body('note', h2, reason: 'superseded')[:success],
         '4: erasing the superseded body succeeds'
  assert !stored?(h2), '4: v2 body is gone'
  assert records.any? { |r| r['type'] == 'l1_body_erasure' && r['content_hash'] == h2 },
         '4: erasure record carries the v2 hash'
  assert updates.any? { |r| r['next_hash'] == h2 }, '4: update records still cite v2'
  assert provider.restore('note', h2, reason: 'gone')[:success] == false,
         '4: restore to an erased body fails'

  # 5. delete, then restore recreates the entry.
  provider.delete('note')
  assert current('note').nil?, '5: entry deleted'
  assert provider.restore('note', h1, reason: 'recreate')[:success], '5: restore after delete'
  assert current('note') == v1, '5: recreated content equals v1'

  # 6. tool surface: erase_body needs approval, history prints short hashes.
  text = tool_text('command' => 'erase_body', 'name' => 'note',
                   'content_hash' => h1, 'reason' => 'no approval given')
  assert text.include?('approved'), '6: erase_body without approval is refused'
  assert stored?(h1), '6: body untouched by the refused call'
  assert tool_text('command' => 'history', 'name' => 'note').include?(h1[0, 12]),
         '6: history text carries the short hash'

  # 7. store switched off: no body kept, one active:false activation appended.
  cfg_path = KairosMcp.skills_config_path
  cfg_backup = File.exist?(cfg_path) ? File.read(cfg_path) : nil
  FileUtils.mkdir_p(File.dirname(cfg_path))
  base = cfg_backup ? (YAML.safe_load(cfg_backup) || {}) : {}
  File.write(cfg_path, base.merge('l1_history' => { 'enabled' => false }).to_yaml)
  off = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)
  v3 = body('v3', 'note3')
  off.create('note3', v3)
  assert !stored?(hash_of(v3)), '7: body not stored while disabled'
  assert records.count { |r| r['type'] == 'l1_history_activation' && r['active'] == false } == 1,
         '7: one active:false activation record'

  # 8. a path-shaped hash is refused, not raised.
  bad = '../../etc/passwd'
  assert provider.restore('note', bad, reason: 'bad hash')[:success] == false,
         '8: restore rejects an invalid hash'
  assert provider.erase_body('note', bad, reason: 'bad hash')[:success] == false,
         '8: erase_body rejects an invalid hash'
rescue StandardError => e
  $fail += 1
  puts "FAIL unexpected #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
ensure
  if cfg_path
    cfg_backup ? File.write(cfg_path, cfg_backup) : FileUtils.rm_f(cfg_path)
  end
  FileUtils.rm_rf(tmp)
  puts "\n#{$pass} passed, #{$fail} failed"
  exit($fail.zero? ? 0 : 1)
end
