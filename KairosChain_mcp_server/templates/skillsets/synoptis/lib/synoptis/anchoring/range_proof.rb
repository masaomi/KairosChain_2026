# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require_relative 'entry'
require_relative 'ec_group'
require_relative 'pedersen'

module Synoptis
  module Anchoring
    # Zero-knowledge range proof for the AUD-L4 ZK aggregate reproducibility
    # SPIKE, Phase 2 (aud_l4_zk_range_proof_design v0.3, converged R2 5/6).
    # KairosChain's first genuine zero-knowledge proof: for a Phase-1 Pedersen
    # commitment C = s*G + r*H it demonstrates s in [0, 7] (the disclosed 3-bit
    # band) WITHOUT revealing s.
    #
    # Construction (spec §2-§4): bit-decomposition Sigma range proof. Each bit
    # b_j of s gets a Pedersen commitment B_j = b_j*G + r_j*H with the bit
    # blindings chosen so Sum 2^j * r_j = r — hence Sum 2^j * B_j = C by
    # construction (the reconstruction invariant). Each B_j carries a
    # Cramer-Damgard-Schoenmakers '94 OR proof that it commits 0 or 1 (Schnorr
    # PoK base H on X_0 = B_j OR X_1 = B_j - G, false branch simulated), made
    # non-interactive by Fiat-Shamir (SHA-256 as random oracle). No trusted
    # setup; no new runtime dependency (pure-Ruby secp256k1 from Phase 1).
    #
    # Verifier contract (spec §5, R1-hardened): every ADMISSION failure —
    # schema, array lengths, non-hex, a scalar >= N, off-curve, identity —
    # RAISES RangeError; only a well-formed proof that fails an ALGEBRAIC check
    # (reconstruction or an OR equation) returns false. The admission checks
    # close the R1 range-escape (a prover supplying extra bits to widen the
    # range) and the point/scalar malleability gaps.
    #
    # Honest limits (spec §9): a valid proof shows s in [0,7]; it does NOT show
    # s is the true re-execution result (RPR-4/MPR-6 residue, unchanged). The
    # pure-Ruby prover is not constant-time (disclosed, SDP-3 non-production);
    # proof elements are emitted in fixed statement-index order so the
    # published transcript leaks nothing.
    module RangeProof
      PROOF_FORMAT = 'sda-1/range-proof'
      CHALLENGE_DOMAIN = 'sda-1/range-proof-bit-challenge'
      VMAX = 7
      BITS = 3
      PROOF_FIELDS = %w[bit_commitments bits format or_proofs vmax].freeze
      OR_PROOF_FIELDS = %w[a0 a1 e0 z0 z1].freeze
      # Fixed-width 64-hex canonical scalars (spec §0.2): value must also be < N.
      HEX_SCALAR = /\A[a-f0-9]{64}\z/

      class RangeError < StandardError; end

      module_function

      # Scalar (group-order) inverse of 4: 4^(N-2) mod N (N prime). NEVER
      # EcGroup.mod_inv, which is the FIELD inverse mod P (spec §1.1).
      def inv4
        @inv4 ||= 4.pow(EcGroup::N - 2, EcGroup::N)
      end

      # -- prover (spec §2-§3) --

      # Prove score in [0, VMAX] for C = Pedersen.commit(score, blinding)
      # without revealing score. Returns the canonical JSON proof string.
      # Refuses out-of-band scores at the prover; the verifier never trusts
      # that refusal (§5 enforces everything independently).
      def prove_range(score, blinding)
        raise RangeError, "score must be an Integer in [0, #{VMAX}], got #{score.inspect}" unless score.is_a?(Integer) && score >= 0 && score <= VMAX
        raise RangeError, 'blinding must be an Integer' unless blinding.is_a?(Integer)

        r = blinding % EcGroup::N
        raise RangeError, 'blinding must be non-zero mod N' if r.zero?

        c_pt = Pedersen.commit(score, blinding)
        bits = Array.new(BITS) { |j| (score >> j) & 1 }

        # Split the blinding: r_0, r_1 fresh non-zero; r_2 derived so that
        # r_0 + 2 r_1 + 4 r_2 = r (mod N) — the reconstruction invariant.
        # r_2 == 0 is resampled (a zero blinding makes B_2 = b_2*G, leaking
        # the top bit); probability 1/N, terminates in one iteration w.h.p.
        r_j = nil
        loop do
          r0 = Pedersen.random_blinding
          r1 = Pedersen.random_blinding
          r2 = ((r - r0 - 2 * r1) * inv4) % EcGroup::N
          next if r2.zero?

          r_j = [r0, r1, r2]
          break
        end

        b_pts = BITS.times.map { |j| Pedersen.commit(bits[j], r_j[j]) }
        or_proofs = BITS.times.map { |j| bit_or_prove(j, c_pt, b_pts[j], bits[j], r_j[j]) }

        Entry.canonical_json(
          'bit_commitments' => b_pts.map { |pt| EcGroup.encode(pt) },
          'bits' => BITS,
          'format' => PROOF_FORMAT,
          'or_proofs' => or_proofs,
          'vmax' => VMAX
        )
      end

      # -- verifier (spec §5) --

      # +proof_string+ is the RAW canonical JSON string (step 0 checks the
      # original bytes). Admission failures raise RangeError; a well-formed
      # proof failing reconstruction or an OR equation returns false.
      def verify_range(commitment_enc, proof_string)
        p = parse_proof!(proof_string)

        c_pt = decode_point!(commitment_enc, 'commitment')
        b_pts = p['bit_commitments'].each_with_index.map { |enc, j| decode_point!(enc, "bit_commitments[#{j}]") }

        proofs = p['or_proofs'].each_with_index.map do |op, j|
          {
            'a0' => decode_point!(op['a0'], "or_proofs[#{j}].a0"),
            'a1' => decode_point!(op['a1'], "or_proofs[#{j}].a1"),
            'e0' => decode_scalar!(op['e0'], "or_proofs[#{j}].e0"),
            'z0' => decode_scalar!(op['z0'], "or_proofs[#{j}].z0"),
            'z1' => decode_scalar!(op['z1'], "or_proofs[#{j}].z1")
          }
        end

        # Step 2 — reconstruction: Sum 2^j * B_j == C. With exactly BITS
        # (step-0) binary bits (step-3) the reconstructable range is [0, 7].
        sum = b_pts.each_with_index.reduce(EcGroup::INFINITY) do |acc, (pt, j)|
          EcGroup.add(acc, EcGroup.scalar_mul(1 << j, pt))
        end
        return false unless sum == c_pt

        # Step 3 — every per-bit CDS OR proof verifies.
        proofs.each_with_index.all? do |op, j|
          bit_or_verify(j, c_pt, b_pts[j], op['a0'], op['a1'], op['e0'], op['z0'], op['z1'])
        end
      end

      # -- internal: CDS'94 OR proof per bit (spec §3) --

      # Emit order is by STATEMENT INDEX (0/1), not by real/fake: for b = 1 the
      # published e0 is the fake branch's challenge. Fixed ordering keeps the
      # published transcript independent of which branch is real (§9d).
      def bit_or_prove(j, c_pt, b_pt, bit, r_bit)
        x = [b_pt, EcGroup.subtract(b_pt, EcGroup.g)] # X_0 = B_j, X_1 = B_j - G
        t = bit
        f = 1 - bit
        e_f = z_f = a_f = a_t = k = nil
        loop do
          e_f = SecureRandom.random_number(EcGroup::N)
          z_f = SecureRandom.random_number(EcGroup::N)
          a_f = EcGroup.subtract(EcGroup.scalar_mul(z_f, EcGroup.h), EcGroup.scalar_mul(e_f, x[f]))
          k = Pedersen.random_blinding
          a_t = EcGroup.scalar_mul(k, EcGroup.h)
          # The verifier rejects identity points; resample the negligible case
          # so an honest proof never trips it (spec R2 P3 note).
          break unless a_f.infinity? || a_t.infinity?
        end
        a_pts = t.zero? ? [a_t, a_f] : [a_f, a_t]
        e = range_challenge(j, c_pt, b_pt, a_pts[0], a_pts[1])
        e_t = (e - e_f) % EcGroup::N
        z_t = (k + e_t * r_bit) % EcGroup::N
        e_by_idx = t.zero? ? e_t : e_f
        z_by_idx = t.zero? ? [z_t, z_f] : [z_f, z_t]
        {
          'a0' => EcGroup.encode(a_pts[0]),
          'a1' => EcGroup.encode(a_pts[1]),
          'e0' => scalar_hex(e_by_idx),
          'z0' => scalar_hex(z_by_idx[0]),
          'z1' => scalar_hex(z_by_idx[1])
        }
      end

      def bit_or_verify(j, c_pt, b_pt, a0_pt, a1_pt, e0, z0, z1)
        e = range_challenge(j, c_pt, b_pt, a0_pt, a1_pt)
        e1 = (e - e0) % EcGroup::N
        lhs0 = EcGroup.scalar_mul(z0, EcGroup.h)
        rhs0 = EcGroup.add(a0_pt, EcGroup.scalar_mul(e0, b_pt))
        return false unless lhs0 == rhs0

        x1 = EcGroup.subtract(b_pt, EcGroup.g)
        lhs1 = EcGroup.scalar_mul(z1, EcGroup.h)
        rhs1 = EcGroup.add(a1_pt, EcGroup.scalar_mul(e1, x1))
        lhs1 == rhs1
      end

      # Fiat-Shamir challenge (spec §4). All operands fixed-width (encode =
      # 66-hex non-identity, j single-digit), so the '|' join is injective.
      def range_challenge(j, c_pt, b_pt, a0_pt, a1_pt)
        transcript = [
          CHALLENGE_DOMAIN, PROOF_FORMAT, "vmax=#{VMAX}", "bits=#{BITS}", "j=#{j}",
          EcGroup.encode(EcGroup.g), EcGroup.encode(EcGroup.h),
          EcGroup.encode(c_pt), EcGroup.encode(b_pt),
          EcGroup.encode(a0_pt), EcGroup.encode(a1_pt)
        ].join('|')
        Integer(Digest::SHA256.hexdigest(transcript), 16) % EcGroup::N
      end

      # -- internal: admission (spec §5 steps 0-1; failures RAISE) --

      def parse_proof!(proof_string)
        raise RangeError, "range proof must be a String (the raw canonical JSON), got #{proof_string.class}" unless proof_string.is_a?(String)

        parsed = begin
          JSON.parse(proof_string)
        rescue JSON::ParserError => e
          raise RangeError, "range proof is not valid JSON: #{e.message}"
        end
        raise RangeError, "range proof must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        p = parsed.transform_keys(&:to_s)
        raise RangeError, "range proof fields must be exactly #{PROOF_FIELDS.join(', ')}" unless p.keys.sort == PROOF_FIELDS
        raise RangeError, "unknown format #{p['format'].inspect} (#{PROOF_FORMAT} only)" unless p['format'] == PROOF_FORMAT
        # Type-strict integer equality: Ruby's == coerces 7.0 == 7, and canonical
        # JSON round-trips floats faithfully, so a Float 7.0/3.0 variant would be
        # a DISTINCT accepting byte-string for the same proof — an encoding
        # malleability against the one-artifact-one-digest discipline (impl R1
        # executable-adversary finding). Integer type is part of admission.
        raise RangeError, "vmax must be the Integer #{VMAX}" unless p['vmax'].is_a?(Integer) && p['vmax'] == VMAX
        raise RangeError, "bits must be the Integer #{BITS}" unless p['bits'].is_a?(Integer) && p['bits'] == BITS
        unless p['bit_commitments'].is_a?(Array) && p['bit_commitments'].length == BITS
          raise RangeError, "bit_commitments must be an array of exactly #{BITS} encoded points"
        end
        unless p['or_proofs'].is_a?(Array) && p['or_proofs'].length == BITS
          raise RangeError, "or_proofs must be an array of exactly #{BITS} proofs (1:1 with bit_commitments)"
        end

        p['or_proofs'] = p['or_proofs'].map do |op|
          o = op.is_a?(Hash) ? op.transform_keys(&:to_s) : {}
          raise RangeError, "each or_proof must have exactly the fields #{OR_PROOF_FIELDS.join(', ')}" unless o.keys.sort == OR_PROOF_FIELDS

          o
        end
        unless Entry.canonical_json(p) == proof_string
          raise RangeError, 'range proof is not in canonical serialization (one artifact, one digest)'
        end

        p
      end

      # EcGroup.decode enforces the canonical compressed encoding (prefix
      # 02/03, exactly 64 hex, x < P, on-curve); we additionally reject the
      # identity (a range proof over the identity would degenerate).
      def decode_point!(enc, label)
        pt = begin
          EcGroup.decode(enc)
        rescue EcGroup::GroupError => e
          raise RangeError, "#{label}: #{e.message}"
        end
        raise RangeError, "#{label} must not be the identity point" if pt.infinity?

        pt
      end

      def decode_scalar!(hex, label)
        raise RangeError, "#{label} must be a fixed-width 64-hex lowercase scalar" unless hex.is_a?(String) && hex.match?(HEX_SCALAR)

        v = Integer(hex, 16)
        raise RangeError, "#{label} must be < N (canonical scalar; non-canonical forms rejected)" unless v < EcGroup::N

        v
      end

      def scalar_hex(value)
        (value % EcGroup::N).to_s(16).rjust(64, '0')
      end
    end
  end
end
