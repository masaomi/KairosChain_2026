# frozen_string_literal: true

# Slice 1 unit + wiring tests for the L2 constitutive attestation module.
# Pure Ruby: requires only FileRegistry + the constitutive module (no MMP).
# Run from project root:
#   ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/templates/skillsets/synoptis/test/test_l2_constitutive_slice1.rb

require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'synoptis/registry/file_registry'
require 'synoptis/constitutive/content_attestation_entry'
require 'synoptis/constitutive/subject_ref'
require 'synoptis/constitutive/attestation_chain'
require 'synoptis/constitutive/proposal_criterion'

$pass = 0
$fail = 0

def assert(cond, msg)
  if cond
    $pass += 1
    puts "  PASS: #{msg}"
  else
    $fail += 1
    puts "  FAIL: #{msg}"
  end
end

def section(t)
  puts "\n#{'=' * 60}\nSECTION: #{t}\n#{'=' * 60}"
end

CAE = Synoptis::Constitutive::ContentAttestationEntry
SR  = Synoptis::Constitutive::SubjectRef
AC  = Synoptis::Constitutive::AttestationChain
PC  = Synoptis::Constitutive::ProposalCriterion

# Build a fake L2 context tree: context_dir/<session>/<name>/<name>.md
def write_context(context_dir, session_id, name, type, body = "body of #{name}")
  dir = File.join(context_dir, session_id, name)
  FileUtils.mkdir_p(dir)
  fm = "---\ntitle: \"#{name}\"\ntype: #{type}\n---\n\n#{body}\n"
  File.write(File.join(dir, "#{name}.md"), fm)
  "context://#{session_id}/#{name}"
end

Dir.mktmpdir do |root|
  context_dir = File.join(root, 'context')
  data_dir = File.join(root, 'synoptis_data')
  FileUtils.mkdir_p(context_dir)
  FileUtils.mkdir_p(data_dir)
  session = 'session_test_0001'

  uri_handoff  = write_context(context_dir, session, 'my_handoff', 'handoff')
  uri_decision = write_context(context_dir, session, 'my_decision', 'decision')
  uri_debrief  = write_context(context_dir, session, 'my_debrief', 'debrief')
  uri_plain    = write_context(context_dir, session, 'my_notes', 'session_summary')

  # ---------------------------------------------------------------
  section('ContentAttestationEntry — canonical form + hashing')

  e1 = CAE.new(subject_id: uri_handoff, digest: 'abc123', moment: '2026-07-05T00:00:00Z')
  e1b = CAE.new(subject_id: uri_handoff, digest: 'abc123', moment: '2026-07-05T00:00:00Z',
                entry_id: e1.entry_id)
  assert(e1.canonical_json == e1b.canonical_json, 'canonical_json deterministic for equal fields')
  assert(e1.entry_hash == e1b.entry_hash, 'entry_hash deterministic for equal fields')

  e2 = CAE.new(subject_id: uri_handoff, digest: 'abc124', moment: '2026-07-05T00:00:00Z',
               entry_id: e1.entry_id)
  assert(e1.entry_hash != e2.entry_hash, 'entry_hash changes when digest changes')

  h = e1.to_h
  assert(h[:kind] == 'content_attestation', 'to_h carries kind=content_attestation')
  assert(h.key?(:snapshot) && h[:snapshot].nil?, 'nil snapshot retained (not compacted)')
  round = CAE.from_h(e1.to_h)
  assert(round.entry_hash == e1.entry_hash, 'from_h round-trips entry_hash')
  assert(!e1.to_h.key?(:signature) && !e1.to_h.key?(:ttl), 'no signature / no ttl fields (posture parity)')

  # ---------------------------------------------------------------
  section('SubjectRef — parse / resolve / digest / type')

  parsed = SR.parse(uri_handoff)
  assert(parsed[:session_id] == session && parsed[:context_name] == 'my_handoff', 'parse splits uri')
  assert_raised = begin; SR.parse('skill://foo'); false; rescue ArgumentError; true; end
  assert(assert_raised, 'parse rejects non-context uri')

  path = SR.resolve_path(uri_handoff, context_dir: context_dir)
  assert(File.exist?(path), 'resolve_path points at the persisted file')

  manual = Digest::SHA256.hexdigest(File.binread(path))
  assert(SR.digest(uri_handoff, context_dir: context_dir) == manual, 'digest = SHA256 of persisted bytes')

  # byte sensitivity: change one byte -> different digest; id unchanged
  d_before = SR.digest(uri_handoff, context_dir: context_dir)
  File.write(path, File.read(path) + 'x')
  d_after = SR.digest(uri_handoff, context_dir: context_dir)
  assert(d_before != d_after, 'digest changes when one byte changes')
  assert(SR.parse(uri_handoff)[:context_name] == 'my_handoff', 'subject-id stable across content change')

  assert(SR.frontmatter_type(uri_decision, context_dir: context_dir) == 'decision', 'frontmatter_type reads type')
  cs = SR.content_state(uri_debrief, context_dir: context_dir)
  assert(cs[:exists] && cs[:bytes] > 0 && cs[:digest], 'content_state reports exists/bytes/digest')

  fail_closed = begin
    SR.digest('context://nope/missing', context_dir: context_dir); false
  rescue StandardError; true; end
  assert(fail_closed, 'digest fail-closed on missing file (never attest absent content)')

  # ---------------------------------------------------------------
  section('ProposalCriterion (ACT-2) — judgment types only')

  crit = PC.new(context_dir: context_dir)
  proposals = crit.propose(session_id: session)
  subjects = proposals.map { |p| p[:subject_id] }
  assert(subjects.include?(uri_handoff), 'proposes handoff type')
  assert(subjects.include?(uri_decision), 'proposes decision type')
  assert(subjects.include?(uri_debrief), 'proposes debrief type')
  assert(!subjects.include?(uri_plain), 'does NOT propose non-judgment (session_summary) type')
  assert(proposals.length == 3, 'exactly 3 judgment contexts proposed')
  assert(crit.propose(session_id: 'no_such_session') == [], 'empty for unknown session')

  # ---------------------------------------------------------------
  section('AttestationChain (LED-2a append-only + LED-5 two stores)')

  reg = Synoptis::Registry::FileRegistry.new(data_dir: data_dir)
  chain = AC.new(registry: reg)

  before_meta = 0 # stand-in: no Meta Ledger touched by this module at all

  ent_a = CAE.new(subject_id: uri_handoff, digest: SR.digest(uri_handoff, context_dir: context_dir),
                  moment: '2026-07-05T01:00:00Z')
  chain.append_content_attestation(ent_a)
  ent_b = CAE.new(subject_id: uri_decision, digest: SR.digest(uri_decision, context_dir: context_dir),
                  moment: '2026-07-05T02:00:00Z')
  chain.append_content_attestation(ent_b)

  entries = chain.entries
  assert(entries.length == 2, 'two appends -> two ledger entries')
  assert(entries[0][:_prev_entry_hash].nil?, 'first entry has no prev hash')
  assert(!entries[1][:_prev_entry_hash].nil?, 'second entry links to prev (hash chain)')
  vc = chain.verify_chain(AC::LEDGER)
  assert(vc[:valid] && vc[:length] == 2, 'verify_chain valid, length 2')

  ledger_file = File.join(data_dir, 'l2_attestation.jsonl')
  oplog_file  = File.join(data_dir, 'l2_operational_log.jsonl')
  assert(File.exist?(ledger_file), 'ledger is its own file l2_attestation.jsonl')

  # ---------------------------------------------------------------
  section('Operational log (ACT-4 decline / ACT-5 trigger)')

  chain.append_trigger(surfaced_count: 3, moment: '2026-07-05T03:00:00Z')
  chain.append_decline(subject_id: uri_debrief, moment: '2026-07-05T03:01:00Z')
  oplog = chain.oplog
  assert(oplog.length == 2, 'oplog has trigger + decline')
  trig = oplog.find { |r| r[:record] == 'trigger' }
  dec  = oplog.find { |r| r[:record] == 'decision' }
  assert(trig && trig[:surfaced_count] == 3 && !trig.key?(:subject_id), 'trigger record content-free + subject-free')
  assert(dec && dec[:decision] == 'declined' && dec[:subject_id] == uri_debrief, 'decline keyed by subject')
  assert(!dec.key?(:digest) && !dec.key?(:content) && !dec.key?(:snapshot), 'decline is content-free (no digest/content)')
  assert(File.exist?(oplog_file) && ledger_file != oplog_file, 'two distinct store files (LED-5)')

  # ---------------------------------------------------------------
  section('LED-1 selective — live context untouched by attestation')

  live_before = File.binread(SR.resolve_path(uri_handoff, context_dir: context_dir))
  chain.append_content_attestation(
    CAE.new(subject_id: uri_handoff, digest: 'zzz', moment: '2026-07-05T04:00:00Z')
  )
  live_after = File.binread(SR.resolve_path(uri_handoff, context_dir: context_dir))
  assert(live_before == live_after, 'appending an attestation does not modify the live context file')

  # ---------------------------------------------------------------
  section('Append-only surface — no edit/delete API')

  assert(!chain.respond_to?(:delete) && !chain.respond_to?(:update), 'chain exposes no delete/update')
  assert(!reg.respond_to?(:delete) && !reg.respond_to?(:overwrite), 'registry exposes no delete/overwrite')
end

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
