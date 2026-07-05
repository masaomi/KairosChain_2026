# frozen_string_literal: true

# Slice 3 unit tests: snapshot embedding + content preview (ACT-2 semantic layer, §Kinds
# optional snapshot). Pure Ruby (no MMP). Run from project root:
#   ruby -I KairosChain_mcp_server/templates/skillsets/synoptis/lib \
#     KairosChain_mcp_server/templates/skillsets/synoptis/test/test_l2_constitutive_slice3.rb

require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'synoptis/constitutive/content_attestation_entry'
require 'synoptis/constitutive/subject_ref'
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
PC  = Synoptis::Constitutive::ProposalCriterion

def write_context(dir, s, n, type, body)
  d = File.join(dir, s, n)
  FileUtils.mkdir_p(d)
  File.write(File.join(d, "#{n}.md"), "---\ntitle: \"#{n}\"\ndate: 2026-07-05\ntype: #{type}\n---\n\n#{body}\n")
  "context://#{s}/#{n}"
end

Dir.mktmpdir do |root|
  context_dir = File.join(root, 'context')
  FileUtils.mkdir_p(context_dir)
  session = 'sess3'
  short_uri = write_context(context_dir, session, 'short_h', 'handoff', 'brief body')
  long_body = 'X' * 1000
  long_uri = write_context(context_dir, session, 'long_h', 'decision', long_body)

  # ---------------------------------------------------------------
  section('SubjectRef content_text / content_preview')

  path = SR.resolve_path(short_uri, context_dir: context_dir)
  assert(SR.content_text(short_uri, context_dir: context_dir) == File.read(path), 'content_text = full persisted text')

  short_prev = SR.content_preview(short_uri, context_dir: context_dir, limit: 300)
  assert(!short_prev.end_with?('…'), 'short content preview has no ellipsis')

  long_prev = SR.content_preview(long_uri, context_dir: context_dir, limit: 300)
  assert(long_prev.end_with?('…') && long_prev.length == 301, 'long content preview bounded to limit + ellipsis')

  assert(SR.content_preview('context://sess3/missing', context_dir: context_dir) == nil, 'preview nil for missing file')

  # ---------------------------------------------------------------
  section('ProposalCriterion surfaces preview (ACT-2 semantic layer)')

  props = PC.new(context_dir: context_dir, preview_chars: 300).propose(session_id: session)
  assert(props.length == 2, 'both judgment contexts proposed')
  assert(props.all? { |p| p.key?(:preview) && !p[:preview].nil? }, 'every proposal carries a preview')
  long = props.find { |p| p[:subject_id] == long_uri }
  assert(long[:preview].end_with?('…'), 'long proposal preview is bounded')

  # ---------------------------------------------------------------
  section('Snapshot embedding (§Kinds optional); snapshot SHA256 == digest')

  digest = SR.digest(short_uri, context_dir: context_dir)
  snap = SR.content_text(short_uri, context_dir: context_dir)
  e = CAE.new(subject_id: short_uri, digest: digest, moment: 'm', snapshot: snap)
  assert(e.to_h[:snapshot] == snap, 'entry carries the embedded snapshot')
  assert(Digest::SHA256.hexdigest(snap) == digest, 'snapshot SHA256 equals the attested digest (auditable)')
  assert(CAE.from_h(e.to_h).entry_hash == e.entry_hash, 'snapshot survives from_h round-trip')

  e_nosnap = CAE.new(subject_id: short_uri, digest: digest, moment: 'm')
  assert(e_nosnap.to_h[:snapshot].nil?, 'no snapshot when not embedded')
  assert(e_nosnap.entry_hash != e.entry_hash, 'embedding a snapshot changes the entry hash')
end

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
