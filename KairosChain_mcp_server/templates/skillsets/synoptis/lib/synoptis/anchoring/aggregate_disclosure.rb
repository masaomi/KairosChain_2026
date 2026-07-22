# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'entry'
require_relative 'selective_disclosure'
require_relative 'ec_group'
require_relative 'pedersen'

module Synoptis
  module Anchoring
    # AUD-L4 ZK aggregate reproducibility SPIKE — the audit binding and the
    # aggregate (design memo §2.1 / §2.2; candidate convention id if promoted:
    # sda-1, "selective disclosure — aggregate"). This is a SPIKE demonstrator,
    # NOT a promoted convention: it adds new files only, touches no frozen
    # invariant (SDP-1..5 / MPR / MAP / RPR are ID references), and modifies
    # nothing in selective_disclosure.rb or reproduction.rb.
    #
    # What Phase 1 realizes:
    #   C1 coverage — one sdp-1-committed, signed, foreign rpr-1 endorsement per
    #      public DOI (unchanged rpr-1/sdp-1 machinery; out of this file's scope
    #      except that a per-DOI SCORE record REFERENCES the endorsement digest).
    #   C2 secrecy — each per-DOI score is committed with Pedersen (hidden).
    #   C3 aggregate — the published mean equals the aggregate of the committed
    #      scores (Pedersen homomorphism + aggregate opening in Pedersen).
    #
    # The score is a COMPANION record, not an rpr-1 field: rpr-1's endorsement
    # schema is closed (verdict is the binary reproduced/not-reproduced), so a
    # graded 0..VMAX reproducibility score lives in its own sda-1/score record,
    # bound to the endorsement by digest reference. Its sdp-1 "score" field
    # digest and the Pedersen commitment are two commitments of ONE integer; an
    # opener holding (score, salt, blinding) recomputes both and their agreement
    # is the SDP-2 checkable-binding obligation. A Pedersen commitment the
    # producer could desynchronise from the score record is a re-authoring under
    # another name and is non-conforming (design memo §2.1).
    #
    # NOT here (design memo §3, §6): nothing constrains a score to [0, VMAX].
    # The aggregate opens even for an out-of-range term, so the mean is forgeable
    # at Phase 1. Closing that is the Phase 2 range proof. This file's tests make
    # that gap explicit rather than hiding it.
    module AggregateDisclosure
      SCORE_FORMAT = 'sda-1/score'
      DOI_SET_FORMAT = 'sda-1/doi-set-commitment'
      # Coarse reproducibility band 0..7 (3-bit), disclosed as deliberately
      # coarse (SDP-5). 0 = not reproducible … 7 = fully reproducible. Phase 2's
      # range proof will prove membership in exactly this band.
      VMAX = 7
      SCORE_FIELDS = %w[endorsement_sha256 format score target_sha256].freeze
      HEX_DIGEST = /\A[a-f0-9]{64}\z/

      class AggregateError < StandardError; end

      module_function

      # Build the canonical sda-1/score companion record for one DOI's audit.
      # It carries the graded score plus the digests that pin it to a specific
      # rpr-1 endorsement and re-execution target (both public — the DOI is
      # public; only the score value is later hidden).
      def score_record(endorsement_sha256:, target_sha256:, score:)
        e = require_digest!(endorsement_sha256, 'endorsement_sha256')
        t = require_digest!(target_sha256, 'target_sha256')
        require_band!(score)

        Entry.canonical_json(
          'endorsement_sha256' => e,
          'format' => SCORE_FORMAT,
          'score' => score,
          'target_sha256' => t
        )
      end

      # Producer side: commit a DOI's score two ways over one integer.
      # Returns { 'aux' => sdp-1 field-commitments record, 'salts' => {...},
      # 'commitment' => compressed Pedersen point, 'score_sha256' => digest of
      # the score record }. The sdp-1 aux hides the score value behind a salted
      # digest; the Pedersen commitment hides it behind a group element; both
      # commit the SAME integer, which is the SDP-2 binding. +salts+/+blinding+
      # are injectable for deterministic tests; producers let them be fresh.
      def commit_score(record_string, score:, blinding: nil, salts: nil)
        record = parse_score_record!(record_string)
        raise AggregateError, "record score #{record['score'].inspect} is out of band" unless record['score'] == require_band!(score)

        built = SelectiveDisclosure.build_field_commitments(record_string, salts: salts)
        r = blinding.nil? ? Pedersen.random_blinding : blinding
        commitment = Pedersen.commit(score, r)
        {
          'aux' => built['record'],
          'blinding' => r,
          'commitment' => EcGroup.encode(commitment),
          'salts' => built['salts'],
          'score_sha256' => Digest::SHA256.hexdigest(record_string.to_s)
        }
      end

      # Checkable SDP-2 binding (design memo §2.1). Given the opening — the score
      # record, its salts, the score integer, and the blinding — verify that
      #   (1) the sdp-1 auxiliary is checkably bound to the score record,
      #   (2) the record's score field equals the claimed integer, in band, and
      #   (3) the Pedersen commitment re-commits that exact integer.
      # All three must hold, or the commitment is desynchronised from the
      # endorsement's score (a re-authoring) and the binding is rejected.
      # Malformed inputs raise; a well-formed non-matching opening returns false.
      def verify_binding(record_string:, aux_string:, salts:, score:, blinding:, commitment:)
        record = parse_score_record!(record_string)
        return false unless SelectiveDisclosure.verify_field_commitments(aux_string, record_string, salts)
        return false unless valid_band?(score)
        return false unless record['score'] == score

        point = EcGroup.decode(commitment)
        point == Pedersen.commit(score, require_blinding!(blinding))
      end

      # Set-commitment over the public DOI list, fixed BEFORE any score exists so
      # the auditor cannot substitute DOIs after seeing results (design memo
      # §2.1 / §6c). Deterministic: SHA-256 over the canonical JSON of the sorted
      # unique DOI digests. In deployment this digest is what a khab-1 anchor
      # commits; the lib computes the referent, the anchoring step (human gate)
      # deposits it.
      def doi_set_commitment(dois)
        list = Array(dois).map { |d| require_nonempty_string!(d, 'doi') }
        raise AggregateError, 'doi set must be non-empty' if list.empty?
        raise AggregateError, 'doi set must be duplicate-free' unless list.uniq.size == list.size

        digests = list.map { |d| Digest::SHA256.hexdigest(d) }.sort
        Digest::SHA256.hexdigest(
          Entry.canonical_json('digests' => digests, 'format' => DOI_SET_FORMAT, 'size' => list.size)
        )
      end

      # Aggregate the per-DOI commitments (design memo §2.2). +commitments+ is a
      # list of compressed points. Returns the compressed aggregate point.
      def aggregate(commitments)
        points = Array(commitments).map { |c| EcGroup.decode(c) }
        EcGroup.encode(Pedersen.aggregate(points))
      end

      # Verify the published mean against the committed scores. Checks the
      # aggregate opening (Σs, Σr) reconstructs the aggregate of +commitments+,
      # then reports the mean as a band-scaled figure. Returns a structured
      # report; +valid+ is false when the opening does not reconstruct.
      #
      # HONEST LIMIT (design memo §6a, echoed here so a caller cannot mistake it
      # for a soundness guarantee): a passing opening proves the mean is honest
      # RELATIVE TO the committed scores, and proves NOTHING about their range.
      # Without the Phase 2 range proof this mean is forgeable with an
      # out-of-range term (see the §3 attack; a Phase 1 test asserts it opens).
      def verify_mean(commitments:, sum_s:, sum_r:)
        points = Array(commitments).map { |c| EcGroup.decode(c) }
        raise AggregateError, 'need at least one commitment' if points.empty?

        agg = Pedersen.aggregate(points)
        opened = Pedersen.open?(agg, sum_s, sum_r)
        count = points.size
        {
          valid: opened,
          count: count,
          sum_s: sum_s,
          mean_band: opened ? Rational(sum_s, count) : nil,
          mean_percent: opened ? Rational(sum_s, count * VMAX) * 100 : nil,
          vmax: VMAX,
          notes: [
            'the mean is honest relative to the committed scores only; that each score is the true re-execution result is NOT proven (RPR-4/MPR-6 residue, unchanged)',
            'no term is proven in [0, ' + VMAX.to_s + ']: at Phase 1 the mean is forgeable with an out-of-range score (design memo §3). The Phase 2 range proof closes this.'
          ]
        }
      end

      # -- internal helpers --

      def parse_score_record!(record_string)
        parsed = begin
          JSON.parse(record_string.to_s)
        rescue JSON::ParserError => e
          raise AggregateError, "score record is not valid JSON: #{e.message}"
        end
        raise AggregateError, "score record must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        r = parsed.transform_keys(&:to_s)
        raise AggregateError, "score record fields must be exactly #{SCORE_FIELDS.join(', ')}" unless r.keys.sort == SCORE_FIELDS
        raise AggregateError, "unknown score record format #{r['format'].inspect} (#{SCORE_FORMAT} only)" unless r['format'] == SCORE_FORMAT

        require_digest!(r['endorsement_sha256'], 'endorsement_sha256')
        require_digest!(r['target_sha256'], 'target_sha256')
        require_band!(r['score'])
        unless Entry.canonical_json(r) == record_string.to_s
          raise AggregateError, 'score record is not in canonical serialization (one record, one digest)'
        end

        r
      end

      def require_band!(score)
        raise AggregateError, "score must be an Integer in [0, #{VMAX}], got #{score.inspect}" unless valid_band?(score)

        score
      end

      def valid_band?(score)
        score.is_a?(Integer) && score >= 0 && score <= VMAX
      end

      def require_digest!(value, label)
        raise AggregateError, "#{label} must be 64-char lowercase hex" unless value.is_a?(String) && value.match?(HEX_DIGEST)

        value
      end

      def require_blinding!(blinding)
        raise AggregateError, 'blinding must be an Integer' unless blinding.is_a?(Integer)

        blinding
      end

      def require_nonempty_string!(value, label)
        raise AggregateError, "#{label} must be a non-empty string" unless value.is_a?(String) && !value.empty?

        value
      end
    end
  end
end
