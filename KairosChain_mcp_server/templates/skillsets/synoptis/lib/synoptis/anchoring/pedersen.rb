# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require_relative 'ec_group'

module Synoptis
  module Anchoring
    # Pedersen commitments over the EcGroup prime-order group, for the AUD-L4 ZK
    # aggregate reproducibility SPIKE (Phase 1 — commitment arithmetic, NOT the
    # zero-knowledge core). A commitment C = s*G + r*H perfectly hides s (any s
    # is equally consistent given an unknown r) and computationally binds it
    # (opening to a different s would reveal log_G(H)). Pedersen is additively
    # homomorphic: sum of commitments commits the sum of values and the sum of
    # blindings. That homomorphism is what lets the SPIKE publish an aggregate
    # while every individual score stays secret (design memo §2.2, sub-claims
    # C2/C3).
    #
    # DELIBERATE LIMIT (design memo §3): a commitment binds the committer to
    # SOME value, never to a LEGITIMATE (in-range) one. The aggregate opening
    # below therefore constrains the SUM but nothing about each term's range;
    # an out-of-range term forges the mean and still opens. Closing that is the
    # Phase 2 range proof (the genuine zero-knowledge proof), not this file.
    module Pedersen
      COMMITMENT_FORMAT = 'sda-1/pedersen-commitment'
      SCHNORR_FORMAT = 'sda-1/aggregate-schnorr'
      # Fiat-Shamir domain separation for the aggregate-randomness proof.
      CHALLENGE_DOMAIN = 'sda-1/aggregate-schnorr-challenge'

      class CommitmentError < StandardError; end

      module_function

      # C = value*G + blinding*H. +value+ is a non-negative integer score;
      # +blinding+ is the secret randomness (reduced mod N). A zero blinding is
      # refused: it collapses hiding (the commitment would equal value*G, an
      # openable multiple of G).
      def commit(value, blinding)
        v = require_nonneg_int!(value, 'value')
        r = require_int!(blinding, 'blinding') % EcGroup::N
        raise CommitmentError, 'blinding must be non-zero (a zero blinding discloses the value)' if r.zero?

        EcGroup.add(EcGroup.scalar_mul(v, EcGroup.g), EcGroup.scalar_mul(r, EcGroup.h))
      end

      # A fresh blinding in [1, N-1]. Producers use this; tests may inject their
      # own for determinism.
      def random_blinding
        loop do
          r = SecureRandom.random_number(EcGroup::N)
          return r unless r.zero?
        end
      end

      # Sum of commitments = commitment of (Σ value, Σ blinding). The identity is
      # the empty aggregate's neutral element.
      def aggregate(commitments)
        commitments.reduce(EcGroup::INFINITY) { |acc, c| EcGroup.add(acc, c) }
      end

      # Plain aggregate opening (design memo §2.2): reveal (Σs, Σr) and check the
      # published aggregate reconstructs. Individual s_i stay perfectly hidden;
      # only the sums are disclosed. Returns true/false (a well-formed
      # non-matching opening is a report, not an error).
      def open?(aggregate_point, sum_s, sum_r)
        s = require_nonneg_int!(sum_s, 'sum_s')
        r = require_int!(sum_r, 'sum_r') % EcGroup::N
        expected = EcGroup.add(EcGroup.scalar_mul(s, EcGroup.g), EcGroup.scalar_mul(r, EcGroup.h))
        aggregate_point == expected
      end

      # Schnorr proof of knowledge of Σr such that (aggregate - Σs*G) = Σr*H,
      # WITHOUT revealing Σr (design memo §2.2 alternative opening). This hides
      # the aggregate randomness but is still NOT the load-bearing ZK — it says
      # nothing about the range of any s_i. +nonce+ is injectable for
      # deterministic tests; producers omit it for a fresh one.
      def prove_aggregate_randomness(aggregate_point, sum_s, sum_r, nonce: nil)
        s = require_nonneg_int!(sum_s, 'sum_s')
        w = require_int!(sum_r, 'sum_r') % EcGroup::N
        pt_p = EcGroup.subtract(aggregate_point, EcGroup.scalar_mul(s, EcGroup.g))
        k = (nonce.nil? ? random_blinding : require_int!(nonce, 'nonce')) % EcGroup::N
        raise CommitmentError, 'nonce must be non-zero' if k.zero?

        a_pt = EcGroup.scalar_mul(k, EcGroup.h)
        c = challenge(pt_p, a_pt)
        z = (k + c * w) % EcGroup::N
        { 'a' => EcGroup.encode(a_pt), 'format' => SCHNORR_FORMAT, 'z' => z.to_s(16) }
      end

      # Verifier side: recompute the challenge and check z*H == A + c*(agg - Σs*G).
      # Structural malformation raises; a genuine proof failure returns false.
      def verify_aggregate_randomness(aggregate_point, sum_s, proof)
        pr = proof.is_a?(Hash) ? proof.transform_keys(&:to_s) : {}
        raise CommitmentError, "unknown proof format #{pr['format'].inspect} (#{SCHNORR_FORMAT} only)" unless pr['format'] == SCHNORR_FORMAT
        raise CommitmentError, 'proof.z must be a lowercase-hex scalar' unless pr['z'].is_a?(String) && pr['z'].match?(/\A[a-f0-9]+\z/)

        s = require_nonneg_int!(sum_s, 'sum_s')
        z = Integer(pr['z'], 16) % EcGroup::N
        a_pt = EcGroup.decode(pr['a'])
        pt_p = EcGroup.subtract(aggregate_point, EcGroup.scalar_mul(s, EcGroup.g))
        c = challenge(pt_p, a_pt)
        lhs = EcGroup.scalar_mul(z, EcGroup.h)
        rhs = EcGroup.add(a_pt, EcGroup.scalar_mul(c, pt_p))
        lhs == rhs
      end

      # -- internal helpers --

      # Fiat-Shamir challenge over the fixed generators and the proof transcript.
      # Binding H and G (via their encodings) domain-separates the proof to this
      # group; binding P and A ties the challenge to the specific statement.
      def challenge(pt_p, a_pt)
        transcript = [CHALLENGE_DOMAIN, EcGroup.encode(EcGroup.g), EcGroup.encode(EcGroup.h),
                      EcGroup.encode(pt_p), EcGroup.encode(a_pt)].join('|')
        Integer(Digest::SHA256.hexdigest(transcript), 16) % EcGroup::N
      end

      def require_int!(value, label)
        raise CommitmentError, "#{label} must be an Integer, got #{value.class}" unless value.is_a?(Integer)

        value
      end

      def require_nonneg_int!(value, label)
        v = require_int!(value, label)
        raise CommitmentError, "#{label} must be non-negative, got #{v}" if v.negative?

        v
      end
    end
  end
end
