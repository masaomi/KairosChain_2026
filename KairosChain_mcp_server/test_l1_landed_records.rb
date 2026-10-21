#!/usr/bin/env ruby
# frozen_string_literal: true

# L1 restore and erase on their failure paths. The live entry, the stored
# bodies and the chain agree however the append ends:
#
#   N1  a record that landed is never treated as not landed -- neither when
#       add_block raises after the write, nor when the SQLite metadata update
#       that follows it fails
#   C3  an interrupt during the append still decides the quarantine
#   N2  a quarantine left behind is settled from the chain on the next access
#   N4  live content in a SkillSet's knowledge dir blocks an erasure
#   X1  a failed restore undoes only what it wrote
#   X2  aborting an erasure never drops intact bytes for a damaged copy
#
# Run from the server directory: ruby test_l1_landed_records.rb

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'

tmp = Dir.mktmpdir('l1_landed_records')
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'

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
objects_root = lambda { File.join(File.dirname(KairosMcp.knowledge_dir), 'l1_history', 'objects') }
stored = lambda { |h| File.exist?(File.join(objects_root.call, h[0, 2], h)) }
quarantines = lambda { |h| Dir.glob(File.join(objects_root.call, h[0, 2], "#{h}.erasing*")) }
live = lambda do |name|
  path = Dir.glob(File.join(KairosMcp.knowledge_dir, name, '*.md')).sort.first
  path && File.read(path)
end

records = lambda do
  KairosMcp::KairosChain::Chain.new.chain.flat_map do |block|
    Array(block.data).map do |raw|
      begin
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        nil
      end
    end
  end.compact
end
erasures_of = lambda { |h| records.call.count { |r| r['type'] == 'l1_body_erasure' && r['content_hash'] == h } }
restores_of = lambda { |name| records.call.count { |r| r['type'] == 'knowledge_update' && r['action'] == 'restore' && r['knowledge_id'] == name } }

chain_class = KairosMcp::KairosChain::Chain
original_add_block = chain_class.instance_method(:add_block)

# Run the block with the next add_block replaced by `behaviour`, which receives
# a callable that performs the real append. Later appends behave normally.
with_next_add_block = lambda do |behaviour, &blk|
  armed = [true]
  chain_class.send(:define_method, :add_block) do |*args|
    real = -> { original_add_block.bind(self).call(*args) }
    if armed[0]
      armed[0] = false
      behaviour.call(real)
    else
      real.call
    end
  end
  begin
    blk.call
  ensure
    chain_class.send(:define_method, :add_block, original_add_block)
  end
end

land_then = lambda { |error| lambda { |real| real.call; raise error } }
raise_only = lambda { |error| lambda { |_real| raise error } }
storage_error = -> { KairosMcp::Storage::Error.new('unknown whether the write landed') }

call_catching = lambda do |&blk|
  blk.call
rescue Exception => e # rubocop:disable Lint/RescueException
  { success: :raised, raised: e.class.name, error: e.message }
end

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(tmp)
    abort "refusing to run: blockchain path #{KairosMcp.blockchain_path} is outside #{tmp}"
  end

  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  kp = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)

  # --- 1 (N1): restore, add_block raises after the record landed ----------
  puts 'case 1: a restore whose record landed stands although add_block raised'
  n1 = body.call('note', 'n1')
  kp.create('note', n1)
  kp.update('note', body.call('note', 'n2'))
  before = restores_of.call('note')
  res = nil
  with_next_add_block.call(land_then.call(storage_error.call)) do
    res = call_catching.call { kp.restore('note', sha.call(n1)) }
  end
  assert.call(res[:success] == true, "case 1: restore reports success (got #{res.inspect})")
  assert.call(live.call('note') == n1, 'case 1: the live entry holds the restored body')
  assert.call(restores_of.call('note') == before + 1, 'case 1: exactly one restore record')

  # --- 2 (N1): restore, the SQLite metadata update fails after landing ----
  puts 'case 2: a metadata failure after the record does not undo the restore'
  n2 = body.call('note', 'n2')
  kp.update('note', body.call('note', 'n3'))
  backend = kp.send(:storage_backend)
  backend.define_singleton_method(:backend_type) { :sqlite }
  backend.define_singleton_method(:save_knowledge_meta) { |*_a| raise 'sqlite: database is locked' }
  before = restores_of.call('note')
  begin
    res = call_catching.call { kp.restore('note', sha.call(n2)) }
  ensure
    backend.singleton_class.send(:remove_method, :backend_type)
    backend.singleton_class.send(:remove_method, :save_knowledge_meta)
  end
  assert.call(res[:success] == true, "case 2: restore reports success (got #{res.inspect})")
  assert.call(live.call('note') == n2, 'case 2: the live entry holds the restored body')
  assert.call(restores_of.call('note') == before + 1, 'case 2: exactly one restore record')

  # --- 3 (N1): erase, add_block raises after the record landed -------------
  puts 'case 3: an erasure whose record landed removes the body'
  e1 = body.call('e', 'e1')
  kp.create('e', e1)
  kp.update('e', body.call('e', 'e2'))
  with_next_add_block.call(land_then.call(storage_error.call)) do
    res = call_catching.call { kp.erase_body('e', sha.call(e1), reason: 'case 3') }
  end
  assert.call(res[:success] == true, "case 3: erase_body reports success (got #{res.inspect})")
  assert.call(!stored.call(sha.call(e1)), 'case 3: the body is gone')
  assert.call(quarantines.call(sha.call(e1)).empty?, 'case 3: no quarantine left')
  assert.call(erasures_of.call(sha.call(e1)) == 1, 'case 3: exactly one erasure record')

  # --- 4 (C3): interrupt before the record landed -------------------------
  puts 'case 4: an interrupt before the record lands puts the body back'
  f1 = body.call('f', 'f1')
  kp.create('f', f1)
  kp.update('f', body.call('f', 'f2'))
  with_next_add_block.call(raise_only.call(Interrupt.new)) do
    res = call_catching.call { kp.erase_body('f', sha.call(f1), reason: 'case 4') }
  end
  assert.call(res[:raised] == 'Interrupt', "case 4: the interrupt propagated (got #{res.inspect})")
  assert.call(stored.call(sha.call(f1)), 'case 4: the body is stored again')
  assert.call(quarantines.call(sha.call(f1)).empty?, 'case 4: no quarantine left')
  assert.call(erasures_of.call(sha.call(f1)).zero?, 'case 4: no erasure record')

  # --- 5 (C3): interrupt after the record landed --------------------------
  puts 'case 5: an interrupt after the record lands still removes the body'
  g1 = body.call('g', 'g1')
  kp.create('g', g1)
  kp.update('g', body.call('g', 'g2'))
  with_next_add_block.call(land_then.call(Interrupt.new)) do
    res = call_catching.call { kp.erase_body('g', sha.call(g1), reason: 'case 5') }
  end
  assert.call(res[:raised] == 'Interrupt', "case 5: the interrupt propagated (got #{res.inspect})")
  assert.call(!stored.call(sha.call(g1)), 'case 5: the body is gone')
  assert.call(quarantines.call(sha.call(g1)).empty?, 'case 5: no quarantine left')
  assert.call(erasures_of.call(sha.call(g1)) == 1, 'case 5: exactly one erasure record')

  # --- 6 (N2): a recorded erasure whose cleanup failed ---------------------
  puts 'case 6: a leftover quarantine with a record is deleted on the next access'
  h1 = body.call('h', 'h1')
  kp.create('h', h1)
  kp.update('h', body.call('h', 'h2'))
  store_class = KairosMcp::L1History
  original_commit = store_class.instance_method(:commit_erase)
  store_class.send(:define_method, :commit_erase) { |*_a| raise 'disk error while deleting' }
  begin
    res = call_catching.call { kp.erase_body('h', sha.call(h1), reason: 'case 6') }
  ensure
    store_class.send(:define_method, :commit_erase, original_commit)
  end
  assert.call(erasures_of.call(sha.call(h1)) == 1, 'case 6: the erasure is recorded')
  assert.call(res[:success] == true, "case 6: erase_body reports the recorded erasure (got #{res.inspect})")
  kp.history('h')
  assert.call(!stored.call(sha.call(h1)), 'case 6: the body is gone after the next access')
  assert.call(quarantines.call(sha.call(h1)).empty?, 'case 6: no quarantine left after the next access')

  # --- 7 (N2): a quarantine without a record -------------------------------
  puts 'case 7: a leftover quarantine without a record is put back on the next access'
  i1 = body.call('i', 'i1')
  kp.create('i', i1)
  kp.update('i', body.call('i', 'i2'))
  kp.send(:history_store).begin_erase(sha.call(i1)) # a crash right after the quarantine
  assert.call(!stored.call(sha.call(i1)), 'case 7: precondition: the body is quarantined')
  kp.history('i')
  assert.call(stored.call(sha.call(i1)), 'case 7: the body is stored again after the next access')
  assert.call(quarantines.call(sha.call(i1)).empty?, 'case 7: no quarantine left')

  # --- 8 (N2): unknown outcome is left for the chain to decide ------------
  if defined?(KairosMcp::KairosChain::LandedProbe)
    puts 'case 8: an unknown outcome leaves the quarantine; the next access decides it'
    k1 = body.call('k', 'k1')
    kp.create('k', k1)
    kp.update('k', body.call('k', 'k2'))
    probe = KairosMcp::KairosChain::LandedProbe.singleton_class
    probe.send(:alias_method, :kc_orig_status, :status)
    probe.send(:define_method, :status) { |*_a, **_k| :unknown }
    begin
      with_next_add_block.call(raise_only.call(storage_error.call)) do
        res = call_catching.call { kp.erase_body('k', sha.call(k1), reason: 'case 8') }
      end
    ensure
      probe.send(:alias_method, :status, :kc_orig_status)
      probe.send(:remove_method, :kc_orig_status)
    end
    assert.call(res[:success] == false, "case 8: erase_body does not report success (got #{res.inspect})")
    assert.call(quarantines.call(sha.call(k1)).size == 1, 'case 8: the body stays quarantined')
    kp.history('k')
    assert.call(stored.call(sha.call(k1)), 'case 8: the next access puts it back (no record)')
  end

  # --- 9 (N4): live content in a SkillSet knowledge dir --------------------
  puts 'case 9: a body live in a SkillSet knowledge dir is not erased'
  j1 = body.call('j', 'j1')
  kp.create('j', j1)
  ext = File.join(tmp, 'skillsets', 'demo', 'knowledge')
  FileUtils.mkdir_p(ext)
  FileUtils.cp_r(File.join(KairosMcp.knowledge_dir, 'j'), File.join(ext, 'j'))
  kp.update('j', body.call('j', 'j2'))
  kp.add_external_dir(ext, source: 'skillset:demo')
  res = call_catching.call { kp.erase_body('j', sha.call(j1), reason: 'case 9') }
  assert.call(res[:success] == false, "case 9: erase_body refuses (got #{res.inspect})")
  assert.call(res[:error].to_s.include?('skillset:demo'), 'case 9: the refusal names the SkillSet dir')
  assert.call(stored.call(sha.call(j1)), 'case 9: the body is still stored')

  # --- 10: a stored body no entry ever pointed at ---------------------------
  puts 'case 10: a body cited by no entry is not erased under any name'
  z = body.call('z', 'orphan')
  kp.send(:history_store).store(z)
  res = call_catching.call { kp.erase_body('z', sha.call(z), reason: 'case 10') }
  assert.call(res[:success] == false, "case 10: erase_body refuses (got #{res.inspect})")
  assert.call(stored.call(sha.call(z)), 'case 10: the body is still stored')

  # --- 12 (C3): restore, interrupt before the record lands -----------------
  puts 'case 12: an interrupt during a restore append puts the live entry back'
  r1 = body.call('r', 'r1')
  kp.create('r', r1)
  r2 = body.call('r', 'r2')
  kp.update('r', r2)
  before = restores_of.call('r')
  with_next_add_block.call(raise_only.call(Interrupt.new)) do
    res = call_catching.call { kp.restore('r', sha.call(r1)) }
  end
  assert.call(res[:raised] == 'Interrupt', "case 12: the interrupt propagated (got #{res.inspect})")
  assert.call(live.call('r') == r2, 'case 12: the live entry is back to its previous body')
  assert.call(restores_of.call('r') == before, 'case 12: no restore record')

  # --- 13 (X1): a restore undoes only what it wrote -------------------------
  # The restore's own write fails before taking effect, while a same-name
  # writer has put its own content there. That content is not the restore's
  # to undo: an entry it never wrote must neither be removed nor rewritten.
  puts 'case 13: a restore whose write never took effect leaves a same-name writer alone'
  parser = KairosMcp::AnthropicSkillParser.singleton_class
  # The next call to `meth` stands for the restore's own write: the same-name
  # writer's content lands first (through the real method), then the write
  # fails before taking effect. Later calls go to the real method.
  other_then_fail = lambda do |meth, other_args, &blk|
    unbound = parser.instance_method(meth)
    real = KairosMcp::AnthropicSkillParser.method(meth)
    armed = [true]
    parser.send(:define_method, meth) do |*args, **kw|
      next real.call(*args, **kw) unless armed[0]

      armed[0] = false
      real.call(*other_args)
      raise IOError, 'no space left on device'
    end
    begin
      blk.call
    ensure
      parser.send(:define_method, meth, unbound)
    end
  end

  s1 = body.call('s', 's1')
  kp.create('s', s1)
  kp.delete('s')
  s_other = body.call('s', 'other writer')
  other_then_fail.call(:create, [KairosMcp.knowledge_dir, 's', s_other]) do
    res = call_catching.call { kp.restore('s', sha.call(s1)) }
  end
  assert.call(res[:success] != true, "case 13a: restore does not report success (got #{res.inspect})")
  assert.call(live.call('s') == s_other, "case 13a: the other writer's new entry is still there (got #{live.call('s').inspect})")

  t1 = body.call('t', 't1')
  kp.create('t', t1)
  kp.update('t', body.call('t', 't2'))
  t_other = body.call('t', 'other writer')
  other_then_fail.call(:update, [File.join(KairosMcp.knowledge_dir, 't'), t_other]) do
    res = call_catching.call { kp.restore('t', sha.call(t1)) }
  end
  assert.call(res[:success] != true, "case 13b: restore does not report success (got #{res.inspect})")
  assert.call(live.call('t') == t_other, "case 13b: the other writer's update is not rewritten (got #{live.call('t').inspect})")

  # --- 14 (X2): an abort keeps intact bytes over a damaged copy -------------
  puts 'case 14: aborting an erasure never drops the quarantine for a damaged copy'
  hs = kp.send(:history_store)
  u1 = body.call('u', 'u1')
  hu = hs.store(u1)
  object = File.join(objects_root.call, hu[0, 2], hu)
  intact = lambda { File.file?(object) && Digest::SHA256.file(object).hexdigest == hu }
  id = hs.begin_erase(hu)
  File.write(object, 'damaged bytes') # a damaged copy appears at the content address
  hs.abort_erase(hu, id)
  assert.call(intact.call, 'case 14a: the object at the content address is intact after the abort')
  assert.call(quarantines.call(hu).empty?, 'case 14a: no quarantine left')
  id = hs.begin_erase(hu)
  hs.store(u1) # stored again, intact
  hs.abort_erase(hu, id)
  assert.call(intact.call, 'case 14b: an intact re-stored copy stands')
  assert.call(quarantines.call(hu).empty?, 'case 14b: the redundant quarantine is dropped')

  # --- 11: a store-root refusal is not remembered ---------------------------
  puts 'case 11: once the store root can be created, bodies are kept again'
  kb2 = File.join(tmp, 'kb2', 'knowledge')
  FileUtils.mkdir_p(kb2)
  blocker = File.join(tmp, 'kb2', 'l1_history')
  File.write(blocker, 'not a directory')
  kp2 = KairosMcp::KnowledgeProvider.new(kb2, vector_search_enabled: false, include_skillset_knowledge: false)
  m1 = body.call('m', 'm1')
  res = call_catching.call { kp2.create('m', m1) }
  assert.call(res[:success] == false, "case 11: create is refused while the root is blocked (got #{res.inspect})")
  File.delete(blocker)
  res = call_catching.call { kp2.create('m', m1) }
  assert.call(res[:success] == true, "case 11: create succeeds once unblocked (got #{res.inspect})")
  assert.call(File.exist?(File.join(tmp, 'kb2', 'l1_history', 'objects', sha.call(m1)[0, 2], sha.call(m1))),
              'case 11: the body is kept in the store')
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
