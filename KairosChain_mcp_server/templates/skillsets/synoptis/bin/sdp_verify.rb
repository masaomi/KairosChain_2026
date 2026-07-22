#!/usr/bin/env ruby
# frozen_string_literal: true

# sdp_verify — offline verifier for sdp-1 selective-disclosure artifacts
# (SDP-1..5, aud_l4_selective_disclosure_design v0.3).
#
# Verifies with EXACTLY the disclosed trust base: the artifacts named on the
# command line plus the shipped sdp-1, rpr-1, and map-1 convention
# definitions. No registry, no network, no producer cooperation. (Authentic
# chain/log views are the caller's inputs; their integrity is the
# khab-1/map-1 surfaces' business.)
#
# Usage:
#   sdp_verify.rb commit  <record.json> [salts.json]
#       builds the sdp-1 field-commitments auxiliary for a canonical record;
#       prints the auxiliary record and (fresh or supplied) salts as JSON.
#   sdp_verify.rb binding <aux.json> <record.json> <salts.json>
#       checks the SDP-2 binding: every field digest and the record digest
#       recompute from record + salts.
#   sdp_verify.rb presentation <presentation.json> [operator_credential.json] [assessment.json]
#       verifies a presentation. conforming-verdict REQUIRES both extras;
#       assessment.json = {"targets":[...record strings...],
#                          "declarations":[{"tolerance":"...","position":N}...],
#                          "endorsement_position":N}.
#   sdp_verify.rb profile <presentation.json>
#       prints the disclosure profile and what it does/does not show.
#   sdp_verify.rb currency <entries.json> <carrier_entry_hash> <extent>
#       runs the sdp-1 §5 retraction scan over a supplied entry view.
#   sdp_verify.rb convention
#       prints the shipped sdp-1 convention digest.
#
# Exit status: 0 = VERIFIED/REPORT, 1 = REJECTED, 2 = usage / unresolvable.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/entry'
require_relative '../lib/synoptis/anchoring/chain_credential'
require_relative '../lib/synoptis/anchoring/reproduction'
require_relative '../lib/synoptis/anchoring/selective_disclosure'

SD = Synoptis::Anchoring::SelectiveDisclosure
CRED = Synoptis::Anchoring::ChainCredential

def die(msg)
  warn "sdp_verify: #{msg}"
  exit 2
end

def reject(msg)
  puts "REJECTED: #{msg}"
  exit 1
end

# Read a record artifact: at most one trailing newline is tolerated (file
# convenience); any other surrounding bytes stay in the string and fail the
# canonical check downstream (refuse-not-coerce). delete_suffix, not chomp:
# chomp also swallows CRLF, which would coerce a non-canonical artifact.
def read_file(path)
  File.read(path).delete_suffix("\n")
rescue SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def load_json(path, label)
  parsed = JSON.parse(File.read(path))
  die "#{path}: #{label} must be a JSON object or array, got #{parsed.class}" unless parsed.is_a?(Hash) || parsed.is_a?(Array)
  parsed
rescue JSON::ParserError, SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def load_json_hash(path, label)
  parsed = load_json(path, label)
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
when 'commit'
  die 'usage: sdp_verify.rb commit <record.json> [salts.json]' unless (1..2).cover?(ARGV.size)
  record = read_file(ARGV[0])
  salts = ARGV[1] ? load_json_hash(ARGV[1], 'salts') : nil
  built = begin
    SD.build_field_commitments(record, salts: salts)
  rescue SD::DisclosureError => e
    reject e.message
  end
  puts JSON.pretty_generate(built)
  warn 'NOTE: keep the salts private; each opened salt discloses exactly its field (sdp-1 §6).'

when 'binding'
  die 'usage: sdp_verify.rb binding <aux.json> <record.json> <salts.json>' unless ARGV.size == 3
  aux = read_file(ARGV[0])
  record = read_file(ARGV[1])
  salts = load_json_hash(ARGV[2], 'salts')
  ok = begin
    SD.verify_field_commitments(aux, record, salts)
  rescue SD::DisclosureError => e
    reject e.message
  end
  reject 'auxiliary is NOT checkably bound to the record (SDP-2: a bound-by-assertion auxiliary is a re-authoring)' unless ok
  puts "VERIFIED: auxiliary is checkably bound to record #{Digest::SHA256.hexdigest(record)[0, 12]}… (total coverage, SDP-2)"

when 'presentation'
  die 'usage: sdp_verify.rb presentation <presentation.json> [operator_credential.json] [assessment.json]' unless (1..3).cover?(ARGV.size)
  pres = read_file(ARGV[0])
  operator = ARGV[1] ? load_json_hash(ARGV[1], 'operator credential') : nil
  assessment = ARGV[2] ? load_json_hash(ARGV[2], 'assessment material') : nil
  report = begin
    SD.verify_presentation(pres, operator_credential: operator, assessment: assessment)
  rescue SD::DisclosureError, CRED::CredentialError => e
    reject e.message
  end
  unless report[:valid]
    puts "REJECTED: presentation does not verify (predicate #{report[:predicate]})"
    report[:failures].each { |f| puts "  - #{f}" }
    exit 1
  end
  puts "VERIFIED: #{report[:predicate]} over committed record #{report[:record_sha256][0, 12]}…"
  report[:opened].each { |n, v| puts "  opened #{n} = #{v.inspect}" }
  report[:notes].each { |n| puts "  NOTE: #{n}" }
  puts 'NOTE: soundness = sha256 collision resistance + Ed25519, no setup; hiding is computational, content-only (SDP-5, sdp-1 §6).'

when 'profile'
  die 'usage: sdp_verify.rb profile <presentation.json>' unless ARGV.size == 1
  pres = read_file(ARGV[0])
  p = begin
    SD.parse_presentation!(pres)
  rescue SD::DisclosureError => e
    reject e.message
  end
  profile = p['profile']
  puts "profile (meaning fixed by sdp-1 §2, never producer gloss — SDP-4):"
  puts "  predicate: #{profile['predicate']}"
  puts "  opened:    #{profile['opened'].join(', ')}"
  puts "  withheld:  every other field of the referenced record (values only; names and count are public)"
  puts "  currency:  #{profile['currency']}"
  puts '  shows:     existence and the opened values of ONE committed record'
  puts '  never:     non-existence, uniqueness, sibling records, contrary verdicts, producer selection (SDP-3)'

when 'currency'
  die 'usage: sdp_verify.rb currency <entries.json> <carrier_entry_hash> <extent>' unless ARGV.size == 3
  entries = load_json(ARGV[0], 'entries')
  die "#{ARGV[0]}: entries must be a JSON array" unless entries.is_a?(Array)
  carrier = ARGV[1].to_s
  die 'carrier_entry_hash must be 64-char lowercase hex' unless carrier.match?(HEX64)
  extent = strict_int(ARGV[2], 'extent')
  scan = begin
    SD.scan_currency(entries: entries, carrier_entry_hash: carrier, extent: extent)
  rescue SD::DisclosureError => e
    reject e.message
  end
  puts "REPORT: #{scan[:status]} (scanned extent #{scan[:scanned_extent]})"
  puts "  hits (positions): #{scan[:hits].join(', ')}" if scan[:hits]&.any?
  puts "  NOTE: #{scan[:note]}"
  exit(scan[:status] == 'retracted' ? 1 : 0)

when 'convention'
  puts "sdp-1 convention sha256: #{SD.convention_sha256}"

else
  die 'usage: sdp_verify.rb commit|binding|presentation|profile|currency|convention …'
end
