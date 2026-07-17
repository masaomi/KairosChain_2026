#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Slice S2: append-line persisted format (AHM-4 / AHM-5 / AHM-9)
# ============================================================================
# Realizes attestation_home_migration_design_v0.3 §M3. The anchor Log persists
# as one JSON entry per line (append-line hash chain) so a commit appends a
# single line (O(1)) instead of rewriting the whole store (O(n)). Invariants
# exercised here:
#   - AHM-5: entry_hash preimage stays Entry.canonical_content; the persisted
#     line is JSON.generate(entry.to_h). No file_registry hashing is reused.
#   - AHM-4: the append-line round trip preserves entry_hash / head byte-for-byte
#     (nothing about the chain semantics changes; only the on-disk shape does).
#   - AHM-9(i): the new loader still reads the superseded single-object `.json`
#     store (dual-format load), and the first write after such a load rewrites
#     the file in append-line form.
#   - Durability: a torn final line (crash mid-append) is dropped on load while
#     every fully-written entry before it is preserved — a committed entry is
#     never silently lost, and an uncommitted torn append is never resurrected.
#
# Usage:  ruby test_anchor_appendline.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)

require 'kairos_mcp'
require 'mmp'
require 'synoptis'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

$pass = 0
$fail = 0
def assert(msg)
  ok = yield
  puts(ok ? "  PASS: #{msg}" : "  FAIL: #{msg}")
  ok ? $pass += 1 : $fail += 1
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail += 1
end

def digest_for(str)
  Digest::SHA256.hexdigest(str)
end

def store_lines(path)
  File.readlines(path).map(&:strip).reject(&:empty?)
end

Dir.mktmpdir do |dir|
  # --------------------------------------------------------------------------
  puts "\n[1] On-disk shape is append-line (one JSON entry per line, O(1) append)"
  path = File.join(dir, 'al.json')
  log = Synoptis::Anchoring::Log.new(storage_path: path, operator_id: 'op')
  a0 = log.append_anchor(digest: digest_for('a'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  a1 = log.append_anchor(digest: digest_for('b'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  a2 = log.append_anchor(digest: digest_for('c'), anchor_type: 'generic', source_id: 's2', depositor: 'op')

  lines = store_lines(path)
  assert('one line per entry') { lines.size == 3 }
  assert('each line is a standalone entry object') do
    lines.each_with_index.all? { |l, i| JSON.parse(l)['position'] == i }
  end
  assert('no metadata wrapper object') { !File.read(path).start_with?('{' + "\n") }
  # No .tmp left behind by the append path.
  assert('append path leaves no temp file') { !File.exist?("#{path}.tmp") }

  # --------------------------------------------------------------------------
  puts "\n[2] Round-trip preserves entry_hash / head / verify (AHM-4/AHM-5)"
  reloaded = Synoptis::Anchoring::Log.new(storage_path: path, operator_id: 'op')
  assert('reload length == 3') { reloaded.length == 3 }
  assert('reload head unchanged') { reloaded.head == a2.entry_hash }
  assert('reload verifies valid') { reloaded.verify[:valid] == true }
  assert('every entry_hash preserved byte-for-byte') do
    reloaded.entries.map(&:entry_hash) == [a0.entry_hash, a1.entry_hash, a2.entry_hash]
  end
  assert('digest index rebuilt on load') { reloaded.find_by_digest(digest_for('b')).size == 1 }
  # A further commit on the reloaded log appends (O(1)) and stays consistent.
  a3 = reloaded.append_anchor(digest: digest_for('d'), anchor_type: 'generic', source_id: 's3', depositor: 'op')
  assert('append after reload grows store to 4 lines') { store_lines(path).size == 4 }
  again = Synoptis::Anchoring::Log.new(storage_path: path, operator_id: 'op')
  assert('second reload sees the appended entry') { again.head == a3.entry_hash && again.length == 4 }

  # --------------------------------------------------------------------------
  puts "\n[3] Withdrawal round-trips through append-line"
  wpath = File.join(dir, 'wal.json')
  wlog = Synoptis::Anchoring::Log.new(storage_path: wpath, operator_id: 'op')
  wa = wlog.append_anchor(digest: digest_for('note'), anchor_type: 'constitutive_note',
                          source_id: 'place://p/anchor/note', depositor: 'op')
  wlog.append_anchor(digest: digest_for('other'), anchor_type: 'generic', source_id: 's', depositor: 'op')
  ww = wlog.append_withdrawal(target: wa.entry_hash, withdrawer: 'op', reason: 'superseded')
  wreload = Synoptis::Anchoring::Log.new(storage_path: wpath, operator_id: 'op')
  assert('withdrawal head preserved') { wreload.head == ww.entry_hash }
  assert('withdrawn state preserved') { wreload.withdrawn?(wa.entry_hash) }
  assert('withdrawal chain still verifies') { wreload.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[4] Backward read of legacy single-object .json (AHM-9 i)"
  # Build a legacy-format store by hand (the pre-S2 shape) and confirm the new
  # loader reads it, preserving entry_hash / head, then migrates it to append-line
  # on the first write.
  legacy_path = File.join(dir, 'legacy.json')
  built = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'src.json'), operator_id: 'op')
  l0 = built.append_anchor(digest: digest_for('L0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  l1 = built.append_anchor(digest: digest_for('L1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  File.write(legacy_path, JSON.pretty_generate(
    'metadata' => { 'version' => '1.0', 'length' => 2, 'head' => l1.entry_hash },
    'entries' => [l0.to_h, l1.to_h]
  ))
  legacy = Synoptis::Anchoring::Log.new(storage_path: legacy_path, operator_id: 'op')
  assert('legacy .json read: length') { legacy.length == 2 }
  assert('legacy .json read: head preserved') { legacy.head == l1.entry_hash }
  assert('legacy .json read: entry_hashes preserved') do
    legacy.entries.map(&:entry_hash) == [l0.entry_hash, l1.entry_hash]
  end
  assert('legacy .json read: verifies valid') { legacy.verify[:valid] == true }
  # File is still legacy shape until the first write.
  assert('legacy file still single-object before write') do
    JSON.parse(File.read(legacy_path)).is_a?(Hash)
  end
  # First write migrates the whole store to append-line (atomic rewrite).
  l2 = legacy.append_anchor(digest: digest_for('L2'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  migrated_lines = store_lines(legacy_path)
  assert('after first write the store is append-line (3 lines)') { migrated_lines.size == 3 }
  assert('migration preserved earlier entry_hashes') do
    migrated_lines.map { |l| JSON.parse(l)['entry_hash'] } == [l0.entry_hash, l1.entry_hash, l2.entry_hash]
  end
  post = Synoptis::Anchoring::Log.new(storage_path: legacy_path, operator_id: 'op')
  assert('migrated store reloads valid') { post.verify[:valid] == true && post.head == l2.entry_hash }

  # --------------------------------------------------------------------------
  puts "\n[5] Legacy backfill (AHM-3/AHM-7) survives append-line migration"
  # An old-format anchor persisted WITHOUT governing_identity must backfill to the
  # legacy governing identity on load, keep entry_hash unchanged, and — once
  # migrated to append-line — persist the backfilled identity so a later reload
  # does not re-backfill under a different owner.
  bf_path = File.join(dir, 'backfill.json')
  seed = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'seed.json'), operator_id: 'agentA')
  old_entry = seed.append_anchor(digest: digest_for('paper'), anchor_type: 'constitutive_note',
                                 source_id: 'place://p/anchor/note', depositor: 'agentA')
  h = old_entry.to_h
  h.delete('governing_identity') # simulate a pre-migration entry
  File.write(bf_path, JSON.pretty_generate('metadata' => { 'version' => '1.0' }, 'entries' => [h]))
  bf = Synoptis::Anchoring::Log.new(storage_path: bf_path, operator_id: 'agentA')
  assert('backfill preserves entry_hash') { bf.entries.first.entry_hash == old_entry.entry_hash }
  assert('backfilled governing_identity == legacy owner') do
    bf.entries.first.governing_identity == 'agentA'
  end
  # Migrate to append-line under a NEW owner, then reload under that new owner:
  # the persisted governing_identity must remain agentA (frozen at commit), not
  # re-backfill to the new owner.
  bf.append_anchor(digest: digest_for('fresh'), anchor_type: 'generic', source_id: 's', depositor: 'agentB')
  bf2 = Synoptis::Anchoring::Log.new(storage_path: bf_path, operator_id: 'agentB')
  assert('migrated old entry keeps original governing_identity') do
    bf2.entries.first.governing_identity == 'agentA'
  end
  assert('migrated store verifies') { bf2.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[6] Torn final line (crash mid-append) is recovered, committed kept"
  torn_path = File.join(dir, 'torn.json')
  tlog = Synoptis::Anchoring::Log.new(storage_path: torn_path, operator_id: 'op')
  t0 = tlog.append_anchor(digest: digest_for('t0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  t1 = tlog.append_anchor(digest: digest_for('t1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  # Simulate a crash that flushed only a prefix of a third entry's line.
  full = File.read(torn_path)
  torn_tail = JSON.generate(
    'position' => 2, 'prev' => t1.entry_hash, 'kind' => 'anchor',
    'body' => { 'digest' => digest_for('t2'), 'source_id' => 's2' }, 'entry_hash' => 'deadbeef'
  )
  File.write(torn_path, full + torn_tail[0, torn_tail.length / 2]) # truncated, no newline
  recovered = Synoptis::Anchoring::Log.new(storage_path: torn_path, operator_id: 'op')
  assert('torn line dropped: only committed entries remain') { recovered.length == 2 }
  assert('torn recovery preserves committed head') { recovered.head == t1.entry_hash }
  assert('recovered chain verifies') { recovered.verify[:valid] == true }
  assert('recovered entry_hashes intact') do
    recovered.entries.map(&:entry_hash) == [t0.entry_hash, t1.entry_hash]
  end
  # The next write cleans the stale torn bytes via an atomic rewrite; a later
  # reload sees a well-formed append-line store with no leftover partial line.
  t2b = recovered.append_anchor(digest: digest_for('t2b'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  clean = Synoptis::Anchoring::Log.new(storage_path: torn_path, operator_id: 'op')
  assert('post-recovery store is clean (3 well-formed lines)') { store_lines(torn_path).size == 3 }
  assert('post-recovery reload valid') { clean.verify[:valid] == true && clean.head == t2b.entry_hash }

  # --------------------------------------------------------------------------
  puts "\n[7] Mid-chain corruption still degrades to empty (integrity boundary)"
  # A parse failure that is NOT the last line is genuine corruption, not a torn
  # append: load degrades to empty (matching the pre-S2 corrupt-store contract),
  # never a partial dangling index.
  corrupt_path = File.join(dir, 'corrupt.json')
  clog = Synoptis::Anchoring::Log.new(storage_path: corrupt_path, operator_id: 'op')
  clog.append_anchor(digest: digest_for('c0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  clog.append_anchor(digest: digest_for('c1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  good = store_lines(corrupt_path)
  File.write(corrupt_path, "{ this is not json\n" + good.join("\n") + "\n")
  cbad = Synoptis::Anchoring::Log.new(storage_path: corrupt_path, operator_id: 'op')
  assert('mid-chain corruption degrades to empty') { cbad.length == 0 }
  assert('degraded store verifies as empty') { cbad.verify[:valid] == true && cbad.length == 0 }

  # --------------------------------------------------------------------------
  puts "\n[8] Failed append clears @appendable so the next write rewrites (durability)"
  # Regression guard for the P0 where a torn partial line from a failed append,
  # with @appendable left true, would be written PAST by the next append and then
  # silently dropped (or degrade the store) on reload. After the failure the next
  # commit MUST rewrite_all atomically, overwriting the torn bytes.
  fa_path = File.join(dir, 'failappend.json')
  falog = Synoptis::Anchoring::Log.new(storage_path: fa_path, operator_id: 'op')
  fa0 = falog.append_anchor(digest: digest_for('f0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  fa1 = falog.append_anchor(digest: digest_for('f1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  # Simulate an append that flushes a partial (torn) line, then fails.
  def falog.append_last_line
    File.open(@storage_path, 'a') { |f| f.write('{"position":2,"prev":"deadbeef","kind":"anch') }
    raise IOError, 'simulated partial append failure'
  end
  fa_raised = false
  begin
    falog.append_anchor(digest: digest_for('f2'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  rescue IOError
    fa_raised = true
  end
  assert('failed append propagates') { fa_raised }
  assert('failed append rolled back in memory') { falog.length == 2 }
  assert('failed append cleared @appendable') { falog.instance_variable_get(:@appendable) == false }
  # The retry now takes rewrite_all (append_last_line is still stubbed but unused),
  # atomically overwriting the file including the torn partial bytes.
  fa2 = falog.append_anchor(digest: digest_for('f2b'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  assert('retry after failure succeeds via rewrite') { falog.length == 3 }
  fa_reload = Synoptis::Anchoring::Log.new(storage_path: fa_path, operator_id: 'op')
  assert('reload after failed-append+retry has no torn corruption') { fa_reload.length == 3 }
  assert('reload preserves all committed entries') do
    fa_reload.entries.map(&:entry_hash) == [fa0.entry_hash, fa1.entry_hash, fa2.entry_hash]
  end
  assert('reload verifies valid') { fa_reload.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[9] Write after corrupt-degrade rewrites cleanly, no append onto stale bytes"
  # Regression guard for the P0 where reset_state! left @appendable true, so the
  # first write after a corrupt-degrade appended onto the still-corrupt bytes and
  # the acknowledged commit was lost on the next load.
  cd_path = File.join(dir, 'corruptdegrade.json')
  seedcd = Synoptis::Anchoring::Log.new(storage_path: cd_path, operator_id: 'op')
  seedcd.append_anchor(digest: digest_for('cd0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  seedcd.append_anchor(digest: digest_for('cd1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  goodcd = store_lines(cd_path)
  File.write(cd_path, "{ not json at all\n" + goodcd.join("\n") + "\n") # mid-file corruption
  cdlog = Synoptis::Anchoring::Log.new(storage_path: cd_path, operator_id: 'op')
  assert('corrupt store degraded to empty') { cdlog.length == 0 }
  assert('degrade cleared @appendable') { cdlog.instance_variable_get(:@appendable) == false }
  # First write must rewrite the whole file atomically, NOT append onto corrupt bytes.
  cdfresh = cdlog.append_anchor(digest: digest_for('cdX'), anchor_type: 'generic', source_id: 'sx', depositor: 'op')
  cdreload = Synoptis::Anchoring::Log.new(storage_path: cd_path, operator_id: 'op')
  assert('post-degrade write survives reload (not lost)') { cdreload.length == 1 }
  assert('post-degrade reload holds exactly the new entry') { cdreload.head == cdfresh.entry_hash }
  assert('post-degrade reload verifies valid') { cdreload.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[10] Failed append that wrote a COMPLETE line (fsync failed) truncates → no resurrection"
  # Regression guard for the durability gap where puts succeeds (a complete line
  # reaches the page cache on close) but fsync raises: in-memory rollback + cleared
  # @appendable protect the running process, but a restart BEFORE the next write
  # would read the complete-but-unacknowledged line as committed and resurrect a
  # write the caller was told failed. The append-path truncate-on-failure restores
  # the pre-append length so no restart can resurrect it.
  res_path = File.join(dir, 'resurrect.json')
  rlog = Synoptis::Anchoring::Log.new(storage_path: res_path, operator_id: 'op')
  r0 = rlog.append_anchor(digest: digest_for('r0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  r1 = rlog.append_anchor(digest: digest_for('r1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  size_before = File.size(res_path)
  # Simulate puts-succeeds-then-fsync-fails: write a full line, then raise. The real
  # append_last_line rescue (with truncate_storage) still runs around this.
  def rlog.write_entry_line(entry)
    File.open(@storage_path, 'a') { |f| f.puts(JSON.generate(entry.to_h)) } # complete line, no fsync
    raise IOError, 'simulated fsync failure after a complete write'
  end
  res_raised = false
  begin
    rlog.append_anchor(digest: digest_for('r2'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  rescue IOError
    res_raised = true
  end
  assert('failed complete-line append propagates') { res_raised }
  assert('failed complete-line append rolled back in memory') { rlog.length == 2 }
  assert('file truncated back to pre-append length') { File.size(res_path) == size_before }
  # A fresh Log (simulating process restart) must NOT resurrect the unacknowledged entry.
  fresh = Synoptis::Anchoring::Log.new(storage_path: res_path, operator_id: 'op')
  assert('no resurrection on restart: length stays 2') { fresh.length == 2 }
  assert('no resurrection: head is last committed entry') { fresh.head == r1.entry_hash }
  assert('post-truncate reload verifies valid') { fresh.verify[:valid] == true }
  assert('no resurrection: entry_hashes are exactly the committed pair') do
    fresh.entries.map(&:entry_hash) == [r0.entry_hash, r1.entry_hash]
  end
end

puts "\n#{'=' * 60}"
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
