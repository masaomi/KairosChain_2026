#!/usr/bin/env ruby
# frozen_string_literal: true

# rpr_verify — offline auditor verifier for rpr-1 reproduction-endorsement
# artifacts (RPR-1..5, aud_l3_reproducibility_design v0.4).
#
# Verifies with EXACTLY the disclosed trust base: the artifacts named on the
# command line plus the shipped rpr-1 and map-1 convention definitions. No
# registry, no network, no operator cooperation. (Authentic chain views are
# the caller's inputs; their integrity is the khab-1/map-1 surfaces' business.)
#
# Usage:
#   rpr_verify.rb target      <target.json>
#   rpr_verify.rb tolerance   <tolerance.json> [target.json]
#       with target.json: additionally checks the binding matches that target.
#   rpr_verify.rb endorsement <endorsement.json> <endorser_credential.json> <signature-hex> [operator_credential.json]
#       with operator credential: additionally checks foreignness (RPR-4).
#   rpr_verify.rb assess      <targets.json> <declarations.json> <invoked_tolerance_sha256> <endorsement_position>
#       targets.json      = JSON array of target record STRINGS
#       declarations.json = JSON array of {"tolerance": "<record string>", "position": <int>}
#   rpr_verify.rb convention
#       prints the shipped rpr-1 convention digest.
#
# Exit status: 0 = VERIFIED/REPORT, 1 = REJECTED, 2 = usage / unresolvable.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/entry'
require_relative '../lib/synoptis/anchoring/chain_credential'
require_relative '../lib/synoptis/anchoring/reproduction'

CRED = Synoptis::Anchoring::ChainCredential
REPRO = Synoptis::Anchoring::Reproduction

def die(msg)
  warn "rpr_verify: #{msg}"
  exit 2
end

def reject(msg)
  puts "REJECTED: #{msg}"
  exit 1
end

# Read a record artifact: at most one trailing newline is tolerated (file
# convenience); any other surrounding bytes stay in the string and fail the
# canonical check downstream (refuse-not-coerce — a padded artifact is not
# the canonical record).
def read_file(path)
  # delete_suffix, not chomp: chomp("\n") also swallows "\r\n" and a bare
  # trailing "\r", which would coerce CRLF artifacts into canonical form.
  File.read(path).delete_suffix("\n")
rescue SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError, SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def load_json_hash(path, label)
  parsed = load_json(path)
  die "#{path}: #{label} must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)
  parsed
end

# Canonical base-10 numerals only: leading zeros are refused, not
# reinterpreted (a non-canonical numeral is a malformed input, exit 2).
def strict_int(value, label)
  die "#{label} must be a canonical base-10 integer, got #{value.inspect}" unless value.is_a?(String) && value.match?(/\A(0|[1-9]\d*)\z/)
  Integer(value, 10)
end

HEX64 = /\A[a-f0-9]{64}\z/

mode = ARGV.shift

case mode
when 'target'
  die 'usage: rpr_verify.rb target <target.json>' unless ARGV.size == 1
  record = read_file(ARGV[0])
  begin
    REPRO.parse_target!(record)
  rescue REPRO::ReproductionError => e
    reject e.message
  end
  puts "VERIFIED: target digest #{REPRO.target_digest(record)}"
  puts "  computation identification: #{REPRO.computation_id(record).split('|').map { |h| h[0, 12] }.join('… | ')}… (output excluded, rpr-1 §1)"
  puts 'NOTE: binding fixes referents, never validates them (RPR-2, MPR-4).'

when 'tolerance'
  die 'usage: rpr_verify.rb tolerance <tolerance.json> [target.json]' unless (1..2).cover?(ARGV.size)
  record = read_file(ARGV[0])
  tol = begin
    REPRO.parse_tolerance!(record)
  rescue REPRO::ReproductionError => e
    reject e.message
  end
  if ARGV[1]
    target = read_file(ARGV[1])
    begin
      digest = REPRO.target_digest(target)
    rescue REPRO::ReproductionError => e
      reject e.message
    end
    reject "tolerance binds target #{tol['target_sha256'][0, 12]}…, not the supplied target #{digest[0, 12]}…" unless tol['target_sha256'] == digest
  end
  puts "VERIFIED: tolerance digest #{Digest::SHA256.hexdigest(record)} (kind #{tol['kind']}, target #{tol['target_sha256'][0, 12]}…)"
  puts 'NOTE: anteriority to any endorsement is decided by committed order (MPR-8), not by this tool.'

when 'endorsement'
  die 'usage: rpr_verify.rb endorsement <endorsement.json> <endorser_credential.json> <signature-hex> [operator_credential.json]' unless (3..4).cover?(ARGV.size)
  record = read_file(ARGV[0])
  cred = load_json_hash(ARGV[1], 'endorser credential')
  ok = begin
    REPRO.verify_endorsement(record, cred, ARGV[2])
  rescue REPRO::ReproductionError, CRED::CredentialError => e
    reject e.message
  end
  reject 'endorsement signature does not verify under the endorser credential' unless ok
  e = REPRO.parse_endorsement!(record)
  if ARGV[3]
    operator = load_json_hash(ARGV[3], 'operator credential')
    begin
      reject 'endorser credential equals operator credential — same-party, not a conforming rpr-1 endorsement (RPR-4)' unless REPRO.foreign?(cred, operator)
    rescue CRED::CredentialError => err
      # An unresolvable operator credential is a caller-input problem, not a
      # verdict about the endorsement (exit-code discipline: 2, not 1).
      die "operator credential unresolvable: #{err.message}"
    end
  end
  puts "VERIFIED: #{e['verdict']} endorsement of target #{e['target_sha256'][0, 12]}… under tolerance #{e['tolerance_sha256'][0, 12]}…"
  puts "  adjudication mode: #{e['adjudication_mode']}#{e['procedure_sha256'] ? " (procedure #{e['procedure_sha256'][0, 12]}…)" : ''}"
  puts 'CONDITIONS (travel with every stronger reading, rpr-1 §3):'
  puts '  - the verdict asserts reproduction or its failure, never correctness (RPR-1, MPR-6)'
  puts '  - evidence of a committed claim, never proof a re-execution happened (RPR-4)'
  puts '  - distinctness is not independence; a colluding pair can fabricate (RPR-4)'
  puts '  - the named mode is a declaration, not a proof (map-1 §3 non-self-certifying)'
  if ARGV[3]
    puts '  - foreignness checked against the SUPPLIED operator credential only'
  else
    puts '  - foreignness (RPR-4 conformance condition) NOT assessed — no operator credential supplied'
  end

when 'assess'
  die 'usage: rpr_verify.rb assess <targets.json> <declarations.json> <invoked_tolerance_sha256> <endorsement_position>' unless ARGV.size == 4
  targets = load_json(ARGV[0])
  die "#{ARGV[0]}: expected a JSON array of target record strings" unless targets.is_a?(Array) && targets.all? { |t| t.is_a?(String) }
  declarations = load_json(ARGV[1])
  die "#{ARGV[1]}: expected a JSON array of {tolerance, position} objects" unless declarations.is_a?(Array)
  invoked = ARGV[2]
  die 'invoked_tolerance_sha256 must be 64-char lowercase hex' unless invoked.match?(HEX64)
  position = strict_int(ARGV[3], 'endorsement_position')
  begin
    report = REPRO.assess_declarations(targets: targets, declarations: declarations,
                                       invoked_tolerance_sha256: invoked, endorsement_position: position)
  rescue REPRO::ReproductionError => e
    reject e.message
  end
  puts JSON.pretty_generate(report)
  puts 'NOTE: the assessment reports, the reader prices (RPR-3: exposure, not prevention).'
  puts 'NOTE: a produced report always exits 0; the conformance bit is invoked_conforming in the report.'

when 'convention'
  puts "rpr-1 convention sha256: #{REPRO.convention_sha256}"

else
  die 'usage: rpr_verify.rb target|tolerance|endorsement|assess|convention ... (see header)'
end
