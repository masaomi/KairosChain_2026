#!/usr/bin/env ruby
# frozen_string_literal: true

# sda_verify — offline verifier for the AUD-L4 ZK aggregate reproducibility
# SPIKE, Phase 1 (Pedersen commitments + aggregate opening + SDP-2 score
# binding). aud_l4_zk_aggregate_reproducibility_spike_design v0.1.
#
# This is a SPIKE demonstrator, not a promoted convention. Phase 1 covers the
# commitment arithmetic only; the genuine zero-knowledge range proof is Phase 2
# and is NOT verified here. Everything is computed with the disclosed base
# (SDP-5): pure-Ruby secp256k1 (no runtime dependency beyond sha256/stdlib),
# H derived nothing-up-my-sleeve from a public seed.
#
# Usage:
#   sda_verify.rb generators
#       prints G, H, and H's derivation seed (the disclosed computational base).
#   sda_verify.rb commit <score> <blinding_hex>
#       prints the Pedersen commitment of an in-band score (0..7). The blinding
#       is secret; supply it as lowercase hex.
#   sda_verify.rb aggregate-verify <commitments.json> <sum_s> <sum_r>
#       checks the plain aggregate opening and reports the mean band/percent.
#       commitments.json = ["<compressed point hex>", ...].
#   sda_verify.rb aggregate-schnorr <commitments.json> <sum_s> <proof.json>
#       checks the Σr-hiding Schnorr aggregate proof for the published Σs.
#   sda_verify.rb binding <score_record.json> <aux.json> <salts.json> <score> <blinding_hex> <commitment_hex>
#       checks the SDP-2 binding: the sdp-1 score digest and the Pedersen
#       commitment commit the same in-band integer.
#   sda_verify.rb doi-set <dois.json>
#       prints the DOI-set commitment (fix this BEFORE scoring; anchor via khab-1).
#
# Exit status: 0 = VERIFIED/REPORT, 1 = REJECTED, 2 = usage / unresolvable.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/entry'
require_relative '../lib/synoptis/anchoring/selective_disclosure'
require_relative '../lib/synoptis/anchoring/ec_group'
require_relative '../lib/synoptis/anchoring/pedersen'
require_relative '../lib/synoptis/anchoring/aggregate_disclosure'

EC = Synoptis::Anchoring::EcGroup
Ped = Synoptis::Anchoring::Pedersen
Agg = Synoptis::Anchoring::AggregateDisclosure

def die(msg)
  warn "sda_verify: #{msg}"
  exit 2
end

def reject(msg)
  puts "REJECTED: #{msg}"
  exit 1
end

def read_file(path)
  File.read(path).delete_suffix("\n")
rescue SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def load_json(path, label)
  JSON.parse(File.read(path))
rescue JSON::ParserError, SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def strict_int(value, label)
  die "#{label} must be a canonical base-10 integer, got #{value.inspect}" unless value.is_a?(String) && value.match?(/\A(0|[1-9]\d*)\z/)
  Integer(value, 10)
end

def hex_scalar(value, label)
  die "#{label} must be lowercase-hex, got #{value.inspect}" unless value.is_a?(String) && value.match?(/\A[a-f0-9]+\z/)
  Integer(value, 16)
end

mode = ARGV.shift

case mode
when 'generators'
  puts "curve:  secp256k1 (pure-Ruby; OpenSSL is a test oracle only, not a runtime dependency — SDP-5)"
  puts "G:      #{EC.encode(EC.g)}"
  puts "H:      #{EC.encode(EC.h)}"
  puts "H_seed: #{EC::H_SEED}"
  puts 'NOTE: H is derived nothing-up-my-sleeve so log_G(H) is unknown (Pedersen binding requirement).'

when 'commit'
  die 'usage: sda_verify.rb commit <score> <blinding_hex>' unless ARGV.size == 2
  score = strict_int(ARGV[0], 'score')
  blinding = hex_scalar(ARGV[1], 'blinding')
  point = begin
    Ped.commit(score, blinding)
  rescue Ped::CommitmentError => e
    reject e.message
  end
  puts "commitment: #{EC.encode(point)}"
  warn 'NOTE: keep the blinding secret; it plus the score opens this commitment (Pedersen hiding).'

when 'aggregate-verify'
  die 'usage: sda_verify.rb aggregate-verify <commitments.json> <sum_s> <sum_r>' unless ARGV.size == 3
  commitments = load_json(ARGV[0], 'commitments')
  die 'commitments must be a JSON array of compressed points' unless commitments.is_a?(Array)
  sum_s = strict_int(ARGV[1], 'sum_s')
  sum_r = strict_int(ARGV[2], 'sum_r')
  report = begin
    Agg.verify_mean(commitments: commitments, sum_s: sum_s, sum_r: sum_r)
  rescue Agg::AggregateError, EC::GroupError => e
    reject e.message
  end
  reject 'aggregate opening does not reconstruct the published aggregate' unless report[:valid]
  puts "VERIFIED: aggregate opens over #{report[:count]} commitment(s)"
  puts "  mean band:    #{report[:mean_band]} / #{report[:vmax]}"
  puts "  mean percent: #{report[:mean_percent].to_f.round(2)}%"
  report[:notes].each { |n| puts "  NOTE: #{n}" }

when 'aggregate-schnorr'
  die 'usage: sda_verify.rb aggregate-schnorr <commitments.json> <sum_s> <proof.json>' unless ARGV.size == 3
  commitments = load_json(ARGV[0], 'commitments')
  die 'commitments must be a JSON array of compressed points' unless commitments.is_a?(Array)
  sum_s = strict_int(ARGV[1], 'sum_s')
  proof = load_json(ARGV[2], 'proof')
  ok = begin
    agg = Agg.aggregate(commitments)
    Ped.verify_aggregate_randomness(EC.decode(agg), sum_s, proof)
  rescue Ped::CommitmentError, Agg::AggregateError, EC::GroupError => e
    reject e.message
  end
  reject 'Schnorr aggregate-randomness proof does not verify for the published Σs' unless ok
  puts "VERIFIED: Σr-hiding Schnorr proof holds for Σs=#{sum_s} (individual scores and Σr stay hidden)"

when 'binding'
  die 'usage: sda_verify.rb binding <score_record.json> <aux.json> <salts.json> <score> <blinding_hex> <commitment_hex>' unless ARGV.size == 6
  record = read_file(ARGV[0])
  aux = read_file(ARGV[1])
  salts = load_json(ARGV[2], 'salts')
  die 'salts must be a JSON object' unless salts.is_a?(Hash)
  score = strict_int(ARGV[3], 'score')
  blinding = hex_scalar(ARGV[4], 'blinding')
  commitment = ARGV[5].to_s
  ok = begin
    Agg.verify_binding(record_string: record, aux_string: aux, salts: salts,
                       score: score, blinding: blinding, commitment: commitment)
  rescue Agg::AggregateError, Synoptis::Anchoring::SelectiveDisclosure::DisclosureError, EC::GroupError, Ped::CommitmentError => e
    reject e.message
  end
  reject 'commitment is NOT bound to the score record (SDP-2: a desynced commitment is a re-authoring)' unless ok
  puts "VERIFIED: sdp-1 score digest and the Pedersen commitment commit the same in-band integer (SDP-2 binding)"

when 'doi-set'
  die 'usage: sda_verify.rb doi-set <dois.json>' unless ARGV.size == 1
  dois = load_json(ARGV[0], 'dois')
  die 'dois must be a JSON array of strings' unless dois.is_a?(Array)
  digest = begin
    Agg.doi_set_commitment(dois)
  rescue Agg::AggregateError => e
    reject e.message
  end
  puts "doi-set commitment: #{digest}"
  puts 'NOTE: fix this before any score exists and anchor it (khab-1); it forbids post-hoc DOI substitution.'

else
  die 'usage: sda_verify.rb generators|commit|aggregate-verify|aggregate-schnorr|binding|doi-set …'
end
