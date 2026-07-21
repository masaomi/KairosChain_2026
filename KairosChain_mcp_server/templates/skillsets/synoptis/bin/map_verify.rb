#!/usr/bin/env ruby
# frozen_string_literal: true

# map_verify — offline auditor verifier for map-1 mutual-anchoring artifacts
# (MAP-1..4, aud_l2_mutual_anchoring_design v0.5).
#
# Verifies with EXACTLY the disclosed trust base: the artifacts named on the
# command line plus the shipped map-1 convention definition. No registry, no
# network, no operator cooperation. (Authentic log/chain views are the
# caller's inputs; their own integrity is checked by the khab-1 surface.)
#
# Usage:
#   map_verify.rb credential  <credential.json>
#   map_verify.rb attestation <credential.json> <payload-file> <signature-hex>
#   map_verify.rb succession  <old_credential.json> <records.json> [changeover_position]
#       records.json = JSON array of internal-chain record STRINGS, committed order
#   map_verify.rb coverage    <rule-file> <anchors.json> [chain_extent] [rule_position] [rule_moment] [now]
#       anchors.json = JSON array of {"tree_size":..,"moment":".."} observations;
#       every_n_records needs chain_extent (+ optional rule_position);
#       every_n_days needs rule_moment and now (ISO8601) as args 5 and 6 —
#       pass 0 0 for the unused args 3 and 4.
#   map_verify.rb pair        <log_a.json> <identity_a> <log_b.json> <identity_b>
#       log_*.json = JSON array of anchor-entry objects (entry.to_h shape);
#       reports what a verified pair establishes (MAP-1) — and ONLY that.
#   map_verify.rb retraction  <log.json> <retraction_entry_hash>
#       checks map-1 §3 coherence of an anchor-log retraction against its target.
#
# Exit status: 0 = VERIFIED/REPORT, 1 = REJECTED, 2 = usage / unresolvable.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/entry'
require_relative '../lib/synoptis/anchoring/chain_credential'
require_relative '../lib/synoptis/anchoring/succession'
require_relative '../lib/synoptis/anchoring/anchoring_rule'
require_relative '../lib/synoptis/anchoring/attestation_types'

ENTRY = Synoptis::Anchoring::Entry
CRED = Synoptis::Anchoring::ChainCredential
SUCC = Synoptis::Anchoring::Succession
RULE = Synoptis::Anchoring::AnchoringRule
ATYPE = Synoptis::Anchoring::AttestationTypes

def die(msg)
  warn "map_verify: #{msg}"
  exit 2
end

def reject(msg)
  puts "REJECTED: #{msg}"
  exit 1
end

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError, SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

# Malformed caller input is unresolvable (exit 2), never a verdict.
# Explicit base 10: Integer('010') would read octal and silently shift a
# governance boundary.
def strict_int(value, label)
  # Digits only: Integer() would also accept '1_0' and padded whitespace.
  die "#{label} must be a base-10 integer, got #{value.inspect}" unless value.is_a?(String) && value.match?(/\A\d+\z/)
  Integer(value, 10)
end

def load_json_hash(path, label)
  parsed = load_json(path)
  die "#{path}: #{label} must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)
  parsed
end

HEX64 = /\A[a-f0-9]{64}\z/

# Structural well-formedness of a matched head binding (khab-1 §4 shapes).
# The strongest claim this tool prints must be unreachable from malformed
# input: a garbage binding is unresolvable, never PAIR ESTABLISHED.
def require_binding_wellformed!(binding, where)
  die "#{where}: head_binding.convention is #{binding['convention'].inspect}, not khab-1" unless binding['convention'] == 'khab-1'
  %w[convention_sha256 cumulative_root].each do |k|
    die "#{where}: head_binding.#{k} missing or not 64-char lowercase hex" unless binding[k].is_a?(String) && binding[k].match?(HEX64)
  end
  die "#{where}: head_binding.tree_size must be a positive Integer" unless binding['tree_size'].is_a?(Integer) && binding['tree_size'].positive?
  unless binding['chain_identity'].is_a?(String) && binding['chain_identity'].match?(/\Ablock1-sha256:[a-f0-9]{64}\z/)
    die "#{where}: head_binding.chain_identity is not block1-sha256:<64-hex> (khab-1 §5)"
  end
end

# Recompute an entry's committed hash from its canonical content. Detects an
# in-place edited entry without any chain access; the full log hash chain is
# the khab-1 surface's business (khab_verify / public verifier).
def require_entry_hash!(entry_h, where)
  content = { 'position' => entry_h['position'], 'prev' => entry_h['prev'],
              'kind' => entry_h['kind'], 'body' => entry_h['body'] }
  recomputed = ENTRY.compute_hash(content)
  return if recomputed == entry_h['entry_hash']

  reject "#{where}: entry_hash does not recompute from committed content (edited in place?)"
end

mode = ARGV.shift

case mode
when 'credential'
  die 'usage: map_verify.rb credential <credential.json>' unless ARGV.size == 1
  cred = load_json_hash(ARGV[0], 'credential')
  begin
    CRED.validate!(cred)
  rescue CRED::CredentialError => e
    reject e.message
  end
  puts "VERIFIED: credential digest #{CRED.credential_digest(cred)} binds #{cred['chain_identity']}"
  puts 'NOTE: binding is a SELF-attestation (map-1 §1); that the credential speaks'
  puts 'for the chain requires the chain to commit the credential digest (map-1 §2).'

when 'attestation'
  die 'usage: map_verify.rb attestation <credential.json> <payload-file> <signature-hex>' unless ARGV.size == 3
  cred = load_json_hash(ARGV[0], 'credential')
  payload = begin
    File.binread(ARGV[1])
  rescue SystemCallError => e
    die "cannot read #{ARGV[1]}: #{e.message}"
  end
  begin
    ok = CRED.verify_attestation(cred, payload, ARGV[2])
  rescue CRED::CredentialError => e
    reject e.message
  end
  reject 'attestation signature does not verify under the credential' unless ok
  puts "VERIFIED: attestation signature valid under credential #{CRED.credential_digest(cred)[0, 12]}…"

when 'succession'
  die 'usage: map_verify.rb succession <old_credential.json> <records.json> [changeover_position]' unless (2..3).cover?(ARGV.size)
  cred = load_json_hash(ARGV[0], 'credential')
  records = load_json(ARGV[1])
  unless records.is_a?(Array) && records.all? { |r| r.is_a?(String) }
    die "#{ARGV[1]}: expected a JSON array of record STRINGS (each element the exact committed record string)"
  end
  changeover = ARGV[2].nil? ? nil : strict_int(ARGV[2], 'changeover_position')
  die 'changeover_position must be non-negative' if !changeover.nil? && changeover.negative?
  begin
    verdict = SUCC.governance(cred, records, changeover_position: changeover)
  rescue CRED::CredentialError => e
    reject e.message
  end
  puts JSON.pretty_generate(verdict)
  puts 'NOTE: the verdict reports what the records show, never intent (key'
  puts 'compromise is indistinguishable from the issuer — MAP-2 disclosed limit).'

when 'coverage'
  unless (2..6).cover?(ARGV.size)
    die 'usage: map_verify.rb coverage <rule-file> <anchors.json> [chain_extent] [rule_position] [rule_moment] [now]'
  end
  rule_string = begin
    File.read(ARGV[0]).strip
  rescue SystemCallError => e
    die "cannot read #{ARGV[0]}: #{e.message}"
  end
  rule = begin
    RULE.parse!(rule_string)
  rescue RULE::RuleError => e
    reject e.message
  end
  anchors = load_json(ARGV[1])
  die "#{ARGV[1]}: expected a JSON array of observations" unless anchors.is_a?(Array)
  extent = ARGV[2].nil? ? nil : strict_int(ARGV[2], 'chain_extent')
  rule_pos = ARGV[3].nil? ? nil : strict_int(ARGV[3], 'rule_position')
  rule_moment = ARGV[4]
  now = ARGV[5]
  # A tool capability gap is a usage error (exit 2), never a REJECTED verdict.
  if rule['trigger'] == 'every_n_records' && extent.nil?
    die 'every_n_records coverage needs chain_extent'
  end
  if rule['trigger'] == 'every_n_days' && (rule_moment.nil? || now.nil?)
    die 'every_n_days coverage needs rule_moment and now (ISO8601), as arguments 5 and 6'
  end
  begin
    report = RULE.coverage(rule_string, anchors, chain_extent: extent, rule_position: rule_pos,
                                                 rule_moment: rule_moment, now: now)
  rescue RULE::RuleError => e
    reject e.message
  end
  puts JSON.pretty_generate(report)

when 'pair'
  die 'usage: map_verify.rb pair <log_a.json> <identity_a> <log_b.json> <identity_b>' unless ARGV.size == 4
  log_a, id_a, log_b, id_b = load_json(ARGV[0]), ARGV[1], load_json(ARGV[2]), ARGV[3]
  [[log_a, ARGV[0]], [log_b, ARGV[2]]].each do |(log, path)|
    die "#{path}: expected a JSON array of anchor-entry objects" unless log.is_a?(Array)
  end
  find = lambda do |log, identity, where|
    log.each_with_index.filter_map do |entry, i|
      e = entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : {}
      # Only anchor entries carry head bindings; anything else shaped to look
      # like one never counts toward a pair.
      next unless e['kind'] == 'anchor'

      body = e['body'].is_a?(Hash) ? e['body'] : {}
      hb = body['head_binding']
      next unless hb.is_a?(Hash) && hb['chain_identity'] == identity

      require_binding_wellformed!(hb, "#{where} entry #{e['position'] || i}")
      require_entry_hash!(e, "#{where} entry #{e['position'] || i}")
      { position: e['position'] || i, cumulative_root: hb['cumulative_root'],
        tree_size: hb['tree_size'], attestation_type: body['attestation_type'] }
    end
  end
  a_holds_b = find.call(log_a, id_b, ARGV[0])
  b_holds_a = find.call(log_b, id_a, ARGV[2])
  reject "no entry in #{ARGV[0]} commits a head binding of #{id_b}" if a_holds_b.empty?
  reject "no entry in #{ARGV[2]} commits a head binding of #{id_a}" if b_holds_a.empty?
  puts 'PAIR ESTABLISHED (MAP-1 — exactly this, nothing stronger):'
  puts "  #{id_b} head(s) committed in log A at #{a_holds_b.map { |e| e[:position] }.join(', ')}"
  puts "  #{id_a} head(s) committed in log B at #{b_holds_a.map { |e| e[:position] }.join(', ')}"
  untyped = (a_holds_b + b_holds_a).count { |e| e[:attestation_type].nil? }
  puts "  untyped (pre-map-1, grandfathered) inscriptions: #{untyped}" if untyped.positive?
  puts 'CONDITIONS (travel with every stronger reading, map-1 §6):'
  puts '  - partner independence is auditor-supplied; a common operator can fabricate the pair'
  puts '  - temporal weight reaches only as far as each log\'s own khab-1 anchoring'
  puts '  - equivocation detection requires authentic views of BOTH logs and cross-comparison'
  puts '  - matched entry hashes recomputed and binding shapes checked here; full log hash-chain'
  puts '    and cumulative-root verification are the khab-1 surface\'s business (khab_verify)'
  puts '  - this pair supplies split-view detection material; it closes nothing'

when 'retraction'
  die 'usage: map_verify.rb retraction <log.json> <retraction_entry_hash>' unless ARGV.size == 2
  log = load_json(ARGV[0])
  die "#{ARGV[0]}: expected a JSON array of anchor-entry objects" unless log.is_a?(Array)
  entries = log.map { |e| e.is_a?(Hash) ? e.transform_keys(&:to_s) : {} }
  retraction = entries.find { |e| e['entry_hash'] == ARGV[1] }
  die "no entry with entry_hash #{ARGV[1]} in #{ARGV[0]}" if retraction.nil?
  body = retraction['body'].is_a?(Hash) ? retraction['body'] : {}
  meta = body['metadata'].is_a?(Hash) ? body['metadata'] : {}
  target_ref = meta['target_entry_hash']
  unless target_ref.is_a?(String) && target_ref.match?(HEX64)
    reject "retraction carries no resolvable metadata.target_entry_hash (got #{target_ref.inspect})"
  end
  target = entries.find { |e| e['entry_hash'] == target_ref }
  reject "target entry #{target_ref} not present in the supplied log view" if target.nil?
  require_entry_hash!(retraction, 'retraction')
  require_entry_hash!(target, 'target')
  verdict = ATYPE.retraction_coherence(retraction, target)
  puts JSON.pretty_generate(verdict)
  exit(verdict[:coherent] ? 0 : 1)

else
  die 'usage: map_verify.rb credential|attestation|succession|coverage|pair|retraction ... (see header)'
end
