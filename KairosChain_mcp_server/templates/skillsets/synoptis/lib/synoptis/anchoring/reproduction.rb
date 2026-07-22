# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'entry'
require_relative 'chain_credential'

module Synoptis
  module Anchoring
    # Reproduction endorsement artifacts (aud_l3_reproducibility_design v0.4,
    # RPR-1..5) under the rpr-1 convention: re-execution target, tolerance
    # declaration, reproduction endorsement, and the declaration-set
    # assessment. rpr-1 builds on map-1 (credentials, §1.1 attestation
    # signatures, types, retraction) and modifies nothing there: signing and
    # verification are ChainCredential calls, retraction is the map-1 §3 act
    # unchanged. Refuse-not-coerce for authored artifacts; the assessment is
    # diagnostic and reports rather than enforces (RPR-3: exposure, not
    # prevention).
    module Reproduction
      CONVENTION_ID = 'rpr-1'
      CONVENTION_PATH = File.expand_path('conventions/rpr-1.md', __dir__)
      TARGET_FORMAT = 'rpr-1/target'
      TOLERANCE_FORMAT = 'rpr-1/tolerance'
      ENDORSEMENT_FORMAT = 'rpr-1/endorsement'
      TOLERANCE_KINDS = %w[bit-identity].freeze
      VERDICTS = %w[reproduced not-reproduced].freeze
      MODES = %w[hand procedure].freeze
      HEX_DIGEST = /\A[a-f0-9]{64}\z/

      # Exactly these fields, sorted (closed schemas; extension = rpr-2).
      TARGET_FIELDS = %w[environment_sha256 format input_sha256 output_sha256 pipeline_sha256].freeze
      # The first three digests in field-name-independent terms: what is
      # re-run. output_sha256 completes the target but is OUTSIDE the
      # committed computation identification (design §3(b)).
      COMPUTATION_ID_FIELDS = %w[environment_sha256 input_sha256 pipeline_sha256].freeze
      TOLERANCE_FIELDS = %w[format kind target_sha256].freeze
      ENDORSEMENT_FIELDS_HAND = %w[adjudication_mode format target_sha256 tolerance_sha256 verdict].freeze
      ENDORSEMENT_FIELDS_PROCEDURE = %w[adjudication_mode format procedure_sha256 target_sha256 tolerance_sha256 verdict].freeze

      class ReproductionError < StandardError; end

      module_function

      # SHA-256 of the shipped rpr-1 convention definition's raw bytes.
      def convention_sha256
        @convention_sha256 ||= begin
          Digest::SHA256.hexdigest(File.binread(CONVENTION_PATH))
        rescue SystemCallError => e
          raise ReproductionError, "rpr-1 convention definition unreadable at #{CONVENTION_PATH}: #{e.message}"
        end
      end

      # -- re-execution target (rpr-1 §1, RPR-2) --

      def build_target(input_sha256:, environment_sha256:, pipeline_sha256:, output_sha256:)
        record = {
          'environment_sha256' => environment_sha256,
          'format' => TARGET_FORMAT,
          'input_sha256' => input_sha256,
          'output_sha256' => output_sha256,
          'pipeline_sha256' => pipeline_sha256
        }
        %w[input_sha256 environment_sha256 pipeline_sha256 output_sha256].each do |k|
          unless record[k].is_a?(String) && record[k].match?(HEX_DIGEST)
            raise ReproductionError, "target.#{k} must be 64-char lowercase hex, got #{record[k].inspect}"
          end
        end
        Entry.canonical_json(record)
      end

      def parse_target!(target_string)
        parse_record!(target_string, TARGET_FORMAT, TARGET_FIELDS, 'target') do |t|
          (TARGET_FIELDS - %w[format]).each do |k|
            raise ReproductionError, "target.#{k} must be 64-char lowercase hex" unless t[k].is_a?(String) && t[k].match?(HEX_DIGEST)
          end
        end
      end

      def target_digest(target_string)
        parse_target!(target_string)
        Digest::SHA256.hexdigest(target_string.to_s)
      end

      # The committed computation identification (design §3(b)): the first
      # three digests. Two targets SHARE a computation iff these are equal;
      # output_sha256 never participates.
      def computation_id(target_string)
        t = parse_target!(target_string)
        COMPUTATION_ID_FIELDS.map { |k| t[k] }.join('|')
      end

      # -- tolerance declaration (rpr-1 §2, RPR-3) --

      def build_tolerance(target_sha256:, kind: 'bit-identity')
        raise ReproductionError, "tolerance.kind must be one of #{TOLERANCE_KINDS.join(', ')}, got #{kind.inspect}" unless TOLERANCE_KINDS.include?(kind.to_s)
        unless target_sha256.is_a?(String) && target_sha256.match?(HEX_DIGEST)
          raise ReproductionError, 'tolerance.target_sha256 must be 64-char lowercase hex'
        end

        Entry.canonical_json('format' => TOLERANCE_FORMAT, 'kind' => kind.to_s, 'target_sha256' => target_sha256)
      end

      def parse_tolerance!(tolerance_string)
        parse_record!(tolerance_string, TOLERANCE_FORMAT, TOLERANCE_FIELDS, 'tolerance') do |t|
          raise ReproductionError, "tolerance.kind must be one of #{TOLERANCE_KINDS.join(', ')}" unless TOLERANCE_KINDS.include?(t['kind'])
          unless t['target_sha256'].is_a?(String) && t['target_sha256'].match?(HEX_DIGEST)
            raise ReproductionError, 'tolerance.target_sha256 must be 64-char lowercase hex'
          end
        end
      end

      def tolerance_digest(tolerance_string)
        parse_tolerance!(tolerance_string)
        Digest::SHA256.hexdigest(tolerance_string.to_s)
      end

      # -- reproduction endorsement (rpr-1 §3, RPR-1/RPR-4) --

      def build_endorsement(target_sha256:, tolerance_sha256:, verdict:, adjudication_mode:, procedure_sha256: nil)
        mode = adjudication_mode.to_s
        raise ReproductionError, "verdict must be one of #{VERDICTS.join(', ')}, got #{verdict.inspect}" unless VERDICTS.include?(verdict.to_s)
        raise ReproductionError, "adjudication_mode must be one of #{MODES.join(', ')}, got #{mode.inspect}" unless MODES.include?(mode)

        record = {
          'adjudication_mode' => mode,
          'format' => ENDORSEMENT_FORMAT,
          'target_sha256' => target_sha256,
          'tolerance_sha256' => tolerance_sha256,
          'verdict' => verdict.to_s
        }
        if mode == 'procedure'
          unless procedure_sha256.is_a?(String) && procedure_sha256.match?(HEX_DIGEST)
            raise ReproductionError, 'procedure mode requires procedure_sha256 as 64-char lowercase hex (RPR-4: the adopted procedure is named)'
          end
          record['procedure_sha256'] = procedure_sha256
        elsif !procedure_sha256.nil?
          raise ReproductionError, 'hand mode must not carry procedure_sha256 (closed schema per mode)'
        end
        %w[target_sha256 tolerance_sha256].each do |k|
          raise ReproductionError, "endorsement.#{k} must be 64-char lowercase hex" unless record[k].is_a?(String) && record[k].match?(HEX_DIGEST)
        end
        Entry.canonical_json(record)
      end

      def parse_endorsement!(endorsement_string)
        parsed = json_object!(endorsement_string, 'endorsement')
        e = parsed.transform_keys(&:to_s)
        raise ReproductionError, "unknown format #{e['format'].inspect} (#{ENDORSEMENT_FORMAT} only)" unless e['format'] == ENDORSEMENT_FORMAT
        raise ReproductionError, "adjudication_mode must be one of #{MODES.join(', ')}" unless MODES.include?(e['adjudication_mode'])

        expected = e['adjudication_mode'] == 'procedure' ? ENDORSEMENT_FIELDS_PROCEDURE : ENDORSEMENT_FIELDS_HAND
        keys = e.keys.sort
        raise ReproductionError, "endorsement fields must be exactly #{expected.join(', ')}, got #{keys.join(', ')}" unless keys == expected
        raise ReproductionError, "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(e['verdict'])
        (expected - %w[format verdict adjudication_mode]).each do |k|
          raise ReproductionError, "endorsement.#{k} must be 64-char lowercase hex" unless e[k].is_a?(String) && e[k].match?(HEX_DIGEST)
        end
        unless Entry.canonical_json(e) == endorsement_string.to_s
          raise ReproductionError, 'endorsement is not in canonical serialization (one record, one digest)'
        end

        e
      end

      # Sign an endorsement under the endorser's map-1 credential (map-1 §1.1
      # attestation signature; the payload is the endorsement record string).
      def sign_endorsement(endorsement_string, credential, key)
        parse_endorsement!(endorsement_string)
        ChainCredential.sign_attestation(credential, key, endorsement_string.to_s)
      end

      # Verify signature + structure. Returns true/false for the signature;
      # malformed endorsement raises (a verdict about an unresolvable record
      # would be noise dressed as judgment).
      def verify_endorsement(endorsement_string, credential, signature_hex)
        parse_endorsement!(endorsement_string)
        ChainCredential.verify_attestation(credential, endorsement_string.to_s, signature_hex)
      end

      # Foreignness conformance (RPR-4): a conforming rpr-1 endorsement's
      # issuer credential is NOT the operator credential of the chain the
      # target belongs to. Digest equality is the decidable surface at rpr-1;
      # distinctness is not independence (disclosed in the convention).
      def foreign?(endorser_credential, operator_credential)
        ChainCredential.credential_digest(endorser_credential) !=
          ChainCredential.credential_digest(operator_credential)
      end

      # -- declaration-set assessment (rpr-1 §2.1, RPR-3) --
      #
      # +targets+       Array of target record STRINGS (the resolvable universe).
      # +declarations+  Array of {'tolerance' => record string, 'position' => Integer}.
      # +invoked_tolerance_sha256+  digest the endorsement names.
      # +endorsement_position+      committed position of the endorsement.
      #
      # Reports the pooled anterior declaration set for the endorsement's
      # target AND its computation-identification siblings, multiplicity, the
      # invoked declaration's standing, and the unresolved residue. Diagnostic:
      # malformed declarations land in the residue, never raise.
      def assess_declarations(targets:, declarations:, invoked_tolerance_sha256:, endorsement_position:)
        pos = endorsement_position
        raise ReproductionError, 'endorsement_position must be an Integer' unless pos.is_a?(Integer)

        by_digest = {}
        Array(targets).each do |t|
          by_digest[Digest::SHA256.hexdigest(t.to_s)] = computation_id(t)
        rescue ReproductionError
          next # an unparsable target resolves nothing; bindings to it fall to residue
        end

        pooled = []
        residue = []
        seen = {}
        Array(declarations).each do |d|
          h = d.is_a?(Hash) ? d.transform_keys(&:to_s) : {}
          decl = h['tolerance'].to_s
          position = h['position']
          digest = Digest::SHA256.hexdigest(decl)
          begin
            t = parse_tolerance!(decl)
          rescue ReproductionError => e
            residue << { tolerance_sha256: digest, reason: "malformed declaration: #{e.message}" }
            next
          end
          unless position.is_a?(Integer)
            residue << { tolerance_sha256: digest, reason: 'no committed position supplied (anteriority undecidable)' }
            next
          end
          # A commitment is (digest, position); the same pair supplied twice is
          # one commitment, not two (one declaration, one digest — rpr-1 §2).
          next if seen[[digest, position]]

          seen[[digest, position]] = true
          comp = by_digest[t['target_sha256']]
          if comp.nil?
            residue << { tolerance_sha256: digest, target_sha256: t['target_sha256'],
                         reason: 'target unresolvable in supplied view (computation sharing undecidable)' }
            next
          end
          pooled << { tolerance_sha256: digest, target_sha256: t['target_sha256'],
                      computation_id: comp, position: position, anterior: position < pos }
        end

        # The invoked digest may be committed at several positions; anteriority
        # is a property of the committed record, not of presentation order
        # (RPR-3): conforming iff ANY anterior commitment exists, represented
        # by the earliest one, with posterior commitments disclosed.
        invoked_commitments = pooled.select { |e| e[:tolerance_sha256] == invoked_tolerance_sha256 }
        invoked_anterior = invoked_commitments.select { |e| e[:anterior] }.min_by { |e| e[:position] }
        invoked = invoked_anterior || invoked_commitments.min_by { |e| e[:position] }
        invoked_posterior = invoked_commitments.reject { |e| e[:anterior] }

        invoked_comp = invoked && invoked[:computation_id]
        set = invoked_comp.nil? ? [] : pooled.select { |e| e[:computation_id] == invoked_comp && e[:anterior] }
        # Deterministic report order (position, then digest): the report's
        # bytes, not just its quantities, are presentation-order-free.
        set = set.sort_by { |e| [e[:position], e[:tolerance_sha256]] }
        # Multiplicity counts distinct declarations (digests), not commitments;
        # rank is the invoked declaration's place in the pooled anterior set,
        # ordered by each declaration's earliest anterior position (rpr-1 §2.1).
        earliest = set.group_by { |e| e[:tolerance_sha256] }.transform_values { |es| es.map { |e| e[:position] }.min }
        # Digest tiebreak: equal earliest positions must not fall back to hash
        # insertion (= presentation) order — the rank, like the verdict, is a
        # function of the committed record alone (rpr-1 §2.1).
        ranked = earliest.sort_by { |d, p| [p, d] }.map(&:first)
        rank = invoked_anterior && (ranked.index(invoked_tolerance_sha256) + 1)
        {
          invoked: invoked,
          invoked_conforming: !invoked_anterior.nil?,
          invoked_posterior: invoked_posterior,
          invoked_rank: rank,
          declaration_set: set,
          multiplicity: ranked.size,
          residue: residue,
          note: if invoked.nil?
                  'invoked tolerance not found among supplied declarations (or unresolvable); nothing to assess'
                elsif invoked_anterior.nil?
                  'no anterior commitment of the invoked tolerance (RPR-3: non-conforming)'
                elsif ranked.size > 1
                  "#{ranked.size} anterior declaration(s) share the invoked computation identification; the menu is visible and priced by the reader (RPR-3)"
                else
                  'single anterior declaration for this computation'
                end
        }
      end

      # -- internal helpers --

      def json_object!(string, label)
        parsed = begin
          JSON.parse(string.to_s)
        rescue JSON::ParserError => e
          raise ReproductionError, "#{label} is not valid JSON: #{e.message}"
        end
        raise ReproductionError, "#{label} must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        parsed
      end

      def parse_record!(string, format, fields, label)
        parsed = json_object!(string, label)
        r = parsed.transform_keys(&:to_s)
        keys = r.keys.sort
        raise ReproductionError, "#{label} fields must be exactly #{fields.join(', ')}, got #{keys.join(', ')}" unless keys == fields
        raise ReproductionError, "unknown format #{r['format'].inspect} (#{format} only)" unless r['format'] == format

        yield r if block_given?
        unless Entry.canonical_json(r) == string.to_s
          raise ReproductionError, "#{label} is not in canonical serialization (one record, one digest)"
        end

        r
      end
    end
  end
end
