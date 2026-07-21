#!/usr/bin/env ruby
# frozen_string_literal: true

# khab_verify — offline auditor verifier for khab-1 head bindings (MPR-4).
#
# Verifies inclusion and consistency proofs with EXACTLY the disclosed trust
# base: the proof artifact, the published head binding(s), and the shipped
# khab-1 convention definition. No internal-chain access, no operator
# cooperation, no network. (The authentic anchor-log view — that the binding
# really is committed at its claimed position — is checked against the log's
# public verification surface, outside this script.)
#
# Usage:
#   khab_verify.rb inclusion   <proof.json> <binding.json>
#   khab_verify.rb consistency <proof.json> <earlier_binding.json> <later_binding.json>
#
# A binding file may be the bare head_binding object, or any JSON object
# carrying it under "head_binding" (e.g. a public-verifier record or an anchor
# entry body).
#
# Exit status: 0 = VERIFIED, 1 = REJECTED, 2 = usage / unresolvable input.

require 'json'
require 'digest'
require_relative '../lib/synoptis/anchoring/cumulative_commitment'

CONVENTION_PATH = File.expand_path('../lib/synoptis/anchoring/conventions/khab-1.md', __dir__)
CC = Synoptis::Anchoring::CumulativeCommitment

def die(msg)
  warn "khab_verify: #{msg}"
  exit 2
end

def reject(msg)
  puts "REJECTED: #{msg}"
  exit 1
end

def load_json(path)
  parsed = JSON.parse(File.read(path))
  die "#{path}: expected a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)
  parsed
rescue JSON::ParserError, SystemCallError => e
  die "cannot read #{path}: #{e.message}"
end

def extract_binding(obj, path)
  b = obj.is_a?(Hash) && obj.key?('head_binding') ? obj['head_binding'] : obj
  die "#{path} carries no head binding" unless b.is_a?(Hash) && b['convention']
  b
end

# Structural well-formedness of a binding's verifiable fields, checked BEFORE
# any verdict logic. The strongest claims this verifier can emit (VERIFIED,
# DIVERGENCE) must be unreachable from malformed input: a missing or
# non-canonical root/extent is unresolvable input (exit 2), never evidence.
def require_wellformed!(binding, path)
  unless binding['cumulative_root'].is_a?(String) && binding['cumulative_root'].match?(/\A[a-f0-9]{64}\z/)
    die "#{path}: cumulative_root missing or not 64-char lowercase hex (khab-1 §4)"
  end
  unless binding['tree_size'].is_a?(Integer) && binding['tree_size'].positive? && binding['tree_size'] < 2**53
    die "#{path}: tree_size missing or not a positive JSON-safe integer (khab-1 §4)"
  end
  return if binding['chain_identity'].is_a?(String) &&
            binding['chain_identity'].match?(/\Ablock1-sha256:[a-f0-9]{64}\z/)

  die "#{path}: chain_identity missing or not in khab-1 §5 canonical form (block1-sha256:<64-hex>)"
end

# MPR-3: the convention identifier must resolve to a definition whose own
# integrity the auditor can verify. A digest mismatch means the binding was
# computed under a definition this verifier does not hold — unresolvable, so
# verification refuses rather than guessing.
def check_convention!(binding)
  reject "unknown convention #{binding['convention'].inspect} (this verifier implements khab-1)" unless
    binding['convention'] == 'khab-1'
  local = begin
    Digest::SHA256.hexdigest(File.binread(CONVENTION_PATH))
  rescue SystemCallError => e
    die "khab-1 convention definition unreadable at #{CONVENTION_PATH}: #{e.message}"
  end
  return if binding['convention_sha256'] == local

  reject "convention_sha256 #{binding['convention_sha256']} does not match the held khab-1 " \
         "definition (#{local}); convention unresolvable"
end

def require_match(proof, binding, proof_key, binding_key, label)
  return if proof[proof_key] == binding[binding_key]

  reject "proof #{label} #{proof[proof_key].inspect} does not match binding #{binding[binding_key].inspect}"
end

mode = ARGV.shift

case mode
when 'inclusion'
  die 'usage: khab_verify.rb inclusion <proof.json> <binding.json>' unless ARGV.size == 2
  proof = load_json(ARGV[0])
  binding = extract_binding(load_json(ARGV[1]), ARGV[1])
  check_convention!(binding)
  require_wellformed!(binding, ARGV[1])
  reject "proof format #{proof['format'].inspect} is not khab-1/inclusion" unless proof['format'] == 'khab-1/inclusion'
  require_match(proof, binding, 'chain_identity', 'chain_identity', 'chain_identity')
  require_match(proof, binding, 'tree_size', 'tree_size', 'tree_size')
  require_match(proof, binding, 'cumulative_root', 'cumulative_root', 'cumulative_root')

  ok = CC.verify_inclusion(
    record_commitment: proof['record_commitment'],
    index: proof['index'],
    tree_size: binding['tree_size'],
    path: proof['path'],
    root: binding['cumulative_root']
  )
  reject 'inclusion proof does not recompute the committed cumulative root' unless ok

  puts 'VERIFIED: record commitment ' \
       "#{proof['record_commitment']} is member ##{proof['index']} of the anchored state " \
       "(tree_size #{binding['tree_size']}, chain #{binding['chain_identity']})."
  puts 'Scope (MPR-5/6): membership, integrity at anchor time, position, order — nothing about ' \
       'content quality or completeness of anchoring; commitment, not content.'

when 'consistency'
  die 'usage: khab_verify.rb consistency <proof.json> <earlier.json> <later.json>' unless ARGV.size == 3
  proof = load_json(ARGV[0])
  earlier = extract_binding(load_json(ARGV[1]), ARGV[1])
  later = extract_binding(load_json(ARGV[2]), ARGV[2])
  check_convention!(earlier)
  check_convention!(later)
  require_wellformed!(earlier, ARGV[1])
  require_wellformed!(later, ARGV[2])
  reject "proof format #{proof['format'].inspect} is not khab-1/consistency" unless proof['format'] == 'khab-1/consistency'
  # MPR-9: extension-relatedness is defined only over the same committed chain
  # identity; different identities terminate the claim rather than failing it.
  reject "bindings commit different chain identities (#{earlier['chain_identity']} vs " \
         "#{later['chain_identity']}); extension claim terminated across an identity change" unless
    earlier['chain_identity'] == later['chain_identity']
  # Equal committed extent with different committed roots needs no proof at
  # all: the two states differ at the same size, so no extension relation can
  # exist. This is arithmetic on the committed bindings — a POSITIVE
  # divergence witness (MPR-9), unlike a mere proof-verification failure.
  if earlier['tree_size'] == later['tree_size'] && earlier['cumulative_root'] != later['cumulative_root']
    puts "DIVERGENCE: both bindings commit chain #{later['chain_identity']} at extent " \
         "#{later['tree_size']} with different cumulative roots; conclusive evidence of " \
         'rewriting or forking (MPR-9)'
    exit 1
  end
  require_match(proof, earlier, 'first_root', 'cumulative_root', 'first_root')
  require_match(proof, later, 'second_root', 'cumulative_root', 'second_root')
  require_match(proof, earlier, 'first_size', 'tree_size', 'first_size')
  require_match(proof, later, 'second_size', 'tree_size', 'second_size')

  ok = CC.verify_consistency(
    first_root: earlier['cumulative_root'],
    first_size: earlier['tree_size'],
    second_root: later['cumulative_root'],
    second_size: later['tree_size'],
    path: proof['path']
  )
  # Design §11: failure of an operator-supplied proof is NOT by itself a
  # positive inconsistency witness — report it as unestablished, not as forgery.
  reject 'consistency proof does not verify; extension claim remains UNESTABLISHED ' \
         '(not by itself evidence of rewriting — MPR-9)' unless ok

  puts "VERIFIED: the later anchored state (tree_size #{later['tree_size']}) commits to an " \
       "extension of the earlier state (tree_size #{earlier['tree_size']}) unchanged as a prefix " \
       "(chain #{later['chain_identity']})."

else
  die "usage: khab_verify.rb {inclusion|consistency} <proof.json> <binding(s).json...>"
end
