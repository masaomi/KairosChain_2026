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
#   sda_verify.rb range-verify <commitment_hex> <range_proof.json>
#       verifies one score's zero-knowledge range proof (s in [0,7]) against its
#       Pedersen commitment (aud_l4_zk_range_proof_design v0.3, Phase 2).
#   sda_verify.rb full-audit-verify <bundle.json>
#       the whole audit in one pass: C1 coverage (sdp-1 presentations), C3
#       aggregate (verify_mean), C4 every per-score range proof.
#       bundle.json = {"doi_set_commitment": hex, "aggregate": {"sum_s": "N",
#       "sum_r": "N"}, "items": [{"commitment": enc, "range_proof": {...},
#       "presentation": {...}} ...]} (presentation optional per item; its
#       absence fails C1 for that item, reported not raised).
#
# Exit status: 0 = VERIFIED/REPORT, 1 = REJECTED, 2 = usage / unresolvable.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/entry'
require_relative '../lib/synoptis/anchoring/selective_disclosure'
require_relative '../lib/synoptis/anchoring/ec_group'
require_relative '../lib/synoptis/anchoring/pedersen'
require_relative '../lib/synoptis/anchoring/aggregate_disclosure'
require_relative '../lib/synoptis/anchoring/range_proof'

EC = Synoptis::Anchoring::EcGroup
Ped = Synoptis::Anchoring::Pedersen
Agg = Synoptis::Anchoring::AggregateDisclosure
RP = Synoptis::Anchoring::RangeProof
SD = Synoptis::Anchoring::SelectiveDisclosure

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

when 'range-verify'
  die 'usage: sda_verify.rb range-verify <commitment_hex> <range_proof.json>' unless ARGV.size == 2
  commitment = ARGV[0].to_s
  proof = read_file(ARGV[1])
  ok = begin
    RP.verify_range(commitment, proof)
  rescue RP::RangeError => e
    reject e.message
  end
  reject 'range proof does not verify (reconstruction or a per-bit OR equation failed)' unless ok
  puts "VERIFIED: commitment #{commitment[0, 12]}… commits a score in [0, #{RP::VMAX}] — proven in zero knowledge (value not revealed)"
  puts 'NOTE: soundness = discrete log (secp256k1) + CDS Sigma OR special-soundness + Fiat-Shamir (SHA-256 as RO); no trusted setup (SDP-5).'
  puts 'NOTE: the proof shows the committed score is in-band, NOT that it is the true re-execution result (RPR-4/MPR-6 residue).'

when 'full-audit-verify'
  die 'usage: sda_verify.rb full-audit-verify <bundle.json>' unless ARGV.size == 1
  bundle = load_json(ARGV[0], 'bundle')
  die 'bundle must be a JSON object' unless bundle.is_a?(Hash)
  b = bundle.transform_keys(&:to_s)
  items = b['items']
  agg_open = b['aggregate'].is_a?(Hash) ? b['aggregate'].transform_keys(&:to_s) : nil
  die 'bundle.items must be a non-empty array' unless items.is_a?(Array) && !items.empty?
  die 'bundle.aggregate must be {sum_s, sum_r}' unless agg_open && agg_open['sum_s'] && agg_open['sum_r']

  sum_s = strict_int(agg_open['sum_s'].to_s, 'aggregate.sum_s')
  sum_r = strict_int(agg_open['sum_r'].to_s, 'aggregate.sum_r')
  views = items.map { |it| it.is_a?(Hash) ? it.transform_keys(&:to_s) : {} }
  commitments = views.map { |it| it['commitment'].to_s }

  # C1 — coverage: every item carries a verifying sdp-1 presentation.
  c1_failures = []
  views.each_with_index do |it, i|
    if it['presentation'].is_a?(Hash)
      begin
        report = SD.verify_presentation(Synoptis::Anchoring::Entry.canonical_json(it['presentation']))
        c1_failures << "item #{i}: presentation does not verify (#{report[:failures].first})" unless report[:valid]
      rescue SD::DisclosureError, Synoptis::Anchoring::ChainCredential::CredentialError => e
        c1_failures << "item #{i}: presentation unresolvable: #{e.message}"
      end
    else
      c1_failures << "item #{i}: no endorsement presentation (coverage unestablished)"
    end
  end

  # C3 — aggregate: the published mean opens over the committed scores.
  c3_report = begin
    Agg.verify_mean(commitments: commitments, sum_s: sum_s, sum_r: sum_r)
  rescue Agg::AggregateError, EC::GroupError => e
    reject "aggregate unresolvable: #{e.message}"
  end

  # C4 — every per-score range proof verifies against its commitment.
  c4_failures = []
  views.each_with_index do |it, i|
    unless it['range_proof'].is_a?(Hash)
      c4_failures << "item #{i}: no range proof"
      next
    end
    begin
      ok = RP.verify_range(it['commitment'].to_s, Synoptis::Anchoring::Entry.canonical_json(it['range_proof']))
      c4_failures << "item #{i}: range proof fails (reconstruction or OR equation)" unless ok
    rescue RP::RangeError => e
      c4_failures << "item #{i}: range proof inadmissible: #{e.message}"
    end
  end

  c1 = c1_failures.empty?
  c3 = c3_report[:valid]
  c4 = c4_failures.empty?
  puts "C1 coverage:  #{c1 ? 'PASS' : 'FAIL'} (#{items.size} item(s))"
  c1_failures.each { |f| puts "  - #{f}" }
  puts "C3 aggregate: #{c3 ? 'PASS' : 'FAIL'}#{c3 ? " — mean #{c3_report[:mean_band].to_f.round(3)} of #{c3_report[:vmax]} (#{c3_report[:mean_percent].to_f.round(2)}%)" : ''}"
  puts "C4 range:     #{c4 ? "PASS (every score proven in [0, #{RP::VMAX}] without disclosure)" : 'FAIL'}"
  c4_failures.each { |f| puts "  - #{f}" }
  puts "doi_set_commitment: #{b['doi_set_commitment']}" if b['doi_set_commitment']
  puts 'NOTE: the aggregate is honest relative to the committed scores; that each score is the true re-execution result is NOT proven (RPR-4/MPR-6 residue).'
  puts 'NOTE: commit the DOI set (khab-1) BEFORE any score exists, or substitution reopens (spike design §6c).'
  if c1 && c3 && c4
    puts 'VERIFIED: full audit holds (C1 coverage + C3 aggregate + C4 range).'
  else
    puts 'REJECTED: one or more audit claims fail.'
    exit 1
  end

else
  die 'usage: sda_verify.rb generators|commit|aggregate-verify|aggregate-schnorr|binding|doi-set|range-verify|full-audit-verify …'
end
